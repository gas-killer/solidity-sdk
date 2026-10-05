// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {SchnorrStakeRegistry} from "../../src/SchnorrStakeRegistry.sol";
import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {IGasKillerNested, TreeSubmission} from "../../src/interface/IGasKillerNested.sol";
import {ISchnorrApprovalRegistry, QuorumSignature} from "../../src/interface/ISchnorrApprovalRegistry.sol";
import {NestedLedger} from "../../src/examples/nested-chain/NestedLedger.sol";
import {NestedVault} from "../../src/examples/nested-chain/NestedVault.sol";
import {NestedRouter} from "../../src/examples/nested-chain/NestedRouter.sol";
import {SchnorrSigner} from "../utils/SchnorrSigner.sol";
import {NestedTreeBuilder} from "../utils/NestedTreeBuilder.sol";

/// @notice End to end: a real `process` call stack (router → vault → ledger) settled as one
///         signed nested tree reproduces native execution exactly, for less gas.
/// @dev Programs are written by hand in the canonical encoder's shape (tracker store, writes,
///      NESTED where the native call happened, logs in emission order) from the storage and logs
///      a native run produces, then settled against a real registry with a real signature.
contract NestedChainTest is Test {
    using NestedTreeBuilder for NestedTreeBuilder.Frame[];

    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    uint256 constant OPERATOR_KEY = 0xA11CE5;
    uint256 constant ROUNDS = 300;
    uint256 constant WEIGHTS = 100;

    SchnorrStakeRegistry registry;
    NestedLedger ledger;
    NestedVault vault;
    NestedRouter router;

    address user = address(0xBEEF);
    uint256[] weights;
    uint256 expiryBlock;

    struct NativeResult {
        uint256 processed;
        uint256 credit;
        bytes32 head;
        uint256 entries;
        uint256 amount;
        Vm.Log[] logs;
    }

    function setUp() public {
        vm.roll(1000);
        registry = new SchnorrStakeRegistry(2, 3, address(this), 0);
        (uint256 px, uint256 py) = SchnorrSigner.publicKey(OPERATOR_KEY);
        (uint256 popS, address popR) =
            SchnorrSigner.sign(OPERATOR_KEY, 991, registry.popMessage(registry.pointAddress(px, py)));
        registry.registerOperator(px, py, 1, popS, popR);
        vm.roll(block.number + 10);

        ledger = new NestedLedger(address(0xA75), address(registry), ROUNDS);
        vault = new NestedVault(address(0xA75), address(registry), ledger);
        router = new NestedRouter(address(0xA75), address(registry), vault);

        for (uint256 i = 0; i < WEIGHTS; ++i) {
            weights.push(uint256(keccak256(abi.encode(i))) % 1000);
        }
        expiryBlock = block.number + 50;
    }

    function test_nestedSettlementReproducesNativeExecution() public {
        NativeResult memory native = _runNative();
        TreeSubmission memory sub = _submission(native);

        vm.recordLogs();
        router.verifyAndUpdateTree(sub);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(router.processed(), native.processed);
        assertEq(vault.credits(user), native.credit);
        assertEq(ledger.head(), native.head);
        assertEq(ledger.entries(), native.entries);
        assertEq(router.stateTransitionCount(), 1);
        assertEq(vault.stateTransitionCount(), 1);
        assertEq(ledger.stateTransitionCount(), 1);

        assertEq(logs.length, native.logs.length, "same events");
        for (uint256 i = 0; i < logs.length; ++i) {
            assertEq(logs[i].emitter, native.logs[i].emitter, "emitter");
            assertEq(logs[i].topics, native.logs[i].topics, "topics");
            assertEq(logs[i].data, native.logs[i].data, "data");
        }
    }

    function test_signatureOverAnotherRootFailsApproval() public {
        NativeResult memory native = _runNative();
        TreeSubmission memory sub = _submission(native);
        sub.sig = _sign(keccak256("another root"));
        vm.expectRevert(ISchnorrApprovalRegistry.InvalidApprovalSignature.selector);
        router.verifyAndUpdateTree(sub);
    }

    /// Execution gas is measured cold, outside calldata; calldata is priced separately at the
    /// standard 16/4 gas per non-zero/zero byte so the comparison covers what a sender pays.
    function test_gas_nestedSettlementCostsLessThanNativeExecution() public {
        NativeResult memory native = _runNative();
        TreeSubmission memory sub = _submission(native);

        uint256 snapshot = vm.snapshotState();
        _coolAll();
        uint256 before = gasleft();
        router.process(user, weights);
        uint256 nativeExec = before - gasleft();
        uint256 nativeCalldata = _calldataGas(abi.encodeCall(NestedRouter.process, (user, weights)));

        vm.revertToState(snapshot);
        _coolAll();
        before = gasleft();
        router.verifyAndUpdateTree(sub);
        uint256 nestedExec = before - gasleft();
        uint256 nestedCalldata = _calldataGas(abi.encodeCall(IGasKillerNested.verifyAndUpdateTree, (sub)));

        console2.log("native execution, calldata:", nativeExec, nativeCalldata);
        console2.log("nested execution, calldata:", nestedExec, nestedCalldata);
        assertLt(nestedExec + nestedCalldata, nativeExec + nativeCalldata, "nested settlement is cheaper");
    }

    function _runNative() private returns (NativeResult memory native) {
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        router.process(user, weights);
        native.logs = vm.getRecordedLogs();
        native.processed = router.processed();
        native.credit = vault.credits(user);
        native.head = ledger.head();
        native.entries = ledger.entries();
        native.amount = native.credit;
        vm.revertToState(snapshot);
    }

    function _submission(NativeResult memory native) private returns (TreeSubmission memory) {
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](3);

        frames[0] = _frame(address(router), address(0), NestedRouter.process.selector, "", 3);
        _op(frames[0], 0, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(uint256(1))));
        _op(frames[0], 1, StateUpdateType.STORE, abi.encode(bytes32(0), bytes32(native.processed)));
        _op(frames[0], 2, StateUpdateType.NESTED, abi.encode(address(vault), uint256(0), uint256(1)));

        frames[1] =
            _frame(address(vault), address(router), bytes4(0), abi.encodeCall(NestedVault.credit, (user, weights)), 4);
        _op(frames[1], 0, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(uint256(1))));
        _op(
            frames[1],
            1,
            StateUpdateType.STORE,
            abi.encode(keccak256(abi.encode(user, uint256(0))), bytes32(native.credit))
        );
        _op(frames[1], 2, StateUpdateType.NESTED, abi.encode(address(ledger), uint256(0), uint256(2)));
        _op(frames[1], 3, StateUpdateType.LOG2, _log2(native.logs[1]));

        frames[2] = _frame(
            address(ledger), address(vault), bytes4(0), abi.encodeCall(NestedLedger.record, (user, native.amount)), 4
        );
        _op(frames[2], 0, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(uint256(1))));
        _op(frames[2], 1, StateUpdateType.STORE, abi.encode(bytes32(0), native.head));
        _op(frames[2], 2, StateUpdateType.STORE, abi.encode(bytes32(uint256(1)), bytes32(native.entries)));
        _op(frames[2], 3, StateUpdateType.LOG2, _log2(native.logs[0]));

        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        return TreeSubmission(
            tree.root,
            expiryBlock,
            tree.expiryProof,
            _sign(tree.root),
            0,
            NestedRouter.process.selector,
            tree.programs[0],
            tree.rootProof,
            tree.rootChildren
        );
    }

    function _frame(address target, address caller, bytes4 selector, bytes memory nativeCall, uint256 ops)
        private
        pure
        returns (NestedTreeBuilder.Frame memory f)
    {
        f.target = target;
        f.caller = caller;
        f.targetFunction = selector;
        f.calldataHash = keccak256(nativeCall);
        f.types = new StateUpdateType[](ops);
        f.args = new bytes[](ops);
    }

    function _op(NestedTreeBuilder.Frame memory f, uint256 i, StateUpdateType kind, bytes memory arg) private pure {
        f.types[i] = kind;
        f.args[i] = arg;
    }

    function _log2(Vm.Log memory log) private pure returns (bytes memory) {
        return abi.encode(log.data, log.topics[0], log.topics[1]);
    }

    function _sign(bytes32 root) private returns (QuorumSignature memory) {
        (uint256 s, address r) = SchnorrSigner.sign(OPERATOR_KEY, uint256(keccak256(abi.encode(root))), root);
        return QuorumSignature(s, r, new address[](0), block.number - 1);
    }

    function _coolAll() private {
        vm.cool(address(router));
        vm.cool(address(vault));
        vm.cool(address(ledger));
        vm.cool(address(registry));
    }

    function _calldataGas(bytes memory data) private pure returns (uint256 gas) {
        for (uint256 i = 0; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }
}
