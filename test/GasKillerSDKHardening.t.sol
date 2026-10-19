// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {TransitionGuard} from "../src/TransitionGuard.sol";
import {IGasKillerSDK} from "../src/interface/IGasKillerSDK.sol";
import {IGasKillerNested} from "../src/interface/IGasKillerNested.sol";
import {IGasKillerSDKBatch, TaskSubmission} from "../src/interface/IGasKillerSDKBatch.sol";
import {ISchnorrStakeRegistry} from "../src/interface/ISchnorrStakeRegistry.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../src/StateChangeHandlerLib.sol";

/// Registry stub with a settable verdict — the guard/latch/batch control flow under test
/// is independent of real signature verification (covered in SchnorrStakeRegistry.t.sol).
/// In strict mode the verdict is "the arguments match what was staged per digest", so a
/// batch item that forwarded a neighbor's (s, Raddr) fails verification. (The stub cannot
/// RECORD calls — the SDK invokes it via STATICCALL.)
contract MockSchnorrRegistry is ISchnorrStakeRegistry {
    bool public verdict = true;
    bool public strict;
    mapping(bytes32 => uint256) public expectedS;
    mapping(bytes32 => address) public expectedRaddr;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function expect(bytes32 message, uint256 s, address Raddr) external {
        strict = true;
        expectedS[message] = s;
        expectedRaddr[message] = Raddr;
    }

    function isValidSignature(bytes32 message, uint256 s, address Raddr, address[] calldata, uint256)
        external
        view
        returns (bool)
    {
        if (strict) return expectedS[message] == s && expectedRaddr[message] == Raddr;
        return verdict;
    }
}

contract TestSDK is GasKillerSDK {
    uint256 public value; // slot 0

    constructor(address registry) {
        _setSchnorrRegistry(registry);
        _setAvsAddress(address(0xA75));
    }
}

/// Re-entry attacker: invoked mid-transition via a CALL state update, it attempts to
/// submit the *next* transition (whose signature the mock registry would accept) while
/// transition N is still applying. Without the guard this interleaves two signed
/// transitions; with it, the re-entrant call must revert `ReentrantTransition`.
contract ReentrantAttacker {
    TestSDK public sdk;
    bool public sawInTransition;
    bytes4 public caughtSelector;
    bool public reentrySucceeded;

    // Pre-staged arguments for the re-entrant verifyAndUpdate (transition N+1).
    bytes32 public msgHash;
    uint32 public refBlock;
    bytes public storageUpdates;
    uint256 public transitionIndex;
    bytes4 public targetFunction;

    constructor(TestSDK _sdk) {
        sdk = _sdk;
    }

    function stage(
        bytes32 _msgHash,
        uint32 _refBlock,
        bytes calldata _storageUpdates,
        uint256 _transitionIndex,
        bytes4 _targetFunction
    ) external {
        msgHash = _msgHash;
        refBlock = _refBlock;
        storageUpdates = _storageUpdates;
        transitionIndex = _transitionIndex;
        targetFunction = _targetFunction;
    }

    /// The CALL-update target. Records the latch state, then tries to re-enter.
    function attack() external {
        sawInTransition = sdk.inTransition();
        address[] memory none = new address[](0);
        try sdk.verifyAndUpdate(
            msgHash, refBlock, storageUpdates, transitionIndex, targetFunction, 1, address(0x1), none
        ) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            caughtSelector = bytes4(reason);
        }
    }

    /// Variant: re-enter through the batch entrypoint instead.
    function attackViaBatch() external {
        sawInTransition = sdk.inTransition();
        TaskSubmission[] memory subs = new TaskSubmission[](1);
        subs[0] = TaskSubmission({
            msgHash: msgHash,
            referenceBlockNumber: refBlock,
            storageUpdates: storageUpdates,
            transitionIndex: transitionIndex,
            targetFunction: targetFunction,
            s: 1,
            Raddr: address(0x1),
            nonSigners: new address[](0),
            value: 0
        });
        try sdk.verifyAndUpdateBatch(subs) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            caughtSelector = bytes4(reason);
        }
    }
}

/// Passive mid-transition reader: records what the latch reports when it is called via a
/// CALL state update.
contract LatchReader {
    TestSDK public sdk;
    bool public sawInTransition;
    uint256 public sawTransitionCount;

    constructor(TestSDK _sdk) {
        sdk = _sdk;
    }

    function observe() external {
        sawInTransition = sdk.inTransition();
        sawTransitionCount = sdk.stateTransitionCount();
    }
}

/// Payable CALL-update target for the value-forwarding tests.
contract ValueSink {
    uint256 public received;

    function take() external payable {
        received += msg.value;
    }
}

/// A batch assembler with no `receive()`, so a refund to it fails.
contract EthRejectingAssembler {
    function settle(TestSDK sdk, TaskSubmission[] calldata subs) external payable {
        sdk.verifyAndUpdateBatch{value: msg.value}(subs);
    }
}

/// A batch assembler whose refund tries to settle again.
contract ReenteringAssembler {
    TestSDK sdk;
    TaskSubmission next;

    function settle(TestSDK _sdk, TaskSubmission[] calldata subs, TaskSubmission calldata _next) external payable {
        sdk = _sdk;
        next = _next;
        sdk.verifyAndUpdateBatch{value: msg.value}(subs);
    }

    receive() external payable {
        sdk.verifyAndUpdate(
            next.msgHash,
            next.referenceBlockNumber,
            next.storageUpdates,
            next.transitionIndex,
            next.targetFunction,
            next.s,
            next.Raddr,
            next.nonSigners
        );
    }
}

contract GasKillerSDKHardeningTest is Test {
    MockSchnorrRegistry mock;
    TestSDK sdk;

    receive() external payable {}

    function setUp() public {
        vm.roll(1000);
        mock = new MockSchnorrRegistry();
        sdk = new TestSDK(address(mock));
    }

    // ---- helpers -----------------------------------------------------------------

    function _storeUpdate(bytes32 slot, bytes32 val) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(slot, val);
        return abi.encode(types, args);
    }

    function _storeAndCallUpdate(bytes32 slot, bytes32 val, address callTarget, bytes memory callData)
        internal
        pure
        returns (bytes memory)
    {
        StateUpdateType[] memory types = new StateUpdateType[](2);
        types[0] = StateUpdateType.STORE;
        types[1] = StateUpdateType.CALL;
        bytes[] memory args = new bytes[](2);
        args[0] = abi.encode(slot, val);
        args[1] = abi.encode(callTarget, uint256(0), callData);
        return abi.encode(types, args);
    }

    /// A lone value-bearing CALL update — the shape that has no funding source unless the
    /// entrypoint is payable.
    function _callUpdate(address target, uint256 val, bytes memory callData) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CALL;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(target, val, callData);
        return abi.encode(types, args);
    }

    function _digest(uint256 transitionIndex, bytes4 targetFn, bytes memory updates) internal view returns (bytes32) {
        return sha256(abi.encode(transitionIndex, address(sdk), targetFn, updates));
    }

    function _digest(uint256 transitionIndex, bytes4 targetFn, bytes memory updates, uint256 value)
        internal
        view
        returns (bytes32)
    {
        if (value == 0) return _digest(transitionIndex, targetFn, updates);
        return sha256(abi.encode(transitionIndex, address(sdk), targetFn, updates, value));
    }

    function _submission(uint256 transitionIndex, bytes memory updates) internal view returns (TaskSubmission memory) {
        return _submission(transitionIndex, updates, 0);
    }

    /// A submission signed for a task analyzed with `value` wei of `msg.value`.
    function _submission(uint256 transitionIndex, bytes memory updates, uint256 value)
        internal
        view
        returns (TaskSubmission memory)
    {
        bytes4 fn = bytes4(keccak256("set()"));
        return TaskSubmission({
            msgHash: _digest(transitionIndex, fn, updates, value),
            referenceBlockNumber: uint32(block.number - 1),
            storageUpdates: updates,
            transitionIndex: transitionIndex,
            targetFunction: fn,
            s: 1,
            Raddr: address(0x1234),
            nonSigners: new address[](0),
            value: value
        });
    }

    function _settle(TaskSubmission memory sub, uint256 value) internal {
        sdk.verifyAndUpdate{value: value}(
            sub.msgHash,
            sub.referenceBlockNumber,
            sub.storageUpdates,
            sub.transitionIndex,
            sub.targetFunction,
            sub.s,
            sub.Raddr,
            sub.nonSigners
        );
    }

    // ---- reentrancy guard --------------------------------------------------------

    /// A CALL-update target re-entering verifyAndUpdate with the *next* transition's
    /// otherwise-valid submission must hit ReentrantTransition — and the outer
    /// transition must still complete (the attacker swallows its own failure).
    function test_reentrantVerifyAndUpdate_reverts() public {
        ReentrantAttacker attacker = new ReentrantAttacker(sdk);

        // Outer transition 0: STORE 42 into slot 0, then CALL attacker.attack().
        bytes memory outerUpdates = _storeAndCallUpdate(
            bytes32(0), bytes32(uint256(42)), address(attacker), abi.encodeCall(ReentrantAttacker.attack, ())
        );
        bytes4 fn = bytes4(keccak256("set()"));
        bytes32 outerHash = _digest(0, fn, outerUpdates);

        // Inner transition 1 (what the attacker will try mid-flight): STORE 666. Its
        // digest/index are exactly what a legitimate *next* submission would carry — the
        // mock registry would approve it, so only the guard stands in the way.
        bytes memory innerUpdates = _storeUpdate(bytes32(0), bytes32(uint256(666)));
        attacker.stage(_digest(1, fn, innerUpdates), uint32(block.number - 1), innerUpdates, 1, fn);

        address[] memory none = new address[](0);
        sdk.verifyAndUpdate(outerHash, uint32(block.number - 1), outerUpdates, 0, fn, 1, address(0x1234), none);

        assertTrue(attacker.sawInTransition(), "latch visible mid-transition");
        assertFalse(attacker.reentrySucceeded(), "re-entry must not succeed");
        assertEq(
            attacker.caughtSelector(),
            TransitionGuard.ReentrantTransition.selector,
            "re-entry rejected by the guard specifically"
        );
        assertEq(sdk.value(), 42, "outer transition applied exactly once");
        assertEq(sdk.stateTransitionCount(), 1, "inner transition did not apply");
    }

    /// Same attack through the batch entrypoint — the guard covers both doors.
    function test_reentrantBatch_reverts() public {
        ReentrantAttacker attacker = new ReentrantAttacker(sdk);

        bytes memory outerUpdates = _storeAndCallUpdate(
            bytes32(0), bytes32(uint256(7)), address(attacker), abi.encodeCall(ReentrantAttacker.attackViaBatch, ())
        );
        bytes4 fn = bytes4(keccak256("set()"));
        bytes32 outerHash = _digest(0, fn, outerUpdates);

        bytes memory innerUpdates = _storeUpdate(bytes32(0), bytes32(uint256(666)));
        attacker.stage(_digest(1, fn, innerUpdates), uint32(block.number - 1), innerUpdates, 1, fn);

        address[] memory none = new address[](0);
        sdk.verifyAndUpdate(outerHash, uint32(block.number - 1), outerUpdates, 0, fn, 1, address(0x1234), none);

        assertFalse(attacker.reentrySucceeded(), "batch re-entry must not succeed");
        assertEq(
            attacker.caughtSelector(),
            TransitionGuard.ReentrantTransition.selector,
            "batch re-entry rejected by the guard"
        );
        assertEq(sdk.value(), 7, "outer transition applied");
        assertEq(sdk.stateTransitionCount(), 1, "no extra transition");
    }

    /// The reverse direction: the OUTER call is a batch whose sub-transition CALLs the
    /// attacker, which tries to re-enter verifyAndUpdate mid-batch. The latch is held
    /// across the whole batch, so the re-entry reverts.
    function test_reentrantFromInsideBatch_reverts() public {
        ReentrantAttacker attacker = new ReentrantAttacker(sdk);

        bytes memory outerUpdates = _storeAndCallUpdate(
            bytes32(0), bytes32(uint256(5)), address(attacker), abi.encodeCall(ReentrantAttacker.attack, ())
        );
        bytes4 fn = bytes4(keccak256("set()"));

        bytes memory innerUpdates = _storeUpdate(bytes32(0), bytes32(uint256(666)));
        attacker.stage(_digest(1, fn, innerUpdates), uint32(block.number - 1), innerUpdates, 1, fn);

        TaskSubmission[] memory subs = new TaskSubmission[](1);
        subs[0] = TaskSubmission({
            msgHash: _digest(0, fn, outerUpdates),
            referenceBlockNumber: uint32(block.number - 1),
            storageUpdates: outerUpdates,
            transitionIndex: 0,
            targetFunction: fn,
            s: 1,
            Raddr: address(0x1234),
            nonSigners: new address[](0),
            value: 0
        });
        sdk.verifyAndUpdateBatch(subs);

        assertTrue(attacker.sawInTransition(), "latch held during the batch");
        assertFalse(attacker.reentrySucceeded(), "mid-batch re-entry must not succeed");
        assertEq(
            attacker.caughtSelector(),
            TransitionGuard.ReentrantTransition.selector,
            "mid-batch re-entry rejected by the guard"
        );
        assertEq(sdk.value(), 5, "batch transition applied");
        assertEq(sdk.stateTransitionCount(), 1, "no interleaved transition");
    }

    /// The guard releases after a transition: a normal follow-up submission succeeds.
    function test_guardReleasesAfterTransition() public {
        bytes memory updates0 = _storeUpdate(bytes32(0), bytes32(uint256(1)));
        TaskSubmission memory s0 = _submission(0, updates0);
        sdk.verifyAndUpdate(
            s0.msgHash, s0.referenceBlockNumber, s0.storageUpdates, 0, s0.targetFunction, s0.s, s0.Raddr, s0.nonSigners
        );

        bytes memory updates1 = _storeUpdate(bytes32(0), bytes32(uint256(2)));
        TaskSubmission memory s1 = _submission(1, updates1);
        sdk.verifyAndUpdate(
            s1.msgHash, s1.referenceBlockNumber, s1.storageUpdates, 1, s1.targetFunction, s1.s, s1.Raddr, s1.nonSigners
        );

        assertEq(sdk.value(), 2);
        assertEq(sdk.stateTransitionCount(), 2);
        assertFalse(sdk.inTransition(), "latch clear after settlement");
    }

    // ---- in-transition latch -----------------------------------------------------

    /// External readers called mid-transition observe the latch up — and can also see
    /// exactly the midway inconsistency it warns about (the counter already reads N+1
    /// while the transition is still applying).
    function test_latchVisibleMidTransition() public {
        LatchReader reader = new LatchReader(sdk);

        bytes memory updates = _storeAndCallUpdate(
            bytes32(0), bytes32(uint256(9)), address(reader), abi.encodeCall(LatchReader.observe, ())
        );
        bytes4 fn = bytes4(keccak256("set()"));
        bytes32 h = _digest(0, fn, updates);

        assertFalse(sdk.inTransition(), "latch down before");
        address[] memory none = new address[](0);
        sdk.verifyAndUpdate(h, uint32(block.number - 1), updates, 0, fn, 1, address(0x1234), none);

        assertTrue(reader.sawInTransition(), "reader saw the latch up mid-transition");
        assertEq(reader.sawTransitionCount(), 1, "counter already bumped mid-transition (why the latch exists)");
        assertFalse(sdk.inTransition(), "latch down after");
    }

    // ---- value forwarding ----------------------------------------------------------

    /// A value-bearing CALL update funded purely out of `msg.value`: the SDK starts at zero
    /// balance, so this only settles because the entrypoint is payable.
    function test_verifyAndUpdate_forwardsMsgValue() public {
        ValueSink sink = new ValueSink();
        uint256 forwarded = 0.13 ether;
        vm.deal(address(this), forwarded);

        TaskSubmission memory sub =
            _submission(0, _callUpdate(address(sink), forwarded, abi.encodeCall(ValueSink.take, ())), forwarded);

        sdk.verifyAndUpdate{value: forwarded}(
            sub.msgHash,
            sub.referenceBlockNumber,
            sub.storageUpdates,
            sub.transitionIndex,
            sub.targetFunction,
            sub.s,
            sub.Raddr,
            sub.nonSigners
        );

        assertEq(sink.received(), forwarded, "value reached the CALL target");
        assertEq(address(sdk).balance, 0, "msg.value alone funded the update");
        assertEq(sdk.stateTransitionCount(), 1);
    }

    /// Under-funding is a hard failure, not a partial application: the EVM fails the CALL
    /// before the target executes, so `RevertingContext` carries empty revert data.
    function test_verifyAndUpdate_underFundedCallReverts() public {
        ValueSink sink = new ValueSink();
        vm.deal(address(this), 0.1 ether);

        bytes memory callData = abi.encodeCall(ValueSink.take, ());
        TaskSubmission memory sub = _submission(0, _callUpdate(address(sink), 0.2 ether, callData), 0.1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector, 0, address(sink), bytes(""), callData
            )
        );
        sdk.verifyAndUpdate{value: 0.1 ether}(
            sub.msgHash,
            sub.referenceBlockNumber,
            sub.storageUpdates,
            sub.transitionIndex,
            sub.targetFunction,
            sub.s,
            sub.Raddr,
            sub.nonSigners
        );

        assertEq(sdk.stateTransitionCount(), 0, "whole transition rolled back");
        assertEq(sink.received(), 0);
    }

    // ---- batch entrypoint ----------------------------------------------------------

    function test_batch_appliesSequentially() public {
        bytes memory updates0 = _storeUpdate(bytes32(0), bytes32(uint256(11)));
        bytes memory updates1 = _storeUpdate(bytes32(0), bytes32(uint256(22)));

        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, updates0);
        subs[1] = _submission(1, updates1);

        sdk.verifyAndUpdateBatch(subs);

        assertEq(sdk.value(), 22, "last write wins");
        assertEq(sdk.stateTransitionCount(), 2, "both transitions tracked");
        assertFalse(sdk.inTransition());
    }

    function test_batch_revertsAtomically_onIndexGap() public {
        bytes memory updates0 = _storeUpdate(bytes32(0), bytes32(uint256(11)));
        bytes memory updates2 = _storeUpdate(bytes32(0), bytes32(uint256(22)));

        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, updates0);
        subs[1] = _submission(2, updates2); // gap: index 1 never settles

        vm.expectRevert(GasKillerSDK.InvalidTransitionIndex.selector);
        sdk.verifyAndUpdateBatch(subs);

        assertEq(sdk.value(), 0, "nothing applied");
        assertEq(sdk.stateTransitionCount(), 0, "whole batch rolled back");
    }

    /// Front-run tolerance: a third party settles the batch's first submission standalone
    /// (permissionless — they just lift it from the mempool); the batch must then skip
    /// that already-settled index and still apply the rest, instead of reverting wholesale.
    function test_batch_skipsAlreadySettled_frontRun() public {
        bytes memory updates0 = _storeUpdate(bytes32(0), bytes32(uint256(11)));
        bytes memory updates1 = _storeUpdate(bytes32(0), bytes32(uint256(22)));

        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, updates0);
        subs[1] = _submission(1, updates1);

        // Front-runner replays subs[0] verbatim through the standalone entrypoint.
        sdk.verifyAndUpdate(
            subs[0].msgHash,
            subs[0].referenceBlockNumber,
            subs[0].storageUpdates,
            subs[0].transitionIndex,
            subs[0].targetFunction,
            subs[0].s,
            subs[0].Raddr,
            subs[0].nonSigners
        );
        assertEq(sdk.stateTransitionCount(), 1, "front-run consumed index 0");

        // The victim's batch still lands its remaining transition.
        sdk.verifyAndUpdateBatch(subs);
        assertEq(sdk.value(), 22, "transition 1 applied despite the front-run");
        assertEq(sdk.stateTransitionCount(), 2, "exactly one extra transition");
    }

    /// A fully redelivered batch is an idempotent no-op, not a revert.
    function test_batch_allAlreadySettled_isNoop() public {
        bytes memory updates0 = _storeUpdate(bytes32(0), bytes32(uint256(11)));
        TaskSubmission[] memory subs = new TaskSubmission[](1);
        subs[0] = _submission(0, updates0);

        sdk.verifyAndUpdateBatch(subs);
        assertEq(sdk.stateTransitionCount(), 1);

        sdk.verifyAndUpdateBatch(subs); // redelivery
        assertEq(sdk.value(), 11, "state unchanged");
        assertEq(sdk.stateTransitionCount(), 1, "skipped, not re-applied");
    }

    /// Each batch item must forward its OWN (msgHash, s, Raddr) to the registry: with the
    /// strict mock, any cross-item plumbing swap fails verification and reverts the batch.
    function test_batch_forwardsPerItemSignatureArgs() public {
        bytes memory updates0 = _storeUpdate(bytes32(0), bytes32(uint256(11)));
        bytes memory updates1 = _storeUpdate(bytes32(0), bytes32(uint256(22)));

        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, updates0);
        subs[1] = _submission(1, updates1);
        subs[0].s = 0xAAA1;
        subs[0].Raddr = address(0xA1);
        subs[1].s = 0xBBB2;
        subs[1].Raddr = address(0xB2);

        mock.expect(subs[0].msgHash, subs[0].s, subs[0].Raddr);
        mock.expect(subs[1].msgHash, subs[1].s, subs[1].Raddr);

        sdk.verifyAndUpdateBatch(subs);
        assertEq(sdk.stateTransitionCount(), 2, "both verified against their own args");
    }

    /// Amortization is real and measured: the marginal cost of sub-transitions 2..4 is
    /// well below a standalone settlement of the same transition shape (they skip the
    /// per-tx cold warm-up; here everything is in-test so the delta shown is the loop
    /// overhead vs full entrypoint re-entry — the intrinsic/cold savings only show
    /// on-chain and are documented in docs/schnorr-hardening-and-gas.md).
    function test_batch_gasAmortization() public {
        // Warm-up transition so both measured calls run on equal (warm) ground — the
        // very first transition pays the 0->1 counter write and cold account accesses.
        TaskSubmission[] memory warmup = new TaskSubmission[](1);
        warmup[0] = _submission(0, _storeUpdate(bytes32(0), bytes32(uint256(1))));
        sdk.verifyAndUpdateBatch(warmup);

        TaskSubmission[] memory one = new TaskSubmission[](1);
        one[0] = _submission(1, _storeUpdate(bytes32(0), bytes32(uint256(2))));

        uint256 g0 = gasleft();
        sdk.verifyAndUpdateBatch(one);
        uint256 gasOne = g0 - gasleft();

        TaskSubmission[] memory four = new TaskSubmission[](4);
        for (uint256 i = 0; i < 4; i++) {
            four[i] = _submission(2 + i, _storeUpdate(bytes32(0), bytes32(uint256(100 + i))));
        }

        g0 = gasleft();
        sdk.verifyAndUpdateBatch(four);
        uint256 gasFour = g0 - gasleft();

        assertEq(sdk.stateTransitionCount(), 6);
        console2.log("batch of 1:", gasOne);
        console2.log("batch of 4:", gasFour);
        console2.log("marginal per extra sub-transition:", (gasFour - gasOne) / 3);
        // Marginal per extra sub-transition must undercut a whole batch-of-one call.
        assertLt((gasFour - gasOne) / 3, gasOne, "sub-transitions amortize the entrypoint cost");
    }

    function test_batch_revertsAtomically_onRejectedSignature() public {
        bytes memory updates0 = _storeUpdate(bytes32(0), bytes32(uint256(11)));
        TaskSubmission[] memory subs = new TaskSubmission[](1);
        subs[0] = _submission(0, updates0);

        mock.setVerdict(false);
        vm.expectRevert(GasKillerSDK.InvalidQuorumSignature.selector);
        sdk.verifyAndUpdateBatch(subs);
        assertEq(sdk.stateTransitionCount(), 0);
    }

    function test_batch_revertsOnEmpty() public {
        TaskSubmission[] memory subs = new TaskSubmission[](0);
        vm.expectRevert(GasKillerSDK.EmptyBatch.selector);
        sdk.verifyAndUpdateBatch(subs);
    }

    // ---- batch value pooling ---------------------------------------------------------

    /// One `msg.value` covers the whole batch: it tops the balance up once and every applied
    /// sub-transition draws from the same pool rather than from a per-submission allowance.
    function test_batch_poolsMsgValueAcrossSubTransitions() public {
        ValueSink sink = new ValueSink();
        uint256 a = 0.2 ether;
        uint256 b = 0.05 ether;
        vm.deal(address(this), a + b);

        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, _callUpdate(address(sink), a, abi.encodeCall(ValueSink.take, ())), a);
        subs[1] = _submission(1, _callUpdate(address(sink), b, abi.encodeCall(ValueSink.take, ())), b);

        sdk.verifyAndUpdateBatch{value: a + b}(subs);

        assertEq(sink.received(), a + b, "both sub-transitions drew from the same pool");
        assertEq(address(sdk).balance, 0, "the batch consumed exactly what was sent");
        assertEq(sdk.stateTransitionCount(), 2);
    }

    /// The pool is shared, so a shortfall on the *last* sub-transition still unwinds the
    /// fully-funded earlier one — atomicity applies to value as much as to storage.
    function test_batch_underFundedRevertsAtomically() public {
        ValueSink sink = new ValueSink();
        uint256 a = 0.2 ether;
        uint256 b = 0.05 ether;
        vm.deal(address(this), a + b);

        bytes memory callData = abi.encodeCall(ValueSink.take, ());
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, _callUpdate(address(sink), a, callData));
        subs[1] = _submission(1, _callUpdate(address(sink), b, callData));

        vm.expectRevert(
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector, 0, address(sink), bytes(""), callData
            )
        );
        sdk.verifyAndUpdateBatch{value: a + b - 1}(subs);

        assertEq(sink.received(), 0, "nothing applied");
        assertEq(sdk.stateTransitionCount(), 0, "whole batch rolled back");
        assertEq(address(sdk).balance, 0, "reverted batch retains nothing");
    }

    /// A front-run turns one submission into a skip. Its share of the pooled `msg.value` goes
    /// back to the assembler instead of staying in the contract.
    function test_batch_refundsASkippedSubmissionsShare() public {
        ValueSink sink = new ValueSink();
        uint256 a = 0.2 ether;
        uint256 b = 0.05 ether;
        vm.deal(address(this), 2 * a + b);

        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, _callUpdate(address(sink), a, abi.encodeCall(ValueSink.take, ())), a);
        subs[1] = _submission(1, _callUpdate(address(sink), b, abi.encodeCall(ValueSink.take, ())), b);

        // Front-runner lifts subs[0] and settles it standalone, funding it themselves.
        _settle(subs[0], a);

        // The victim's batch still sends the full sum; subs[0] is skipped.
        sdk.verifyAndUpdateBatch{value: a + b}(subs);

        assertEq(sink.received(), a + b, "only the two applied transitions moved value");
        assertEq(sdk.stateTransitionCount(), 2);
        assertEq(address(sdk).balance, 0, "nothing is stranded in the contract");
        assertEq(address(this).balance, a, "the skipped submission's share is refunded");
    }

    /// Value beyond what the applied items need is refunded too, after their updates apply.
    function test_batch_refundsOverpayment() public {
        uint256 a = 0.2 ether;
        uint256 extra = 0.01 ether;
        vm.deal(address(this), a + extra);
        TaskSubmission[] memory subs = new TaskSubmission[](1);
        subs[0] = _submission(0, _storeUpdate(bytes32(0), bytes32(a)), a);

        sdk.verifyAndUpdateBatch{value: a + extra}(subs);

        assertEq(sdk.value(), a);
        assertEq(address(sdk).balance, a, "the contract keeps exactly what it credited");
        assertEq(address(this).balance, extra);
    }

    /// A sender that can't accept the refund doesn't revert the batch; the surplus stays.
    function test_batch_keepsTheSurplusWhenTheSenderRejectsEth() public {
        uint256 a = 0.2 ether;
        uint256 b = 0.05 ether;
        EthRejectingAssembler assembler = new EthRejectingAssembler();
        vm.deal(address(this), 2 * a + b);
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, _storeUpdate(bytes32(0), bytes32(a)), a);
        subs[1] = _submission(1, _storeUpdate(bytes32(0), bytes32(a + b)), b);

        _settle(subs[0], a);
        assembler.settle{value: a + b}(sdk, subs);

        assertEq(sdk.stateTransitionCount(), 2, "the batch still applied");
        assertEq(address(sdk).balance, 2 * a + b, "the unrefundable share stays in the contract");
    }

    /// The refund runs under the latch, so a sender can't use it to settle another transition.
    function test_batch_refundCannotReenterSettlement() public {
        uint256 a = 0.2 ether;
        ReenteringAssembler assembler = new ReenteringAssembler();
        vm.deal(address(this), 1 ether);
        TaskSubmission[] memory subs = new TaskSubmission[](1);
        subs[0] = _submission(0, _storeUpdate(bytes32(0), bytes32(a)), a);
        TaskSubmission memory next = _submission(1, _storeUpdate(bytes32(0), bytes32(uint256(7))));

        assembler.settle{value: 1 ether}(sdk, subs, next);

        assertEq(sdk.stateTransitionCount(), 1, "the re-entrant settlement did not apply");
        assertEq(sdk.value(), a);
        assertEq(address(sdk).balance, 1 ether, "the failed refund left the surplus in place");
    }

    // ---- inbound value -------------------------------------------------------------

    /// A deposit replays as a plain STORE crediting the signed amount. The digest binds the
    /// value, so it settles only with exactly that ETH (gas-killer/solidity-sdk#104).
    function test_verifyAndUpdate_bindsInboundValue() public {
        uint256 deposit = 1 ether;
        vm.deal(address(this), 2 * deposit);
        TaskSubmission memory sub = _submission(0, _storeUpdate(bytes32(0), bytes32(deposit)), deposit);

        vm.expectRevert(GasKillerSDK.InvalidSignature.selector);
        _settle(sub, 0);
        vm.expectRevert(GasKillerSDK.InvalidSignature.selector);
        _settle(sub, deposit - 1);
        vm.expectRevert(GasKillerSDK.InvalidSignature.selector);
        _settle(sub, deposit + 1);

        _settle(sub, deposit);
        assertEq(sdk.value(), deposit);
        assertEq(address(sdk).balance, deposit, "credited exactly what arrived");
    }

    /// A signature over a zero-value task cannot settle a transition that brings ETH either,
    /// so a caller cannot slip value past what the operators analyzed.
    function test_verifyAndUpdate_zeroValueSignatureRejectsValue() public {
        vm.deal(address(this), 1);
        TaskSubmission memory sub = _submission(0, _storeUpdate(bytes32(0), bytes32(uint256(1))));
        vm.expectRevert(GasKillerSDK.InvalidSignature.selector);
        _settle(sub, 1);
    }

    /// Zero-value transitions keep the original four-field digest, so existing signatures and
    /// off-chain parity are unchanged; a valued one uses the five-field encoding.
    function test_digestEncodings() public view {
        bytes memory updates = _storeUpdate(bytes32(0), bytes32(uint256(7)));
        bytes4 fn = bytes4(keccak256("set()"));
        bytes32 legacy = sha256(abi.encode(uint256(3), address(sdk), fn, updates));
        assertEq(sdk.getMessageHash(3, fn, updates), legacy, "zero-value digest unchanged");
        assertEq(sdk.getMessageHashWithValue(3, fn, updates, 0), legacy, "explicit zero matches");
        assertEq(
            sdk.getMessageHashWithValue(3, fn, updates, 5),
            sha256(abi.encode(uint256(3), address(sdk), fn, updates, uint256(5))),
            "valued digest appends the value"
        );
    }

    /// Each batch item binds its own value and `msg.value` must cover the applied sum, so a
    /// batch of deposits cannot be credited more than it brings.
    function test_batch_requiresTheAppliedValue() public {
        uint256 a = 0.2 ether;
        uint256 b = 0.05 ether;
        vm.deal(address(this), a + b);
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, _storeUpdate(bytes32(0), bytes32(a)), a);
        subs[1] = _submission(1, _storeUpdate(bytes32(0), bytes32(a + b)), b);

        vm.expectRevert(abi.encodeWithSelector(GasKillerSDK.InsufficientBatchValue.selector, a + b - 1, a + b));
        sdk.verifyAndUpdateBatch{value: a + b - 1}(subs);

        sdk.verifyAndUpdateBatch{value: a + b}(subs);
        assertEq(sdk.value(), a + b);
        assertEq(address(sdk).balance, a + b);
    }

    /// The item's value is part of its digest, so understating it in the submission fails.
    function test_batch_understatedItemValueFailsTheDigest() public {
        TaskSubmission[] memory subs = new TaskSubmission[](1);
        subs[0] = _submission(0, _storeUpdate(bytes32(0), bytes32(uint256(1 ether))), 1 ether);
        subs[0].value = 0;
        vm.expectRevert(GasKillerSDK.InvalidSignature.selector);
        sdk.verifyAndUpdateBatch(subs);
    }

    /// A skipped item adds nothing to the required value: its transition already settled with
    /// its own ETH, so the rest of the batch needs only its own share.
    function test_batch_skippedItemIsNotRequired() public {
        uint256 a = 0.2 ether;
        uint256 b = 0.05 ether;
        vm.deal(address(this), a + b);
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        subs[0] = _submission(0, _storeUpdate(bytes32(0), bytes32(a)), a);
        subs[1] = _submission(1, _storeUpdate(bytes32(0), bytes32(a + b)), b);

        _settle(subs[0], a);
        sdk.verifyAndUpdateBatch{value: b}(subs);
        assertEq(sdk.value(), a + b);
        assertEq(address(sdk).balance, a + b);
    }

    // ---- ERC-165 -------------------------------------------------------------------

    /// The router's preflight id is untouched; the batch extension is additive.
    function test_supportsBothInterfaceIds() public view {
        assertTrue(sdk.supportsInterface(type(IGasKillerSDK).interfaceId), "core id unchanged");
        assertTrue(sdk.supportsInterface(type(IGasKillerSDKBatch).interfaceId), "batch extension id");
        assertEq(
            type(IGasKillerSDK).interfaceId,
            IGasKillerSDK.verifyAndUpdate.selector,
            "core id is still exactly the verifyAndUpdate selector"
        );
        // Pinned literals. The core ID is what every deployed router preflights, so a change to
        // it is an interface break for all of them; state mutability is not part of a function
        // signature, so `payable` leaves it untouched.
        assertEq(type(IGasKillerSDK).interfaceId, bytes4(0x82b35a01), "core id must not drift");
        // The batch ID is the `verifyAndUpdateBatch` selector, which covers the `TaskSubmission`
        // tuple. It moved from 0x2ea5ee1d when submissions gained `value` (#104): batch callers
        // and probes built for the old struct do not match contracts built from this SDK. Move
        // it again only as a deliberate, announced break.
        assertEq(type(IGasKillerSDKBatch).interfaceId, bytes4(0xce8e6efc), "batch id must not drift");
        assertFalse(sdk.supportsInterface(type(IGasKillerNested).interfaceId), "nested is opt-in");
        assertEq(type(IGasKillerNested).interfaceId, bytes4(0x78481874), "nested id must not drift");
    }

    /// A base consumer has no nested entrypoints, and a NESTED op in a flat program reverts.
    function test_baseConsumer_rejectsNestedOp() public {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.NESTED;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(address(sdk), uint256(0), bytes32(uint256(1)));
        TaskSubmission memory sub = _submission(0, abi.encode(types, args));

        vm.expectRevert(StateChangeHandlerLib.NestedOutsideTree.selector);
        sdk.verifyAndUpdate(
            sub.msgHash,
            sub.referenceBlockNumber,
            sub.storageUpdates,
            sub.transitionIndex,
            sub.targetFunction,
            sub.s,
            sub.Raddr,
            sub.nonSigners
        );

        (bool ok,) = address(sdk).call(abi.encodeCall(IGasKillerNested.pendingChild, ()));
        assertFalse(ok, "no nested entrypoints");
    }
}
