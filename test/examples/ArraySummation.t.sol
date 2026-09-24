// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ArraySummation} from "../../src/examples/array-summation/ArraySummation.sol";
import {ArraySummationFactory} from "../../src/examples/array-summation/ArraySummationFactory.sol";
import {IGasKillerSDK} from "../../src/interface/IGasKillerSDK.sol";
import {ISchnorrStakeRegistry} from "../../src/interface/ISchnorrStakeRegistry.sol";
import {IGasKillerSDK} from "../../src/interface/IGasKillerSDK.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";

/// A registry stub that returns a settable verdict (same pattern as
/// `GasKillerSDK.t.sol`), so the example contract's `verifyAndUpdate` flow can be
/// exercised without a real aggregate signature. The real signature path is covered
/// end-to-end at the registry level in `SchnorrStakeRegistry.t.sol`.
contract MockSchnorrRegistry is ISchnorrStakeRegistry {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function isValidSignature(bytes32, uint256, address, address[] calldata, uint256) external view returns (bool) {
        return verdict;
    }
}

contract ArraySummationTest is Test {
    address internal constant AVS = address(0xA75);

    MockSchnorrRegistry mock;
    ArraySummation target;

    function setUp() public {
        vm.roll(1000);
        mock = new MockSchnorrRegistry();
        target = new ArraySummation(AVS, address(mock), 10, 1000, 42);
    }

    function _storeUpdate(bytes32 slot, bytes32 val) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(slot, val);
        return abi.encode(types, args);
    }

    function _digest(uint256 transitionIndex, bytes4 targetFn, bytes memory updates) internal view returns (bytes32) {
        return sha256(abi.encode(transitionIndex, address(target), targetFn, updates));
    }

    function test_supportsInterface() public view {
        assertTrue(target.supportsInterface(type(IERC165).interfaceId), "IERC165 not supported");
        assertTrue(target.supportsInterface(type(IGasKillerSDK).interfaceId), "IGasKillerSDK not supported");
        assertFalse(target.supportsInterface(0xffffffff), "0xffffffff must be unsupported");
    }

    function test_interfaceId_isVerifyAndUpdateSelector() public pure {
        assertEq(
            type(IGasKillerSDK).interfaceId,
            IGasKillerSDK.verifyAndUpdate.selector,
            "single-function interface id must equal the verifyAndUpdate selector"
        );
    }

    function test_getMessageHash_parity() public view {
        bytes memory updates = _storeUpdate(bytes32(uint256(0)), bytes32(uint256(99)));
        bytes32 expected = sha256(abi.encode(uint256(0), address(target), ArraySummation.sum.selector, updates));
        assertEq(
            target.getMessageHash(0, ArraySummation.sum.selector, updates), expected, "getMessageHash parity broken"
        );
    }

    function test_factory_deploysAndWires() public {
        ArraySummationFactory factory = new ArraySummationFactory();
        address deployed = factory.deployArraySummation(AVS, address(mock), 5, 100, 1);

        assertEq(factory.getDeployedContractCount(), 1, "count mismatch");
        assertTrue(factory.isContractDeployedByFactory(deployed), "membership missing");
        assertEq(factory.deployedContracts(0), deployed, "list mismatch");

        ArraySummation instance = ArraySummation(deployed);
        assertEq(instance.schnorrRegistry(), address(mock), "registry mismatch");
        assertEq(instance.avsAddress(), AVS, "avs mismatch");
        assertEq(instance.getArrayLength(), 5, "array size mismatch");
    }

    function test_verifyAndUpdate_appliesStoreToCurrentSum() public {
        // STORE into slot 0 = `currentSum` (immutables occupy no storage; the SDK and
        // StateTracker state live at constant ERC-7201-style slots).
        bytes memory updates = _storeUpdate(bytes32(uint256(0)), bytes32(uint256(1352)));
        uint256 ti = target.stateTransitionCount(); // 0
        bytes4 fn = ArraySummation.sum.selector;
        bytes32 h = _digest(ti, fn, updates);
        address[] memory none = new address[](0);

        target.verifyAndUpdate(h, uint32(block.number - 1), updates, ti, fn, 1, address(0x1234), none);

        assertEq(target.currentSum(), 1352, "STORE not applied to currentSum");
        assertEq(target.stateTransitionCount(), ti + 1, "transition not tracked");
    }
}
