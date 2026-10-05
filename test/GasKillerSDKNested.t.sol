// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {SchnorrStakeRegistry} from "../src/SchnorrStakeRegistry.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {TransitionGuard} from "../src/TransitionGuard.sol";
import {IGasKillerNested, TreeSubmission} from "../src/interface/IGasKillerNested.sol";
import {ISchnorrApprovalRegistry, QuorumSignature} from "../src/interface/ISchnorrApprovalRegistry.sol";
import {NestedFrames} from "../src/libraries/NestedFrames.sol";
import {SchnorrSigner} from "./utils/SchnorrSigner.sol";
import {NestedTreeBuilder} from "./utils/NestedTreeBuilder.sol";

contract NestedNode is GasKillerSDK {
    constructor(address registry) {
        _setSchnorrRegistry(registry);
        _setAvsAddress(address(0xA75));
    }

    receive() external payable {}

    function setBlockStaleMeasure(uint256 measure) external {
        _setBlockStaleMeasure(measure);
    }

    /// A native tracked call: moves the counter outside any signed tree.
    function bump() external trackState {}
}

/// An SDK consumer that forwards arbitrary calls, like a multicall or smart wallet.
contract ForwardingNode is NestedNode {
    constructor(address registry) NestedNode(registry) {}

    function forward(address target, bytes calldata data) external payable {
        (bool ok, bytes memory result) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

/// Not an SDK contract: reports whatever pending child it is told to.
contract AttackerParent {
    bytes32 public pendingChild;

    function attack(address victim, bytes32 root, bytes32 leaf, bytes calldata witness) external {
        pendingChild = leaf;
        IGasKillerNested(victim).applyNested(root, leaf, witness);
    }
}

/// Called mid-transition by a CALL op; records what it observed or re-enters.
contract Probe {
    bool public sawInTransition;
    bytes public reentry;
    address public reentryTarget;

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentry = data;
    }

    function observe(address node) external {
        sawInTransition = GasKillerSDK(payable(node)).inTransition();
        if (reentryTarget != address(0)) {
            (bool ok, bytes memory result) = reentryTarget.call(reentry);
            if (!ok) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }
}

contract GasKillerSDKNestedTest is Test {
    using NestedTreeBuilder for NestedTreeBuilder.Frame[];

    SchnorrStakeRegistry registry;
    NestedNode a;
    NestedNode b;
    NestedNode c;
    Probe probe;

    uint256 constant OPERATOR_KEY = 0xA11CE5;
    bytes4 constant TASK = bytes4(keccak256("task()"));
    bytes32 constant SLOT_X = bytes32(uint256(0x10));
    bytes32 constant SLOT_Y = bytes32(uint256(0x11));

    uint256 expiryBlock;

    function setUp() public {
        vm.roll(1000);
        registry = new SchnorrStakeRegistry(2, 3, address(this), 0);
        (uint256 px, uint256 py) = SchnorrSigner.publicKey(OPERATOR_KEY);
        (uint256 popS, address popR) =
            SchnorrSigner.sign(OPERATOR_KEY, 991, registry.popMessage(registry.pointAddress(px, py)));
        registry.registerOperator(px, py, 1, popS, popR);
        vm.roll(block.number + 10);

        a = new NestedNode(address(registry));
        b = new NestedNode(address(registry));
        c = new NestedNode(address(registry));
        probe = new Probe();
        expiryBlock = block.number + 50;
    }

    // ---------------------------------------------------------------------------------
    // Happy paths
    // ---------------------------------------------------------------------------------

    function test_chainAppliesEveryFrame() public {
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](3);
        frames[0] = _frame(address(a), address(0), 0, 0, _ops2(_store(SLOT_X, 1), _nested(address(b), 0, 1)));
        frames[1] = _frame(address(b), address(a), 0, 0, _ops2(_store(SLOT_X, 2), _nested(address(c), 0, 2)));
        frames[2] = _frame(address(c), address(b), 0, 0, _ops2(_store(SLOT_X, 3), _log1(keccak256("from c"))));
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);

        vm.recordLogs();
        a.verifyAndUpdateTree(_submission(tree, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_load(a, SLOT_X), 1);
        assertEq(_load(b, SLOT_X), 2);
        assertEq(_load(c, SLOT_X), 3);
        assertEq(a.stateTransitionCount(), 1);
        assertEq(b.stateTransitionCount(), 1);
        assertEq(c.stateTransitionCount(), 1);
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(c));
        assertFalse(a.inTransition());
        assertEq(a.pendingChild(), bytes32(0));
    }

    function test_cycleAppliesBothRootContractFramesAndHoldsTheLatch() public {
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](3);
        frames[0] = _frame(address(a), address(0), 0, 0, _ops2(_store(SLOT_X, 1), _nested(address(b), 0, 1)));
        frames[1] = _frame(address(b), address(a), 0, 0, _ops2(_store(SLOT_X, 2), _nested(address(a), 0, 2)));
        frames[2] = _frame(
            address(a),
            address(b),
            1,
            0,
            _ops2(_store(SLOT_Y, 5), _call(address(probe), abi.encodeCall(Probe.observe, (address(a)))))
        );
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);

        a.verifyAndUpdateTree(_submission(tree, 0));

        assertEq(_load(a, SLOT_X), 1);
        assertEq(_load(a, SLOT_Y), 5);
        assertEq(_load(b, SLOT_X), 2);
        assertEq(a.stateTransitionCount(), 2, "one index per A frame");
        assertTrue(probe.sawInTransition(), "A latched during its inner frame");
        assertFalse(a.inTransition());
    }

    function test_calleeCalledTwiceAppliesInOrder() public {
        NestedTreeBuilder.Frame[] memory frames = _twiceFrames();
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        a.verifyAndUpdateTree(_submission(tree, 0));
        assertEq(_load(b, SLOT_X), 20, "second frame applied last");
        assertEq(b.stateTransitionCount(), 2);
    }

    function test_swappedWitnessesForTheSameCalleeRevert() public {
        NestedTreeBuilder.Frame[] memory frames = _twiceFrames();
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        (tree.rootChildren[0], tree.rootChildren[1]) = (tree.rootChildren[1], tree.rootChildren[0]);
        TreeSubmission memory sub = _submission(tree, 0);
        vm.expectPartialRevert(StateChangeHandlerLib.RevertingContext.selector);
        a.verifyAndUpdateTree(sub);
    }

    function test_valueForwardedThroughNestedOp() public {
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](2);
        frames[0] = _frame(address(a), address(0), 0, 0, _ops1(_nested(address(b), 1 ether, 1)));
        frames[1] = _frame(address(b), address(a), 0, 1 ether, _ops1(_store(SLOT_X, 9)));
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        a.verifyAndUpdateTree{value: 1 ether}(_submission(tree, 0));
        assertEq(address(b).balance, 1 ether);
        assertEq(address(a).balance, 0);
    }

    function test_twoLeafTreeMatchesSingleTransitionSettlement() public {
        NestedNode twin = new NestedNode(address(registry));
        StateUpdateType[] memory types = new StateUpdateType[](1);
        bytes[] memory args = new bytes[](1);
        Op memory op = _store(SLOT_X, 77);
        (types[0], args[0]) = (op.kind, op.arg);
        bytes memory program = abi.encode(types, args);

        bytes32 digest = twin.getMessageHash(0, TASK, program);
        (uint256 s, address r) = SchnorrSigner.sign(OPERATOR_KEY, 4242, digest);
        twin.verifyAndUpdate(digest, uint32(block.number - 1), program, 0, TASK, s, r, new address[](0));

        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](1);
        frames[0] = _frame(address(a), address(0), 0, 0, _ops1(_store(SLOT_X, 77)));
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        assertEq(tree.frameLeaves[0], a.getMessageHash(0, TASK, program), "root leaf is the legacy digest");
        a.verifyAndUpdateTree(_submission(tree, 0));

        assertEq(_load(a, SLOT_X), _load(twin, SLOT_X));
        assertEq(a.stateTransitionCount(), twin.stateTransitionCount());
    }

    // ---------------------------------------------------------------------------------
    // Frames applied outside their parent
    // ---------------------------------------------------------------------------------

    function test_directCallerOtherThanTheSignedParentFails() public {
        NestedTreeBuilder.Tree memory tree = _chainAB().build(expiryBlock);
        _approve(tree, address(a));
        vm.expectPartialRevert(IGasKillerNested.LeafMismatch.selector);
        b.applyNested(tree.root, tree.frameLeaves[1], tree.witnesses[1]);
    }

    function test_forwardingParentCannotBeMadeToApplyAFrameOutsideItsTree() public {
        ForwardingNode f = new ForwardingNode(address(registry));
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](2);
        frames[0] = _frame(address(f), address(0), 0, 0, _ops2(_store(SLOT_X, 1), _nested(address(b), 0, 1)));
        frames[1] = _frame(address(b), address(f), 0, 0, _ops1(_store(SLOT_X, 2)));
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);

        _approve(tree, address(f));
        bytes memory call =
            abi.encodeCall(IGasKillerNested.applyNested, (tree.root, tree.frameLeaves[1], tree.witnesses[1]));
        vm.expectRevert(
            abi.encodeWithSelector(IGasKillerNested.NotPendingChild.selector, address(f), tree.frameLeaves[1])
        );
        f.forward(address(b), call);
        assertEq(b.stateTransitionCount(), 0);
    }

    function test_attackerNamedAsParentIsBoundedByTheSignedExpiry() public {
        AttackerParent attacker = new AttackerParent();
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](2);
        frames[0] = _frame(address(a), address(0), 0, 0, _ops1(_nested(address(c), 0, 1)));
        frames[1] = _frame(address(c), address(attacker), 0, 0, _ops1(_store(SLOT_X, 66)));
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        QuorumSignature memory sig = _sign(tree.root);

        uint256 snapshot = vm.snapshotState();
        registry.verifyAndApprove(tree.root, address(a), expiryBlock, tree.expiryProof, sig);
        attacker.attack(address(c), tree.root, tree.frameLeaves[1], tree.witnesses[1]);
        assertEq(_load(c, SLOT_X), 66, "within expiry only the named frame applies");
        assertEq(a.stateTransitionCount(), 0);

        vm.revertToState(snapshot);
        vm.roll(expiryBlock + 1);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrApprovalRegistry.ApprovalExpired.selector, expiryBlock));
        registry.verifyAndApprove(tree.root, address(a), expiryBlock, tree.expiryProof, sig);
        vm.expectRevert(abi.encodeWithSelector(IGasKillerNested.NotApproved.selector, tree.root));
        attacker.attack(address(c), tree.root, tree.frameLeaves[1], tree.witnesses[1]);
    }

    function test_unapprovedRootIsRejected() public {
        NestedTreeBuilder.Tree memory tree = _chainAB().build(expiryBlock);
        vm.prank(address(a));
        vm.expectRevert(abi.encodeWithSelector(IGasKillerNested.NotApproved.selector, tree.root));
        b.applyNested(tree.root, tree.frameLeaves[1], tree.witnesses[1]);
    }

    function test_wrongForwardedValueFailsTheLeaf() public {
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](2);
        frames[0] = _frame(address(a), address(0), 0, 0, _ops1(_nested(address(b), 0, 1)));
        frames[1] = _frame(address(b), address(a), 0, 1 ether, _ops1(_store(SLOT_X, 2)));
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        TreeSubmission memory sub = _submission(tree, 0);
        vm.expectPartialRevert(StateChangeHandlerLib.RevertingContext.selector);
        a.verifyAndUpdateTree(sub);
    }

    // ---------------------------------------------------------------------------------
    // Staleness, ordering and expiry
    // ---------------------------------------------------------------------------------

    function test_replayedTreeRevertsOnTheRootIndex() public {
        NestedTreeBuilder.Tree memory tree = _chainAB().build(expiryBlock);
        TreeSubmission memory sub = _submission(tree, 0);
        a.verifyAndUpdateTree(sub);
        vm.expectRevert(GasKillerSDK.InvalidTransitionIndex.selector);
        a.verifyAndUpdateTree(sub);
    }

    function test_calleeCounterMovedBeforeSettlementRevertsTheWholeTree() public {
        NestedTreeBuilder.Tree memory tree = _chainAB().build(expiryBlock);
        TreeSubmission memory sub = _submission(tree, 0);
        b.bump();
        vm.expectPartialRevert(StateChangeHandlerLib.RevertingContext.selector);
        a.verifyAndUpdateTree(sub);
        assertEq(_load(a, SLOT_X), 0);
        assertEq(a.stateTransitionCount(), 0);
    }

    function test_calleeWithTighterStalenessWindowRejectsAnOlderRefBlock() public {
        NestedTreeBuilder.Tree memory tree = _chainAB().build(expiryBlock);
        b.setBlockStaleMeasure(3);
        TreeSubmission memory sub = _submission(tree, 0);
        sub.sig = _signAt(tree.root, block.number - 5);
        vm.expectPartialRevert(StateChangeHandlerLib.RevertingContext.selector);
        a.verifyAndUpdateTree(sub);
    }

    function test_treeAfterExpiryReverts() public {
        NestedTreeBuilder.Tree memory tree = _chainAB().build(expiryBlock);
        TreeSubmission memory sub = _submission(tree, 0);
        vm.roll(expiryBlock + 1);
        sub.sig = _signAt(tree.root, block.number - 1);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrApprovalRegistry.ApprovalExpired.selector, expiryBlock));
        a.verifyAndUpdateTree(sub);
    }

    function test_wrongExpiryProofReverts() public {
        NestedTreeBuilder.Tree memory tree = _chainAB().build(expiryBlock);
        TreeSubmission memory sub = _submission(tree, 0);
        sub.expiryBlock = expiryBlock + 1;
        vm.expectRevert(ISchnorrApprovalRegistry.InvalidExpiryProof.selector);
        a.verifyAndUpdateTree(sub);
    }

    function test_rootLeafOutsideTheTreeReverts() public {
        NestedTreeBuilder.Tree memory tree = _chainAB().build(expiryBlock);
        TreeSubmission memory sub = _submission(tree, 0);
        sub.targetFunction = bytes4(0xdeadbeef);
        vm.expectPartialRevert(IGasKillerNested.NotTreeMember.selector);
        a.verifyAndUpdateTree(sub);
    }

    function test_wrongRootIndexReverts() public {
        NestedTreeBuilder.Tree memory tree = _chainAB().build(expiryBlock);
        TreeSubmission memory sub = _submission(tree, 0);
        sub.transitionIndex = 1;
        vm.expectRevert(GasKillerSDK.InvalidTransitionIndex.selector);
        a.verifyAndUpdateTree(sub);
    }

    // ---------------------------------------------------------------------------------
    // Re-entry and interfaces
    // ---------------------------------------------------------------------------------

    function test_reenteringTheTreeEntrypointDuringATreeReverts() public {
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](1);
        frames[0] = _frame(
            address(c), address(0), 0, 0, _ops1(_call(address(probe), abi.encodeCall(Probe.observe, (address(c)))))
        );
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        TreeSubmission memory sub = _submission(tree, 0);
        probe.setReentry(address(c), abi.encodeCall(IGasKillerNested.verifyAndUpdateTree, (sub)));

        bytes memory reentry = abi.encodeWithSelector(TransitionGuard.ReentrantTransition.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector,
                0,
                address(probe),
                reentry,
                abi.encodeCall(Probe.observe, (address(c)))
            )
        );
        c.verifyAndUpdateTree(sub);
    }

    function test_reportsTheNestedInterface() public view {
        assertTrue(a.supportsInterface(type(IGasKillerNested).interfaceId));
    }

    // ---------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------

    function _chainAB() private view returns (NestedTreeBuilder.Frame[] memory frames) {
        frames = new NestedTreeBuilder.Frame[](2);
        frames[0] = _frame(address(a), address(0), 0, 0, _ops2(_store(SLOT_X, 1), _nested(address(b), 0, 1)));
        frames[1] = _frame(address(b), address(a), 0, 0, _ops1(_store(SLOT_X, 2)));
    }

    function _twiceFrames() private view returns (NestedTreeBuilder.Frame[] memory frames) {
        frames = new NestedTreeBuilder.Frame[](3);
        frames[0] = _frame(address(a), address(0), 0, 0, _ops2(_nested(address(b), 0, 1), _nested(address(b), 0, 2)));
        frames[1] = _frame(address(b), address(a), 0, 0, _ops1(_store(SLOT_X, 10)));
        frames[2] = _frame(address(b), address(a), 1, 0, _ops1(_store(SLOT_X, 20)));
    }

    function _frame(address target, address caller, uint256 index, uint256 value, Op[] memory ops)
        private
        pure
        returns (NestedTreeBuilder.Frame memory f)
    {
        f.target = target;
        f.caller = caller;
        f.index = index;
        f.value = value;
        f.calldataHash = keccak256(abi.encode("native call", target, index));
        f.targetFunction = TASK;
        f.types = new StateUpdateType[](ops.length);
        f.args = new bytes[](ops.length);
        for (uint256 i = 0; i < ops.length; ++i) {
            (f.types[i], f.args[i]) = (ops[i].kind, ops[i].arg);
        }
    }

    struct Op {
        StateUpdateType kind;
        bytes arg;
    }

    function _ops1(Op memory x) private pure returns (Op[] memory ops) {
        ops = new Op[](1);
        ops[0] = x;
    }

    function _ops2(Op memory x, Op memory y) private pure returns (Op[] memory ops) {
        ops = new Op[](2);
        (ops[0], ops[1]) = (x, y);
    }

    function _store(bytes32 slot, uint256 value) private pure returns (Op memory) {
        return Op(StateUpdateType.STORE, abi.encode(slot, bytes32(value)));
    }

    function _nested(address target, uint256 value, uint256 childFrame) private pure returns (Op memory) {
        return Op(StateUpdateType.NESTED, abi.encode(target, value, childFrame));
    }

    function _call(address target, bytes memory data) private pure returns (Op memory) {
        return Op(StateUpdateType.CALL, abi.encode(target, uint256(0), data));
    }

    function _log1(bytes32 topic) private pure returns (Op memory) {
        return Op(StateUpdateType.LOG1, abi.encode(bytes(""), topic));
    }

    function _submission(NestedTreeBuilder.Tree memory tree, uint256 rootIndex)
        private
        returns (TreeSubmission memory)
    {
        return TreeSubmission(
            tree.root,
            expiryBlock,
            tree.expiryProof,
            _sign(tree.root),
            rootIndex,
            TASK,
            tree.programs[0],
            tree.rootProof,
            tree.rootChildren
        );
    }

    function _approve(NestedTreeBuilder.Tree memory tree, address rootContract) private {
        registry.verifyAndApprove(tree.root, rootContract, expiryBlock, tree.expiryProof, _sign(tree.root));
    }

    function _sign(bytes32 root) private returns (QuorumSignature memory) {
        return _signAt(root, block.number - 1);
    }

    function _signAt(bytes32 root, uint256 refBlock) private returns (QuorumSignature memory) {
        (uint256 s, address r) = SchnorrSigner.sign(OPERATOR_KEY, uint256(keccak256(abi.encode(root, refBlock))), root);
        return QuorumSignature(s, r, new address[](0), refBlock);
    }

    function _load(NestedNode node, bytes32 slot) private view returns (uint256) {
        return uint256(vm.load(address(node), slot));
    }
}
