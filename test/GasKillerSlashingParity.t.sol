// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasKillerSDKExposed} from "./exposed/GasKillerSDKExposed.sol";
import {SchnorrGasKillerSDK} from "../src/schnorr/SchnorrGasKillerSDK.sol";
import {ISchnorrStakeRegistry} from "../src/schnorr/interface/ISchnorrStakeRegistry.sol";
import {GasKillerBLSSlasher} from "../src/GasKillerBLSSlasher.sol";
import {IGasKillerSlasher} from "../src/interface/IGasKillerSlasher.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";

/// Schnorr registry stub that approves any aggregate signature — these tests exercise the
/// digest binding and the slasher recording hook, not signature verification (covered in
/// SchnorrStakeRegistry.t.sol).
contract AcceptingSchnorrRegistry is ISchnorrStakeRegistry {
    function isValidSignature(bytes32, uint256, address, address[] calldata, uint256) external pure returns (bool) {
        return true;
    }
}

/// Minimal slasher stand-in that records the commitment hashes the SDK reports. Only
/// `recordCommitment` is invoked by the SDK during settlement, so nothing else is implemented.
contract MockRecordingSlasher {
    bytes32 public lastRecorded;
    uint256 public recordCount;

    function recordCommitment(bytes32 commitmentHash) external {
        lastRecorded = commitmentHash;
        recordCount++;
    }
}

/// Concrete Schnorr SDK wired to a registry and (optionally) a slasher.
contract SlashableSchnorrSDK is SchnorrGasKillerSDK {
    uint256 public value; // slot 0

    constructor(address registry, address slasher_) {
        _setSchnorrRegistry(registry);
        _setAvsAddress(address(0xA75));
        _setSlasher(slasher_);
    }
}

/// @notice Guards that the BLS and Schnorr SDKs bind the SAME execution-context digest the
///         `GasKillerSlasher` recomputes, so a commitment signed under either scheme is
///         challengeable by the same fraud-proof machinery. Also covers the Schnorr slasher
///         recording hook and rejection of the pre-parity `targetFunction` digest.
contract GasKillerSlashingParityTest is Test {
    // Fixed execution-context fields bound into the task digest. Values are arbitrary; only
    // encoding consistency across BLS SDK, Schnorr SDK, and the slasher matters here.
    bytes32 internal constant ANCHOR = keccak256("anchor-block");
    address internal constant CALLER = address(0xCA11E4);
    bytes internal constant CALLDATA = hex"deadbeef";

    function _storeUpdate(bytes32 slot, bytes32 val) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(slot, val);
        return abi.encode(types, args);
    }

    function _expected(address contractAddress, uint256 ti, bytes memory updates) internal pure returns (bytes32) {
        return sha256(abi.encode(ti, contractAddress, ANCHOR, CALLER, CALLDATA, updates));
    }

    function _commitment(address contractAddress, uint256 ti, bytes memory updates)
        internal
        pure
        returns (IGasKillerSlasher.SignedCommitment memory)
    {
        return IGasKillerSlasher.SignedCommitment({
            transitionIndex: ti,
            contractAddress: contractAddress,
            anchorHash: ANCHOR,
            callerAddress: CALLER,
            contractCalldata: CALLDATA,
            storageUpdates: updates
        });
    }

    function _deployBlsSlasher() internal returns (GasKillerBLSSlasher) {
        // computeCommitmentHash is pure, so the wiring addresses are irrelevant here.
        return new GasKillerBLSSlasher(
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            bytes32(0),
            bytes32(0),
            0,
            0
        );
    }

    /// Both SDKs must produce exactly the digest the slasher's `computeCommitmentHash` recomputes
    /// for a commitment naming that SDK — the whole point of the digest change is this parity.
    function test_digestParity_bothSdksMatchSlasherCommitmentHash() public {
        GasKillerSDKExposed blsSdk = new GasKillerSDKExposed(address(0xA75), address(0xB15));
        AcceptingSchnorrRegistry registry = new AcceptingSchnorrRegistry();
        SlashableSchnorrSDK schnorrSdk = new SlashableSchnorrSDK(address(registry), address(0));
        GasKillerBLSSlasher slasher = _deployBlsSlasher();

        uint256 ti = 3;
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(99)));

        bytes32 blsHash = blsSdk.getMessageHash(ti, ANCHOR, CALLER, CALLDATA, updates);
        bytes32 schnorrHash = schnorrSdk.getMessageHash(ti, ANCHOR, CALLER, CALLDATA, updates);

        // Each SDK binds its own address; the encoding is otherwise identical across schemes.
        assertEq(blsHash, _expected(address(blsSdk), ti, updates), "BLS digest encoding");
        assertEq(schnorrHash, _expected(address(schnorrSdk), ti, updates), "Schnorr digest encoding");

        // The slasher recognizes each SDK's digest, so a commitment signed under either scheme
        // hashes to the value the slasher checks against.
        assertEq(slasher.computeCommitmentHash(_commitment(address(blsSdk), ti, updates)), blsHash, "BLS<->slasher");
        assertEq(
            slasher.computeCommitmentHash(_commitment(address(schnorrSdk), ti, updates)),
            schnorrHash,
            "Schnorr<->slasher"
        );
    }

    /// The Schnorr SDK forwards the verified commitment hash to its configured slasher during
    /// settlement, opening the challenge window.
    function test_schnorr_recordsCommitmentWithSlasher() public {
        vm.roll(1000);
        AcceptingSchnorrRegistry registry = new AcceptingSchnorrRegistry();
        MockRecordingSlasher slasher = new MockRecordingSlasher();
        SlashableSchnorrSDK sdk = new SlashableSchnorrSDK(address(registry), address(slasher));

        bytes memory updates = _storeUpdate(bytes32(0), bytes32(uint256(42)));
        uint256 ti = sdk.stateTransitionCount();
        bytes32 h = sdk.getMessageHash(ti, ANCHOR, CALLER, CALLDATA, updates);
        address[] memory none = new address[](0);

        vm.expectCall(address(slasher), abi.encodeCall(MockRecordingSlasher.recordCommitment, (h)));
        sdk.verifyAndUpdate(
            h, uint32(block.number - 1), updates, ti, ANCHOR, CALLER, CALLDATA, 1, address(0x1234), none
        );

        assertEq(sdk.value(), 42, "state applied");
        assertEq(slasher.lastRecorded(), h, "commitment recorded with the digest");
        assertEq(slasher.recordCount(), 1, "recorded exactly once");
    }

    /// The pre-parity 4-field `targetFunction` digest no longer validates: the SDK recomputes the
    /// 6-field execution-context digest, so an old-format hash is rejected as an invalid signature.
    function test_schnorr_oldTargetFunctionDigestRejected() public {
        vm.roll(1000);
        AcceptingSchnorrRegistry registry = new AcceptingSchnorrRegistry();
        SlashableSchnorrSDK sdk = new SlashableSchnorrSDK(address(registry), address(0));

        bytes memory updates = _storeUpdate(bytes32(0), bytes32(uint256(1)));
        uint256 ti = sdk.stateTransitionCount();
        bytes32 oldDigest = sha256(abi.encode(ti, address(sdk), bytes4(0xdeadbeef), updates));
        address[] memory none = new address[](0);

        vm.expectRevert(SchnorrGasKillerSDK.InvalidSignature.selector);
        sdk.verifyAndUpdate(
            oldDigest, uint32(block.number - 1), updates, ti, ANCHOR, CALLER, CALLDATA, 1, address(0x1234), none
        );
    }
}
