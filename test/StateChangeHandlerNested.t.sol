// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {StateChangeHandlerLib, StateUpdateType, NestedContext} from "../src/StateChangeHandlerLib.sol";
import {IGasKillerNested} from "../src/interface/IGasKillerNested.sol";

/// Runs programs through the handler with or without a tree context.
contract HandlerHarness {
    function runPlain(StateUpdateType[] memory types, bytes[] memory args) external payable {
        StateChangeHandlerLib._runStateUpdates(types, args);
    }

    function runInTree(bytes32 root, StateUpdateType[] memory types, bytes[] memory args, bytes[] memory children)
        external
        payable
    {
        StateChangeHandlerLib._runStateUpdates(types, args, NestedContext(root, children, 0));
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

    function applyNested(bytes32 root, bytes32 expectedLeaf, bytes calldata witness) external payable {
        require(!shouldRevert, "child refused");
        seen.push(Seen(root, expectedLeaf, witness, msg.value, IGasKillerNested(msg.sender).pendingChild()));
    }

    function count() external view returns (uint256) {
        return seen.length;
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

    function _leaf(uint256 i) private pure returns (bytes32) {
        return keccak256(abi.encode("leaf", i));
    }
}
