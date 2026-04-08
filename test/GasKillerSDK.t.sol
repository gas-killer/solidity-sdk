// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import "../src/GasKillerSDK.sol";
import "./exposed/GasKillerSDKExposed.sol";
import "./mocks/MockGasKillerServiceManager.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {StateChangeHandlerLib} from "../src/StateChangeHandlerLib.sol";

contract GasKillerSDKTest is Test {
    GasKillerSDKExposed public sdk;

    function setUp() public {
        MockGasKillerServiceManager avsServiceManager = new MockGasKillerServiceManager();
        sdk = new GasKillerSDKExposed(address(avsServiceManager), makeAddr("BLS_SIG_CHECKER"));
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
