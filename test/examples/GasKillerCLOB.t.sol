// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {GasKillerCLOB} from "../../src/examples/gaskiller-clob/GasKillerCLOB.sol";
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
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _sym) {
        name = _name;
        symbol = _sym;
    }

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

/// @title GasKillerCLOBTest
/// @notice Tests the single-slot CLOB: deposit/withdraw, order placement/cancellation, epoch
///         settlement, the O(1) storage-write invariant, the end-to-end Gas Killer path, and the
///         above-block-limit gas proof that motivates the unbounded execution mode.
///
/// @dev The test contract plays the role of the off-chain operator: it mirrors the full exchange
///      state in plain Solidity mappings, builds `CLOBState` witnesses from that mirror, and after
///      every on-chain mutation cross-checks `clob.stateHash() == clob.computeStateHash(witness)`.
contract GasKillerCLOBTest is Test {
    GasKillerCLOB internal clob;
    MockBLSChecker internal bls;
    MockERC20 internal weth; // base token
    MockERC20 internal usdc; // quote token

    address internal avs = address(0xA75);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    uint256 internal constant BASE_UNIT = 1e18;
    uint256 internal constant PRICE = 3000 * BASE_UNIT;

    // StateTracker slot (keccak256("gasKiller.stateTracker") - 1)
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    // ---- off-chain mirror ----
    // Track every user ever seen so _witness() doesn't miss anyone (including vm.addr users).
    address[] internal mAllUsers;
    mapping(address => bool) internal mKnown;
    mapping(address => uint256) internal mBase;
    mapping(address => uint256) internal mQuote;
    uint64 internal mNextOrderId;

    struct MirrorOrder {
        uint64 id;
        address maker;
        bool isBid;
        uint256 price;
        uint256 size;
        uint64 placedAt;
    }

    MirrorOrder[] internal mOrders;

    function setUp() public {
        bls = new MockBLSChecker();
        weth = new MockERC20("Wrapped ETH", "WETH");
        usdc = new MockERC20("USD Coin", "USDC");
        clob = new GasKillerCLOB(avs, address(bls), IERC20(address(weth)), IERC20(address(usdc)));

        weth.mint(alice, 100 * BASE_UNIT);
        weth.mint(bob, 100 * BASE_UNIT);
        weth.mint(carol, 100 * BASE_UNIT); // carol needs WETH too
        usdc.mint(alice, 1_000_000 * BASE_UNIT);
        usdc.mint(bob, 1_000_000 * BASE_UNIT);
        usdc.mint(carol, 1_000_000 * BASE_UNIT);

        vm.prank(alice);
        weth.approve(address(clob), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(clob), type(uint256).max);
        vm.prank(bob);
        weth.approve(address(clob), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(clob), type(uint256).max);
        vm.prank(carol);
        weth.approve(address(clob), type(uint256).max);
        vm.prank(carol);
        usdc.approve(address(clob), type(uint256).max);

        _registerUser(alice);
        _registerUser(bob);
        _registerUser(carol);

        _assertInSync();
    }

    // ============================================================================================
    // Construction
    // ============================================================================================

    function testInitialCommitmentIsEmpty() public view {
        GasKillerCLOB.CLOBState memory empty;
        empty.balances = new GasKillerCLOB.Balance[](0);
        empty.orders = new GasKillerCLOB.Order[](0);
        assertEq(clob.stateHash(), clob.computeStateHash(empty));
        assertEq(clob.stateTransitionCount(), 0);
    }

    // ============================================================================================
    // Deposit / withdraw
    // ============================================================================================

    function testDeposit() public {
        uint256 amount = 5 * BASE_UNIT;
        vm.prank(alice);
        clob.deposit(_witness(), true, amount);
        mBase[alice] += amount;
        _assertInSync();
        assertEq(clob.stateTransitionCount(), 1);
    }

    function testDepositQuote() public {
        uint256 amount = 9000 * BASE_UNIT;
        vm.prank(alice);
        clob.deposit(_witness(), false, amount);
        mQuote[alice] += amount;
        _assertInSync();
    }

    function testWithdraw() public {
        _doDeposit(alice, true, 10 * BASE_UNIT);
        uint256 amount = 3 * BASE_UNIT;
        vm.prank(alice);
        clob.withdraw(_witness(), true, amount);
        mBase[alice] -= amount;
        _assertInSync();
    }

    function testWithdrawInsufficientReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(GasKillerCLOB.InsufficientBalance.selector, alice, true, 0, 1)
        );
        clob.withdraw(_witness(), true, 1);
    }

    function testWrongWitnessReverts() public {
        GasKillerCLOB.CLOBState memory bad = _witness();
        GasKillerCLOB.Balance[] memory fakeBalances = new GasKillerCLOB.Balance[](1);
        fakeBalances[0] = GasKillerCLOB.Balance(alice, 1, 0);
        bad.balances = fakeBalances;
        vm.expectRevert();
        vm.prank(alice);
        clob.deposit(bad, true, 1 * BASE_UNIT);
    }

    // ============================================================================================
    // Order placement and cancellation
    // ============================================================================================

    function testPlaceAsk() public {
        _doDeposit(alice, true, 1 * BASE_UNIT);

        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 1 * BASE_UNIT, 1000);

        _assertInSync();
        assertEq(mBase[alice], 0); // base locked in ask
    }

    function testPlaceBid() public {
        uint256 lockedQuote = PRICE;
        _doDeposit(alice, false, lockedQuote);

        vm.warp(2000);
        _doPlaceOrder(alice, true, PRICE, 1 * BASE_UNIT, 2000);

        _assertInSync();
        assertEq(mQuote[alice], 0); // quote locked in bid
    }

    function testPlaceOrderInsufficientCollateralReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(GasKillerCLOB.InsufficientBalance.selector, alice, true, 0, BASE_UNIT)
        );
        clob.placeOrder(_witness(), false, PRICE, BASE_UNIT);
    }

    function testCancelOrder() public {
        _doDeposit(alice, true, 2 * BASE_UNIT);
        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 2 * BASE_UNIT, 1000);

        uint64 orderId = mNextOrderId - 1;
        vm.prank(alice);
        clob.cancelOrder(_witness(), orderId);
        _mCancelOrder(orderId);

        _assertInSync();
        assertEq(mBase[alice], 2 * BASE_UNIT); // collateral restored
    }

    function testCancelNotMakerReverts() public {
        _doDeposit(alice, true, 1 * BASE_UNIT);
        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 1 * BASE_UNIT, 1000);
        uint64 orderId = mNextOrderId - 1;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GasKillerCLOB.NotOrderMaker.selector, orderId, bob));
        clob.cancelOrder(_witness(), orderId);
    }

    function testCancelUnknownOrderReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GasKillerCLOB.OrderNotFound.selector, uint64(99)));
        clob.cancelOrder(_witness(), 99);
    }

    // ============================================================================================
    // settleEpoch — matching semantics
    // ============================================================================================

    function testSettleMatchesCrossingOrders() public {
        _doDeposit(alice, true, 1 * BASE_UNIT);
        _doDeposit(bob, false, PRICE);
        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 1 * BASE_UNIT, 1000);
        vm.warp(1001);
        _doPlaceOrder(bob, true, PRICE, 1 * BASE_UNIT, 1001);

        vm.warp(1002);
        clob.settleEpoch(_witness());
        _mSettle();

        _assertInSync();
        assertEq(mBase[bob], 1 * BASE_UNIT);
        assertEq(mQuote[alice], PRICE);
        assertEq(mOrders.length, 0);
    }

    function testSettlePartialFill() public {
        _doDeposit(alice, true, 2 * BASE_UNIT);
        _doDeposit(bob, false, PRICE);
        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 2 * BASE_UNIT, 1000);
        vm.warp(1001);
        _doPlaceOrder(bob, true, PRICE, 1 * BASE_UNIT, 1001);

        vm.warp(1002);
        clob.settleEpoch(_witness());
        _mSettle();

        _assertInSync();
        assertEq(mBase[bob], 1 * BASE_UNIT);
        assertEq(mQuote[alice], PRICE);
        assertEq(mOrders.length, 1); // 1 ETH ask remaining
    }

    function testSettleNoMatch() public {
        _doDeposit(alice, true, 1 * BASE_UNIT);
        _doDeposit(bob, false, 2000 * BASE_UNIT);
        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 1 * BASE_UNIT, 1000);
        vm.warp(1001);
        _doPlaceOrder(bob, true, 2000 * BASE_UNIT, 1 * BASE_UNIT, 1001);

        vm.warp(1002);
        clob.settleEpoch(_witness());

        _assertInSync();
        assertEq(mOrders.length, 2);
    }

    function testOverbidCollateralRefunded() public {
        uint256 bidPrice = 4000 * BASE_UNIT;
        _doDeposit(alice, true, 1 * BASE_UNIT);
        _doDeposit(bob, false, bidPrice);
        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 1 * BASE_UNIT, 1000);
        vm.warp(1001);
        _doPlaceOrder(bob, true, bidPrice, 1 * BASE_UNIT, 1001);

        vm.warp(1002);
        clob.settleEpoch(_witness());
        _mSettle();

        _assertInSync();
        assertEq(mQuote[bob], 1000 * BASE_UNIT); // 1000 USDC refund
        assertEq(mQuote[alice], PRICE);
    }

    function testPriceTimePriority() public {
        // Two asks at same price, different timestamps: earlier one fills first
        _doDeposit(alice, true, 1 * BASE_UNIT);
        _doDeposit(carol, true, 1 * BASE_UNIT);
        _doDeposit(bob, false, PRICE);

        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 1 * BASE_UNIT, 1000);
        vm.warp(1001);
        _doPlaceOrder(carol, false, PRICE, 1 * BASE_UNIT, 1001);
        vm.warp(1002);
        _doPlaceOrder(bob, true, PRICE, 1 * BASE_UNIT, 1002);

        vm.warp(1003);
        clob.settleEpoch(_witness());
        _mSettle();

        _assertInSync();
        // Alice's ask filled first (earliest timestamp), carol's remains
        assertEq(mBase[alice], 0);
        assertEq(mQuote[alice], PRICE);
        assertEq(mOrders.length, 1);
        assertEq(mOrders[0].maker, carol);
    }

    // ============================================================================================
    // The headline property: storage writes are O(1)
    // ============================================================================================

    function testSettleEpochWritesExactlyTwoSlots() public {
        _doDeposit(alice, true, 1 * BASE_UNIT);
        _doDeposit(bob, false, PRICE);
        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 1 * BASE_UNIT, 1000);
        vm.warp(1001);
        _doPlaceOrder(bob, true, PRICE, 1 * BASE_UNIT, 1001);

        vm.record();
        vm.warp(1002);
        clob.settleEpoch(_witness());
        (, bytes32[] memory writes) = vm.accesses(address(clob));

        bool sawState;
        bool sawTracker;
        bytes32 stateSlot = clob.STATE_SLOT();
        for (uint256 i = 0; i < writes.length; i++) {
            if (writes[i] == stateSlot) sawState = true;
            else if (writes[i] == TRACKER_SLOT) sawTracker = true;
            else revert("unexpected storage write");
        }
        assertTrue(sawState, "STATE_SLOT not written");
        assertTrue(sawTracker, "TRACKER_SLOT not written");
    }

    function testSettleEpochWritesExactlyTwoSlots_manyOrders() public {
        // 20 users (10 crossing bid/ask pairs), confirm write count stays O(1)
        uint256 n = 20;
        for (uint256 i = 0; i < n; i++) {
            address user = vm.addr(i + 100);
            weth.mint(user, 1 * BASE_UNIT);
            usdc.mint(user, PRICE);
            vm.prank(user);
            weth.approve(address(clob), type(uint256).max);
            vm.prank(user);
            usdc.approve(address(clob), type(uint256).max);
            _registerUser(user);

            if (i % 2 == 0) {
                _doDeposit(user, true, 1 * BASE_UNIT);
                _doPlaceOrder(user, false, PRICE, 1 * BASE_UNIT, uint64(i + 1000));
            } else {
                _doDeposit(user, false, PRICE);
                _doPlaceOrder(user, true, PRICE, 1 * BASE_UNIT, uint64(i + 1000));
            }
        }

        vm.record();
        vm.warp(2000);
        clob.settleEpoch(_witness());
        (, bytes32[] memory writes) = vm.accesses(address(clob));

        bytes32 stateSlot = clob.STATE_SLOT();
        for (uint256 i = 0; i < writes.length; i++) {
            assertTrue(
                writes[i] == stateSlot || writes[i] == TRACKER_SLOT,
                "unexpected storage write with many orders"
            );
        }
        _mSettle();
        _assertInSync();
    }

    // ============================================================================================
    // End-to-end Gas Killer path: operator applies a transition as a single STORE op
    // ============================================================================================

    function testVerifyAndUpdateAppliesSingleStore() public {
        _doDeposit(alice, true, 1 * BASE_UNIT);
        _doDeposit(bob, false, PRICE);
        vm.warp(1000);
        _doPlaceOrder(alice, false, PRICE, 1 * BASE_UNIT, 1000);
        vm.warp(1001);
        _doPlaceOrder(bob, true, PRICE, 1 * BASE_UNIT, 1001);

        // Operator computes the post-settle state off-chain
        _mSettle();
        vm.warp(1002);
        uint192 newHash = clob.computeStateHash(_witness());
        bytes32 newPacked = bytes32((uint256(newHash) << 64) | uint256(uint64(1002)));

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(clob.STATE_SLOT(), newPacked);
        bytes memory storageUpdates = abi.encode(types, args);

        vm.roll(100);
        uint32 refBlock = 99;
        uint256 transitionIndex = clob.stateTransitionCount();
        bytes4 targetFunction = clob.settleEpoch.selector;
        bytes32 msgHash = sha256(abi.encode(transitionIndex, address(clob), targetFunction, storageUpdates));

        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;

        vm.record();
        clob.verifyAndUpdate(msgHash, hex"00", refBlock, storageUpdates, transitionIndex, targetFunction, sig);
        (, bytes32[] memory writes) = vm.accesses(address(clob));

        bytes32 stateSlot = clob.STATE_SLOT();
        for (uint256 i = 0; i < writes.length; i++) {
            assertTrue(writes[i] == stateSlot || writes[i] == TRACKER_SLOT, "unexpected slot written");
        }

        assertEq(clob.stateHash(), newHash);
        assertEq(clob.stateTransitionCount(), transitionIndex + 1);
        _assertInSync();
    }

    // ============================================================================================
    // Above-block-gas-limit proof — the raison d'être of unbounded mode
    // ============================================================================================

    /// @notice Prove that settleEpoch on a large book exceeds the mainnet block gas limit
    ///         while landing only two storage writes on-chain.
    ///
    /// @dev Uses `vm.store` to inject a large pre-built order book directly (bypassing the
    ///      O(N^3) incremental-placement setup cost). The orders are passed in REVERSE id order
    ///      as the witness, forcing O(N^2) insertion sort in `_canonicalizeOrders`. This is the
    ///      source of the >30M gas proof — the canonical sort is called twice (once in `_load`
    ///      and once in `_writeState`) with a combined N^2/2 = 719,400 swaps each.
    ///
    ///      Design constraints:
    ///      (a) Non-crossing book (bid price < ask price): avoids fills, which would trigger O(N^2)
    ///          memory re-allocations inside `_credit` (array-grows-by-one per fill) and push
    ///          total memory into the hundreds of MB, causing OOG before the sort completes.
    ///      (b) placedAt ascending with id: ensures _sortBids/_sortAsks see already-sorted input
    ///          (O(N)). The inner loop of _sortBids/_sortAsks allocates `Order memory prev` on
    ///          every ITERATION (not just outer), causing O(N^2) memory growth when not short-
    ///          circuited. _canonicalizeOrders does NOT allocate in its inner loop, so it's safe.
    ///
    ///      Foundry's default test gas limit is i64::MAX, so this test can run without flags.
    function testSettleEpochAboveBlockGasLimit() public {
        uint256 MAINNET_BLOCK_GAS_LIMIT = 30_000_000;
        uint256 N = 1200; // 600 asks + 600 bids
        uint256 half = N / 2;

        // Build the CLOBState in memory. All collateral is "locked" in orders (0 free balances).
        // Bids priced below asks so no fills happen.
        GasKillerCLOB.CLOBState memory st;
        st.nextOrderId = uint64(N);
        st.balances = new GasKillerCLOB.Balance[](0);
        st.orders = new GasKillerCLOB.Order[](N);

        // Asks (id 0..half-1): price = PRICE; placedAt = id+1 (ascending).
        // After canonical sort by id, asks are already time-sorted → _sortAsks is O(N).
        for (uint256 i = 0; i < half; i++) {
            st.orders[i] = GasKillerCLOB.Order({
                id: uint64(i),
                maker: vm.addr(i + 1),
                isBid: false,
                price: PRICE,
                size: 1 * BASE_UNIT,
                placedAt: uint64(i + 1) // ascending: 1, 2, ..., half
            });
        }
        // Bids (id half..N-1): price = PRICE-1 (non-crossing); placedAt = (i+1) ascending.
        // After canonical sort by id, bids are already time-sorted → _sortBids is O(N).
        for (uint256 i = 0; i < half; i++) {
            st.orders[half + i] = GasKillerCLOB.Order({
                id: uint64(half + i),
                maker: vm.addr(half + i + 1),
                isBid: true,
                price: PRICE - 1,   // strictly below asks — no fills
                size: 1 * BASE_UNIT,
                placedAt: uint64(i + 1) // ascending: 1, 2, ..., half
            });
        }

        // Compute the commitment from the forward-ordered state (O(N) sort since IDs are in order)
        uint192 h = clob.computeStateHash(st);
        uint64 ts = uint64(block.timestamp);
        vm.store(address(clob), clob.STATE_SLOT(), bytes32((uint256(h) << 64) | uint256(ts)));

        // Reverse the orders array. The canonical sort inside settleEpoch is order-independent,
        // so the reversed witness hashes to the same commitment — proven by the StateWitnessMismatch
        // check that _load runs at the start of settleEpoch. The O(N^2) sort cost is what we measure.
        for (uint256 i = 0; i < N / 2; i++) {
            GasKillerCLOB.Order memory tmp = st.orders[i];
            st.orders[i] = st.orders[N - 1 - i];
            st.orders[N - 1 - i] = tmp;
        }
        // (No pre-call assertEq here — calling computeStateHash on 1200 reversed orders itself
        // costs ~560M gas, which would exhaust the budget before settleEpoch runs.)

        // Measure the direct settleEpoch gas — Gas Killer operators run this off-chain
        // under SimProfile::UnboundedV1 (gas limit 2^40 ≈ 1.1 Tgas).
        uint256 gasBefore = gasleft();
        clob.settleEpoch(st);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("settleEpoch gas (N=1200 orders, O(N^2) sorts)", gasUsed);
        assertGt(
            gasUsed,
            MAINNET_BLOCK_GAS_LIMIT,
            "settleEpoch must exceed the block gas limit - this is why Gas Killer operators run it off-chain"
        );
    }

    // ============================================================================================
    // Emergency exit
    // ============================================================================================

    function testEmergencyWithdrawAfterDelay() public {
        _doDeposit(alice, true, 5 * BASE_UNIT); // _doDeposit already updates mirror

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        clob.emergencyWithdraw(_witness(), true, 5 * BASE_UNIT);
        mBase[alice] -= 5 * BASE_UNIT;

        _assertInSync();
    }

    function testEmergencyWithdrawBeforeDelayReverts() public {
        _doDeposit(alice, true, 1 * BASE_UNIT);

        vm.warp(block.timestamp + 3 days);

        vm.prank(alice);
        vm.expectRevert();
        clob.emergencyWithdraw(_witness(), true, 1 * BASE_UNIT);
    }

    function testEmergencyWithdrawDoesNotResetTimer() public {
        _doDeposit(alice, true, 5 * BASE_UNIT); // _doDeposit already updates mirror

        vm.warp(block.timestamp + 7 days + 1);
        uint64 timerBefore = clob.lastTransitionAt();

        vm.prank(alice);
        clob.emergencyWithdraw(_witness(), true, 1 * BASE_UNIT);
        mBase[alice] -= 1 * BASE_UNIT;

        // Timer must NOT advance — emergency path preserves it so ALL users can exit
        assertEq(clob.lastTransitionAt(), timerBefore, "emergency withdrawal must not reset inactivity timer");
        _assertInSync();
    }

    // ============================================================================================
    // Fuzz: commitment always tracks the mirror
    // ============================================================================================

    function testFuzzDepositWithdrawStaysInSync(uint256 amount) public {
        amount = bound(amount, 1, 10 * BASE_UNIT);

        vm.prank(alice);
        clob.deposit(_witness(), true, amount);
        mBase[alice] += amount;
        _assertInSync();

        vm.prank(alice);
        clob.withdraw(_witness(), true, amount);
        mBase[alice] -= amount;
        _assertInSync();
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

    function _doDeposit(address user, bool isBase, uint256 amount) internal {
        _registerUser(user);
        vm.prank(user);
        clob.deposit(_witness(), isBase, amount);
        if (isBase) mBase[user] += amount;
        else mQuote[user] += amount;
    }

    function _doPlaceOrder(address user, bool isBid, uint256 price, uint256 size, uint64 ts) internal {
        _registerUser(user);
        vm.warp(ts);
        vm.prank(user);
        clob.placeOrder(_witness(), isBid, price, size);
        if (isBid) mQuote[user] -= size * price / BASE_UNIT;
        else mBase[user] -= size;
        mOrders.push(MirrorOrder(mNextOrderId++, user, isBid, price, size, ts));
    }

    function _mCancelOrder(uint64 orderId) internal {
        for (uint256 i = 0; i < mOrders.length; i++) {
            if (mOrders[i].id == orderId) {
                MirrorOrder memory o = mOrders[i];
                if (o.isBid) mQuote[o.maker] += o.size * o.price / BASE_UNIT;
                else mBase[o.maker] += o.size;
                for (uint256 j = i; j < mOrders.length - 1; j++) mOrders[j] = mOrders[j + 1];
                mOrders.pop();
                return;
            }
        }
    }

    /// @dev Simple mirror settle: repeatedly find and fill the best crossing pair.
    function _mSettle() internal {
        bool progress = true;
        while (progress) {
            progress = false;
            uint256 bestBidIdx;
            bool foundBid;
            uint256 bestAskIdx;
            bool foundAsk;

            for (uint256 i = 0; i < mOrders.length; i++) {
                if (mOrders[i].isBid) {
                    if (
                        !foundBid || mOrders[i].price > mOrders[bestBidIdx].price
                            || (
                                mOrders[i].price == mOrders[bestBidIdx].price
                                    && mOrders[i].placedAt < mOrders[bestBidIdx].placedAt
                            )
                    ) {
                        bestBidIdx = i;
                        foundBid = true;
                    }
                } else {
                    if (
                        !foundAsk || mOrders[i].price < mOrders[bestAskIdx].price
                            || (
                                mOrders[i].price == mOrders[bestAskIdx].price
                                    && mOrders[i].placedAt < mOrders[bestAskIdx].placedAt
                            )
                    ) {
                        bestAskIdx = i;
                        foundAsk = true;
                    }
                }
            }
            if (!foundBid || !foundAsk) break;
            if (mOrders[bestBidIdx].price < mOrders[bestAskIdx].price) break;

            uint256 fillPrice = mOrders[bestAskIdx].price;
            uint256 fillSize = mOrders[bestBidIdx].size < mOrders[bestAskIdx].size
                ? mOrders[bestBidIdx].size
                : mOrders[bestAskIdx].size;
            uint256 fillQuote = fillSize * fillPrice / BASE_UNIT;

            mBase[mOrders[bestBidIdx].maker] += fillSize;
            mQuote[mOrders[bestAskIdx].maker] += fillQuote;

            uint256 locked = fillSize * mOrders[bestBidIdx].price / BASE_UNIT;
            if (locked > fillQuote) mQuote[mOrders[bestBidIdx].maker] += locked - fillQuote;

            mOrders[bestBidIdx].size -= fillSize;
            mOrders[bestAskIdx].size -= fillSize;

            if (mOrders[bestBidIdx].size == 0) {
                for (uint256 j = bestBidIdx; j < mOrders.length - 1; j++) mOrders[j] = mOrders[j + 1];
                mOrders.pop();
                if (bestAskIdx > bestBidIdx) bestAskIdx--;
            }
            if (bestAskIdx < mOrders.length && mOrders[bestAskIdx].size == 0) {
                for (uint256 j = bestAskIdx; j < mOrders.length - 1; j++) mOrders[j] = mOrders[j + 1];
                mOrders.pop();
            }
            progress = true;
        }
    }

    /// @dev Build a CLOBState witness from the off-chain mirror.
    ///      Includes all users ever seen (mAllUsers); drops zero-balance entries automatically
    ///      since _canonicalizeBalances omits them.
    function _witness() internal view returns (GasKillerCLOB.CLOBState memory s) {
        uint256 bCount;
        for (uint256 i = 0; i < mAllUsers.length; i++) {
            if (mBase[mAllUsers[i]] > 0 || mQuote[mAllUsers[i]] > 0) bCount++;
        }
        s.balances = new GasKillerCLOB.Balance[](bCount);
        uint256 w;
        for (uint256 i = 0; i < mAllUsers.length; i++) {
            address u = mAllUsers[i];
            if (mBase[u] > 0 || mQuote[u] > 0) {
                s.balances[w++] = GasKillerCLOB.Balance(u, mBase[u], mQuote[u]);
            }
        }

        s.orders = new GasKillerCLOB.Order[](mOrders.length);
        for (uint256 i = 0; i < mOrders.length; i++) {
            s.orders[i] = GasKillerCLOB.Order({
                id: mOrders[i].id,
                maker: mOrders[i].maker,
                isBid: mOrders[i].isBid,
                price: mOrders[i].price,
                size: mOrders[i].size,
                placedAt: mOrders[i].placedAt
            });
        }

        s.nextOrderId = mNextOrderId;
    }

    function _assertInSync() internal view {
        assertEq(
            clob.stateHash(),
            clob.computeStateHash(_witness()),
            "contract commitment diverged from operator mirror"
        );
    }
}
