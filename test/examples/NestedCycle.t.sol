// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SchnorrStakeRegistry} from "../../src/SchnorrStakeRegistry.sol";
import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {TreeSubmission} from "../../src/interface/IGasKillerNested.sol";
import {QuorumSignature} from "../../src/interface/ISchnorrApprovalRegistry.sol";
import {CycleRoot} from "../../src/examples/nested-cycle/CycleRoot.sol";
import {CycleRelay} from "../../src/examples/nested-cycle/CycleRelay.sol";
import {SchnorrSigner} from "../utils/SchnorrSigner.sol";
import {NestedTreeBuilder} from "../utils/NestedTreeBuilder.sol";

/// Called from inside the re-entered root frame. Mirrors `CycleRoot.finish`'s native check,
/// which never runs on replay: the re-entered frame must see the counter `start` already wrote
/// and must not yet see its own final write.
contract CycleObserver {
    error NotIntermediateState(uint256 counter, uint256 settled);

    uint256 public confirmations;

    function check(CycleRoot root, uint256 expected) external {
        if (root.counter() != expected || root.settled() == expected) {
            revert NotIntermediateState(root.counter(), root.settled());
        }
        confirmations += 1;
    }
}

/// @notice End to end: `CycleRoot.start` → `CycleRelay.relay` → `CycleRoot.finish` settled as
///         one tree in which the root contract applies two frames, the second while the first
///         is still applying.
contract NestedCycleTest is Test {
    using NestedTreeBuilder for NestedTreeBuilder.Frame[];

    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    uint256 constant OPERATOR_KEY = 0xA11CE5;

    SchnorrStakeRegistry registry;
    CycleRoot root;
    CycleRelay relay;
    CycleObserver observer;
    uint256 expiryBlock;

    function setUp() public {
        vm.roll(1000);
        registry = new SchnorrStakeRegistry(2, 3, address(this), 0);
        (uint256 px, uint256 py) = SchnorrSigner.publicKey(OPERATOR_KEY);
        (uint256 popS, address popR) =
            SchnorrSigner.sign(OPERATOR_KEY, 991, registry.popMessage(registry.pointAddress(px, py)));
        registry.registerOperator(px, py, 1, popS, popR);
        vm.roll(block.number + 10);

        root = new CycleRoot(address(0xA75), address(registry));
        relay = new CycleRelay(address(0xA75), address(registry), root);
        root.setRelay(relay);
        observer = new CycleObserver();
        expiryBlock = block.number + 50;
    }

    function test_cycleSettlesAndMatchesNativeExecution() public {
        uint256 snapshot = vm.snapshotState();
        root.start();
        (uint256 counter, uint256 settled, uint256 relayed) = (root.counter(), root.settled(), relay.relayed());
        (uint256 rootCount, uint256 relayCount) = (root.stateTransitionCount(), relay.stateTransitionCount());
        vm.revertToState(snapshot);

        root.verifyAndUpdateTree(_submission(counter));

        assertEq(root.counter(), counter);
        assertEq(root.settled(), settled);
        assertEq(relay.relayed(), relayed);
        assertEq(root.stateTransitionCount(), rootCount, "two root frames, two transitions");
        assertEq(relay.stateTransitionCount(), relayCount);
        assertEq(observer.confirmations(), 1, "re-entered frame saw canonical intermediate state");
        assertFalse(root.inTransition());
    }

    function test_reenteredFrameAppliedTooEarlyIsCaught() public {
        // Moving the root frame's final re-assertion of `settled` ahead of the NESTED call makes
        // the re-entered frame observe final state, which native execution never shows it.
        NestedTreeBuilder.Frame[] memory frames = _frames(1, true);
        TreeSubmission memory sub = _toSubmission(frames.build(expiryBlock));
        bytes memory reason = abi.encodeWithSelector(CycleObserver.NotIntermediateState.selector, 1, 1);
        try root.verifyAndUpdateTree(sub) {
            fail("tree settled");
        } catch (bytes memory err) {
            // The observer's error arrives wrapped in one RevertingContext per enclosing frame.
            assertTrue(_contains(err, reason), "observer rejected the early final write");
        }
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; ++i) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length && match_; ++j) {
                match_ = haystack[i + j] == needle[j];
            }
            if (match_) return true;
        }
        return false;
    }

    function _submission(uint256 n) private returns (TreeSubmission memory) {
        return _toSubmission(_frames(n, false).build(expiryBlock));
    }

    /// Frame 0 is `start` (root index 0), frame 1 is `relay`, frame 2 is `finish` (root index 1).
    /// Frame 0 ends with the canonical encoder's final slice, re-asserting every slot the root
    /// contract touched, including the ones frame 2 wrote.
    function _frames(uint256 n, bool settleEarly) private view returns (NestedTreeBuilder.Frame[] memory frames) {
        frames = new NestedTreeBuilder.Frame[](3);

        frames[0] = _frame(address(root), address(0), 0, CycleRoot.start.selector, "", settleEarly ? 6 : 5);
        uint256 i;
        _op(frames[0], i++, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(uint256(1))));
        _op(frames[0], i++, StateUpdateType.STORE, abi.encode(bytes32(0), bytes32(n)));
        if (settleEarly) _op(frames[0], i++, StateUpdateType.STORE, abi.encode(bytes32(uint256(1)), bytes32(n)));
        _op(frames[0], i++, StateUpdateType.NESTED, abi.encode(address(relay), uint256(0), uint256(1)));
        _op(frames[0], i++, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(uint256(2))));
        _op(frames[0], i++, StateUpdateType.STORE, abi.encode(bytes32(uint256(1)), bytes32(n)));

        frames[1] = _frame(address(relay), address(root), 0, bytes4(0), abi.encodeCall(CycleRelay.relay, (n)), 3);
        _op(frames[1], 0, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(uint256(1))));
        _op(frames[1], 1, StateUpdateType.STORE, abi.encode(bytes32(0), bytes32(n)));
        _op(frames[1], 2, StateUpdateType.NESTED, abi.encode(address(root), uint256(0), uint256(2)));

        frames[2] = _frame(address(root), address(relay), 1, bytes4(0), abi.encodeCall(CycleRoot.finish, (n)), 3);
        _op(frames[2], 0, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(uint256(2))));
        _op(
            frames[2],
            1,
            StateUpdateType.CALL,
            abi.encode(address(observer), uint256(0), abi.encodeCall(CycleObserver.check, (root, n)))
        );
        _op(frames[2], 2, StateUpdateType.STORE, abi.encode(bytes32(uint256(1)), bytes32(n)));
    }

    function _toSubmission(NestedTreeBuilder.Tree memory tree) private returns (TreeSubmission memory) {
        (uint256 s, address r) = SchnorrSigner.sign(OPERATOR_KEY, uint256(keccak256(abi.encode(tree.root))), tree.root);
        return TreeSubmission(
            tree.root,
            expiryBlock,
            tree.expiryProof,
            QuorumSignature(s, r, new address[](0), block.number - 1),
            0,
            CycleRoot.start.selector,
            tree.programs[0],
            tree.rootProof,
            tree.rootChildren
        );
    }

    function _frame(
        address target,
        address caller,
        uint256 index,
        bytes4 selector,
        bytes memory nativeCall,
        uint256 ops
    ) private pure returns (NestedTreeBuilder.Frame memory f) {
        f.target = target;
        f.caller = caller;
        f.index = index;
        f.targetFunction = selector;
        f.calldataHash = keccak256(nativeCall);
        f.types = new StateUpdateType[](ops);
        f.args = new bytes[](ops);
    }

    function _op(NestedTreeBuilder.Frame memory f, uint256 i, StateUpdateType kind, bytes memory arg) private pure {
        f.types[i] = kind;
        f.args[i] = arg;
    }
}
