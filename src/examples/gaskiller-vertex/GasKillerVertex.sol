// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title GasKillerVertex
/// @notice A proof-of-concept CROSS-MARGIN PERPETUAL-FUTURES DEX demonstrating the Gas Killer
///         "unbounded off-chain compute, O(1) on-chain state" pattern — the derivatives analogue
///         of `GasKillerCLOB`. It is a clean-room reimplementation of the *architecture* of a
///         Vertex-style exchange (a sequencer that posts oracle prices and batches off-chain-ordered
///         actions; a cross-margin clearinghouse; a perp engine with funding; health-based
///         liquidations), NOT a port of Vertex's GPL-2.0 source.
///
/// @dev ## The single-slot commitment
///      The ENTIRE mutable exchange — every account's quote collateral and open perp positions,
///      every resting order, every market's oracle price and cumulative funding index, and the
///      insurance-fund balance — is committed into ONE storage slot:
///
///        bits[255:64] = uint192(keccak256(canonical_state)[:24])   — 192-bit state hash
///        bits[63:0]   = uint64(block.timestamp at last transition)  — for the emergency-exit gate
///
///      Writes per transition are always O(1): 1 (commitment slot) + 1 (StateTracker counter),
///      regardless of how many accounts, positions, orders, funding accruals, or liquidations the
///      transition processed.
///
/// @dev ## Two paths to advance state (identical to GasKillerCLOB)
///      1. **Standalone path** — the caller supplies a `ExchangeState` witness; the contract verifies
///         it against the stored commitment, runs the operation in memory, and writes the new
///         commitment. The expensive `settleEpoch` matching runs here when the book is small.
///      2. **Gas Killer path** (inherited `verifyAndUpdate`) — AVS operators run `settleEpoch`
///         off-chain under `SimProfile::UnboundedV1`; the cross-market matching plus the
///         cross-account funding/liquidation sweep exceeds any real block gas limit. Operators
///         BLS-sign a single `STORE(STATE_SLOT, newPacked)` payload; on-chain application is one SSTORE.
///
/// @dev ## Cross-margin accounting (WAD = 1e18 fixed point)
///      A perp position never moves the quote token at fill time — only margin is at risk. An
///      account's *equity* is its quote collateral plus unrealized PnL minus funding owed:
///
///        equity(a) = a.collateral
///                    + Σ_i  size_i * (oracle_i − avgEntry_i) / 1e18     (unrealized PnL, signed)
///                    − Σ_i  size_i * (cumFunding_i − entryFunding_i) / 1e18  (funding owed, signed)
///
///        initialMargin(a)     = Σ_i |size_i| * oracle_i * imf_i / 1e36
///        maintenanceMargin(a) = Σ_i |size_i| * oracle_i * mmf_i / 1e36
///
///      Withdrawals and order placement require `equity ≥ initialMargin` (counting the prospective
///      fill). An account with `equity < maintenanceMargin` is liquidatable by anyone.
///
/// @dev ## Emergency exit
///      If no transition lands for `EMERGENCY_DELAY` (7 days), any user with no open positions may
///      `emergencyWithdraw` their free collateral. This path deliberately omits `trackState` so it
///      does not reset the inactivity timer — all users can exit if the operator is permanently offline.
contract GasKillerVertex is GasKillerSDK {
    // =============================================================================================
    // State model
    // =============================================================================================

    /// @notice A perp position within a cross-margin account
    struct Position {
        uint32 marketId;
        int256 size; // signed base amount: +long, −short (WAD)
        int256 avgEntry; // volume-weighted entry price (WAD quote-per-base)
        int256 entryFunding; // market.cumFunding snapshot when funding was last realized on this position
    }

    /// @notice A cross-margin account
    struct Account {
        address owner;
        int256 collateral; // quote balance (WAD); may go negative = bad debt
        Position[] positions;
    }

    /// @notice A resting limit order (spot-style book over a perp market)
    struct Order {
        uint64 id;
        address maker;
        uint32 marketId;
        bool isBid; // true = buy base (open/increase long), false = sell base
        uint256 price; // WAD quote-per-base
        uint256 size; // remaining base amount (WAD)
        uint64 placedAt; // for price-time priority tiebreak
    }

    /// @notice A perpetual market
    struct Market {
        uint32 id;
        uint256 oracle; // mark/index price (WAD quote-per-base)
        int256 cumFunding; // cumulative funding index (WAD quote-per-base); longs pay when it rises
        uint256 imf; // initial margin fraction (WAD); e.g. 0.05e18 => 20x max leverage
        uint256 mmf; // maintenance margin fraction (WAD); e.g. 0.03e18
    }

    /// @notice The full expanded exchange state passed as a witness to every mutator
    struct ExchangeState {
        uint64 nextOrderId;
        int256 insuranceFund; // quote balance backstopping liquidation bad debt (WAD)
        Account[] accounts;
        Order[] orders;
        Market[] markets;
    }

    // =============================================================================================
    // Storage: exactly one mutable slot
    // =============================================================================================

    /// @notice The single storage slot committing the entire exchange state.
    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("gaskiller.vertex.stateRoot")) - 1)) & ~0xff
    bytes32 public constant STATE_SLOT = 0x17e6773ed84b1fcb5ab117ade99c6d9314ebef61a2c508276b2c8c20e1308e00;

    bytes32 private constant STATE_DOMAIN =
        0x584a8eca37bc9bc2d1cb8601eb5a6ffb3a46d52935114d192a1e1987bc624eaa; // keccak256("gaskiller.vertex.state.v1")

    /// @notice How long without any transition before users may exit unilaterally
    uint256 public constant EMERGENCY_DELAY = 7 days;

    /// @notice WAD fixed-point unit
    int256 private constant WAD = 1e18;

    /// @notice Fraction of notional paid by a liquidated account as penalty (WAD); routed to insurance fund
    uint256 public constant LIQUIDATION_PENALTY = 0.025e18; // 2.5%

    // =============================================================================================
    // Immutables
    // =============================================================================================

    IERC20 public immutable quote;

    // =============================================================================================
    // Events
    // =============================================================================================

    event Deposit(address indexed user, uint256 amount);
    event Withdrawal(address indexed user, uint256 amount);
    event MarketListed(uint32 indexed marketId, uint256 imf, uint256 mmf);
    event MarketSynced(uint32 indexed marketId, uint256 oracle, int256 cumFunding);
    event OrderPlaced(uint64 indexed orderId, address indexed maker, uint32 indexed marketId, bool isBid, uint256 price, uint256 size);
    event OrderCancelled(uint64 indexed orderId);
    event EpochSettled(uint256 fills);
    event Liquidated(address indexed victim, uint32 indexed marketId, address indexed liquidator);
    event EmergencyWithdrawal(address indexed user, uint256 amount);

    // =============================================================================================
    // Errors
    // =============================================================================================

    error StateWitnessMismatch(uint192 expected, uint192 provided);
    error NonCanonicalWitness();
    error InsufficientCollateral(address user, int256 equity, int256 required);
    error OrderNotFound(uint64 orderId);
    error NotOrderMaker(uint64 orderId, address caller);
    error MarketNotListed(uint32 marketId);
    error MarketAlreadyListed(uint32 marketId);
    error AccountNotHealthyEnough();
    error AccountNotLiquidatable(address victim);
    error HasOpenPositions(address user);
    error EmergencyDelayNotMet(uint64 lastTransition, uint256 required);

    // =============================================================================================
    // Construction
    // =============================================================================================

    constructor(address _avsAddress, address _blsSigChecker, IERC20 _quote) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        quote = _quote;
        ExchangeState memory empty;
        empty.accounts = new Account[](0);
        empty.orders = new Order[](0);
        empty.markets = new Market[](0);
        _writePacked(_stateHash(empty), 0);
    }

    // =============================================================================================
    // Collateral
    // =============================================================================================

    /// @notice Deposit `amount` of the quote token as cross-margin collateral
    function deposit(ExchangeState memory s, uint256 amount) external trackState {
        ExchangeState memory st = _load(s);
        quote.transferFrom(msg.sender, address(this), amount);
        _creditCollateral(st, msg.sender, int256(amount));
        _writeState(st);
        emit Deposit(msg.sender, amount);
    }

    /// @notice Withdraw `amount` of quote collateral; account must remain initial-margin healthy
    function withdraw(ExchangeState memory s, uint256 amount) external trackState {
        ExchangeState memory st = _load(s);
        _creditCollateral(st, msg.sender, -int256(amount));

        (int256 equity, int256 initialMargin,) = _accountMargin(st, msg.sender);
        require(equity >= initialMargin, InsufficientCollateral(msg.sender, equity, initialMargin));

        quote.transfer(msg.sender, amount);
        _writeState(st);
        emit Withdrawal(msg.sender, amount);
    }

    // =============================================================================================
    // Market administration (operator-driven; part of the committed state)
    // =============================================================================================

    /// @notice List a new perpetual market with the given margin fractions and initial oracle price
    function listMarket(ExchangeState memory s, uint32 marketId, uint256 imf, uint256 mmf, uint256 initialOracle)
        external
        trackState
    {
        ExchangeState memory st = _load(s);
        (, bool exists) = _indexOfMarket(st.markets, marketId);
        require(!exists, MarketAlreadyListed(marketId));

        Market[] memory m = new Market[](st.markets.length + 1);
        for (uint256 i = 0; i < st.markets.length; i++) m[i] = st.markets[i];
        m[st.markets.length] = Market({id: marketId, oracle: initialOracle, cumFunding: 0, imf: imf, mmf: mmf});
        st.markets = m;

        _writeState(st);
        emit MarketListed(marketId, imf, mmf);
    }

    /// @notice Sequencer posts a fresh oracle price and applies an accrued funding delta for a market.
    /// @dev `fundingDelta` is the funding-index increment for the period, computed off-chain from the
    ///      mark-vs-index premium. Positive `fundingDelta` means longs pay shorts.
    function syncMarket(ExchangeState memory s, uint32 marketId, uint256 newOracle, int256 fundingDelta)
        external
        trackState
    {
        ExchangeState memory st = _load(s);
        (uint256 mi, bool exists) = _indexOfMarket(st.markets, marketId);
        require(exists, MarketNotListed(marketId));
        st.markets[mi].oracle = newOracle;
        st.markets[mi].cumFunding += fundingDelta;
        _writeState(st);
        emit MarketSynced(marketId, newOracle, st.markets[mi].cumFunding);
    }

    // =============================================================================================
    // Orders
    // =============================================================================================

    /// @notice Place a resting limit order on a market; account must be initial-margin healthy as if it filled
    function placeOrder(ExchangeState memory s, uint32 marketId, bool isBid, uint256 price, uint256 size)
        external
        trackState
    {
        ExchangeState memory st = _load(s);
        (, bool exists) = _indexOfMarket(st.markets, marketId);
        require(exists, MarketNotListed(marketId));

        // Margin the order: check the account stays initial-margin healthy if this order fully filled
        // at its limit price. We simulate the fill on a scratch copy of the caller's position set.
        _requireHealthyAfterHypotheticalFill(st, msg.sender, marketId, isBid, price, size);

        Order[] memory newOrders = new Order[](st.orders.length + 1);
        for (uint256 i = 0; i < st.orders.length; i++) newOrders[i] = st.orders[i];
        newOrders[st.orders.length] = Order({
            id: st.nextOrderId,
            maker: msg.sender,
            marketId: marketId,
            isBid: isBid,
            price: price,
            size: size,
            placedAt: uint64(block.timestamp)
        });
        uint64 newId = st.nextOrderId;
        st.nextOrderId++;
        st.orders = newOrders;

        _writeState(st);
        emit OrderPlaced(newId, msg.sender, marketId, isBid, price, size);
    }

    /// @notice Cancel a resting order (caller must be the maker)
    function cancelOrder(ExchangeState memory s, uint64 orderId) external trackState {
        ExchangeState memory st = _load(s);
        (uint256 idx, bool found) = _indexOfOrder(st.orders, orderId);
        require(found, OrderNotFound(orderId));
        require(st.orders[idx].maker == msg.sender, NotOrderMaker(orderId, msg.sender));
        st.orders = _removeOrder(st.orders, idx);
        _writeState(st);
        emit OrderCancelled(orderId);
    }

    // =============================================================================================
    // Epoch settlement — the expensive off-chain function
    // =============================================================================================

    /// @notice Accrue funding onto every touched position and match all crossing orders, per market.
    ///
    /// @dev This is the function Gas Killer operators execute OFF-CHAIN under `SimProfile::UnboundedV1`.
    ///      For each market it sorts the book (price-time priority, O(N²) insertion sort) and matches
    ///      crossing pairs; a fill updates BOTH makers' positions (no quote moves — perps post margin,
    ///      not notional) and realizes funding + reduce-PnL as needed. With many markets and orders the
    ///      combined sort + position sweep exceeds any real block gas limit.
    function settleEpoch(ExchangeState memory s) external trackState {
        ExchangeState memory st = _load(s);
        uint256 fills = _matchAllMarkets(st);
        _writeState(st);
        emit EpochSettled(fills);
    }

    // =============================================================================================
    // Liquidation — anyone may close an underwater account's position at the oracle price
    // =============================================================================================

    /// @notice Liquidate `victim`'s position in `marketId` when their equity is below maintenance margin.
    /// @dev The position is closed at the market oracle price; realized PnL settles into the victim's
    ///      collateral, a `LIQUIDATION_PENALTY` of the closed notional is taken from the victim into the
    ///      insurance fund, and the liquidator inherits the position at the oracle price (so they take on
    ///      the risk). Any residual negative collateral is absorbed by the insurance fund as bad debt.
    function liquidate(ExchangeState memory s, address victim, uint32 marketId) external trackState {
        ExchangeState memory st = _load(s);

        (int256 equity,, int256 maintMargin) = _accountMargin(st, victim);
        require(equity < maintMargin, AccountNotLiquidatable(victim));

        (uint256 ai, bool aFound) = _indexOfAccount(st.accounts, victim);
        require(aFound, AccountNotLiquidatable(victim));
        (uint256 pi, bool pFound) = _indexOfPosition(st.accounts[ai].positions, marketId);
        require(pFound, AccountNotLiquidatable(victim));
        (uint256 mi,) = _indexOfMarket(st.markets, marketId);

        int256 oracle = int256(st.markets[mi].oracle);

        // Realize funding + close PnL into the victim's collateral at the oracle price
        _realizeFundingOnAccount(st.accounts[ai], pi, st.markets);
        Position memory pos = st.accounts[ai].positions[pi];
        int256 closePnl = pos.size * (oracle - pos.avgEntry) / WAD;
        st.accounts[ai].collateral += closePnl;

        // Penalty on the closed notional → insurance fund
        uint256 notional = _abs(pos.size) * st.markets[mi].oracle / 1e18;
        int256 penalty = int256(notional * LIQUIDATION_PENALTY / 1e18);
        st.accounts[ai].collateral -= penalty;
        st.insuranceFund += penalty;

        // If the victim is now in bad debt, the insurance fund eats it
        if (st.accounts[ai].collateral < 0) {
            st.insuranceFund += st.accounts[ai].collateral;
            st.accounts[ai].collateral = 0;
        }

        // Liquidator inherits the position at the oracle price (assumes the risk) and must back it
        // with their own collateral — the liquidator has to be initial-margin healthy afterwards,
        // exactly like withdraw()/placeOrder(). This prevents a zero-collateral liquidator from
        // taking a free directional bet and socializing any adverse move onto the insurance fund.
        st.accounts[ai].positions = _removePosition(st.accounts[ai].positions, pi);
        _applyPositionDelta(st, msg.sender, marketId, pos.size, oracle);
        (int256 liqEquity, int256 liqInitial,) = _accountMargin(st, msg.sender);
        require(liqEquity >= liqInitial, InsufficientCollateral(msg.sender, liqEquity, liqInitial));

        _writeState(st);
        emit Liquidated(victim, marketId, msg.sender);
    }

    // =============================================================================================
    // Emergency exit — bypasses trackState; does NOT reset the inactivity timer
    // =============================================================================================

    /// @notice Withdraw free collateral after the operator has been inactive for EMERGENCY_DELAY.
    /// @dev Only accounts with no open positions may use this path (there is no oracle to value
    ///      positions against once the operator is gone). Does not call `trackState`.
    function emergencyWithdraw(ExchangeState memory s, uint256 amount) external {
        uint64 last = lastTransitionAt();
        require(uint64(block.timestamp) - last > uint64(EMERGENCY_DELAY), EmergencyDelayNotMet(last, EMERGENCY_DELAY));

        ExchangeState memory st = _load(s);
        (uint256 ai, bool found) = _indexOfAccount(st.accounts, msg.sender);
        require(found, InsufficientCollateral(msg.sender, 0, int256(amount)));
        require(st.accounts[ai].positions.length == 0, HasOpenPositions(msg.sender));
        require(
            st.accounts[ai].collateral >= int256(amount),
            InsufficientCollateral(msg.sender, st.accounts[ai].collateral, int256(amount))
        );

        st.accounts[ai].collateral -= int256(amount);
        quote.transfer(msg.sender, amount);
        _writePacked(_stateHash(st), last); // update hash, preserve timer
        emit EmergencyWithdrawal(msg.sender, amount);
    }

    // =============================================================================================
    // Public views (used by operators off-chain)
    // =============================================================================================

    function computeStateHash(ExchangeState memory s) public pure returns (uint192) {
        return _stateHash(s);
    }

    function stateHash() public view returns (uint192) {
        return uint192(_readPacked() >> 64);
    }

    function lastTransitionAt() public view returns (uint64) {
        return uint64(uint256(_readPacked()));
    }

    /// @notice Compute (equity, initialMargin, maintenanceMargin) for an account against a witness.
    function accountMargin(ExchangeState memory s, address owner)
        external
        pure
        returns (int256 equity, int256 initialMargin, int256 maintMargin)
    {
        return _accountMargin(s, owner);
    }

    // =============================================================================================
    // Internal — witness loading and state writing
    // =============================================================================================

    function _load(ExchangeState memory s) private view returns (ExchangeState memory) {
        uint192 provided = _stateHash(s);
        uint192 expected = stateHash();
        require(provided == expected, StateWitnessMismatch(expected, provided));
        s.accounts = _canonicalizeAccounts(s.accounts);
        s.orders = _canonicalizeOrders(s.orders);
        s.markets = _canonicalizeMarkets(s.markets);
        return s;
    }

    function _writeState(ExchangeState memory s) private {
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

    function _stateHash(ExchangeState memory s) private pure returns (uint192) {
        Account[] memory ca = _canonicalizeAccounts(s.accounts);
        Order[] memory co = _canonicalizeOrders(s.orders);
        Market[] memory cm = _canonicalizeMarkets(s.markets);
        bytes32 h = keccak256(abi.encode(STATE_DOMAIN, s.nextOrderId, s.insuranceFund, ca, co, cm));
        return uint192(bytes24(h));
    }

    // =============================================================================================
    // Internal — canonicalization (deterministic order for hashing)
    // =============================================================================================

    /// @dev Sort accounts by owner ascending; reject duplicates; drop empty accounts (0 collateral,
    ///      no positions). Positions within each account are sorted by marketId and zero-size dropped.
    function _canonicalizeAccounts(Account[] memory a) private pure returns (Account[] memory) {
        uint256 n = a.length;
        for (uint256 i = 1; i < n; i++) {
            Account memory key = a[i];
            uint256 j = i;
            while (j > 0 && uint160(a[j - 1].owner) > uint160(key.owner)) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }
        uint256 kept = 0;
        for (uint256 i = 0; i < n; i++) {
            if (i > 0) require(a[i].owner != a[i - 1].owner, NonCanonicalWitness());
            a[i].positions = _canonicalizePositions(a[i].positions);
            if (a[i].collateral != 0 || a[i].positions.length > 0) kept++;
        }
        Account[] memory out = new Account[](kept);
        uint256 w = 0;
        for (uint256 i = 0; i < n; i++) {
            if (a[i].collateral != 0 || a[i].positions.length > 0) out[w++] = a[i];
        }
        return out;
    }

    /// @dev Sort positions by marketId ascending; reject duplicates; drop zero-size positions.
    function _canonicalizePositions(Position[] memory p) private pure returns (Position[] memory) {
        uint256 n = p.length;
        for (uint256 i = 1; i < n; i++) {
            Position memory key = p[i];
            uint256 j = i;
            while (j > 0 && p[j - 1].marketId > key.marketId) {
                p[j] = p[j - 1];
                j--;
            }
            p[j] = key;
        }
        uint256 kept = 0;
        for (uint256 i = 0; i < n; i++) {
            if (i > 0) require(p[i].marketId != p[i - 1].marketId, NonCanonicalWitness());
            if (p[i].size != 0) kept++;
        }
        Position[] memory out = new Position[](kept);
        uint256 w = 0;
        for (uint256 i = 0; i < n; i++) {
            if (p[i].size != 0) out[w++] = p[i];
        }
        return out;
    }

    /// @dev Sort orders by id ascending; reject duplicate ids.
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

    /// @dev Sort markets by id ascending; reject duplicate ids.
    function _canonicalizeMarkets(Market[] memory m) private pure returns (Market[] memory) {
        uint256 n = m.length;
        for (uint256 i = 1; i < n; i++) {
            Market memory key = m[i];
            uint256 j = i;
            while (j > 0 && m[j - 1].id > key.id) {
                m[j] = m[j - 1];
                j--;
            }
            m[j] = key;
        }
        for (uint256 i = 1; i < n; i++) {
            require(m[i].id != m[i - 1].id, NonCanonicalWitness());
        }
        return m;
    }

    // =============================================================================================
    // Internal — cross-margin health
    // =============================================================================================

    /// @dev equity, initial margin, and maintenance margin for an account, valued at current oracles.
    function _accountMargin(ExchangeState memory st, address owner)
        private
        pure
        returns (int256 equity, int256 initialMargin, int256 maintMargin)
    {
        (uint256 ai, bool found) = _indexOfAccount(st.accounts, owner);
        if (!found) return (0, 0, 0);
        return _marginOfAccount(st.accounts[ai], st.markets);
    }

    /// @dev Margin figures for a standalone account against a market set (no state dependency).
    function _marginOfAccount(Account memory a, Market[] memory markets)
        private
        pure
        returns (int256 equity, int256 initialMargin, int256 maintMargin)
    {
        equity = a.collateral;
        for (uint256 i = 0; i < a.positions.length; i++) {
            Position memory p = a.positions[i];
            (uint256 mi, bool mFound) = _indexOfMarket(markets, p.marketId);
            if (!mFound) continue;
            Market memory m = markets[mi];
            int256 oracle = int256(m.oracle);
            equity += p.size * (oracle - p.avgEntry) / WAD; // unrealized PnL
            equity -= p.size * (m.cumFunding - p.entryFunding) / WAD; // funding owed
            // Single 1e36 denominator (matches the header formula) — avoids the extra truncation
            // that a two-step |size|*oracle/1e18 then *frac/1e18 would introduce.
            uint256 absNotional = _abs(p.size) * m.oracle;
            initialMargin += int256(absNotional * m.imf / 1e36);
            maintMargin += int256(absNotional * m.mmf / 1e36);
        }
    }

    /// @dev Revert unless `owner` remains initial-margin healthy after hypothetically filling
    ///      `size` at `price` on `marketId` (bid = +size, ask = −size). Side-effect-free: the
    ///      hypothetical fill is applied to a deep-cloned scratch account, never to `st`.
    function _requireHealthyAfterHypotheticalFill(
        ExchangeState memory st,
        address owner,
        uint32 marketId,
        bool isBid,
        uint256 price,
        uint256 size
    ) private pure {
        int256 delta = isBid ? int256(size) : -int256(size);
        (uint256 ai, bool found) = _indexOfAccount(st.accounts, owner);
        Account memory scratch =
            found ? _cloneAccount(st.accounts[ai]) : Account({owner: owner, collateral: 0, positions: new Position[](0)});
        _applyDeltaToAccount(scratch, st.markets, marketId, delta, int256(price));
        (int256 equity, int256 initialMargin,) = _marginOfAccount(scratch, st.markets);
        require(equity >= initialMargin, AccountNotHealthyEnough());
    }

    /// @dev Deep-copy an account (positions contain only value types, so copy field-by-field).
    function _cloneAccount(Account memory a) private pure returns (Account memory c) {
        c.owner = a.owner;
        c.collateral = a.collateral;
        Position[] memory ps = new Position[](a.positions.length);
        for (uint256 i = 0; i < a.positions.length; i++) {
            ps[i] = Position({
                marketId: a.positions[i].marketId,
                size: a.positions[i].size,
                avgEntry: a.positions[i].avgEntry,
                entryFunding: a.positions[i].entryFunding
            });
        }
        c.positions = ps;
    }

    // =============================================================================================
    // Internal — matching
    // =============================================================================================

    /// @dev Match crossing orders in every market. Returns total fills. O(N²) per market from the sorts.
    function _matchAllMarkets(ExchangeState memory st) private pure returns (uint256 fills) {
        // Markets are already canonical; match each one's crossing orders.
        for (uint256 mIdx = 0; mIdx < st.markets.length; mIdx++) {
            fills += _matchMarket(st, st.markets[mIdx].id);
        }
        // Rebuild the order book keeping only orders with residual size.
        uint256 remaining = 0;
        for (uint256 i = 0; i < st.orders.length; i++) if (st.orders[i].size > 0) remaining++;
        Order[] memory kept = new Order[](remaining);
        uint256 w = 0;
        for (uint256 i = 0; i < st.orders.length; i++) if (st.orders[i].size > 0) kept[w++] = st.orders[i];
        st.orders = kept;
    }

    /// @dev Match one market's crossing orders in price-time priority; updates maker positions in place.
    function _matchMarket(ExchangeState memory st, uint32 marketId) private pure returns (uint256 fills) {
        (Order[] memory bids, Order[] memory asks) = _splitAndSort(st.orders, marketId);

        uint256 bi = 0;
        uint256 ai = 0;
        while (bi < bids.length && ai < asks.length) {
            if (bids[bi].price < asks[ai].price) break;

            // Self-trade prevention: a maker may not fill against their own order (it would rewrite
            // their avgEntry and book phantom PnL against themselves). Cancel the NEWER of the two
            // crossing orders (tie-break by id) and retry; the older keeps its book priority.
            if (bids[bi].maker == asks[ai].maker) {
                bool cancelBid = bids[bi].placedAt > asks[ai].placedAt
                    || (bids[bi].placedAt == asks[ai].placedAt && bids[bi].id > asks[ai].id);
                if (cancelBid) {
                    _writeBackOrderSize(st, bids[bi].id, 0);
                    bids[bi].size = 0;
                    bi++;
                } else {
                    _writeBackOrderSize(st, asks[ai].id, 0);
                    asks[ai].size = 0;
                    ai++;
                }
                continue;
            }

            int256 fillPrice = int256(asks[ai].price);
            uint256 fillSize = bids[bi].size < asks[ai].size ? bids[bi].size : asks[ai].size;

            // Perp fill: buyer goes long, seller goes short, both at fillPrice. No quote transfer.
            _applyPositionDelta(st, bids[bi].maker, marketId, int256(fillSize), fillPrice);
            _applyPositionDelta(st, asks[ai].maker, marketId, -int256(fillSize), fillPrice);

            bids[bi].size -= fillSize;
            asks[ai].size -= fillSize;
            _writeBackOrderSize(st, bids[bi].id, bids[bi].size);
            _writeBackOrderSize(st, asks[ai].id, asks[ai].size);

            if (bids[bi].size == 0) bi++;
            if (asks[ai].size == 0) ai++;
            fills++;
        }
    }

    /// @dev Partition orders of `marketId` into bids/asks and sort each for price-time priority.
    function _splitAndSort(Order[] memory orders, uint32 marketId)
        private
        pure
        returns (Order[] memory bids, Order[] memory asks)
    {
        uint256 nb;
        uint256 na;
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].marketId != marketId || orders[i].size == 0) continue;
            if (orders[i].isBid) nb++;
            else na++;
        }
        bids = new Order[](nb);
        asks = new Order[](na);
        uint256 bi;
        uint256 ai;
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].marketId != marketId || orders[i].size == 0) continue;
            if (orders[i].isBid) bids[bi++] = orders[i];
            else asks[ai++] = orders[i];
        }
        _sortBids(bids);
        _sortAsks(asks);
    }

    /// @dev Insertion sort bids: price desc, tie-break placedAt asc (FIFO). O(N²) worst case.
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

    /// @dev Insertion sort asks: price asc, tie-break placedAt asc (FIFO). O(N²) worst case.
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

    /// @dev Reflect a residual order size back into the canonical order array by id.
    function _writeBackOrderSize(ExchangeState memory st, uint64 orderId, uint256 newSize) private pure {
        (uint256 idx, bool found) = _indexOfOrder(st.orders, orderId);
        if (found) st.orders[idx].size = newSize;
    }

    // =============================================================================================
    // Internal — position & collateral mutation
    // =============================================================================================

    /// @dev Apply a signed size delta to `owner`'s position on `marketId` within `st` (creates the
    ///      account if absent). Thin wrapper over the account-based core.
    function _applyPositionDelta(ExchangeState memory st, address owner, uint32 marketId, int256 delta, int256 price)
        private
        pure
    {
        if (delta == 0) return;
        uint256 ai = _ensureAccount(st, owner);
        _applyDeltaToAccount(st.accounts[ai], st.markets, marketId, delta, price);
    }

    /// @dev Open/increase (weighted avg entry) or reduce/close (realize PnL into collateral) a
    ///      position on `a`. Realizes accrued funding first. Mutates `a` in place.
    function _applyDeltaToAccount(Account memory a, Market[] memory markets, uint32 marketId, int256 delta, int256 price)
        private
        pure
    {
        if (delta == 0) return;
        (uint256 mi, bool mFound) = _indexOfMarket(markets, marketId);
        int256 cumFunding = mFound ? markets[mi].cumFunding : int256(0);

        (uint256 pi, bool pFound) = _indexOfPosition(a.positions, marketId);
        if (!pFound) {
            Position[] memory ps = new Position[](a.positions.length + 1);
            for (uint256 i = 0; i < a.positions.length; i++) ps[i] = a.positions[i];
            ps[a.positions.length] =
                Position({marketId: marketId, size: delta, avgEntry: price, entryFunding: cumFunding});
            a.positions = ps;
            return;
        }

        // Realize funding accrued since last touch, then reset the snapshot
        _realizeFundingOnAccount(a, pi, markets);
        Position memory p = a.positions[pi];

        int256 oldSize = p.size;
        int256 newSize = oldSize + delta;

        if (oldSize == 0) {
            p.avgEntry = price;
        } else if ((oldSize > 0) == (delta > 0)) {
            // Increasing in the same direction: volume-weighted average entry
            int256 absOld = _absI(oldSize);
            int256 absDelta = _absI(delta);
            p.avgEntry = (absOld * p.avgEntry + absDelta * price) / (absOld + absDelta);
        } else {
            // Reducing / flipping: realize PnL on the closed portion into collateral
            int256 closed = _absI(delta) < _absI(oldSize) ? _absI(delta) : _absI(oldSize);
            int256 dir = oldSize > 0 ? int256(1) : int256(-1);
            int256 pnl = dir * closed * (price - p.avgEntry) / WAD;
            a.collateral += pnl;
            if ((newSize > 0) != (oldSize > 0) && newSize != 0) {
                p.avgEntry = price; // flipped past zero: remainder opens at `price`
            }
            // If merely reduced (same side) avgEntry is unchanged.
        }

        p.size = newSize;
        a.positions[pi] = p;
    }

    /// @dev Realize funding owed on `a.positions[pi]` into collateral and reset its funding snapshot.
    function _realizeFundingOnAccount(Account memory a, uint256 pi, Market[] memory markets) private pure {
        Position memory p = a.positions[pi];
        (uint256 mi, bool f) = _indexOfMarket(markets, p.marketId);
        int256 cumFunding = f ? markets[mi].cumFunding : p.entryFunding;
        int256 owed = p.size * (cumFunding - p.entryFunding) / WAD; // longs pay when cumFunding rises
        a.collateral -= owed;
        p.entryFunding = cumFunding;
        a.positions[pi] = p;
    }

    function _creditCollateral(ExchangeState memory st, address owner, int256 amount) private pure {
        uint256 ai = _ensureAccount(st, owner);
        st.accounts[ai].collateral += amount;
    }

    /// @dev Return the index of `owner`'s account, creating an empty one if absent.
    function _ensureAccount(ExchangeState memory st, address owner) private pure returns (uint256) {
        (uint256 ai, bool found) = _indexOfAccount(st.accounts, owner);
        if (found) return ai;
        Account[] memory a = new Account[](st.accounts.length + 1);
        for (uint256 i = 0; i < st.accounts.length; i++) a[i] = st.accounts[i];
        a[st.accounts.length] = Account({owner: owner, collateral: 0, positions: new Position[](0)});
        st.accounts = a;
        return st.accounts.length - 1;
    }

    // =============================================================================================
    // Internal — array lookups & removals
    // =============================================================================================

    function _indexOfAccount(Account[] memory a, address owner) private pure returns (uint256, bool) {
        for (uint256 i = 0; i < a.length; i++) if (a[i].owner == owner) return (i, true);
        return (0, false);
    }

    function _indexOfPosition(Position[] memory p, uint32 marketId) private pure returns (uint256, bool) {
        for (uint256 i = 0; i < p.length; i++) if (p[i].marketId == marketId) return (i, true);
        return (0, false);
    }

    function _indexOfOrder(Order[] memory orders, uint64 orderId) private pure returns (uint256, bool) {
        for (uint256 i = 0; i < orders.length; i++) if (orders[i].id == orderId) return (i, true);
        return (0, false);
    }

    function _indexOfMarket(Market[] memory m, uint32 marketId) private pure returns (uint256, bool) {
        for (uint256 i = 0; i < m.length; i++) if (m[i].id == marketId) return (i, true);
        return (0, false);
    }

    function _removeOrder(Order[] memory orders, uint256 idx) private pure returns (Order[] memory) {
        Order[] memory out = new Order[](orders.length - 1);
        for (uint256 i = 0; i < idx; i++) out[i] = orders[i];
        for (uint256 i = idx + 1; i < orders.length; i++) out[i - 1] = orders[i];
        return out;
    }

    function _removePosition(Position[] memory p, uint256 idx) private pure returns (Position[] memory) {
        Position[] memory out = new Position[](p.length - 1);
        for (uint256 i = 0; i < idx; i++) out[i] = p[i];
        for (uint256 i = idx + 1; i < p.length; i++) out[i - 1] = p[i];
        return out;
    }

    // =============================================================================================
    // Internal — math helpers
    // =============================================================================================

    function _abs(int256 x) private pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _absI(int256 x) private pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}
