// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ReentrantCheckpoint} from "../../src/examples/reentrant-checkpoint/ReentrantCheckpoint.sol";
import {ReentrantObserver} from "../../src/examples/reentrant-checkpoint/ReentrantObserver.sol";
import {ReentrantCheckpointFactory} from "../../src/examples/reentrant-checkpoint/ReentrantCheckpointFactory.sol";
import {ISchnorrStakeRegistry} from "../../src/schnorr/interface/ISchnorrStakeRegistry.sol";
import {StateUpdateType, StateChangeHandlerLib} from "../../src/StateChangeHandlerLib.sol";

/// Registry stub that approves any signature — this suite exercises the
/// state-application + re-entrancy behavior, not signature verification (covered in
/// SchnorrStakeRegistry.t.sol).
contract MockSchnorrRegistry is ISchnorrStakeRegistry {
    function isValidSignature(bytes32, uint256, address, address[] calldata, uint256) external pure returns (bool) {
        return true;
    }
}

/// @notice Proves that a task making a **re-entrant external call mid-transition** settles
///         correctly through `verifyAndUpdate` when the update program presents canonical
///         intermediate state — and is REJECTED when it does not.
///
///         Slots (from `forge inspect ... storageLayout`): counter=0, lastObserved=1. This
///         mirrors the program the canonical off-chain encoder produces for
///         `ReentrantCheckpoint.advance()`:
///           [Store(counter,N), Call(observer.observe(N)), Store(lastObserved,N)]
contract ReentrantCheckpointTest is Test {
    MockSchnorrRegistry registry;
    ReentrantObserver observer;
    ReentrantCheckpoint checkpoint;

    bytes32 constant SLOT_COUNTER = bytes32(uint256(0));
    bytes32 constant SLOT_LAST_OBSERVED = bytes32(uint256(1));

    // Fixed execution-context fields bound into the task digest. The mock registry ignores the
    // signature, so only digest/preimage consistency matters — the values themselves are arbitrary.
    bytes32 constant ANCHOR = keccak256("anchor-block");
    address constant CALLER = address(0xCA11E4);
    bytes constant CALLDATA = hex"deadbeef";

    function setUp() public {
        vm.roll(1000);
        registry = new MockSchnorrRegistry();
        observer = new ReentrantObserver();
        checkpoint = new ReentrantCheckpoint(address(0xA75), address(registry), address(observer));
    }

    // ---- update-program builders --------------------------------------------------

    function _store(bytes32 slot, bytes32 value) internal pure returns (StateUpdateType, bytes memory) {
        return (StateUpdateType.STORE, abi.encode(slot, value));
    }

    function _observeCall(uint256 expected) internal view returns (StateUpdateType, bytes memory) {
        bytes memory callargs = abi.encodeCall(ReentrantObserver.observe, (expected));
        return (StateUpdateType.CALL, abi.encode(address(observer), uint256(0), callargs));
    }

    /// The canonical program for advance() at transition N-1 -> N.
    function _canonicalProgram(uint256 n) internal view returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](3);
        bytes[] memory args = new bytes[](3);
        (types[0], args[0]) = _store(SLOT_COUNTER, bytes32(n)); // pre-call: counter = N
        (types[1], args[1]) = _observeCall(n); // external re-entrant call
        (types[2], args[2]) = _store(SLOT_LAST_OBSERVED, bytes32(n)); // final write, AFTER the call
        return abi.encode(types, args);
    }

    /// The digest verifyAndUpdate reconstructs. Computed OUTSIDE any expectRevert so the
    /// sha256 precompile staticcall doesn't confuse the cheatcode.
    function _digest(uint256 transitionIndex, bytes memory program) internal view returns (bytes32) {
        return sha256(abi.encode(transitionIndex, address(checkpoint), ANCHOR, CALLER, CALLDATA, program));
    }

    function _submit(uint256 transitionIndex, bytes memory program) internal {
        address[] memory none = new address[](0);
        checkpoint.verifyAndUpdate(
            _digest(transitionIndex, program),
            uint32(block.number - 1),
            program,
            transitionIndex,
            ANCHOR,
            CALLER,
            CALLDATA,
            1,
            address(0x1234),
            none
        );
    }

    // ---- happy path ---------------------------------------------------------------

    /// The re-entrant observation succeeds because the program brings the target to the
    /// canonical intermediate state (counter=N, lastObserved still previous) BEFORE the
    /// external call, then writes lastObserved after. Proves re-entrancy settles safely.
    function test_reentrantTaskSettles() public {
        _submit(0, _canonicalProgram(1));

        assertEq(checkpoint.counter(), 1, "counter advanced");
        assertEq(checkpoint.lastObserved(), 1, "final write applied");
        assertEq(checkpoint.stateTransitionCount(), 1, "transition tracked");
        // The re-entrant call actually executed on-chain during settlement.
        assertEq(observer.confirmations(), 1, "observer confirmed the canonical read");
    }

    /// Two consecutive transitions both settle; the observer confirms each — proving the
    /// intermediate check works every transition (not just the first).
    function test_reentrantTaskSettles_sequential() public {
        _submit(0, _canonicalProgram(1));
        _submit(1, _canonicalProgram(2));
        assertEq(checkpoint.counter(), 2);
        assertEq(checkpoint.lastObserved(), 2);
        assertEq(observer.confirmations(), 2, "both re-entrant reads canonical");
    }

    // ---- the observer's checks are load-bearing (canonical state is required) ------

    /// Omit the pre-call counter slice: the re-entrant read sees the stale value (0, not 1)
    /// and the observer reverts — reverting the whole settlement.
    function test_missingPreCallSlice_reverts() public {
        StateUpdateType[] memory types = new StateUpdateType[](2);
        bytes[] memory args = new bytes[](2);
        (types[0], args[0]) = _observeCall(1); // call FIRST — counter still 0
        (types[1], args[1]) = _store(SLOT_COUNTER, bytes32(uint256(1)));
        bytes memory program = abi.encode(types, args);
        bytes32 h = _digest(0, program); // sha256 done before expectRevert
        address[] memory none = new address[](0);

        // The observe() call is program index 0; the re-entrant read sees counter=0 but
        // expects 1 (the canonical post-increment value), so it reverts with
        // CounterNotCanonical(0, 1), which the CALL handler wraps in RevertingContext.
        vm.expectRevert(
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector,
                uint256(0),
                address(observer),
                abi.encodeWithSelector(ReentrantObserver.CounterNotCanonical.selector, uint256(0), uint256(1)),
                abi.encodeCall(ReentrantObserver.observe, (1))
            )
        );
        checkpoint.verifyAndUpdate(
            h, uint32(block.number - 1), program, 0, ANCHOR, CALLER, CALLDATA, 1, address(0x1234), none
        );
        assertEq(checkpoint.stateTransitionCount(), 0, "nothing settled");
        assertEq(observer.confirmations(), 0, "observer rejected the stale read");
    }

    /// Apply the final `lastObserved` write BEFORE the external call: the re-entrant read
    /// sees a contract that already looks finalized for this transition — an image native
    /// execution never had at that point — and the observer reverts.
    function test_finalStateBeforeCall_reverts() public {
        StateUpdateType[] memory types = new StateUpdateType[](3);
        bytes[] memory args = new bytes[](3);
        (types[0], args[0]) = _store(SLOT_COUNTER, bytes32(uint256(1)));
        (types[1], args[1]) = _store(SLOT_LAST_OBSERVED, bytes32(uint256(1))); // WRONG: too early
        (types[2], args[2]) = _observeCall(1);
        bytes memory program = abi.encode(types, args);
        bytes32 h = _digest(0, program);
        address[] memory none = new address[](0);

        // The observe() call is program index 2; by then lastObserved already equals the
        // expected counter (1), so the re-entrant read reverts with
        // FinalStateAppliedTooEarly(), wrapped in RevertingContext.
        vm.expectRevert(
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector,
                uint256(2),
                address(observer),
                abi.encodeWithSelector(ReentrantObserver.FinalStateAppliedTooEarly.selector),
                abi.encodeCall(ReentrantObserver.observe, (1))
            )
        );
        checkpoint.verifyAndUpdate(
            h, uint32(block.number - 1), program, 0, ANCHOR, CALLER, CALLDATA, 1, address(0x1234), none
        );
        assertEq(checkpoint.stateTransitionCount(), 0, "nothing settled");
    }

    // ---- factory ------------------------------------------------------------------

    function test_factory_deploysWiredPair() public {
        ReentrantCheckpointFactory factory = new ReentrantCheckpointFactory();
        (address cp, address obs) = factory.deployReentrantCheckpoint(address(0xA75), address(registry));

        assertTrue(factory.isContractDeployedByFactory(cp), "tracked");
        assertEq(factory.observerOf(cp), obs, "pair wired");
        assertEq(ReentrantCheckpoint(cp).observer(), obs, "checkpoint points at its observer");
        assertEq(factory.getDeployedContractCount(), 1);
    }
}
