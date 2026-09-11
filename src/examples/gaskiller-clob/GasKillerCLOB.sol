// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title GasKillerCLOB
/// @notice A proof-of-concept spot central-limit-order-book (CLOB) DEX demonstrating the Gas Killer
///         "unbounded Solidity, O(1) on-chain state" pattern.
///
/// @dev ## The single-slot commitment
///      Every mutable piece of exchange state — user balances in the base and quote tokens plus the
///      entire open order book — is committed into ONE storage slot:
///
///        bits[255:64] = uint192(keccak256(canonical_state)[:24])   — 192-bit state hash
///        bits[63:0]   = uint64(block.timestamp at last transition)  — for emergency exit gate
///
///      Writes per transition: 1 (commitment slot) + 1 (StateTracker counter) = always O(1),
///      regardless of how many orders match or how many balances change.
///
/// @dev ## Two paths to advance state
///      1. **Standalone path** (`deposit`, `withdraw`, `placeOrder`, `cancelOrder`, `settleEpoch`):
///         the caller supplies a `CLOBState` witness. The contract verifies the witness against the
///         stored commitment, runs the operation in memory, and writes the new commitment. Fully
///         self-contained; the expensive `settleEpoch` call can run on-chain when the book is small.
///
///      2. **Gas Killer path** (inherited `verifyAndUpdate`): AVS operators run `settleEpoch` off-chain
///         under `SimProfile::UnboundedV1` (gas limit 2^40 ≈ 1.1 Tgas). With thousands of orders,
///         the insertion-sort matching loop alone exceeds any real block gas limit. Operators
///         BLS-sign a single `STORE(STATE_SLOT, newPacked)` payload; on-chain application is one
///         SSTORE. See `docs/UNBOUNDED_MODE.md` for the node/guest consistency requirements.
///
/// @dev ## Emergency exit
///      If no operator-applied `verifyAndUpdate` has landed in `EMERGENCY_DELAY` seconds (7 days),
///      any user who can supply a valid state witness may call `emergencyWithdraw` to reclaim funds.
///      This path does NOT call `trackState` (intentionally: it must not reset the inactivity timer
///      so that all users can exit even when the operator is permanently offline).
///
/// @dev ## Price convention
///      `Order.price` is quote-per-base in 1e18 fixed-point. For a ETH/USDC pair, price = 3000e18
///      means 3000 USDC per 1 ETH. Fill amounts: `fillQuote = fillSize * fillPrice / 1e18`.
contract GasKillerCLOB is GasKillerSDK {
    // =============================================================================================
    // State model
    // =============================================================================================

    /// @notice One user's balances in the two tokens
    struct Balance {
        address user;
        uint256 base;
        uint256 quote;
    }

    /// @notice A resting limit order
    struct Order {
        uint64 id;
        address maker;
        bool isBid;
        uint256 price;    // quote-per-base, 1e18 scaled
        uint256 size;     // remaining base amount
        uint64 placedAt;  // block.timestamp when placed; used for price-time priority tiebreaking
    }

    /// @notice The full expanded exchange state passed as a witness to every mutator
    struct CLOBState {
        uint64 nextOrderId;
        Balance[] balances;
        Order[] orders;
    }

    // =============================================================================================
    // Storage: exactly one mutable slot
    // =============================================================================================

    /// @notice The single storage slot committing the entire exchange state.
    /// @dev Derived per ERC-7201:
    ///      `keccak256(abi.encode(uint256(keccak256("gaskiller.clob.stateRoot")) - 1)) & ~bytes32(uint256(0xff))`
    bytes32 public constant STATE_SLOT =
        0xd3842c651d7dfa51aa7b515449be5772f634abf2d7fb90b065ffdc8da4ff0000;

    bytes32 private constant STATE_DOMAIN =
        0xb25e23626216d50125e9b023b4f9fd90f115392ee487c35c73b21455590be4e9; // keccak256("gaskiller.clob.state.v1")

    /// @notice How long without an operator transition before users may exit unilaterally
    uint256 public constant EMERGENCY_DELAY = 7 days;

    // =============================================================================================
    // Immutables
    // =============================================================================================

    IERC20 public immutable base;
    IERC20 public immutable quote;

    // =============================================================================================
    // Events
    // =============================================================================================

    event Deposit(address indexed user, bool indexed isBase, uint256 amount);
    event Withdrawal(address indexed user, bool indexed isBase, uint256 amount);
    event OrderPlaced(uint64 indexed orderId, address indexed maker, bool isBid, uint256 price, uint256 size);
    event OrderCancelled(uint64 indexed orderId);
    event EpochSettled(uint256 fills);
    event EmergencyWithdrawal(address indexed user, bool indexed isBase, uint256 amount);

    // =============================================================================================
    // Errors
    // =============================================================================================

    error StateWitnessMismatch(uint192 expected, uint192 provided);
    error NonCanonicalWitness();
    error InsufficientBalance(address user, bool isBase, uint256 balance, uint256 needed);
    error OrderNotFound(uint64 orderId);
    error NotOrderMaker(uint64 orderId, address caller);
    error EmergencyDelayNotMet(uint64 lastTransition, uint256 required);

    // =============================================================================================
    // Construction
    // =============================================================================================

    constructor(address _avsAddress, address _blsSigChecker, IERC20 _base, IERC20 _quote) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        base = _base;
        quote = _quote;
        // Write the empty-state commitment. Timestamp 0 means the emergency gate opens after 7 days
        // from epoch (i.e., immediately in practice); real deployments should call settleEpoch or
        // any other trackState function shortly after construction to reset the timer.
        CLOBState memory empty;
        empty.balances = new Balance[](0);
        empty.orders = new Order[](0);
        _writePacked(_stateHash(empty), 0);
    }

    // =============================================================================================
    // Standalone mutators — each writes exactly one storage slot (plus the trackState counter)
    // =============================================================================================

    /// @notice Deposit `amount` of the base or quote token into the exchange
    /// @param s Witness for the current exchange state
    /// @param isBase True to deposit the base token, false to deposit the quote token
    /// @param amount Token amount (in token's native decimals)
    function deposit(CLOBState memory s, bool isBase, uint256 amount) external trackState {
        CLOBState memory st = _load(s);
        if (isBase) {
            base.transferFrom(msg.sender, address(this), amount);
        } else {
            quote.transferFrom(msg.sender, address(this), amount);
        }
        st.balances = _credit(st.balances, msg.sender, isBase, amount);
        _writeState(st);
        emit Deposit(msg.sender, isBase, amount);
    }

    /// @notice Withdraw `amount` of the base or quote token from the exchange
    /// @param s Witness for the current exchange state
    /// @param isBase True to withdraw the base token, false to withdraw the quote token
    /// @param amount Token amount to withdraw
    function withdraw(CLOBState memory s, bool isBase, uint256 amount) external trackState {
        CLOBState memory st = _load(s);
        _debit(st.balances, msg.sender, isBase, amount);
        if (isBase) {
            base.transfer(msg.sender, amount);
        } else {
            quote.transfer(msg.sender, amount);
        }
        _writeState(st);
        emit Withdrawal(msg.sender, isBase, amount);
    }

    /// @notice Place a limit order; locks the required collateral from the caller's balance
    /// @param s Witness for the current exchange state
    /// @param isBid True for a buy-base order (locks quote), false for a sell-base order (locks base)
    /// @param price Quote-per-base in 1e18 fixed-point
    /// @param size Base amount
    function placeOrder(CLOBState memory s, bool isBid, uint256 price, uint256 size) external trackState {
        CLOBState memory st = _load(s);

        // Lock collateral up-front
        if (isBid) {
            _debit(st.balances, msg.sender, false, size * price / 1e18);
        } else {
            _debit(st.balances, msg.sender, true, size);
        }

        // Append the new order
        Order[] memory newOrders = new Order[](st.orders.length + 1);
        for (uint256 i = 0; i < st.orders.length; i++) newOrders[i] = st.orders[i];
        newOrders[st.orders.length] = Order({
            id: st.nextOrderId,
            maker: msg.sender,
            isBid: isBid,
            price: price,
            size: size,
            placedAt: uint64(block.timestamp)
        });
        uint64 newId = st.nextOrderId;
        st.nextOrderId++;
        st.orders = newOrders;

        _writeState(st);
        emit OrderPlaced(newId, msg.sender, isBid, price, size);
    }

    /// @notice Cancel a resting order and restore its locked collateral
    /// @param s Witness for the current exchange state
    /// @param orderId The order to cancel (caller must be the maker)
    function cancelOrder(CLOBState memory s, uint64 orderId) external trackState {
        CLOBState memory st = _load(s);

        (uint256 idx, bool found) = _indexOfOrder(st.orders, orderId);
        require(found, OrderNotFound(orderId));
        Order memory o = st.orders[idx];
        require(o.maker == msg.sender, NotOrderMaker(orderId, msg.sender));

        // Restore locked collateral
        if (o.isBid) {
            st.balances = _credit(st.balances, msg.sender, false, o.size * o.price / 1e18);
        } else {
            st.balances = _credit(st.balances, msg.sender, true, o.size);
        }
        st.orders = _removeOrder(st.orders, idx);

        _writeState(st);
        emit OrderCancelled(orderId);
    }

    /// @notice Match all crossing bid/ask pairs in price-time priority order.
    ///
    /// @dev This is the function Gas Killer operators execute **off-chain** under
    ///      `SimProfile::UnboundedV1`. With thousands of resting orders, the three O(N²)
    ///      insertion sorts (canonicalize + sort bids + sort asks) exceed any real block gas
    ///      limit. Operators sign the resulting single-slot commitment; on-chain application is
    ///      one SSTORE regardless of fill count.
    ///
    ///      Matching rules:
    ///      - Bids sorted by price descending, ties broken by `placedAt` ascending (FIFO).
    ///      - Asks sorted by price ascending, ties broken by `placedAt` ascending (FIFO).
    ///      - Fill at the resting ask price; overbid collateral refunded to the bid maker.
    ///      - Fully-filled orders removed; partial orders remain at the reduced size.
    ///
    /// @param s Witness for the current exchange state
    function settleEpoch(CLOBState memory s) external trackState {
        CLOBState memory st = _load(s);

        (Order[] memory bids, Order[] memory asks) = _splitAndSort(st.orders);

        uint256 bi = 0;
        uint256 ai = 0;
        uint256 fills = 0;

        while (bi < bids.length && ai < asks.length) {
            if (bids[bi].price < asks[ai].price) break;

            uint256 fillPrice = asks[ai].price;
            uint256 fillSize = bids[bi].size < asks[ai].size ? bids[bi].size : asks[ai].size;
            uint256 fillQuote = fillSize * fillPrice / 1e18;

            // Credit base to bid maker, quote to ask maker
            st.balances = _credit(st.balances, bids[bi].maker, true, fillSize);
            st.balances = _credit(st.balances, asks[ai].maker, false, fillQuote);

            // Refund overbid: bid locked (size * bid.price), paid (size * ask.price)
            uint256 lockedQuote = fillSize * bids[bi].price / 1e18;
            if (lockedQuote > fillQuote) {
                st.balances = _credit(st.balances, bids[bi].maker, false, lockedQuote - fillQuote);
            }

            bids[bi].size -= fillSize;
            asks[ai].size -= fillSize;
            if (bids[bi].size == 0) bi++;
            if (asks[ai].size == 0) ai++;
            fills++;
        }

        // Rebuild order list from remaining orders only
        uint256 remaining = 0;
        for (uint256 i = bi; i < bids.length; i++) if (bids[i].size > 0) remaining++;
        for (uint256 i = ai; i < asks.length; i++) if (asks[i].size > 0) remaining++;

        Order[] memory newOrders = new Order[](remaining);
        uint256 w = 0;
        for (uint256 i = bi; i < bids.length; i++) if (bids[i].size > 0) newOrders[w++] = bids[i];
        for (uint256 i = ai; i < asks.length; i++) if (asks[i].size > 0) newOrders[w++] = asks[i];
        st.orders = newOrders;

        _writeState(st);
        emit EpochSettled(fills);
    }

    // =============================================================================================
    // Emergency exit — bypasses trackState; does NOT reset the inactivity timer
    // =============================================================================================

    /// @notice Withdraw after the operator has been inactive for EMERGENCY_DELAY.
    /// @dev Intentionally does not call `trackState` so the inactivity timer is not reset,
    ///      allowing ALL users to exit even when the operator is permanently offline.
    /// @param s Witness for the current exchange state
    /// @param isBase Token to withdraw (true = base, false = quote)
    /// @param amount Amount to withdraw
    function emergencyWithdraw(CLOBState memory s, bool isBase, uint256 amount) external {
        uint64 last = lastTransitionAt();
        require(uint64(block.timestamp) - last > uint64(EMERGENCY_DELAY), EmergencyDelayNotMet(last, EMERGENCY_DELAY));

        CLOBState memory st = _load(s);
        _debit(st.balances, msg.sender, isBase, amount);
        if (isBase) {
            base.transfer(msg.sender, amount);
        } else {
            quote.transfer(msg.sender, amount);
        }
        // Update the state hash but preserve lastTransitionAt
        _writePacked(_stateHash(st), last);
        emit EmergencyWithdrawal(msg.sender, isBase, amount);
    }

    // =============================================================================================
    // Public views
    // =============================================================================================

    /// @notice Compute the canonical 192-bit commitment for any state (used by operators off-chain)
    function computeStateHash(CLOBState memory s) public pure returns (uint192) {
        return _stateHash(s);
    }

    /// @notice The 192-bit state hash stored in the upper bits of STATE_SLOT
    function stateHash() public view returns (uint192) {
        return uint192(_readPacked() >> 64);
    }

    /// @notice The timestamp of the last operator or user transition
    function lastTransitionAt() public view returns (uint64) {
        return uint64(uint256(_readPacked()));
    }

    // =============================================================================================
    // Internal — witness loading and state writing
    // =============================================================================================

    function _load(CLOBState memory s) private view returns (CLOBState memory) {
        uint192 provided = _stateHash(s);
        uint192 expected = stateHash();
        require(provided == expected, StateWitnessMismatch(expected, provided));
        // Return with canonicalized sub-structures so callers work on canonical form
        s.balances = _canonicalizeBalances(s.balances);
        s.orders = _canonicalizeOrders(s.orders);
        return s;
    }

    function _writeState(CLOBState memory s) private {
        _writePacked(_stateHash(s), uint64(block.timestamp));
    }

    function _writePacked(uint192 h, uint64 ts) private {
        uint256 packed = (uint256(h) << 64) | uint256(ts);
        assembly {
            sstore(STATE_SLOT, packed)
        }
    }

    function _readPacked() private view returns (uint256 packed) {
        assembly {
            packed := sload(STATE_SLOT)
        }
    }

    // =============================================================================================
    // Internal — commitment hashing
    // =============================================================================================

    function _stateHash(CLOBState memory s) private pure returns (uint192) {
        Balance[] memory cb = _canonicalizeBalances(s.balances);
        Order[] memory co = _canonicalizeOrders(s.orders);
        bytes32 h = keccak256(abi.encode(STATE_DOMAIN, s.nextOrderId, cb, co));
        return uint192(bytes24(h));
    }

    // =============================================================================================
    // Internal — canonicalization
    // =============================================================================================

    /// @dev Sort balances by user ascending; reject duplicate users; drop zero entries.
    ///      O(N²) insertion sort — N = number of unique users.
    function _canonicalizeBalances(Balance[] memory b) private pure returns (Balance[] memory) {
        uint256 n = b.length;
        for (uint256 i = 1; i < n; i++) {
            Balance memory key = b[i];
            uint256 j = i;
            while (j > 0 && uint160(b[j - 1].user) > uint160(key.user)) {
                b[j] = b[j - 1];
                j--;
            }
            b[j] = key;
        }
        uint256 kept = 0;
        for (uint256 i = 0; i < n; i++) {
            if (i > 0) require(b[i].user != b[i - 1].user, NonCanonicalWitness());
            if (b[i].base > 0 || b[i].quote > 0) kept++;
        }
        Balance[] memory out = new Balance[](kept);
        uint256 w = 0;
        for (uint256 i = 0; i < n; i++) {
            if (b[i].base > 0 || b[i].quote > 0) out[w++] = b[i];
        }
        return out;
    }

    /// @dev Sort orders by id ascending; reject duplicate ids.
    ///      O(N²) insertion sort — N = number of open orders.
    function _canonicalizeOrders(Order[] memory orders) private pure returns (Order[] memory) {
        uint256 n = orders.length;
        for (uint256 i = 1; i < n; i++) {
            Order memory key = orders[i];
            uint256 j = i;
            while (j > 0 && orders[j - 1].id > key.id) {
                orders[j] = orders[j - 1];
                j--;
            }
            orders[j] = key;
        }
        for (uint256 i = 1; i < n; i++) {
            require(orders[i].id != orders[i - 1].id, NonCanonicalWitness());
        }
        return orders;
    }

    // =============================================================================================
    // Internal — price-time sort for matching
    // =============================================================================================

    /// @dev Separate orders into bids and asks, then sort each group for price-time priority matching.
    ///      This is the main source of O(N²) cost in settleEpoch for large books.
    function _splitAndSort(Order[] memory orders)
        private
        pure
        returns (Order[] memory bids, Order[] memory asks)
    {
        uint256 nb;
        uint256 na;
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].isBid) nb++;
            else na++;
        }
        bids = new Order[](nb);
        asks = new Order[](na);
        uint256 bi;
        uint256 ai;
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].isBid) bids[bi++] = orders[i];
            else asks[ai++] = orders[i];
        }
        _sortBids(bids);
        _sortAsks(asks);
    }

    /// @dev Insertion sort bids: price descending, tie-break by placedAt ascending (FIFO).
    ///      O(N²) worst case — N = number of bids. This is intentional: the unbounded-mode demo
    ///      exploits this cost to prove settleEpoch exceeds the block gas limit for large N.
    function _sortBids(Order[] memory orders) private pure {
        uint256 n = orders.length;
        for (uint256 i = 1; i < n; i++) {
            Order memory key = orders[i];
            uint256 j = i;
            while (j > 0) {
                Order memory prev = orders[j - 1];
                if (prev.price > key.price || (prev.price == key.price && prev.placedAt <= key.placedAt)) break;
                orders[j] = prev;
                j--;
            }
            orders[j] = key;
        }
    }

    /// @dev Insertion sort asks: price ascending, tie-break by placedAt ascending (FIFO).
    function _sortAsks(Order[] memory orders) private pure {
        uint256 n = orders.length;
        for (uint256 i = 1; i < n; i++) {
            Order memory key = orders[i];
            uint256 j = i;
            while (j > 0) {
                Order memory prev = orders[j - 1];
                if (prev.price < key.price || (prev.price == key.price && prev.placedAt <= key.placedAt)) break;
                orders[j] = prev;
                j--;
            }
            orders[j] = key;
        }
    }

    // =============================================================================================
    // Internal — in-memory balance manipulation
    // =============================================================================================

    function _credit(Balance[] memory b, address user, bool isBase, uint256 amount)
        private
        pure
        returns (Balance[] memory)
    {
        if (amount == 0) return b;
        (uint256 idx, bool found) = _indexOfUser(b, user);
        if (found) {
            if (isBase) b[idx].base += amount;
            else b[idx].quote += amount;
            return b;
        }
        Balance[] memory out = new Balance[](b.length + 1);
        for (uint256 i = 0; i < b.length; i++) out[i] = b[i];
        out[b.length] = Balance({user: user, base: isBase ? amount : 0, quote: isBase ? 0 : amount});
        return out;
    }

    function _debit(Balance[] memory b, address user, bool isBase, uint256 amount) private pure {
        (uint256 idx, bool found) = _indexOfUser(b, user);
        uint256 bal = found ? (isBase ? b[idx].base : b[idx].quote) : 0;
        require(bal >= amount, InsufficientBalance(user, isBase, bal, amount));
        if (isBase) b[idx].base -= amount;
        else b[idx].quote -= amount;
    }

    function _indexOfUser(Balance[] memory b, address user) private pure returns (uint256 idx, bool found) {
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i].user == user) return (i, true);
        }
    }

    function _indexOfOrder(Order[] memory orders, uint64 orderId) private pure returns (uint256 idx, bool found) {
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].id == orderId) return (i, true);
        }
    }

    function _removeOrder(Order[] memory orders, uint256 idx) private pure returns (Order[] memory) {
        Order[] memory out = new Order[](orders.length - 1);
        for (uint256 i = 0; i < idx; i++) out[i] = orders[i];
        for (uint256 i = idx + 1; i < orders.length; i++) out[i - 1] = orders[i];
        return out;
    }
}
