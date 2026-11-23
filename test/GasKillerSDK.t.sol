// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {ISchnorrStakeRegistry} from "../src/interface/ISchnorrStakeRegistry.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";

/// A registry stub that returns a settable verdict, so the SDK wrapper's control flow
/// (digest reconstruction, transition-index and staleness checks, state application) can be
/// tested without a real aggregate signature over the deploy-dependent digest. The real
/// signature path is covered end-to-end at the registry level in `SchnorrStakeRegistry.t.sol`.
contract MockSchnorrRegistry is ISchnorrStakeRegistry {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function isValidSignature(bytes32, uint256, address, address[] calldata, uint256) external view returns (bool) {
        return verdict;
    }
}

/// Concrete SDK: stores a `value` at slot 0; `verifyAndUpdate` is expected to STORE into it.
contract TestSDK is GasKillerSDK {
    uint256 public value; // slot 0

    constructor(address registry) {
        _setSchnorrRegistry(registry);
        _setAvsAddress(address(0xA75));
    }
}

contract GasKillerSDKTest is Test {
    MockSchnorrRegistry mock;
    TestSDK sdk;

    function setUp() public {
        vm.roll(1000);
        mock = new MockSchnorrRegistry();
        sdk = new TestSDK(address(mock));
    }

    function _storeUpdate(bytes32 slot, bytes32 val) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(slot, val);
        return abi.encode(types, args);
    }

    function _digest(uint256 transitionIndex, bytes4 targetFn, bytes memory updates) internal view returns (bytes32) {
        return sha256(abi.encode(transitionIndex, block.chainid, address(sdk), targetFn, updates));
    }

    function test_verifyAndUpdate_appliesStore() public {
        bytes memory updates = _storeUpdate(bytes32(0), bytes32(uint256(42)));
        uint256 ti = sdk.stateTransitionCount(); // 0
        bytes4 fn = bytes4(keccak256("set()"));
        address[] memory none = new address[](0);

        sdk.verifyAndUpdate(uint32(block.number - 1), updates, ti, fn, 1, address(0x1234), none);

        assertEq(sdk.value(), 42, "STORE applied");
        assertEq(sdk.stateTransitionCount(), ti + 1, "transition tracked");
    }

    /// The registry is asked about the digest the SDK rebuilds from the submitted fields, so the
    /// signature can only cover the payload actually being settled.
    function test_verifyAndUpdate_verifiesRecomputedDigest() public {
        bytes memory updates = _storeUpdate(bytes32(0), bytes32(uint256(1)));
        uint256 ti = sdk.stateTransitionCount();
        bytes4 fn = bytes4(keccak256("set()"));
        address[] memory none = new address[](0);
        vm.expectCall(
            address(mock),
            abi.encodeCall(
                MockSchnorrRegistry.isValidSignature,
                (_digest(ti, fn, updates), 1, address(0x1), none, block.number - 1)
            )
        );
        sdk.verifyAndUpdate(uint32(block.number - 1), updates, ti, fn, 1, address(0x1), none);
    }

    function test_verifyAndUpdate_revertsOnBadTransitionIndex() public {
        bytes memory updates = _storeUpdate(bytes32(0), bytes32(uint256(1)));
        bytes4 fn = bytes4(0);
        uint256 badTi = 5;
        address[] memory none = new address[](0);
        vm.expectRevert(GasKillerSDK.InvalidTransitionIndex.selector);
        sdk.verifyAndUpdate(uint32(block.number - 1), updates, badTi, fn, 1, address(0x1), none);
    }

    function test_verifyAndUpdate_revertsWhenRegistryRejects() public {
        mock.setVerdict(false);
        bytes memory updates = _storeUpdate(bytes32(0), bytes32(uint256(7)));
        uint256 ti = sdk.stateTransitionCount();
        bytes4 fn = bytes4(0);
        address[] memory none = new address[](0);
        vm.expectRevert(GasKillerSDK.InvalidQuorumSignature.selector);
        sdk.verifyAndUpdate(uint32(block.number - 1), updates, ti, fn, 1, address(0x1), none);
    }

    function test_verifyAndUpdate_revertsOnFutureBlock() public {
        bytes memory updates = _storeUpdate(bytes32(0), bytes32(uint256(1)));
        uint256 ti = sdk.stateTransitionCount();
        bytes4 fn = bytes4(0);
        address[] memory none = new address[](0);
        vm.expectRevert(GasKillerSDK.FutureBlockNumber.selector);
        sdk.verifyAndUpdate(uint32(block.number), updates, ti, fn, 1, address(0x1), none);
    }
}
