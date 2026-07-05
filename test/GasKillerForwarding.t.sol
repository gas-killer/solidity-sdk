// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import "../src/GasKillerSDK.sol";
import {IGasKillerForwardee} from "../src/interface/IGasKillerForwardee.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import "./exposed/GasKillerSDKExposed.sol";

/// @dev ECDSA stake-registry stand-in: implements the ERC-1271 `isValidSignature`
/// endpoint the SDK calls, returning the magic value so `verifyAndUpdate` can be
/// exercised end-to-end. `setValid(false)` makes it reject, to test the failure path.
contract MockECDSAStakeRegistry {
    // ERC-1271 magic value: bytes4(keccak256("isValidSignature(bytes32,bytes)"))
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    bool public valid = true;

    function setValid(bool _valid) external {
        valid = _valid;
    }

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        return valid ? MAGIC_VALUE : bytes4(0xffffffff);
    }
}

contract GasKillerForwardingTest is Test {
    // keccak256("gasKiller.stateTracker") - 1, mirrors StateTracker.STATE_TRACKER_STORAGE_LOCATION
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    // ERC-7201 base slot of GasKillerSDKStorage (gaskiller.GasKillerSDKECDSA.storage)
    bytes32 internal constant SDK_CONFIG_SLOT = 0x6056deb87cab365bf76a6725b8b096dec334581845ea9d3c2627f8b0efdde700;

    GasKillerSDKExposed public a;
    GasKillerSDKExposed public b;
    GasKillerSDKExposed public c;
    MockECDSAStakeRegistry public registry;

    function setUp() public {
        registry = new MockECDSAStakeRegistry();
        a = new GasKillerSDKExposed(makeAddr("AVS"), address(registry));
        b = new GasKillerSDKExposed(makeAddr("AVS"), address(registry));
        c = new GasKillerSDKExposed(makeAddr("AVS"), address(registry));

        // Peer topology: B trusts A, C trusts B (A -> B -> C)
        b.setTrustedForwarderExternal(address(a), true);
        c.setTrustedForwarderExternal(address(b), true);
    }

    // ============ Helpers ============

    function _singleStore(bytes32 slot, bytes32 value) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(slot, value);
        return abi.encode(types, args);
    }

    /// @dev Encode a forwarding CALL op arg targeting `callee.applyForwardedUpdates`.
    function _forwardArg(address callee, uint256 value, bytes memory subUpdates, uint256 expectedIndex)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            callee, value, abi.encodeCall(IGasKillerForwardee.applyForwardedUpdates, (subUpdates, expectedIndex))
        );
    }

    // ============ applyForwardedUpdates: direct calls ============

    function test_applyForwardedUpdates_appliesStoreAndBumpsCounter() public {
        bytes32 slot = bytes32(uint256(42));
        bytes32 value = bytes32(uint256(1337));

        vm.expectEmit(true, true, false, false, address(b));
        emit IGasKillerForwardee.ForwardedUpdatesApplied(address(a), 0);

        vm.prank(address(a));
        b.applyForwardedUpdates(_singleStore(slot, value), 0);

        assertEq(vm.load(address(b), slot), value, "forwarded STORE not applied");
        assertEq(b.stateTransitionCount(), 1, "counter must advance once per forwarded apply");
    }

    function test_applyForwardedUpdates_untrustedCallerReverts() public {
        address rando = makeAddr("rando");
        vm.expectRevert(abi.encodeWithSelector(IGasKillerForwardee.UntrustedForwarder.selector, rando));
        vm.prank(rando);
        b.applyForwardedUpdates(_singleStore(bytes32(uint256(1)), bytes32(uint256(2))), 0);
    }

    function test_applyForwardedUpdates_wrongIndexReverts() public {
        vm.expectRevert(IGasKillerSDK.InvalidTransitionIndex.selector);
        vm.prank(address(a));
        b.applyForwardedUpdates(_singleStore(bytes32(uint256(1)), bytes32(uint256(2))), 5);
    }

    function test_applyForwardedUpdates_staleIndexAfterDirectTransitionReverts() public {
        // A tracked transition on B advances its counter...
        vm.prank(address(a));
        b.applyForwardedUpdates(_singleStore(bytes32(uint256(1)), bytes32(uint256(2))), 0);

        // ...so a forward computed against the old counter must fail.
        vm.expectRevert(IGasKillerSDK.InvalidTransitionIndex.selector);
        vm.prank(address(a));
        b.applyForwardedUpdates(_singleStore(bytes32(uint256(1)), bytes32(uint256(3))), 0);
    }

    function test_applyForwardedUpdates_reservedTrackerSlotReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IGasKillerForwardee.ReservedSlot.selector, 0, TRACKER_SLOT));
        vm.prank(address(a));
        b.applyForwardedUpdates(_singleStore(TRACKER_SLOT, bytes32(uint256(999))), 0);
    }

    function test_applyForwardedUpdates_reservedConfigSlotsRevert() public {
        // All five fixed slots of GasKillerSDKStorage (namespace..trustedForwarders base) are reserved.
        for (uint256 offset = 0; offset < 5; offset++) {
            bytes32 slot = bytes32(uint256(SDK_CONFIG_SLOT) + offset);
            vm.expectRevert(abi.encodeWithSelector(IGasKillerForwardee.ReservedSlot.selector, 0, slot));
            vm.prank(address(a));
            b.applyForwardedUpdates(_singleStore(slot, bytes32(uint256(1))), 0);
        }
    }

    function test_applyForwardedUpdates_slotAdjacentToConfigIsWritable() public {
        // First slot past the reserved range must not be blocked.
        bytes32 slot = bytes32(uint256(SDK_CONFIG_SLOT) + 5);
        vm.prank(address(a));
        b.applyForwardedUpdates(_singleStore(slot, bytes32(uint256(7))), 0);
        assertEq(vm.load(address(b), slot), bytes32(uint256(7)));
    }

    function test_applyForwardedUpdates_mismatchedArraysRevert() public {
        StateUpdateType[] memory types = new StateUpdateType[](2);
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(bytes32(uint256(1)), bytes32(uint256(2)));

        vm.expectRevert(StateChangeHandlerLib.InvalidArguments.selector);
        vm.prank(address(a));
        b.applyForwardedUpdates(abi.encode(types, args), 0);
    }

    function test_isTrustedForwarder() public {
        assertTrue(b.isTrustedForwarder(address(a)));
        assertFalse(b.isTrustedForwarder(makeAddr("rando")));
        assertFalse(a.isTrustedForwarder(address(b)), "trust must not be symmetric by default");

        b.setTrustedForwarderExternal(address(a), false);
        assertFalse(b.isTrustedForwarder(address(a)), "revocation must take effect");
    }

    function test_setTrustedForwarder_rejectsEOA() public {
        // Allowlisting a codeless address (EOA/undeployed) must fail fast: such an address
        // could otherwise call applyForwardedUpdates directly with no quorum verification.
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(IGasKillerForwardee.InvalidForwarder.selector, eoa));
        b.setTrustedForwarderExternal(eoa, true);

        // Revoking a codeless address is still allowed (no-op that clears any stale entry).
        b.setTrustedForwarderExternal(eoa, false);
        assertFalse(b.isTrustedForwarder(eoa));
    }

    // ============ Forwarding through a bundle (A's handler executes the CALL op) ============

    function test_forward_throughBundle() public {
        bytes32 aSlot = bytes32(uint256(0x100));
        bytes32 bSlot = bytes32(uint256(0x200));

        // A's bundle: STORE into A, then forward B's sub-payload.
        StateUpdateType[] memory types = new StateUpdateType[](2);
        types[0] = StateUpdateType.STORE;
        types[1] = StateUpdateType.CALL;
        bytes[] memory args = new bytes[](2);
        args[0] = abi.encode(aSlot, bytes32(uint256(11)));
        args[1] = _forwardArg(address(b), 0, _singleStore(bSlot, bytes32(uint256(22))), 0);

        a.stateChangeHandlerExternal(abi.encode(types, args));

        assertEq(vm.load(address(a), aSlot), bytes32(uint256(11)), "root STORE not applied");
        assertEq(vm.load(address(b), bSlot), bytes32(uint256(22)), "forwarded STORE not applied");
        assertEq(b.stateTransitionCount(), 1);
    }

    function test_forward_recursive_AtoBtoC() public {
        bytes32 bSlot = bytes32(uint256(0xB0));
        bytes32 cSlot = bytes32(uint256(0xC0));

        // B's sub-payload: STORE into B, then forward C's sub-payload (C trusts B).
        StateUpdateType[] memory bTypes = new StateUpdateType[](2);
        bTypes[0] = StateUpdateType.STORE;
        bTypes[1] = StateUpdateType.CALL;
        bytes[] memory bArgs = new bytes[](2);
        bArgs[0] = abi.encode(bSlot, bytes32(uint256(2)));
        bArgs[1] = _forwardArg(address(c), 0, _singleStore(cSlot, bytes32(uint256(3))), 0);

        // A's bundle: a single forward to B.
        StateUpdateType[] memory aTypes = new StateUpdateType[](1);
        aTypes[0] = StateUpdateType.CALL;
        bytes[] memory aArgs = new bytes[](1);
        aArgs[0] = _forwardArg(address(b), 0, abi.encode(bTypes, bArgs), 0);

        a.stateChangeHandlerExternal(abi.encode(aTypes, aArgs));

        assertEq(vm.load(address(b), bSlot), bytes32(uint256(2)));
        assertEq(vm.load(address(c), cSlot), bytes32(uint256(3)));
        assertEq(b.stateTransitionCount(), 1);
        assertEq(c.stateTransitionCount(), 1);
    }

    function test_forward_repeatedCallee_consecutiveIndices() public {
        StateUpdateType[] memory types = new StateUpdateType[](2);
        types[0] = StateUpdateType.CALL;
        types[1] = StateUpdateType.CALL;
        bytes[] memory args = new bytes[](2);
        args[0] = _forwardArg(address(b), 0, _singleStore(bytes32(uint256(1)), bytes32(uint256(1))), 0);
        args[1] = _forwardArg(address(b), 0, _singleStore(bytes32(uint256(2)), bytes32(uint256(2))), 1);

        a.stateChangeHandlerExternal(abi.encode(types, args));

        assertEq(vm.load(address(b), bytes32(uint256(1))), bytes32(uint256(1)));
        assertEq(vm.load(address(b), bytes32(uint256(2))), bytes32(uint256(2)));
        assertEq(b.stateTransitionCount(), 2, "each forward must bump the callee counter once");
    }

    function test_forward_replayRevertsAndBundleIsAtomic() public {
        bytes32 aSlot = bytes32(uint256(0x111));
        bytes memory subUpdates = _singleStore(bytes32(uint256(1)), bytes32(uint256(1)));
        bytes memory forwardCallargs = abi.encodeCall(IGasKillerForwardee.applyForwardedUpdates, (subUpdates, 0));

        // A's bundle: STORE into A, forward to B, then replay the same forward (stale index).
        StateUpdateType[] memory types = new StateUpdateType[](3);
        types[0] = StateUpdateType.STORE;
        types[1] = StateUpdateType.CALL;
        types[2] = StateUpdateType.CALL;
        bytes[] memory args = new bytes[](3);
        args[0] = abi.encode(aSlot, bytes32(uint256(1)));
        args[1] = abi.encode(address(b), uint256(0), forwardCallargs);
        args[2] = abi.encode(address(b), uint256(0), forwardCallargs);

        // The replayed forward fails B's index check and bubbles as RevertingContext.
        vm.expectRevert(
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector,
                2,
                address(b),
                abi.encodeWithSelector(IGasKillerSDK.InvalidTransitionIndex.selector),
                forwardCallargs
            )
        );
        a.stateChangeHandlerExternal(abi.encode(types, args));

        // Whole-bundle atomicity: nothing from the failed bundle may persist.
        assertEq(vm.load(address(a), aSlot), bytes32(0), "root STORE must be rolled back");
        assertEq(vm.load(address(b), bytes32(uint256(1))), bytes32(0), "forwarded STORE must be rolled back");
        assertEq(b.stateTransitionCount(), 0, "callee counter must be rolled back");
    }

    function test_forward_valueThreading() public {
        uint256 amount = 1 ether;
        vm.deal(address(a), amount);

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CALL;
        bytes[] memory args = new bytes[](1);
        args[0] = _forwardArg(address(b), amount, _singleStore(bytes32(uint256(1)), bytes32(uint256(1))), 0);

        a.stateChangeHandlerExternal(abi.encode(types, args));

        assertEq(address(b).balance, amount, "forwarded ETH not received by callee");
        assertEq(address(a).balance, 0);
    }

    // ============ ERC-165 ============

    function test_supportsInterface_forwardee() public view {
        assertTrue(b.supportsInterface(type(IGasKillerForwardee).interfaceId));
        // Pre-existing detection must be unchanged.
        assertTrue(b.supportsInterface(type(IGasKillerSDK).interfaceId));
        assertTrue(b.supportsInterface(type(IERC165).interfaceId));
    }

    // ============ verifyAndUpdate end-to-end (mock ECDSA stake registry) ============

    function _signedBundleCall(GasKillerSDKExposed root, bytes memory storageUpdates) internal {
        vm.roll(100);
        uint32 referenceBlockNumber = 99;
        uint256 transitionIndex = root.stateTransitionCount();
        bytes4 targetFunction = bytes4(keccak256("someBusinessFunction()"));
        bytes32 msgHash = sha256(abi.encode(transitionIndex, address(root), targetFunction, storageUpdates));

        // The mock registry accepts any operators/signatures, so empty arrays suffice.
        address[] memory operators = new address[](0);
        bytes[] memory signatures = new bytes[](0);

        root.verifyAndUpdate(
            msgHash, referenceBlockNumber, storageUpdates, transitionIndex, targetFunction, operators, signatures
        );
    }

    function test_verifyAndUpdate_multicallBundle() public {
        bytes32 aSlot = bytes32(uint256(0xA1));
        bytes32 bSlot = bytes32(uint256(0xB1));

        StateUpdateType[] memory types = new StateUpdateType[](2);
        types[0] = StateUpdateType.STORE;
        types[1] = StateUpdateType.CALL;
        bytes[] memory args = new bytes[](2);
        args[0] = abi.encode(aSlot, bytes32(uint256(0xAA)));
        args[1] = _forwardArg(address(b), 0, _singleStore(bSlot, bytes32(uint256(0xBB))), 0);

        _signedBundleCall(a, abi.encode(types, args));

        assertEq(vm.load(address(a), aSlot), bytes32(uint256(0xAA)));
        assertEq(vm.load(address(b), bSlot), bytes32(uint256(0xBB)));
        assertEq(a.stateTransitionCount(), 1, "root counter bumped by verifyAndUpdate");
        assertEq(b.stateTransitionCount(), 1, "callee counter bumped by the forward");
    }

    function test_verifyAndUpdate_invalidQuorumSignatureReverts() public {
        // Registry does not return the ERC-1271 magic value → the quorum is rejected.
        registry.setValid(false);

        vm.roll(100);
        bytes memory storageUpdates = _singleStore(bytes32(uint256(1)), bytes32(uint256(1)));
        bytes32 msgHash = sha256(abi.encode(uint256(0), address(a), bytes4(0), storageUpdates));
        address[] memory operators = new address[](0);
        bytes[] memory signatures = new bytes[](0);

        vm.expectRevert(IGasKillerSDK.InvalidQuorumSignature.selector);
        a.verifyAndUpdate(msgHash, 99, storageUpdates, 0, bytes4(0), operators, signatures);
    }
}
