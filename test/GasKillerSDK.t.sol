// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import "../src/GasKillerSDK.sol";
import "./exposed/GasKillerSDKExposed.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {StateChangeHandlerLib} from "../src/StateChangeHandlerLib.sol";

contract GasKillerSDKTest is Test {
    GasKillerSDKExposed public sdk;

    function setUp() public {
        sdk = new GasKillerSDKExposed(makeAddr("AVS"), makeAddr("ECDSA_REGISTRY"));
    }

    function test_stateChangeHandlerExternal_Store() public {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;

        bytes[] memory args = new bytes[](1);
        bytes32 slot = bytes32(uint256(1));
        bytes32 value = bytes32(uint256(100));
        args[0] = abi.encode(slot, value);

        sdk.stateChangeHandlerExternal(abi.encode(types, args));

        assertEq(vm.load(address(sdk), slot), value);
    }

    function test_stateChangeHandlerExternal_Call() public {
        /// Deploy a simple target contract
        SimpleTarget target = new SimpleTarget();

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CALL;

        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(address(target), uint256(0), abi.encodeWithSignature("setValue(uint256)", 42));

        sdk.stateChangeHandlerExternal(abi.encode(types, args));

        assertEq(target.value(), 42);
    }

    function test_stateChangeHandlerExternal_Call_RevertingContext() public {
        SimpleTarget target = new SimpleTarget();

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CALL;

        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(address(target), uint256(0), abi.encodeWithSignature("revertCall()"));

        vm.expectRevert(
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector,
                0,
                address(target),
                bytes("reverted"),
                abi.encodeWithSignature("revertCall()")
            )
        );
        sdk.stateChangeHandlerExternal(abi.encode(types, args));
    }

    function test_stateChangeHandlerExternal_Log1() public {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.LOG1;

        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(bytes("log data"), keccak256("Log1(bytes)"));
        console.logBytes(args[0]);

        vm.recordLogs();

        sdk.stateChangeHandlerExternal(abi.encode(types, args));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 1);
        assertEq(logs[0].topics[0], keccak256("Log1(bytes)"));
        assertEq(logs[0].data, "log data");
    }

    function test_stateChangeHandlerExternal_InvalidArguments() public {
        StateUpdateType[] memory types = new StateUpdateType[](2);
        bytes[] memory args = new bytes[](1);

        vm.expectRevert(StateChangeHandlerLib.InvalidArguments.selector);
        sdk.stateChangeHandlerExternal(abi.encode(types, args));
    }

    function test_stateChangeHandlerExternal_Create() public {
        bytes memory initcode = type(Deployable).creationCode;

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CREATE;

        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(uint256(0), initcode);

        // CREATE derives the address from (deployer, nonce); the deployer is the sdk.
        address predicted = vm.computeCreateAddress(address(sdk), vm.getNonce(address(sdk)));

        sdk.stateChangeHandlerExternal(abi.encode(types, args));

        assertGt(predicted.code.length, 0, "no code at predicted CREATE address");
        assertEq(Deployable(predicted).x(), 42, "constructor did not run");
    }

    function test_stateChangeHandlerExternal_Create2() public {
        bytes memory initcode = type(Deployable).creationCode;
        bytes32 salt = keccak256("gas.killer.create2.salt");

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CREATE2;

        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(salt, uint256(0), initcode);

        // CREATE2 is deterministic: keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode)).
        address predicted = vm.computeCreate2Address(salt, keccak256(initcode), address(sdk));

        sdk.stateChangeHandlerExternal(abi.encode(types, args));

        assertGt(predicted.code.length, 0, "no code at predicted CREATE2 address");
        assertEq(Deployable(predicted).x(), 42, "constructor did not run");
    }

    function test_stateChangeHandlerExternal_Create_ForwardsValue() public {
        bytes memory initcode = type(Deployable).creationCode;
        uint256 endowment = 1 ether;
        vm.deal(address(sdk), endowment);

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CREATE;

        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(endowment, initcode);

        address predicted = vm.computeCreateAddress(address(sdk), vm.getNonce(address(sdk)));

        sdk.stateChangeHandlerExternal(abi.encode(types, args));

        assertEq(predicted.balance, endowment, "endowment not forwarded via CREATE");
    }

    function test_stateChangeHandlerExternal_Create2_ForwardsValue() public {
        bytes memory initcode = type(Deployable).creationCode;
        bytes32 salt = keccak256("gas.killer.create2.valued");
        uint256 endowment = 1 ether;
        vm.deal(address(sdk), endowment);

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CREATE2;

        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(salt, endowment, initcode);

        address predicted = vm.computeCreate2Address(salt, keccak256(initcode), address(sdk));

        sdk.stateChangeHandlerExternal(abi.encode(types, args));

        assertEq(predicted.balance, endowment, "endowment not forwarded via CREATE2");
    }

    function test_stateChangeHandlerExternal_Create_RevertsOnFailedDeployment() public {
        // Initcode whose constructor reverts -> CREATE returns address(0).
        bytes memory initcode = type(RevertingDeploy).creationCode;

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CREATE;

        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(uint256(0), initcode);

        vm.expectRevert(StateChangeHandlerLib.DeploymentFailed.selector);
        sdk.stateChangeHandlerExternal(abi.encode(types, args));
    }

    function test_stateChangeHandlerExternal_Create2_RevertsOnFailedDeployment() public {
        bytes memory initcode = type(RevertingDeploy).creationCode;

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CREATE2;

        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(keccak256("revert.salt"), uint256(0), initcode);

        vm.expectRevert(StateChangeHandlerLib.DeploymentFailed.selector);
        sdk.stateChangeHandlerExternal(abi.encode(types, args));
    }

    function test_ERC165_supportsInterface() public {
        /// Test that the contract supports IERC165
        assertTrue(sdk.supportsInterface(type(IERC165).interfaceId));

        /// Test that the contract supports IGasKillerSDK
        assertTrue(sdk.supportsInterface(type(IGasKillerSDK).interfaceId));

        /// Test that the contract does not support a random interface
        assertFalse(sdk.supportsInterface(0x12345678));

        /// Test that the contract does not support 0xffffffff (invalid interface ID)
        assertFalse(sdk.supportsInterface(0xffffffff));
    }
}

contract SimpleTarget {
    uint256 public value;

    function setValue(uint256 _value) public {
        value = _value;
    }

    function revertCall() public pure {
        bytes32 _msg = "reverted";
        assembly {
            mstore(0, _msg)
            revert(0, 8)
        }
    }
}

/// @dev Minimal contract deployed by the CREATE/CREATE2 tests. The constructor
/// is payable so it can receive an endowment, and sets state so tests can
/// confirm the constructor actually ran at the deployed address.
contract Deployable {
    uint256 public x;

    constructor() payable {
        x = 42;
    }
}

/// @dev Initcode whose constructor always reverts, so CREATE/CREATE2 return
/// address(0) and the handler raises DeploymentFailed.
contract RevertingDeploy {
    constructor() {
        revert("no deploy");
    }
}
