// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {SchnorrStakeRegistry} from "../../src/SchnorrStakeRegistry.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {IGasKillerNested, TreeSubmission} from "../../src/interface/IGasKillerNested.sol";
import {QuorumSignature} from "../../src/interface/ISchnorrApprovalRegistry.sol";
import {DepositGateway} from "../../src/examples/nested-deposit/DepositGateway.sol";
import {DepositVault} from "../../src/examples/nested-deposit/DepositVault.sol";
import {HashChain} from "../../src/examples/HashChain.sol";
import {SchnorrSigner} from "../utils/SchnorrSigner.sol";
import {NestedTreeBuilder} from "../utils/NestedTreeBuilder.sol";

/// @notice End to end: a `deposit` whose ETH the gateway forwards to the vault, settled as one
///         tree in which the `NESTED` op carries the value into the vault's frame.
contract NestedDepositTest is Test {
    using NestedTreeBuilder for NestedTreeBuilder.Frame[];

    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    uint256 constant OPERATOR_KEY = 0xA11CE5;
    uint256 constant DEPOSIT = 1 ether;
    uint256 constant ROUNDS = 1000;

    SchnorrStakeRegistry registry;
    DepositGateway gateway;
    DepositVault vault;

    address account = address(0xBEEF);
    uint256 expiryBlock;

    function setUp() public {
        vm.roll(1000);
        registry = new SchnorrStakeRegistry(2, 3, address(this), 0);
        (uint256 px, uint256 py) = SchnorrSigner.publicKey(OPERATOR_KEY);
        (uint256 popS, address popR) =
            SchnorrSigner.sign(OPERATOR_KEY, 991, registry.popMessage(registry.pointAddress(px, py)));
        registry.registerOperator(px, py, 1, popS, popR);
        vm.roll(block.number + 10);

        gateway = new DepositGateway(address(0xA75), address(registry), ROUNDS);
        vault = gateway.vault();
        expiryBlock = block.number + 50;
    }

    function test_nestedDepositReproducesNativeExecution() public {
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        gateway.deposit{value: DEPOSIT}(account);
        Vm.Log[] memory nativeLogs = vm.getRecordedLogs();
        vm.revertToState(snapshot);

        vm.recordLogs();
        gateway.verifyAndUpdateTree{value: DEPOSIT}(_submission(DEPOSIT, DEPOSIT));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(gateway.deposits(), 1);
        assertEq(vault.balances(account), DEPOSIT);
        assertEq(vault.receipt(), _receipt(DEPOSIT));
        assertEq(address(vault).balance, DEPOSIT, "the NESTED op moved the ETH");
        assertEq(address(gateway).balance, 0, "the gateway holds nothing at rest");
        assertEq(gateway.stateTransitionCount(), 1);
        assertEq(vault.stateTransitionCount(), 1);

        assertEq(logs.length, nativeLogs.length, "same events");
        for (uint256 i = 0; i < logs.length; ++i) {
            assertEq(logs[i].emitter, nativeLogs[i].emitter, "emitter");
            assertEq(logs[i].topics, nativeLogs[i].topics, "topics");
            assertEq(logs[i].data, nativeLogs[i].data, "data");
        }
    }

    function test_settlingWithoutTheDepositReverts() public {
        TreeSubmission memory sub = _submission(DEPOSIT, DEPOSIT);
        vm.expectPartialRevert(StateChangeHandlerLib.RevertingContext.selector);
        gateway.verifyAndUpdateTree(sub);
        assertEq(vault.balances(account), 0);
    }

    function test_vaultFrameSignedForMoreThanTheNestedOpForwardsFailsItsLeaf() public {
        TreeSubmission memory sub = _submission(DEPOSIT / 2, DEPOSIT);
        try gateway.verifyAndUpdateTree{value: DEPOSIT}(sub) {
            fail("tree settled");
        } catch (bytes memory err) {
            assertEq(bytes4(err), StateChangeHandlerLib.RevertingContext.selector);
            (, address target, bytes memory revertData,) = abi.decode(_args(err), (uint256, address, bytes, bytes));
            assertEq(target, address(vault));
            assertEq(bytes4(revertData), IGasKillerNested.LeafMismatch.selector, "the vault rejected its frame");
        }
    }

    /// Pins what remains open until gas-killer/solidity-sdk#104 binds the root's value: ETH
    /// forced into the gateway can fund a zero-value settlement. It credits only ETH that
    /// reaches the vault, so the vault stays fully backed.
    function test_strayGatewayEthCanFundAZeroValueSettlementButTheVaultStaysBacked() public {
        vm.deal(address(gateway), DEPOSIT);
        gateway.verifyAndUpdateTree(_submission(DEPOSIT, DEPOSIT));
        assertEq(vault.balances(account), DEPOSIT);
        assertEq(address(vault).balance, vault.balances(account));
    }

    function test_onlyTheGatewayDeposits() public {
        vm.expectRevert(DepositVault.NotGateway.selector);
        vault.deposit{value: DEPOSIT}(account);
    }

    function test_withdrawPaysOutTheCreditedDeposit() public {
        gateway.verifyAndUpdateTree{value: DEPOSIT}(_submission(DEPOSIT, DEPOSIT));
        vm.prank(account);
        vault.withdraw(DEPOSIT);
        assertEq(account.balance, DEPOSIT);
        assertEq(vault.balances(account), 0);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(DepositVault.InsufficientBalance.selector, 0, 1));
        vault.withdraw(1);
    }

    /// Frame 0 is the gateway's `deposit` (tracker, counter, NESTED forwarding `forwarded`);
    /// frame 1 is the vault's, signed as receiving `credited`, with the receipt it chains.
    function _submission(uint256 forwarded, uint256 credited) private returns (TreeSubmission memory) {
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](2);

        frames[0] = _frame(address(gateway), address(0), 0, DepositGateway.deposit.selector, "", 3);
        _op(frames[0], 0, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(uint256(1))));
        _op(frames[0], 1, StateUpdateType.STORE, abi.encode(bytes32(0), bytes32(uint256(1))));
        _op(frames[0], 2, StateUpdateType.NESTED, abi.encode(address(vault), forwarded, uint256(1)));

        frames[1] = _frame(
            address(vault), address(gateway), credited, bytes4(0), abi.encodeCall(DepositVault.deposit, (account)), 4
        );
        bytes32 receipt = _receipt(credited);
        _op(frames[1], 0, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(uint256(1))));
        _op(
            frames[1],
            1,
            StateUpdateType.STORE,
            abi.encode(keccak256(abi.encode(account, uint256(0))), bytes32(credited))
        );
        _op(frames[1], 2, StateUpdateType.STORE, abi.encode(bytes32(uint256(1)), receipt));
        _op(
            frames[1],
            3,
            StateUpdateType.LOG2,
            abi.encode(
                abi.encode(credited, receipt), DepositVault.Deposited.selector, bytes32(uint256(uint160(account)))
            )
        );

        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        (uint256 s, address r) = SchnorrSigner.sign(OPERATOR_KEY, uint256(keccak256(abi.encode(tree.root))), tree.root);
        return TreeSubmission(
            tree.root,
            expiryBlock,
            tree.expiryProof,
            QuorumSignature(s, r, new address[](0), block.number - 1),
            0,
            DepositGateway.deposit.selector,
            tree.programs[0],
            tree.rootProof,
            tree.rootChildren
        );
    }

    function _frame(
        address target,
        address caller,
        uint256 value,
        bytes4 selector,
        bytes memory nativeCall,
        uint256 ops
    ) private pure returns (NestedTreeBuilder.Frame memory f) {
        f.target = target;
        f.caller = caller;
        f.value = value;
        f.targetFunction = selector;
        f.calldataHash = keccak256(nativeCall);
        f.types = new StateUpdateType[](ops);
        f.args = new bytes[](ops);
    }

    function _receipt(uint256 amount) private view returns (bytes32) {
        return HashChain.extend(keccak256(abi.encode(bytes32(0), account, amount)), ROUNDS);
    }

    function _op(NestedTreeBuilder.Frame memory f, uint256 i, StateUpdateType kind, bytes memory arg) private pure {
        f.types[i] = kind;
        f.args[i] = arg;
    }

    function _args(bytes memory err) private pure returns (bytes memory args) {
        args = new bytes(err.length - 4);
        for (uint256 i = 0; i < args.length; ++i) {
            args[i] = err[i + 4];
        }
    }
}
