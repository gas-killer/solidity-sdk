// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {SchnorrGasKillerSDK} from "../src/schnorr/SchnorrGasKillerSDK.sol";
import {TransitionGuard} from "../src/TransitionGuard.sol";
import {ISchnorrGasKillerSDK} from "../src/schnorr/interface/ISchnorrGasKillerSDK.sol";
import {ISchnorrGasKillerSDKBatch, SchnorrTaskSubmission} from "../src/schnorr/interface/ISchnorrGasKillerSDKBatch.sol";
import {ISchnorrStakeRegistry} from "../src/schnorr/interface/ISchnorrStakeRegistry.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";

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

contract TestSchnorrSDK is SchnorrGasKillerSDK {
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
    TestSchnorrSDK public sdk;
    bool public sawInTransition;
    bytes4 public caughtSelector;
    bool public reentrySucceeded;

    // Pre-staged arguments for the re-entrant verifyAndUpdate (transition N+1).
    bytes32 public msgHash;
    uint32 public refBlock;
    bytes public storageUpdates;
    uint256 public transitionIndex;
    bytes4 public targetFunction;

    constructor(TestSchnorrSDK _sdk) {
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
        SchnorrTaskSubmission[] memory subs = new SchnorrTaskSubmission[](1);
        subs[0] = SchnorrTaskSubmission({
            msgHash: msgHash,
            referenceBlockNumber: refBlock,
            storageUpdates: storageUpdates,
            transitionIndex: transitionIndex,
            targetFunction: targetFunction,
            s: 1,
            Raddr: address(0x1),
            nonSigners: new address[](0)
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
    TestSchnorrSDK public sdk;
    bool public sawInTransition;
    uint256 public sawTransitionCount;

    constructor(TestSchnorrSDK _sdk) {
        sdk = _sdk;
    }

    function observe() external {
        sawInTransition = sdk.inTransition();
        sawTransitionCount = sdk.stateTransitionCount();
    }
}

contract SchnorrGasKillerSDKHardeningTest is Test {
    MockSchnorrRegistry mock;
    TestSchnorrSDK sdk;

    function setUp() public {
        vm.roll(1000);
        mock = new MockSchnorrRegistry();
        sdk = new TestSchnorrSDK(address(mock));
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

    function _digest(uint256 transitionIndex, bytes4 targetFn, bytes memory updates) internal view returns (bytes32) {
        return sha256(abi.encode(transitionIndex, address(sdk), targetFn, updates));
    }

    function _submission(uint256 transitionIndex, bytes memory updates)
        internal
        view
        returns (SchnorrTaskSubmission memory)
    {
        bytes4 fn = bytes4(keccak256("set()"));
        return SchnorrTaskSubmission({
            msgHash: _digest(transitionIndex, fn, updates),
            referenceBlockNumber: uint32(block.number - 1),
            storageUpdates: updates,
            transitionIndex: transitionIndex,
            targetFunction: fn,
            s: 1,
            Raddr: address(0x1234),
            nonSigners: new address[](0)
        });
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

        SchnorrTaskSubmission[] memory subs = new SchnorrTaskSubmission[](1);
        subs[0] = SchnorrTaskSubmission({
            msgHash: _digest(0, fn, outerUpdates),
            referenceBlockNumber: uint32(block.number - 1),
            storageUpdates: outerUpdates,
            transitionIndex: 0,
            targetFunction: fn,
            s: 1,
            Raddr: address(0x1234),
            nonSigners: new address[](0)
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
        SchnorrTaskSubmission memory s0 = _submission(0, updates0);
        sdk.verifyAndUpdate(
            s0.msgHash, s0.referenceBlockNumber, s0.storageUpdates, 0, s0.targetFunction, s0.s, s0.Raddr, s0.nonSigners
        );

        bytes memory updates1 = _storeUpdate(bytes32(0), bytes32(uint256(2)));
        SchnorrTaskSubmission memory s1 = _submission(1, updates1);
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

    // ---- batch entrypoint ----------------------------------------------------------

    function test_batch_appliesSequentially() public {
        bytes memory updates0 = _storeUpdate(bytes32(0), bytes32(uint256(11)));
        bytes memory updates1 = _storeUpdate(bytes32(0), bytes32(uint256(22)));

        SchnorrTaskSubmission[] memory subs = new SchnorrTaskSubmission[](2);
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

        SchnorrTaskSubmission[] memory subs = new SchnorrTaskSubmission[](2);
        subs[0] = _submission(0, updates0);
        subs[1] = _submission(2, updates2); // gap: index 1 never settles

        vm.expectRevert(SchnorrGasKillerSDK.InvalidTransitionIndex.selector);
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

        SchnorrTaskSubmission[] memory subs = new SchnorrTaskSubmission[](2);
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
        SchnorrTaskSubmission[] memory subs = new SchnorrTaskSubmission[](1);
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

        SchnorrTaskSubmission[] memory subs = new SchnorrTaskSubmission[](2);
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
        SchnorrTaskSubmission[] memory warmup = new SchnorrTaskSubmission[](1);
        warmup[0] = _submission(0, _storeUpdate(bytes32(0), bytes32(uint256(1))));
        sdk.verifyAndUpdateBatch(warmup);

        SchnorrTaskSubmission[] memory one = new SchnorrTaskSubmission[](1);
        one[0] = _submission(1, _storeUpdate(bytes32(0), bytes32(uint256(2))));

        uint256 g0 = gasleft();
        sdk.verifyAndUpdateBatch(one);
        uint256 gasOne = g0 - gasleft();

        SchnorrTaskSubmission[] memory four = new SchnorrTaskSubmission[](4);
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
        SchnorrTaskSubmission[] memory subs = new SchnorrTaskSubmission[](1);
        subs[0] = _submission(0, updates0);

        mock.setVerdict(false);
        vm.expectRevert(SchnorrGasKillerSDK.InvalidQuorumSignature.selector);
        sdk.verifyAndUpdateBatch(subs);
        assertEq(sdk.stateTransitionCount(), 0);
    }

    function test_batch_revertsOnEmpty() public {
        SchnorrTaskSubmission[] memory subs = new SchnorrTaskSubmission[](0);
        vm.expectRevert(SchnorrGasKillerSDK.EmptyBatch.selector);
        sdk.verifyAndUpdateBatch(subs);
    }

    // ---- ERC-165 -------------------------------------------------------------------

    /// The router's preflight id is untouched; the batch extension is additive.
    function test_supportsBothInterfaceIds() public view {
        assertTrue(sdk.supportsInterface(type(ISchnorrGasKillerSDK).interfaceId), "core id unchanged");
        assertTrue(sdk.supportsInterface(type(ISchnorrGasKillerSDKBatch).interfaceId), "batch extension id");
        assertEq(
            type(ISchnorrGasKillerSDK).interfaceId,
            ISchnorrGasKillerSDK.verifyAndUpdate.selector,
            "core id is still exactly the verifyAndUpdate selector"
        );
    }
}
