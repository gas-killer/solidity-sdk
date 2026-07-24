// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SchnorrArraySummation} from "../../src/examples/array-summation/SchnorrArraySummation.sol";
import {SchnorrArraySummationFactory} from "../../src/examples/array-summation/SchnorrArraySummationFactory.sol";
import {ISchnorrGasKillerSDK} from "../../src/schnorr/interface/ISchnorrGasKillerSDK.sol";
import {ISchnorrStakeRegistry} from "../../src/schnorr/interface/ISchnorrStakeRegistry.sol";
import {IGasKillerSDK} from "../../src/interface/IGasKillerSDK.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";

/// A registry stub that returns a settable verdict (same pattern as
/// `SchnorrGasKillerSDK.t.sol`), so the example contract's `verifyAndUpdate` flow can be
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

contract SchnorrArraySummationTest is Test {
    address internal constant AVS = address(0xA75);

    MockSchnorrRegistry mock;
    SchnorrArraySummation target;

    // Fixed execution-context fields bound into the task digest. The mock registry ignores the
    // signature, so only digest/preimage consistency matters — the values themselves are arbitrary.
    bytes32 internal constant ANCHOR = keccak256("anchor-block");
    address internal constant CALLER = address(0xCA11E4);
    bytes internal constant CALLDATA = hex"deadbeef";

    function setUp() public {
        vm.roll(1000);
        mock = new MockSchnorrRegistry();
        target = new SchnorrArraySummation(AVS, address(mock), 10, 1000, 42);
    }

    function _storeUpdate(bytes32 slot, bytes32 val) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(slot, val);
        return abi.encode(types, args);
    }

    function _digest(
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes memory contractCalldata,
        bytes memory updates
    ) internal view returns (bytes32) {
        return sha256(
            abi.encode(transitionIndex, address(target), anchorHash, callerAddress, contractCalldata, updates)
        );
    }

    function test_supportsInterface() public view {
        assertTrue(target.supportsInterface(type(IERC165).interfaceId), "IERC165 not supported");
        assertTrue(
            target.supportsInterface(type(ISchnorrGasKillerSDK).interfaceId), "ISchnorrGasKillerSDK not supported"
        );
        // The Schnorr and BLS SDK interfaces carry distinct `verifyAndUpdate` signatures, so a
        // Schnorr target must not report the BLS `IGasKillerSDK` id — an ERC-165 preflight relies
        // on this to tell a Schnorr target apart from a BLS one.
        assertFalse(
            target.supportsInterface(type(IGasKillerSDK).interfaceId),
            "BLS IGasKillerSDK interface id must be unsupported"
        );
        assertFalse(target.supportsInterface(0xffffffff), "0xffffffff must be unsupported");
    }

    function test_interfaceId_isVerifyAndUpdateSelector() public pure {
        assertEq(
            type(ISchnorrGasKillerSDK).interfaceId,
            ISchnorrGasKillerSDK.verifyAndUpdate.selector,
            "single-function interface id must equal the verifyAndUpdate selector"
        );
    }

    function test_getMessageHash_parity() public view {
        bytes memory updates = _storeUpdate(bytes32(uint256(0)), bytes32(uint256(99)));
        bytes32 expected = sha256(abi.encode(uint256(0), address(target), ANCHOR, CALLER, CALLDATA, updates));
        assertEq(target.getMessageHash(0, ANCHOR, CALLER, CALLDATA, updates), expected, "getMessageHash parity broken");
    }

    function test_factory_deploysAndWires() public {
        SchnorrArraySummationFactory factory = new SchnorrArraySummationFactory();
        address deployed = factory.deploySchnorrArraySummation(AVS, address(mock), 5, 100, 1);

        assertEq(factory.getDeployedContractCount(), 1, "count mismatch");
        assertTrue(factory.isContractDeployedByFactory(deployed), "membership missing");
        assertEq(factory.deployedContracts(0), deployed, "list mismatch");

        SchnorrArraySummation instance = SchnorrArraySummation(deployed);
        assertEq(instance.schnorrRegistry(), address(mock), "registry mismatch");
        assertEq(instance.avsAddress(), AVS, "avs mismatch");
        assertEq(instance.getArrayLength(), 5, "array size mismatch");
    }

    function test_verifyAndUpdate_appliesStoreToCurrentSum() public {
        // STORE into slot 0 = `currentSum` (immutables occupy no storage; the SDK and
        // StateTracker state live at constant ERC-7201-style slots).
        bytes memory updates = _storeUpdate(bytes32(uint256(0)), bytes32(uint256(1352)));
        uint256 ti = target.stateTransitionCount(); // 0
        bytes32 h = _digest(ti, ANCHOR, CALLER, CALLDATA, updates);
        address[] memory none = new address[](0);

        target.verifyAndUpdate(
            h, uint32(block.number - 1), updates, ti, ANCHOR, CALLER, CALLDATA, 1, address(0x1234), none
        );

        assertEq(target.currentSum(), 1352, "STORE not applied to currentSum");
        assertEq(target.stateTransitionCount(), ti + 1, "transition not tracked");
    }
}
