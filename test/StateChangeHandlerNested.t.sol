// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {StateChangeHandlerLib, StateUpdateType, NestedContext} from "../src/StateChangeHandlerLib.sol";
import {IGasKillerNested} from "../src/interface/IGasKillerNested.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";

/// Runs programs through the handler with or without a tree context.
contract HandlerHarness {
    /// @dev The transition counter, which every real settlement list protects. These programs
    ///      never write it, so the guard is on without changing what they test.
    function _ranges() internal pure returns (StorageGuard.ProtectedRange[] memory r) {
        r = new StorageGuard.ProtectedRange[](1);
        uint256 tracker = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
        r[0] = StorageGuard.ProtectedRange(tracker, tracker, StorageGuard.FULL);
    }

    function runPlain(StateUpdateType[] memory types, bytes[] memory args) external payable {
        StateChangeHandlerLib._runStateUpdates(types, args, _ranges());
    }

    function runWithRanges(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges
    ) external {
        StateChangeHandlerLib._runStateUpdates(types, args, ranges);
    }

    function runInTreeWithRanges(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges
    ) external {
        StateChangeHandlerLib._runStateUpdates(
            types, args, ranges, NestedContext(bytes32(uint256(1)), new bytes[](0), 0)
        );
    }

    function runInTree(bytes32 root, StateUpdateType[] memory types, bytes[] memory args, bytes[] memory children)
        external
        payable
    {
        StateChangeHandlerLib._runStateUpdates(types, args, _ranges(), NestedContext(root, children, 0));
    }

    function pendingChild() external view returns (bytes32) {
        return StateChangeHandlerLib._pendingChild();
    }
}

/// Stands in for an SDK callee: records what its parent handed it and what the parent reported
/// as its pending child at that moment.
contract RecordingChild {
    struct Seen {
        bytes32 root;
        bytes32 leaf;
        bytes witness;
        uint256 value;
        bytes32 parentPending;
    }

    Seen[] public seen;
    bool public shouldRevert;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function applyNested(bytes32 root, bytes32 expectedLeaf, bytes calldata witness) external payable returns (bytes4) {
        require(!shouldRevert, "child refused");
        seen.push(Seen(root, expectedLeaf, witness, msg.value, IGasKillerNested(msg.sender).pendingChild()));
        return IGasKillerNested.applyNested.selector;
    }

    function count() external view returns (uint256) {
        return seen.length;
    }
}

/// Not an SDK callee: accepts any call, as a proxy upgraded away from the SDK might.
contract PermissiveFallback {
    fallback() external payable {}
}

/// Returns a full word that is not the acknowledgement.
contract WrongAck {
    fallback(bytes calldata) external payable returns (bytes memory) {
        return abi.encode(bytes32(uint256(1)));
    }
}

contract StateChangeHandlerNestedTest is Test {
    HandlerHarness parent;
    RecordingChild child;
    bytes32 constant ROOT = keccak256("root");

    function setUp() public {
        parent = new HandlerHarness();
        child = new RecordingChild();
        vm.deal(address(parent), 10 ether);
    }

    /// @notice An empty range list never means unprotected: it reverts on both guarded
    ///         entrypoints, even for a program that writes nothing, so a caller who passes one to
    ///         get past the signature change finds out on the first run. The only unchecked path
    ///         is the explicitly named `_runStateUpdatesUnguarded`.
    function test_emptyRangeListReverts() public {
        StorageGuard.ProtectedRange[] memory none = new StorageGuard.ProtectedRange[](0);
        StateUpdateType[] memory types = new StateUpdateType[](0);
        bytes[] memory args = new bytes[](0);

        vm.expectRevert(StateChangeHandlerLib.NoProtectedRanges.selector);
        parent.runWithRanges(types, args, none);
        vm.expectRevert(StateChangeHandlerLib.NoProtectedRanges.selector);
        parent.runInTreeWithRanges(types, args, none);

        // One range is enough.
        StorageGuard.ProtectedRange[] memory one = new StorageGuard.ProtectedRange[](1);
        one[0] = StorageGuard.ProtectedRange(5, 5, StorageGuard.FULL);
        parent.runWithRanges(types, args, one);
        parent.runInTreeWithRanges(types, args, one);
    }

    /// @notice Pins the documented precondition: the handler doesn't re-validate its list (the SDK
    ///         validates at deployment), so a direct caller's malformed list fails open. If this
    ///         starts reverting, update `_run`'s NatSpec.
    function test_handlerTrustsTheCallerToValidate() public {
        StorageGuard.ProtectedRange[] memory descending = new StorageGuard.ProtectedRange[](2);
        descending[0] = StorageGuard.ProtectedRange(9, 9, StorageGuard.FULL);
        descending[1] = StorageGuard.ProtectedRange(0, 0, StorageGuard.FULL);
        StateUpdateType[] memory types = new StateUpdateType[](1);
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(bytes32(0), bytes32(uint256(1)));
        parent.runWithRanges(types, args, descending);
        assertEq(vm.load(address(parent), bytes32(0)), bytes32(uint256(1)), "slot 0 was written");
    }

    function test_nestedOutsideTreeReverts() public {
        (StateUpdateType[] memory types, bytes[] memory args) = _program(1, 0);
        vm.expectRevert(StateChangeHandlerLib.NestedOutsideTree.selector);
        parent.runPlain(types, args);
    }

    function test_nestedHandsChildItsWitnessAndValue() public {
        (StateUpdateType[] memory types, bytes[] memory args) = _program(1, 1 ether);
        bytes[] memory children = new bytes[](1);
        children[0] = hex"0a0b";
        uint256 before = address(child).balance;

        parent.runInTree(ROOT, types, args, children);

        (bytes32 root, bytes32 leaf, bytes memory witness, uint256 value, bytes32 pending) = child.seen(0);
        assertEq(root, ROOT);
        assertEq(leaf, _leaf(0));
        assertEq(witness, hex"0a0b");
        assertEq(value, 1 ether);
        assertEq(pending, _leaf(0), "parent reports the child it is calling");
        assertEq(address(child).balance - before, 1 ether);
        assertEq(parent.pendingChild(), bytes32(0), "cleared after the call");
    }

    function test_childrenAreConsumedInProgramOrder() public {
        (StateUpdateType[] memory types, bytes[] memory args) = _program(3, 0);
        bytes[] memory children = new bytes[](3);
        for (uint256 i = 0; i < 3; ++i) {
            children[i] = abi.encode(i);
        }
        parent.runInTree(ROOT, types, args, children);
        for (uint256 i = 0; i < 3; ++i) {
            (, bytes32 leaf, bytes memory witness,, bytes32 pending) = child.seen(i);
            assertEq(leaf, _leaf(i));
            assertEq(witness, abi.encode(i));
            assertEq(pending, _leaf(i));
        }
    }

    function test_moreNestedOpsThanWitnessesReverts() public {
        (StateUpdateType[] memory types, bytes[] memory args) = _program(2, 0);
        bytes[] memory children = new bytes[](1);
        vm.expectRevert(abi.encodeWithSelector(StateChangeHandlerLib.MissingWitness.selector, 1));
        parent.runInTree(ROOT, types, args, children);
    }

    function test_surplusWitnessesRevert() public {
        (StateUpdateType[] memory types, bytes[] memory args) = _program(1, 0);
        bytes[] memory children = new bytes[](2);
        vm.expectRevert(abi.encodeWithSelector(StateChangeHandlerLib.UnconsumedWitnesses.selector, 2, 1));
        parent.runInTree(ROOT, types, args, children);
    }

    function test_witnessesWithoutNestedOpsRevertEvenOutsideNesting() public {
        StateUpdateType[] memory types = new StateUpdateType[](0);
        bytes[] memory args = new bytes[](0);
        bytes[] memory children = new bytes[](1);
        vm.expectRevert(abi.encodeWithSelector(StateChangeHandlerLib.UnconsumedWitnesses.selector, 1, 0));
        parent.runInTree(ROOT, types, args, children);
    }

    function test_revertingChildSurfacesAsRevertingContext() public {
        child.setRevert(true);
        (StateUpdateType[] memory types, bytes[] memory args) = _program(1, 0);
        bytes[] memory children = new bytes[](1);
        bytes memory callargs = abi.encodeCall(IGasKillerNested.applyNested, (ROOT, _leaf(0), children[0]));
        bytes memory reason = abi.encodeWithSignature("Error(string)", "child refused");
        vm.expectRevert(
            abi.encodeWithSelector(StateChangeHandlerLib.RevertingContext.selector, 0, address(child), reason, callargs)
        );
        parent.runInTree(ROOT, types, args, children);
        assertEq(parent.pendingChild(), bytes32(0));
    }

    function test_targetWithoutCodeIsNotTreatedAsApplied() public {
        _expectNotApplied(address(0xC0DE));
    }

    function test_permissiveFallbackIsNotTreatedAsApplied() public {
        _expectNotApplied(address(new PermissiveFallback()));
    }

    function test_wrongAcknowledgementIsNotTreatedAsApplied() public {
        _expectNotApplied(address(new WrongAck()));
    }

    function test_plainProgramsRunUnchanged() public {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        bytes[] memory args = new bytes[](1);
        types[0] = StateUpdateType.STORE;
        args[0] = abi.encode(bytes32(uint256(5)), bytes32(uint256(42)));
        parent.runPlain(types, args);
        assertEq(vm.load(address(parent), bytes32(uint256(5))), bytes32(uint256(42)));
    }

    function test_nestedIsAppendedAfterExistingDiscriminants() public pure {
        assertEq(uint8(StateUpdateType.CREATE2), 8);
        assertEq(uint8(StateUpdateType.NESTED), 9);
    }

    function _program(uint256 n, uint256 value)
        private
        view
        returns (StateUpdateType[] memory types, bytes[] memory args)
    {
        types = new StateUpdateType[](n);
        args = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            types[i] = StateUpdateType.NESTED;
            args[i] = abi.encode(address(child), value, _leaf(i));
        }
    }

    function _expectNotApplied(address target) private {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        bytes[] memory args = new bytes[](1);
        types[0] = StateUpdateType.NESTED;
        args[0] = abi.encode(target, uint256(0), _leaf(0));
        bytes[] memory children = new bytes[](1);
        vm.expectRevert(abi.encodeWithSelector(StateChangeHandlerLib.NestedNotApplied.selector, 0, target));
        parent.runInTree(ROOT, types, args, children);
    }

    function _leaf(uint256 i) private pure returns (bytes32) {
        return keccak256(abi.encode("leaf", i));
    }
}
