// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {GasKillerVertex} from "../../src/examples/gaskiller-vertex/GasKillerVertex.sol";
import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// ------------------------------------------------------------------------------------------------
// Test helpers
// ------------------------------------------------------------------------------------------------

/// @dev Minimal BLS checker that always reports 100% signed stake.
contract MockBLSChecker {
    function checkSignatures(
        bytes32,
        bytes calldata quorumNumbers,
        uint32,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory
    ) external pure returns (IBLSSignatureCheckerTypes.QuorumStakeTotals memory totals, bytes32) {
        uint256 n = quorumNumbers.length;
        totals.signedStakeForQuorum = new uint96[](n);
        totals.totalStakeForQuorum = new uint96[](n);
        for (uint256 i = 0; i < n; i++) {
            totals.signedStakeForQuorum[i] = uint96(1e18);
            totals.totalStakeForQuorum[i] = uint96(1e18);
        }
    }
}

/// @dev Minimal ERC20 for testing — unbounded mint, no access control.
contract MockERC20 is IERC20 {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

// ------------------------------------------------------------------------------------------------
// Main test suite
// ------------------------------------------------------------------------------------------------

/// @title GasKillerVertexTest
/// @notice Tests the single-slot cross-margin perp DEX: deposits, market listing, oracle/funding
///         sync, order placement with initial-margin checks, epoch matching that opens perp
///         positions, funding accrual, health-based liquidation, the O(1) storage-write invariant,
///         the end-to-end Gas Killer path, and the above-block-limit gas proof.
///
/// @dev The test contract plays the off-chain operator: it mirrors the full exchange state and after
///      every on-chain mutation cross-checks `vertex.stateHash() == vertex.computeStateHash(witness)`.
contract GasKillerVertexTest is Test {
    GasKillerVertex internal vertex;
    MockBLSChecker internal bls;
    MockERC20 internal usdc;

    address internal avs = address(0xA75);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal liq = address(0x11C);

    uint256 internal constant WAD = 1e18;
    uint32 internal constant ETH = 1;
    uint256 internal constant IMF = 0.05e18; // 5% → 20x
    uint256 internal constant MMF = 0.03e18; // 3%
    uint256 internal constant PRICE = 3000e18;

    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    // ---- off-chain mirror ----
    address[] internal mAllUsers;
    mapping(address => bool) internal mKnown;
    mapping(address => int256) internal mColl;
    // positions: user => marketId => (size, avgEntry, entryFunding)
    mapping(address => mapping(uint32 => int256)) internal mSize;
    mapping(address => mapping(uint32 => int256)) internal mAvg;
    mapping(address => mapping(uint32 => int256)) internal mEntryFunding;
    mapping(address => uint32[]) internal mUserMarkets;
    mapping(address => mapping(uint32 => bool)) internal mHasPos;

    uint64 internal mNextOrderId;
    int256 internal mInsurance;

    struct MOrder {
        uint64 id;
        address maker;
        uint32 marketId;
        bool isBid;
        uint256 price;
        uint256 size;
        uint64 placedAt;
    }

    MOrder[] internal mOrders;

    // markets
    uint32[] internal mMarketIds;
    mapping(uint32 => bool) internal mMarketListed;
    mapping(uint32 => uint256) internal mOracle;
    mapping(uint32 => int256) internal mCumFunding;
    mapping(uint32 => uint256) internal mImf;
    mapping(uint32 => uint256) internal mMmf;

    function setUp() public {
        bls = new MockBLSChecker();
        usdc = new MockERC20();
        vertex = new GasKillerVertex(avs, address(bls), IERC20(address(usdc)));

        address[4] memory users = [alice, bob, carol, liq];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 10_000_000 * WAD);
            vm.prank(users[i]);
            usdc.approve(address(vertex), type(uint256).max);
            _registerUser(users[i]);
        }

        _assertInSync();
    }

    // ============================================================================================
    // Construction / basic collateral
    // ============================================================================================

    function testInitialCommitmentIsEmpty() public view {
        GasKillerVertex.ExchangeState memory empty;
        empty.accounts = new GasKillerVertex.Account[](0);
        empty.orders = new GasKillerVertex.Order[](0);
        empty.markets = new GasKillerVertex.Market[](0);
        assertEq(vertex.stateHash(), vertex.computeStateHash(empty));
        assertEq(vertex.stateTransitionCount(), 0);
    }

    function testDeposit() public {
        _doDeposit(alice, 100_000 * WAD);
        _assertInSync();
        assertEq(vertex.stateTransitionCount(), 1);
    }

    function testWithdraw() public {
        _doDeposit(alice, 100_000 * WAD);
        _doWithdraw(alice, 40_000 * WAD);
        _assertInSync();
    }

    function testWithdrawBeyondEquityReverts() public {
        _doDeposit(alice, 1_000 * WAD);
        vm.prank(alice);
        vm.expectRevert();
        vertex.withdraw(_witness(), 2_000 * WAD);
    }

    // ============================================================================================
    // Markets
    // ============================================================================================

    function testListMarket() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _assertInSync();
    }

    function testListMarketDuplicateReverts() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        vm.expectRevert(abi.encodeWithSelector(GasKillerVertex.MarketAlreadyListed.selector, ETH));
        vertex.listMarket(_witness(), ETH, IMF, MMF, PRICE);
    }

    function testSyncMarket() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doSyncMarket(ETH, 3100e18, 0);
        _assertInSync();
        assertEq(mOracle[ETH], 3100e18);
    }

    // ============================================================================================
    // Orders + margin checks
    // ============================================================================================

    function testPlaceOrderRequiresMargin() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        // No collateral → placing a 1 ETH bid needs 3000*0.05 = 150 USDC margin → revert
        vm.prank(alice);
        vm.expectRevert(GasKillerVertex.AccountNotHealthyEnough.selector);
        vertex.placeOrder(_witness(), ETH, true, PRICE, 1 * WAD);
    }

    function testPlaceOrderWithMargin() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 1_000 * WAD);
        _doPlaceOrder(alice, ETH, true, PRICE, 1 * WAD, 100);
        _assertInSync();
    }

    function testCancelOrder() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 1_000 * WAD);
        _doPlaceOrder(alice, ETH, true, PRICE, 1 * WAD, 100);
        uint64 id = mNextOrderId - 1;
        vm.prank(alice);
        vertex.cancelOrder(_witness(), id);
        _mCancelOrder(id);
        _assertInSync();
    }

    function testCancelNotMakerReverts() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 1_000 * WAD);
        _doPlaceOrder(alice, ETH, true, PRICE, 1 * WAD, 100);
        uint64 id = mNextOrderId - 1;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GasKillerVertex.NotOrderMaker.selector, id, bob));
        vertex.cancelOrder(_witness(), id);
    }

    // ============================================================================================
    // Matching opens perp positions
    // ============================================================================================

    function testSettleOpensPositions() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 10_000 * WAD);
        _doDeposit(bob, 10_000 * WAD);

        _doPlaceOrder(alice, ETH, true, PRICE, 2 * WAD, 100); // buyer → long
        _doPlaceOrder(bob, ETH, false, PRICE, 2 * WAD, 101); // seller → short

        vm.warp(200);
        vertex.settleEpoch(_witness());
        _mSettle();

        _assertInSync();
        assertEq(mSize[alice][ETH], int256(2 * WAD)); // alice long 2 ETH
        assertEq(mSize[bob][ETH], -int256(2 * WAD)); // bob short 2 ETH
        assertEq(mOrders.length, 0);
    }

    function testPnLRealizedOnClose() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 10_000 * WAD);
        _doDeposit(bob, 10_000 * WAD);

        // Open: alice long 1 ETH @ 3000, bob short 1 ETH @ 3000
        _doPlaceOrder(alice, ETH, true, PRICE, 1 * WAD, 100);
        _doPlaceOrder(bob, ETH, false, PRICE, 1 * WAD, 101);
        vm.warp(200);
        vertex.settleEpoch(_witness());
        _mSettle();
        _assertInSync();

        // Close: alice sells 1 ETH @ 3200, carol buys 1 ETH @ 3200
        _doDeposit(carol, 10_000 * WAD);
        _doPlaceOrder(alice, ETH, false, 3200e18, 1 * WAD, 300);
        _doPlaceOrder(carol, ETH, true, 3200e18, 1 * WAD, 301);
        vm.warp(400);
        vertex.settleEpoch(_witness());
        _mSettle();

        _assertInSync();
        // alice closed her long at +200 profit → collateral 10000 + 200 = 10200, size 0
        assertEq(mSize[alice][ETH], 0);
        assertEq(mColl[alice], int256(10_200 * WAD));
    }

    function testSelfTradeBooksNoPhantomPnL() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 10_000 * WAD);
        _doDeposit(bob, 10_000 * WAD);

        // Open alice long 2 ETH @ 3000
        _doPlaceOrder(alice, ETH, true, PRICE, 2 * WAD, 100);
        _doPlaceOrder(bob, ETH, false, PRICE, 2 * WAD, 101);
        vm.warp(200);
        vertex.settleEpoch(_witness());
        _mSettle();
        _assertInSync();

        // Oracle rises; alice tries to self-cross a bid and ask at 3200 to fabricate PnL
        _doSyncMarket(ETH, 3200e18, 0);
        _doPlaceOrder(alice, ETH, true, 3200e18, 1 * WAD, 300);
        _doPlaceOrder(alice, ETH, false, 3200e18, 1 * WAD, 301);

        vm.warp(400);
        vertex.settleEpoch(_witness());
        _mSettle();

        _assertInSync();
        // Position and collateral are untouched — the self-cross booked nothing
        assertEq(mSize[alice][ETH], int256(2 * WAD));
        assertEq(mAvg[alice][ETH], int256(PRICE));
        assertEq(mColl[alice], int256(10_000 * WAD));
    }

    // ============================================================================================
    // Funding
    // ============================================================================================

    function testFundingAccruesToPositions() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 10_000 * WAD);
        _doDeposit(bob, 10_000 * WAD);
        _doPlaceOrder(alice, ETH, true, PRICE, 1 * WAD, 100); // long
        _doPlaceOrder(bob, ETH, false, PRICE, 1 * WAD, 101); // short
        vm.warp(200);
        vertex.settleEpoch(_witness());
        _mSettle();
        _assertInSync();

        // Positive funding index delta of 10 (quote/base): long pays 10, short receives 10
        _doSyncMarket(ETH, PRICE, 10e18);

        // Equity check: alice (long) equity should be 10000 - 10 (funding owed, unrealized), bob +10
        (int256 aEq,,) = vertex.accountMargin(_witness(), alice);
        (int256 bEq,,) = vertex.accountMargin(_witness(), bob);
        assertEq(aEq, int256(10_000 * WAD) - int256(10 * WAD));
        assertEq(bEq, int256(10_000 * WAD) + int256(10 * WAD));

        // Realize it: alice reduces her position, funding hits collateral
        _doDeposit(carol, 10_000 * WAD);
        _doPlaceOrder(alice, ETH, false, PRICE, 1 * WAD, 300);
        _doPlaceOrder(carol, ETH, true, PRICE, 1 * WAD, 301);
        vm.warp(400);
        vertex.settleEpoch(_witness());
        _mSettle();
        _assertInSync();
        // alice: 10000 - 10 funding + 0 PnL (closed at entry) = 9990
        assertEq(mColl[alice], int256(10_000 * WAD) - int256(10 * WAD));
    }

    // ============================================================================================
    // Liquidation
    // ============================================================================================

    function testLiquidateUnderwaterAccount() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        // alice posts just enough for a 10 ETH long: notional 30000, IM 1500. Give her 1600.
        _doDeposit(alice, 1_600 * WAD);
        _doDeposit(bob, 100_000 * WAD);
        _doPlaceOrder(alice, ETH, true, PRICE, 10 * WAD, 100);
        _doPlaceOrder(bob, ETH, false, PRICE, 10 * WAD, 101);
        vm.warp(200);
        vertex.settleEpoch(_witness());
        _mSettle();
        _assertInSync();

        // Liquidator must post collateral to back the position it inherits (IM = 10*2800*0.05 = 1400)
        _doDeposit(liq, 5_000 * WAD);

        // Price drops to 2800: alice PnL = 10*(2800-3000) = -2000 → equity 1600-2000 = -400 < MM
        _doSyncMarket(ETH, 2800e18, 0);

        (int256 aEq,, int256 aMm) = vertex.accountMargin(_witness(), alice);
        assertLt(aEq, aMm);

        vm.prank(liq);
        vertex.liquidate(_witness(), alice, ETH);
        _mLiquidate(alice, ETH, liq);

        _assertInSync();
        assertEq(mSize[alice][ETH], 0); // position closed
        assertEq(mSize[liq][ETH], int256(10 * WAD)); // liquidator inherited the long
    }

    function testLiquidateHealthyReverts() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 10_000 * WAD);
        _doDeposit(bob, 10_000 * WAD);
        _doPlaceOrder(alice, ETH, true, PRICE, 1 * WAD, 100);
        _doPlaceOrder(bob, ETH, false, PRICE, 1 * WAD, 101);
        vm.warp(200);
        vertex.settleEpoch(_witness());
        _mSettle();

        vm.prank(liq);
        vm.expectRevert(abi.encodeWithSelector(GasKillerVertex.AccountNotLiquidatable.selector, alice));
        vertex.liquidate(_witness(), alice, ETH);
    }

    // ============================================================================================
    // O(1) storage-write invariant
    // ============================================================================================

    function testSettleWritesExactlyTwoSlots() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 10_000 * WAD);
        _doDeposit(bob, 10_000 * WAD);
        _doPlaceOrder(alice, ETH, true, PRICE, 1 * WAD, 100);
        _doPlaceOrder(bob, ETH, false, PRICE, 1 * WAD, 101);

        vm.record();
        vm.warp(200);
        vertex.settleEpoch(_witness());
        (, bytes32[] memory writes) = vm.accesses(address(vertex));

        bytes32 stateSlot = vertex.STATE_SLOT();
        bool sawState;
        bool sawTracker;
        for (uint256 i = 0; i < writes.length; i++) {
            if (writes[i] == stateSlot) sawState = true;
            else if (writes[i] == TRACKER_SLOT) sawTracker = true;
            else revert("unexpected storage write");
        }
        assertTrue(sawState && sawTracker);
    }

    // ============================================================================================
    // End-to-end Gas Killer path
    // ============================================================================================

    function testVerifyAndUpdateAppliesSingleStore() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 10_000 * WAD);
        _doDeposit(bob, 10_000 * WAD);
        _doPlaceOrder(alice, ETH, true, PRICE, 1 * WAD, 100);
        _doPlaceOrder(bob, ETH, false, PRICE, 1 * WAD, 101);

        // Operator computes post-settle state off-chain
        _mSettle();
        vm.warp(200);
        uint192 newHash = vertex.computeStateHash(_witness());
        bytes32 newPacked = bytes32((uint256(newHash) << 64) | uint256(uint64(200)));

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(vertex.STATE_SLOT(), newPacked);
        bytes memory storageUpdates = abi.encode(types, args);

        vm.roll(100);
        uint32 refBlock = 99;
        uint256 transitionIndex = vertex.stateTransitionCount();
        bytes4 targetFn = vertex.settleEpoch.selector;
        bytes32 msgHash = sha256(abi.encode(transitionIndex, address(vertex), targetFn, storageUpdates));
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;

        vertex.verifyAndUpdate(msgHash, hex"00", refBlock, storageUpdates, transitionIndex, targetFn, sig);

        assertEq(vertex.stateHash(), newHash);
        assertEq(vertex.stateTransitionCount(), transitionIndex + 1);
        _assertInSync();
    }

    // ============================================================================================
    // Above-block-gas-limit proof
    // ============================================================================================

    /// @notice Prove that settleEpoch over a large multi-market book exceeds the mainnet block gas
    ///         limit while landing only two storage writes on-chain.
    /// @dev Uses `vm.store` to inject a large pre-built non-crossing book directly, passed REVERSED
    ///      so `_canonicalizeOrders` runs its O(N^2) insertion sort. Non-crossing (bids below asks)
    ///      so no fills → no position allocation churn, isolating the sort cost.
    function testSettleEpochAboveBlockGasLimit() public {
        uint256 BLOCK_LIMIT = 30_000_000;
        uint256 N = 1200;
        uint256 half = N / 2;

        GasKillerVertex.ExchangeState memory st;
        st.nextOrderId = uint64(N);
        st.accounts = new GasKillerVertex.Account[](0);
        st.orders = new GasKillerVertex.Order[](N);
        st.markets = new GasKillerVertex.Market[](1);
        st.markets[0] =
            GasKillerVertex.Market({id: ETH, oracle: PRICE, cumFunding: 0, imf: IMF, mmf: MMF});

        for (uint256 i = 0; i < half; i++) {
            st.orders[i] = GasKillerVertex.Order({
                id: uint64(i),
                maker: vm.addr(i + 1),
                marketId: ETH,
                isBid: false,
                price: PRICE,
                size: 1 * WAD,
                placedAt: uint64(i + 1)
            });
        }
        for (uint256 i = 0; i < half; i++) {
            st.orders[half + i] = GasKillerVertex.Order({
                id: uint64(half + i),
                maker: vm.addr(half + i + 1),
                marketId: ETH,
                isBid: true,
                price: PRICE - 1, // strictly below asks — no fills
                size: 1 * WAD,
                placedAt: uint64(i + 1)
            });
        }

        uint192 h = vertex.computeStateHash(st);
        vm.store(address(vertex), vertex.STATE_SLOT(), bytes32((uint256(h) << 64) | uint256(block.timestamp)));

        // Reverse the orders — same commitment (canonical sort is order-independent), forces O(N^2).
        for (uint256 i = 0; i < N / 2; i++) {
            GasKillerVertex.Order memory tmp = st.orders[i];
            st.orders[i] = st.orders[N - 1 - i];
            st.orders[N - 1 - i] = tmp;
        }

        uint256 gasBefore = gasleft();
        vertex.settleEpoch(st);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("settleEpoch gas (N=1200 orders, O(N^2) sort)", gasUsed);
        assertGt(gasUsed, BLOCK_LIMIT, "settleEpoch must exceed the block gas limit");
    }

    // ============================================================================================
    // Emergency exit
    // ============================================================================================

    function testEmergencyWithdrawAfterDelay() public {
        _doDeposit(alice, 5_000 * WAD);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        vertex.emergencyWithdraw(_witness(), 5_000 * WAD);
        mColl[alice] -= int256(5_000 * WAD);
        _assertInSync();
    }

    function testEmergencyWithdrawBeforeDelayReverts() public {
        _doDeposit(alice, 5_000 * WAD);
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vm.expectRevert();
        vertex.emergencyWithdraw(_witness(), 1 * WAD);
    }

    function testEmergencyWithdrawWithOpenPositionReverts() public {
        _doListMarket(ETH, IMF, MMF, PRICE);
        _doDeposit(alice, 10_000 * WAD);
        _doDeposit(bob, 10_000 * WAD);
        _doPlaceOrder(alice, ETH, true, PRICE, 1 * WAD, 100);
        _doPlaceOrder(bob, ETH, false, PRICE, 1 * WAD, 101);
        vm.warp(200);
        vertex.settleEpoch(_witness());
        _mSettle();

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GasKillerVertex.HasOpenPositions.selector, alice));
        vertex.emergencyWithdraw(_witness(), 1 * WAD);
    }

    // ============================================================================================
    // Mirror helpers — "the operator"
    // ============================================================================================

    function _registerUser(address u) internal {
        if (!mKnown[u]) {
            mKnown[u] = true;
            mAllUsers.push(u);
        }
    }

    function _doDeposit(address user, uint256 amount) internal {
        _registerUser(user);
        vm.prank(user);
        vertex.deposit(_witness(), amount);
        mColl[user] += int256(amount);
    }

    function _doWithdraw(address user, uint256 amount) internal {
        vm.prank(user);
        vertex.withdraw(_witness(), amount);
        mColl[user] -= int256(amount);
    }

    function _doListMarket(uint32 id, uint256 imf, uint256 mmf, uint256 oracle) internal {
        vertex.listMarket(_witness(), id, imf, mmf, oracle);
        if (!mMarketListed[id]) {
            mMarketListed[id] = true;
            mMarketIds.push(id);
        }
        mImf[id] = imf;
        mMmf[id] = mmf;
        mOracle[id] = oracle;
    }

    function _doSyncMarket(uint32 id, uint256 oracle, int256 fundingDelta) internal {
        vertex.syncMarket(_witness(), id, oracle, fundingDelta);
        mOracle[id] = oracle;
        mCumFunding[id] += fundingDelta;
    }

    function _doPlaceOrder(address user, uint32 marketId, bool isBid, uint256 price, uint256 size, uint64 ts)
        internal
    {
        _registerUser(user);
        vm.warp(ts);
        vm.prank(user);
        vertex.placeOrder(_witness(), marketId, isBid, price, size);
        mOrders.push(MOrder(mNextOrderId++, user, marketId, isBid, price, size, ts));
    }

    function _mCancelOrder(uint64 id) internal {
        for (uint256 i = 0; i < mOrders.length; i++) {
            if (mOrders[i].id == id) {
                for (uint256 j = i; j < mOrders.length - 1; j++) mOrders[j] = mOrders[j + 1];
                mOrders.pop();
                return;
            }
        }
    }

    function _mTouchPosition(address u, uint32 m) internal {
        if (!mHasPos[u][m]) {
            mHasPos[u][m] = true;
            mUserMarkets[u].push(m);
            mEntryFunding[u][m] = mCumFunding[m];
        }
    }

    /// @dev Mirror of _applyDeltaToAccount: realize funding, then open/increase/reduce.
    function _mApplyDelta(address u, uint32 m, int256 delta, int256 price) internal {
        _registerUser(u);
        _mTouchPosition(u, m);
        // realize funding
        int256 owed = mSize[u][m] * (mCumFunding[m] - mEntryFunding[u][m]) / int256(WAD);
        mColl[u] -= owed;
        mEntryFunding[u][m] = mCumFunding[m];

        int256 oldSize = mSize[u][m];
        int256 newSize = oldSize + delta;
        if (oldSize == 0) {
            mAvg[u][m] = price;
        } else if ((oldSize > 0) == (delta > 0)) {
            int256 absOld = oldSize >= 0 ? oldSize : -oldSize;
            int256 absDelta = delta >= 0 ? delta : -delta;
            mAvg[u][m] = (absOld * mAvg[u][m] + absDelta * price) / (absOld + absDelta);
        } else {
            int256 absOld = oldSize >= 0 ? oldSize : -oldSize;
            int256 absDelta = delta >= 0 ? delta : -delta;
            int256 closed = absDelta < absOld ? absDelta : absOld;
            int256 dir = oldSize > 0 ? int256(1) : int256(-1);
            mColl[u] += dir * closed * (price - mAvg[u][m]) / int256(WAD);
            if ((newSize > 0) != (oldSize > 0) && newSize != 0) mAvg[u][m] = price;
        }
        mSize[u][m] = newSize;
    }

    /// @dev Mirror of settleEpoch matching (single ETH market, price-time priority).
    function _mSettle() internal {
        bool progress = true;
        while (progress) {
            progress = false;
            uint256 bestBid;
            bool fB;
            uint256 bestAsk;
            bool fA;
            for (uint256 i = 0; i < mOrders.length; i++) {
                if (mOrders[i].size == 0) continue;
                if (mOrders[i].isBid) {
                    if (
                        !fB || mOrders[i].price > mOrders[bestBid].price
                            || (mOrders[i].price == mOrders[bestBid].price && mOrders[i].placedAt < mOrders[bestBid].placedAt)
                    ) {
                        bestBid = i;
                        fB = true;
                    }
                } else {
                    if (
                        !fA || mOrders[i].price < mOrders[bestAsk].price
                            || (mOrders[i].price == mOrders[bestAsk].price && mOrders[i].placedAt < mOrders[bestAsk].placedAt)
                    ) {
                        bestAsk = i;
                        fA = true;
                    }
                }
            }
            if (!fB || !fA) break;
            if (mOrders[bestBid].price < mOrders[bestAsk].price) break;

            // Self-trade prevention mirror: cancel the newer of the two crossing orders, keep the older.
            if (mOrders[bestBid].maker == mOrders[bestAsk].maker) {
                bool cancelBid = mOrders[bestBid].placedAt > mOrders[bestAsk].placedAt
                    || (mOrders[bestBid].placedAt == mOrders[bestAsk].placedAt && mOrders[bestBid].id > mOrders[bestAsk].id);
                if (cancelBid) mOrders[bestBid].size = 0;
                else mOrders[bestAsk].size = 0;
                progress = true;
                continue;
            }

            uint256 fillSize = mOrders[bestBid].size < mOrders[bestAsk].size ? mOrders[bestBid].size : mOrders[bestAsk].size;
            int256 fillPrice = int256(mOrders[bestAsk].price);
            uint32 m = mOrders[bestBid].marketId;

            _mApplyDelta(mOrders[bestBid].maker, m, int256(fillSize), fillPrice);
            _mApplyDelta(mOrders[bestAsk].maker, m, -int256(fillSize), fillPrice);

            mOrders[bestBid].size -= fillSize;
            mOrders[bestAsk].size -= fillSize;
            progress = true;
        }
        // prune filled orders
        uint256 w = 0;
        for (uint256 i = 0; i < mOrders.length; i++) {
            if (mOrders[i].size > 0) {
                mOrders[w] = mOrders[i];
                w++;
            }
        }
        while (mOrders.length > w) mOrders.pop();
    }

    /// @dev Mirror of liquidate.
    function _mLiquidate(address victim, uint32 m, address liquidator) internal {
        // realize funding
        int256 owed = mSize[victim][m] * (mCumFunding[m] - mEntryFunding[victim][m]) / int256(WAD);
        mColl[victim] -= owed;
        mEntryFunding[victim][m] = mCumFunding[m];

        int256 oracle = int256(mOracle[m]);
        int256 size = mSize[victim][m];
        mColl[victim] += size * (oracle - mAvg[victim][m]) / int256(WAD);

        uint256 notional = (size >= 0 ? uint256(size) : uint256(-size)) * mOracle[m] / WAD;
        int256 penalty = int256(notional * vertex.LIQUIDATION_PENALTY() / 1e18);
        mColl[victim] -= penalty;
        mInsurance += penalty;

        if (mColl[victim] < 0) {
            mInsurance += mColl[victim];
            mColl[victim] = 0;
        }

        // remove victim position
        mSize[victim][m] = 0;
        mAvg[victim][m] = 0;
        mEntryFunding[victim][m] = 0;
        mHasPos[victim][m] = false;
        _removeUserMarket(victim, m);

        // liquidator inherits at oracle
        _mApplyDelta(liquidator, m, size, oracle);
    }

    function _removeUserMarket(address u, uint32 m) internal {
        uint32[] storage arr = mUserMarkets[u];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == m) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    /// @dev Build an ExchangeState witness from the off-chain mirror.
    function _witness() internal view returns (GasKillerVertex.ExchangeState memory s) {
        // accounts
        uint256 aCount;
        for (uint256 i = 0; i < mAllUsers.length; i++) {
            address u = mAllUsers[i];
            if (mColl[u] != 0 || mUserMarkets[u].length > 0) aCount++;
        }
        s.accounts = new GasKillerVertex.Account[](aCount);
        uint256 w;
        for (uint256 i = 0; i < mAllUsers.length; i++) {
            address u = mAllUsers[i];
            if (mColl[u] == 0 && mUserMarkets[u].length == 0) continue;
            uint32[] memory ms = mUserMarkets[u];
            // count non-zero positions
            uint256 pc;
            for (uint256 k = 0; k < ms.length; k++) {
                if (mSize[u][ms[k]] != 0) pc++;
            }
            GasKillerVertex.Position[] memory ps = new GasKillerVertex.Position[](pc);
            uint256 pw;
            for (uint256 k = 0; k < ms.length; k++) {
                uint32 mk = ms[k];
                if (mSize[u][mk] == 0) continue;
                ps[pw++] = GasKillerVertex.Position({
                    marketId: mk,
                    size: mSize[u][mk],
                    avgEntry: mAvg[u][mk],
                    entryFunding: mEntryFunding[u][mk]
                });
            }
            s.accounts[w++] = GasKillerVertex.Account({owner: u, collateral: mColl[u], positions: ps});
        }

        // orders
        s.orders = new GasKillerVertex.Order[](mOrders.length);
        for (uint256 i = 0; i < mOrders.length; i++) {
            s.orders[i] = GasKillerVertex.Order({
                id: mOrders[i].id,
                maker: mOrders[i].maker,
                marketId: mOrders[i].marketId,
                isBid: mOrders[i].isBid,
                price: mOrders[i].price,
                size: mOrders[i].size,
                placedAt: mOrders[i].placedAt
            });
        }

        // markets
        s.markets = new GasKillerVertex.Market[](mMarketIds.length);
        for (uint256 i = 0; i < mMarketIds.length; i++) {
            uint32 id = mMarketIds[i];
            s.markets[i] = GasKillerVertex.Market({
                id: id,
                oracle: mOracle[id],
                cumFunding: mCumFunding[id],
                imf: mImf[id],
                mmf: mMmf[id]
            });
        }

        s.nextOrderId = mNextOrderId;
        s.insuranceFund = mInsurance;
    }

    function _assertInSync() internal view {
        assertEq(vertex.stateHash(), vertex.computeStateHash(_witness()), "commitment diverged from mirror");
    }
}
