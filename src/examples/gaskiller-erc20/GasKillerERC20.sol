// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";

/// @title GasKillerERC20
/// @notice An ERC20 whose *entire* mutable state — `totalSupply`, every account balance, and every
///         allowance — is rolled up ("committed") into a SINGLE storage slot.
/// @dev ## Why a single slot?
///      A conventional ERC20 keeps balances/allowances in `mapping`s, so a `transfer` performs at least
///      two `SSTORE`s (debit + credit) and a `mint` performs two (`balanceOf` + `totalSupply`). The
///      number of storage writes scales with how many accounts a transition touches.
///
///      GasKillerERC20 instead stores only a 32-byte **commitment** to the full token state in one slot
///      (`STATE_ROOT_SLOT`). The authoritative, expanded state lives off-chain (with the Gas Killer AVS
///      operators). Every state transition — no matter how many logical accounts it moves — recomputes
///      the commitment and writes it back with exactly ONE `SSTORE`. Storage writes are therefore always
///      O(1):
///
///        writes per transition = 1 (commitment)  +  1 (StateTracker counter, from `trackState`)
///
///      ## Two ways to advance state
///      1. **Standalone / reference path** (this contract's `transfer`, `approve`, ... functions): the
///         caller passes the current expanded state as a `TokenState` *witness*. The contract verifies
///         the witness hashes to the stored commitment, applies the operation in memory, and writes the
///         new commitment. This makes the contract fully self-contained and unit-testable without any
///         operators. It is the "expensive" path (O(n) calldata/hashing) — the on-chain analogue of
///         `ArraySummation.sum()`.
///      2. **Gas Killer path** (inherited `verifyAndUpdate`): AVS operators compute the new commitment
///         off-chain, BLS-sign a payload containing a single `STORE(STATE_ROOT_SLOT, newRoot)` op, and
///         submit it. On-chain this is one `STORE` + the `trackState` counter — O(1) in everything.
///
///      Both paths reach identical commitments because both use the same canonical hashing rules
///      (`computeStateRoot`). Operators simply run `computeStateRoot` off-chain.
///
///      ## Reads
///      Because balances are not individually stored, `balanceOf` / `allowance` / `totalSupply` take a
///      `TokenState` witness and are verified against the commitment before answering. Off-chain the
///      operators (or any indexer that tracks the committed state) serve these reads.
///
///      ## Trust model
///      The Gas Killer path trusts the BLS quorum to compute a correct `newRoot`; the contract does not
///      re-run transition logic on-chain (that is the whole point of Gas Killer). The standalone path
///      trusts nothing — it verifies the witness and recomputes the root itself. As a fail-closed
///      backstop even against a faulty quorum, every load also checks the supply-conservation invariant
///      (`sum(balances) == totalSupply`), so an inflationary commitment becomes unusable.
///
///      ## Operator responsibilities (Gas Killer path)
///      - Compute `newRoot` from the *current* committed state with `computeStateRoot` (the same rules
///        the contract uses). The `verifyAndUpdate` `transitionIndex` check strictly orders updates, so a
///        root computed against a stale state reverts rather than corrupting the token.
///      - Emit faithful ERC20 events. Because applying a `STORE` does not run transfer logic, operators
///        should append `LOG3`/`LOG2` ops for each logical `Transfer`/`Approval` in the same signed
///        payload (they are covered by the signature). Storage writes stay O(1); only logs scale with
///        the batch. See `test/examples/GasKillerERC20.t.sol` for the faithful-event pattern.
///
///      ## Liveness note
///      A standalone mutator verifies its witness against the *current* commitment; if another
///      transition lands first the witness is stale and the call reverts (fail-closed, no fund risk).
///      Callers rebuild the witness from the latest root and retry — the standalone path is optimistic
///      concurrency, and the operator batch is the intended high-throughput route.
contract GasKillerERC20 is GasKillerSDK {
    // ---------------------------------------------------------------------------------------------
    // State model
    // ---------------------------------------------------------------------------------------------

    /// @notice A single `owner -> spender` allowance entry
    struct Allowance {
        /// @notice The spender authorised to move the owner's tokens
        address spender;
        /// @notice The remaining approved amount
        uint256 amount;
    }

    /// @notice One account's slice of the token state: its balance plus the allowances it has granted
    struct Account {
        /// @notice The account address
        address owner;
        /// @notice The account's token balance
        uint256 balance;
        /// @notice Allowances this account has granted to spenders
        Allowance[] allowances;
    }

    /// @notice The complete, expanded token state that the on-chain commitment commits to
    /// @dev Passed as a *witness* to reads and to the standalone mutators. Any representation of a given
    ///      logical state is accepted — the contract canonicalises it before hashing (see
    ///      `computeStateRoot`), so ordering and zero-valued entries do not matter to the caller.
    struct TokenState {
        /// @notice The total token supply
        uint256 totalSupply;
        /// @notice Every account with a non-zero balance and/or at least one allowance
        Account[] accounts;
    }

    // ---------------------------------------------------------------------------------------------
    // Storage: exactly one mutable slot
    // ---------------------------------------------------------------------------------------------

    /// @notice The single storage slot holding the commitment to the entire mutable token state
    /// @dev Derived per ERC-7201:
    ///      `keccak256(abi.encode(uint256(keccak256("gaskiller.erc20.stateRoot")) - 1)) & ~bytes32(uint256(0xff))`.
    ///      This is the *only* storage slot this contract ever writes during a state transition, and it
    ///      is the slot operators target with their single `STORE` op in the Gas Killer path.
    bytes32 public constant STATE_ROOT_SLOT = 0x49bc0cd4d462775d6259c19b13640f4b39061d6257821c1d7377a437ae3c0700;

    /// @notice Domain separator mixed into the commitment to prevent cross-context hash collisions
    bytes32 private constant STATE_DOMAIN = keccak256("gaskiller.erc20.state.v1");

    // ---------------------------------------------------------------------------------------------
    // Metadata: immutable, occupies zero storage slots (lives in bytecode)
    // ---------------------------------------------------------------------------------------------

    /// @notice The number of decimals the token uses
    uint8 public constant decimals = 18;

    /// @notice Address permitted to `mint`; `address(0)` disables minting (fixed supply)
    address public immutable minter;

    bytes32 private immutable _nameWord;
    bytes32 private immutable _symbolWord;
    uint256 private immutable _nameLen;
    uint256 private immutable _symbolLen;

    // ---------------------------------------------------------------------------------------------
    // Events (ERC20)
    // ---------------------------------------------------------------------------------------------

    /// @notice Emitted when `value` tokens move from `from` to `to` (mint: from==0, burn: to==0)
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when `owner` sets `spender`'s allowance to `value`
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice Thrown when the supplied `TokenState` witness does not hash to the on-chain commitment
    /// @param expected The commitment currently stored on-chain
    /// @param provided The commitment computed from the supplied witness
    error StateWitnessMismatch(bytes32 expected, bytes32 provided);

    /// @notice Thrown when a witness contains duplicate owners or duplicate spenders (ambiguous state)
    error NonCanonicalWitness();

    /// @notice Thrown when a witness's balances do not sum to its declared `totalSupply`
    /// @dev Fail-closed guard: every state reachable through the honest API conserves supply, so this
    ///      can only fire on a malformed/malicious commitment (e.g. an operator that signed an
    ///      inflationary root). It makes silent inflation unreadable rather than merely unlikely.
    error SupplyInvariantBroken(uint256 totalSupply, uint256 balanceSum);

    /// @notice Thrown when an account cannot cover a debit
    error InsufficientBalance(address owner, uint256 balance, uint256 needed);

    /// @notice Thrown when a spender's allowance cannot cover a `transferFrom`
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 needed);

    /// @notice Thrown when `mint` is called by an account other than `minter`
    error NotMinter();

    /// @notice Thrown when transferring or minting to the zero address
    error TransferToZeroAddress();

    /// @notice Thrown when a name/symbol longer than 32 bytes is supplied at construction
    error MetadataTooLong();

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploy a GasKillerERC20 and commit its initial state
    /// @param _avsAddress The AVS service manager address used for BLS quorum validation
    /// @param _blsSigChecker The BLS signature checker contract address
    /// @param name_ Token name (must be <= 32 bytes)
    /// @param symbol_ Token symbol (must be <= 32 bytes)
    /// @param _minter Address allowed to mint; pass `address(0)` for a fixed-supply token
    /// @param initialHolder Recipient of the initial supply (ignored when `initialSupply == 0`)
    /// @param initialSupply Amount minted to `initialHolder` at construction
    constructor(
        address _avsAddress,
        address _blsSigChecker,
        string memory name_,
        string memory symbol_,
        address _minter,
        address initialHolder,
        uint256 initialSupply
    ) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);

        (_nameWord, _nameLen) = _pack(name_);
        (_symbolWord, _symbolLen) = _pack(symbol_);
        minter = _minter;

        // Build the initial expanded state, then commit it with a single write.
        TokenState memory initial;
        if (initialSupply > 0) {
            require(initialHolder != address(0), TransferToZeroAddress());
            initial.totalSupply = initialSupply;
            initial.accounts = new Account[](1);
            initial.accounts[0].owner = initialHolder;
            initial.accounts[0].balance = initialSupply;
            emit Transfer(address(0), initialHolder, initialSupply);
        }
        _writeRoot(computeStateRoot(initial));
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata getters
    // ---------------------------------------------------------------------------------------------

    /// @notice The token name
    function name() public view returns (string memory) {
        return _unpack(_nameWord, _nameLen);
    }

    /// @notice The token symbol
    function symbol() public view returns (string memory) {
        return _unpack(_symbolWord, _symbolLen);
    }

    // ---------------------------------------------------------------------------------------------
    // Commitment access
    // ---------------------------------------------------------------------------------------------

    /// @notice Return the current on-chain commitment to the token state
    /// @return root The 32-byte commitment stored in `STATE_ROOT_SLOT`
    function stateRoot() public view returns (bytes32 root) {
        assembly {
            root := sload(STATE_ROOT_SLOT)
        }
    }

    /// @notice Compute the canonical commitment for an expanded token state
    /// @dev This is the single source of truth for the commitment. Off-chain operators run the same
    ///      computation to produce the `newRoot` they submit through `verifyAndUpdate`. The input may be
    ///      in any order and may contain zero-valued entries; it is canonicalised first (see
    ///      `_canonicalize`), so equal logical states always yield the same root.
    /// @param s The expanded token state
    /// @return The canonical commitment
    function computeStateRoot(TokenState memory s) public pure returns (bytes32) {
        return _hashState(s.totalSupply, _canonicalize(s.accounts));
    }

    // ---------------------------------------------------------------------------------------------
    // Reads (witness-verified)
    // ---------------------------------------------------------------------------------------------

    /// @notice Return `account`'s balance, verifying `s` against the on-chain commitment first
    /// @param s A witness for the current token state
    /// @param account The account to query
    /// @return The balance of `account` (0 if absent)
    function balanceOf(TokenState memory s, address account) public view returns (uint256) {
        (Account[] memory accounts,) = _load(s);
        (uint256 idx, bool found) = _indexOfOwner(accounts, account);
        return found ? accounts[idx].balance : 0;
    }

    /// @notice Return the `owner -> spender` allowance, verifying `s` against the commitment first
    /// @param s A witness for the current token state
    /// @param owner The token owner
    /// @param spender The approved spender
    /// @return The remaining allowance (0 if absent)
    function allowance(TokenState memory s, address owner, address spender) public view returns (uint256) {
        (Account[] memory accounts,) = _load(s);
        return _getAllowance(accounts, owner, spender);
    }

    /// @notice Return the total supply, verifying `s` against the commitment first
    /// @param s A witness for the current token state
    /// @return The total supply
    function totalSupply(TokenState memory s) public view returns (uint256) {
        (, uint256 supply) = _load(s);
        return supply;
    }

    // ---------------------------------------------------------------------------------------------
    // Mutators (standalone / reference path) — each writes exactly one storage slot
    // ---------------------------------------------------------------------------------------------

    /// @notice Move `amount` tokens from the caller to `to`
    /// @param s A witness for the current token state
    /// @param to Recipient of the tokens
    /// @param amount Number of tokens to move
    /// @return Always true on success (ERC20 convention)
    function transfer(TokenState memory s, address to, uint256 amount) public trackState returns (bool) {
        require(to != address(0), TransferToZeroAddress());
        (Account[] memory accounts, uint256 supply) = _load(s);

        address from = msg.sender;
        _debit(accounts, from, amount);
        accounts = _credit(accounts, to, amount);

        _writeRoot(_hashState(supply, _canonicalize(accounts)));
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Move `amount` tokens from `from` to `to` using the caller's allowance
    /// @param s A witness for the current token state
    /// @param from The account whose tokens are moved
    /// @param to Recipient of the tokens
    /// @param amount Number of tokens to move
    /// @return Always true on success (ERC20 convention)
    function transferFrom(TokenState memory s, address from, address to, uint256 amount)
        public
        trackState
        returns (bool)
    {
        require(to != address(0), TransferToZeroAddress());
        (Account[] memory accounts, uint256 supply) = _load(s);

        address spender = msg.sender;
        uint256 current = _getAllowance(accounts, from, spender);
        // Treat max allowance as infinite: do not decrement (standard ERC20 optimisation).
        if (current != type(uint256).max) {
            require(current >= amount, InsufficientAllowance(from, spender, current, amount));
            accounts = _setAllowance(accounts, from, spender, current - amount);
        }

        _debit(accounts, from, amount);
        accounts = _credit(accounts, to, amount);

        _writeRoot(_hashState(supply, _canonicalize(accounts)));
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Set `spender`'s allowance over the caller's tokens to `amount`
    /// @param s A witness for the current token state
    /// @param spender The spender being approved
    /// @param amount The new allowance
    /// @return Always true on success (ERC20 convention)
    function approve(TokenState memory s, address spender, uint256 amount) public trackState returns (bool) {
        (Account[] memory accounts, uint256 supply) = _load(s);

        address owner = msg.sender;
        accounts = _setAllowance(accounts, owner, spender, amount);

        _writeRoot(_hashState(supply, _canonicalize(accounts)));
        emit Approval(owner, spender, amount);
        return true;
    }

    /// @notice Mint `amount` new tokens to `to` (only callable by `minter`)
    /// @param s A witness for the current token state
    /// @param to Recipient of the newly minted tokens
    /// @param amount Number of tokens to mint
    function mint(TokenState memory s, address to, uint256 amount) public trackState {
        require(msg.sender == minter, NotMinter());
        require(to != address(0), TransferToZeroAddress());
        (Account[] memory accounts, uint256 supply) = _load(s);

        supply += amount; // checked arithmetic guards against supply overflow
        accounts = _credit(accounts, to, amount);

        _writeRoot(_hashState(supply, _canonicalize(accounts)));
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn `amount` of the caller's tokens
    /// @param s A witness for the current token state
    /// @param amount Number of tokens to burn
    function burn(TokenState memory s, uint256 amount) public trackState {
        (Account[] memory accounts, uint256 supply) = _load(s);

        address from = msg.sender;
        _debit(accounts, from, amount);
        supply -= amount; // safe: _debit guarantees from's balance (<= supply) covered `amount`

        _writeRoot(_hashState(supply, _canonicalize(accounts)));
        emit Transfer(from, address(0), amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal: witness verification
    // ---------------------------------------------------------------------------------------------

    /// @notice Verify `s` against the on-chain commitment and return its canonical, expanded form
    /// @param s The witness to verify
    /// @return accounts The canonicalised account set (sorted by owner, zero entries dropped)
    /// @return supply The verified total supply
    function _load(TokenState memory s) private view returns (Account[] memory accounts, uint256 supply) {
        accounts = _canonicalize(s.accounts);
        bytes32 provided = _hashState(s.totalSupply, accounts);
        bytes32 expected = stateRoot();
        require(provided == expected, StateWitnessMismatch(expected, provided));
        supply = s.totalSupply;

        // Enforce conservation: balances must sum to totalSupply. Reachable states always satisfy this
        // (the constructor and every mutator preserve it), so this only rejects a malformed commitment.
        uint256 balanceSum;
        for (uint256 i = 0; i < accounts.length; i++) {
            balanceSum += accounts[i].balance; // checked; partial sums never exceed a valid totalSupply
        }
        require(balanceSum == supply, SupplyInvariantBroken(supply, balanceSum));
    }

    /// @notice Hash a canonical (already sorted/compacted) state into its commitment
    function _hashState(uint256 supply, Account[] memory canonicalAccounts) private pure returns (bytes32) {
        return keccak256(abi.encode(STATE_DOMAIN, supply, canonicalAccounts));
    }

    // ---------------------------------------------------------------------------------------------
    // Internal: canonicalisation (guarantees one commitment per logical state)
    // ---------------------------------------------------------------------------------------------

    /// @notice Produce the canonical form of an account set: allowances canonicalised, accounts sorted
    ///         strictly ascending by owner, and empty accounts (zero balance and no allowances) removed
    /// @dev Reverts on duplicate owners so a logical state has exactly one canonical representation.
    ///      Mutates the input array in place while sorting; callers pass throwaway memory copies.
    function _canonicalize(Account[] memory accounts) private pure returns (Account[] memory) {
        uint256 n = accounts.length;

        // Canonicalise each account's allowances first.
        for (uint256 i = 0; i < n; i++) {
            accounts[i].allowances = _canonicalizeAllowances(accounts[i].allowances);
        }

        // Insertion sort by owner ascending.
        for (uint256 i = 1; i < n; i++) {
            Account memory key = accounts[i];
            uint256 j = i;
            while (j > 0 && uint160(accounts[j - 1].owner) > uint160(key.owner)) {
                accounts[j] = accounts[j - 1];
                j--;
            }
            accounts[j] = key;
        }

        // Count survivors and reject duplicate owners.
        uint256 kept = 0;
        for (uint256 i = 0; i < n; i++) {
            if (i > 0) {
                require(accounts[i].owner != accounts[i - 1].owner, NonCanonicalWitness());
            }
            if (accounts[i].balance != 0 || accounts[i].allowances.length != 0) {
                kept++;
            }
        }

        // Compact out empty accounts.
        Account[] memory out = new Account[](kept);
        uint256 w = 0;
        for (uint256 i = 0; i < n; i++) {
            if (accounts[i].balance != 0 || accounts[i].allowances.length != 0) {
                out[w++] = accounts[i];
            }
        }
        return out;
    }

    /// @notice Canonical form of an allowance list: sorted strictly ascending by spender, zero amounts
    ///         removed, duplicate spenders rejected
    function _canonicalizeAllowances(Allowance[] memory allowances) private pure returns (Allowance[] memory) {
        uint256 n = allowances.length;

        for (uint256 i = 1; i < n; i++) {
            Allowance memory key = allowances[i];
            uint256 j = i;
            while (j > 0 && uint160(allowances[j - 1].spender) > uint160(key.spender)) {
                allowances[j] = allowances[j - 1];
                j--;
            }
            allowances[j] = key;
        }

        uint256 kept = 0;
        for (uint256 i = 0; i < n; i++) {
            if (i > 0) {
                require(allowances[i].spender != allowances[i - 1].spender, NonCanonicalWitness());
            }
            if (allowances[i].amount != 0) {
                kept++;
            }
        }

        Allowance[] memory out = new Allowance[](kept);
        uint256 w = 0;
        for (uint256 i = 0; i < n; i++) {
            if (allowances[i].amount != 0) {
                out[w++] = allowances[i];
            }
        }
        return out;
    }

    // ---------------------------------------------------------------------------------------------
    // Internal: in-memory state manipulation
    // ---------------------------------------------------------------------------------------------

    /// @notice Locate an owner in a canonical account set
    function _indexOfOwner(Account[] memory accounts, address owner) private pure returns (uint256 idx, bool found) {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i].owner == owner) {
                return (i, true);
            }
        }
        return (0, false);
    }

    /// @notice Locate a spender in an allowance list
    function _indexOfSpender(Allowance[] memory allowances, address spender)
        private
        pure
        returns (uint256 idx, bool found)
    {
        for (uint256 i = 0; i < allowances.length; i++) {
            if (allowances[i].spender == spender) {
                return (i, true);
            }
        }
        return (0, false);
    }

    /// @notice Reduce `from`'s balance by `amount`, reverting if it cannot cover it
    /// @dev No reallocation: an existing account is edited in place; an absent account has balance 0 and
    ///      so only a zero debit succeeds.
    function _debit(Account[] memory accounts, address from, uint256 amount) private pure {
        (uint256 idx, bool found) = _indexOfOwner(accounts, from);
        uint256 balance = found ? accounts[idx].balance : 0;
        require(balance >= amount, InsufficientBalance(from, balance, amount));
        if (found) {
            accounts[idx].balance = balance - amount;
        }
    }

    /// @notice Increase `to`'s balance by `amount`, appending a new account when `to` is absent
    /// @return The (possibly reallocated) account set
    function _credit(Account[] memory accounts, address to, uint256 amount) private pure returns (Account[] memory) {
        if (amount == 0) {
            return accounts;
        }
        (uint256 idx, bool found) = _indexOfOwner(accounts, to);
        if (found) {
            accounts[idx].balance += amount;
            return accounts;
        }
        Account[] memory out = new Account[](accounts.length + 1);
        for (uint256 i = 0; i < accounts.length; i++) {
            out[i] = accounts[i];
        }
        out[accounts.length] = Account({owner: to, balance: amount, allowances: new Allowance[](0)});
        return out;
    }

    /// @notice Read the `owner -> spender` allowance from a canonical account set
    function _getAllowance(Account[] memory accounts, address owner, address spender) private pure returns (uint256) {
        (uint256 idx, bool found) = _indexOfOwner(accounts, owner);
        if (!found) {
            return 0;
        }
        (uint256 aIdx, bool aFound) = _indexOfSpender(accounts[idx].allowances, spender);
        return aFound ? accounts[idx].allowances[aIdx].amount : 0;
    }

    /// @notice Set the `owner -> spender` allowance to `amount`
    /// @dev Creates the owner account and/or the allowance entry as needed. Setting `amount == 0` simply
    ///      relies on later canonicalisation to drop the (now zero) entry. Does not emit `Approval`;
    ///      callers that represent an explicit approval do so themselves.
    /// @return The (possibly reallocated) account set
    function _setAllowance(Account[] memory accounts, address owner, address spender, uint256 amount)
        private
        pure
        returns (Account[] memory)
    {
        (uint256 idx, bool found) = _indexOfOwner(accounts, owner);

        if (!found) {
            if (amount == 0) {
                return accounts;
            }
            // Append a new owner account carrying a single allowance.
            Account[] memory out = new Account[](accounts.length + 1);
            for (uint256 i = 0; i < accounts.length; i++) {
                out[i] = accounts[i];
            }
            Allowance[] memory one = new Allowance[](1);
            one[0] = Allowance({spender: spender, amount: amount});
            out[accounts.length] = Account({owner: owner, balance: 0, allowances: one});
            return out;
        }

        Allowance[] memory current = accounts[idx].allowances;
        (uint256 aIdx, bool aFound) = _indexOfSpender(current, spender);
        if (aFound) {
            current[aIdx].amount = amount;
            return accounts;
        }
        if (amount == 0) {
            return accounts;
        }
        // Append a new allowance entry to this account.
        Allowance[] memory expanded = new Allowance[](current.length + 1);
        for (uint256 i = 0; i < current.length; i++) {
            expanded[i] = current[i];
        }
        expanded[current.length] = Allowance({spender: spender, amount: amount});
        accounts[idx].allowances = expanded;
        return accounts;
    }

    // ---------------------------------------------------------------------------------------------
    // Internal: commitment slot & metadata helpers
    // ---------------------------------------------------------------------------------------------

    /// @notice Write `root` to the single commitment slot (the only transition-time storage write)
    function _writeRoot(bytes32 root) private {
        assembly {
            sstore(STATE_ROOT_SLOT, root)
        }
    }

    /// @notice Pack a <=32-byte string into a single word plus its length
    function _pack(string memory value) private pure returns (bytes32 word, uint256 length) {
        bytes memory raw = bytes(value);
        require(raw.length <= 32, MetadataTooLong());
        length = raw.length;
        assembly {
            word := mload(add(raw, 0x20))
        }
    }

    /// @notice Reconstruct a string from its packed word and length
    function _unpack(bytes32 word, uint256 length) private pure returns (string memory) {
        bytes memory raw = new bytes(length);
        assembly {
            mstore(add(raw, 0x20), word)
        }
        return string(raw);
    }
}
