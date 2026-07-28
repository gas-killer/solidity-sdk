// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {
    IBLSSignatureChecker,
    IBLSSignatureCheckerTypes
} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {IGasKillerSDK} from "../src/interface/IGasKillerSDK.sol";
import {IGasKillerSDKAuth} from "../src/interface/IGasKillerSDKAuth.sol";
import {GasKillerSDKExposed} from "./exposed/GasKillerSDKExposed.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";

/// @dev Minimal stand-in for the EigenLayer BLS signature checker. `checkSignatures` ignores the
/// (mocked) signature and returns preconfigured stake totals, so tests drive the SDK's quorum
/// logic deterministically. It is `view` (the SDK calls it via STATICCALL) and therefore holds no
/// call history; tests assert hash correctness through the SDK's own `expectedHash == msgHash`
/// check, which must pass before this is ever reached.
contract MockBLSSignatureChecker {
    uint96 public signedStake;
    uint96 public totalStake;

    constructor(uint96 _signedStake, uint96 _totalStake) {
        signedStake = _signedStake;
        totalStake = _totalStake;
    }

    function setStake(uint96 _signedStake, uint96 _totalStake) external {
        signedStake = _signedStake;
        totalStake = _totalStake;
    }

    /// @dev `view` to match `IBLSSignatureChecker.checkSignatures`; the SDK invokes it via
    /// STATICCALL, so this must not modify state.
    function checkSignatures(
        bytes32,
        bytes calldata quorumNumbers,
        uint32,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory
    ) external view returns (IBLSSignatureCheckerTypes.QuorumStakeTotals memory totals, bytes32) {
        uint256 n = quorumNumbers.length;
        totals.signedStakeForQuorum = new uint96[](n);
        totals.totalStakeForQuorum = new uint96[](n);
        for (uint256 i = 0; i < n; i++) {
            totals.signedStakeForQuorum[i] = signedStake;
            totals.totalStakeForQuorum[i] = totalStake;
        }
        return (totals, bytes32(0));
    }
}

contract GasKillerSDKAuthTest is Test {
    // Vector A — a real EIP-1559 tx (Sepolia, chainId 11155111) signed by Anvil account 0.
    address constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant TARGET = 0x00000000000000000000000000000000000000A1;
    uint256 constant CHAIN = 11155111;
    uint256 constant NONCE = 7;
    uint256 constant VALUE = 12345;
    bytes constant CALLDATA = hex"abcdef01";
    bytes32 constant SIG_R = 0x06e8d35c9dee8cecc94c166b2083ba97c09553578fb89a3f5e159edc0ebf5c92;
    bytes32 constant SIG_S = 0x028f46d16b07b96dc44d699c35020498e2a9520b7d05ee35a7b55019743c0653;
    uint8 constant SIG_YPARITY = 1;

    GasKillerSDKExposed sdk;
    MockBLSSignatureChecker bls;

    bytes quorumNumbers = hex"00"; // one quorum, number 0
    uint32 refBlock;

    function setUp() public {
        bls = new MockBLSSignatureChecker(100, 100); // full stake signed → threshold met
        // Deploy at the exact address the vector was signed against, so `to == address(this)`.
        GasKillerSDKExposed impl = new GasKillerSDKExposed(makeAddr("AVS"), address(bls));
        vm.etch(TARGET, address(impl).code);
        sdk = GasKillerSDKExposed(TARGET);
        // Reinitialise storage at the etched address (etch copies code, not storage).
        sdk.init(makeAddr("AVS"), address(bls));

        vm.chainId(CHAIN);
        vm.roll(1000);
        refBlock = uint32(block.number - 1);
    }

    /// Encodes a single STORE update writing `value` to `slot`.
    function _storeUpdate(bytes32 slot, bytes32 value) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(slot, value);
        return abi.encode(types, args);
    }

    function _signedTx() internal pure returns (IGasKillerSDKAuth.SignedTx memory) {
        return IGasKillerSDKAuth.SignedTx({
            nonce: NONCE,
            maxPriorityFeePerGas: 1_000_000_000,
            maxFeePerGas: 2_000_000_000,
            gasLimit: 1_000_000,
            value: VALUE,
            callData: CALLDATA,
            yParity: SIG_YPARITY,
            r: SIG_R,
            s: SIG_S
        });
    }

    function _emptyNss() internal pure returns (IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss) {}

    // -- happy path ------------------------------------------------------------------------------

    function test_verifyAndUpdateWithAuth_appliesUpdatesAndSpendsNonce() public {
        bytes32 slot = bytes32(uint256(0x1234));
        bytes32 val = bytes32(uint256(42));
        bytes memory updates = _storeUpdate(slot, val);

        // Operators attest to exactly this call: hash commits to the recovered signer, value,
        // nonce, calldata, and the storage diff.
        bytes32 msgHash = sdk.getSignedMessageHash(0, SIGNER, VALUE, NONCE, CALLDATA, updates);

        assertFalse(sdk.isNonceUsed(SIGNER, NONCE));

        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 0, _signedTx(), _emptyNss());

        assertEq(vm.load(address(sdk), slot), val, "state update not applied");
        assertEq(sdk.stateTransitionCount(), 1, "transition count not incremented");
        assertTrue(sdk.isNonceUsed(SIGNER, NONCE), "nonce not spent");
    }

    // -- replay ----------------------------------------------------------------------------------

    function test_replay_sameSignerAndNonce_reverts() public {
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));
        bytes32 msgHash = sdk.getSignedMessageHash(0, SIGNER, VALUE, NONCE, CALLDATA, updates);

        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 0, _signedTx(), _emptyNss());

        // Second settlement of the same (signer, nonce) — even at the next transition index —
        // must be rejected.
        bytes32 msgHash2 = sdk.getSignedMessageHash(1, SIGNER, VALUE, NONCE, CALLDATA, updates);
        vm.expectRevert(IGasKillerSDKAuth.ReplayedTransaction.selector);
        sdk.verifyAndUpdateWithAuth(msgHash2, quorumNumbers, refBlock, updates, 1, _signedTx(), _emptyNss());
    }

    // -- binding: the attestation cannot be detached from the authorized call --------------------

    function test_wrongSignerCommitment_reverts() public {
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));
        // Operators (maliciously or by mistake) commit to a different signer than the signature
        // recovers. The contract recomputes the hash with the *recovered* signer → mismatch.
        address notSigner = address(0xdead);
        bytes32 msgHash = sdk.getSignedMessageHash(0, notSigner, VALUE, NONCE, CALLDATA, updates);

        vm.expectRevert(IGasKillerSDK.InvalidSignature.selector);
        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 0, _signedTx(), _emptyNss());
    }

    function test_tamperedCalldata_reverts() public {
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));
        // A relayer swaps the calldata (and commits a hash for the swapped call). The recovered
        // signer changes because the signature covers the calldata, so the recomputed hash cannot
        // match whatever was committed.
        bytes32 msgHash = sdk.getSignedMessageHash(0, SIGNER, VALUE, NONCE, hex"deadbeef", updates);
        IGasKillerSDKAuth.SignedTx memory userTx = _signedTx();
        userTx.callData = hex"deadbeef";

        vm.expectRevert(IGasKillerSDK.InvalidSignature.selector);
        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 0, userTx, _emptyNss());
    }

    function test_tamperedValue_reverts() public {
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));
        IGasKillerSDKAuth.SignedTx memory userTx = _signedTx();
        userTx.value = VALUE + 1; // not what was signed
        // Even if operators commit to the tampered value, the recovered signer no longer matches.
        bytes32 msgHash = sdk.getSignedMessageHash(0, SIGNER, VALUE + 1, NONCE, CALLDATA, updates);

        vm.expectRevert(IGasKillerSDK.InvalidSignature.selector);
        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 0, userTx, _emptyNss());
    }

    /// A signature for this contract cannot be replayed on a different contract: the sighash pins
    /// `to = address(this)`, so a different address recovers a different (or zero) signer.
    function test_signatureBoundToContractAddress() public {
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));

        GasKillerSDKExposed other = new GasKillerSDKExposed(makeAddr("AVS"), address(bls));
        // Build the hash the honest operators would produce for `other` — they recover the signer
        // against `other`'s address, which is NOT SIGNER, so committing SIGNER here fails.
        bytes32 msgHash = other.getSignedMessageHash(0, SIGNER, VALUE, NONCE, CALLDATA, updates);
        vm.expectRevert(IGasKillerSDK.InvalidSignature.selector);
        other.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 0, _signedTx(), _emptyNss());
    }

    // -- signature validity ----------------------------------------------------------------------

    function test_zeroRecoveredSigner_reverts() public {
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));
        IGasKillerSDKAuth.SignedTx memory userTx = _signedTx();
        userTx.r = bytes32(0); // ecrecover returns address(0)
        bytes32 msgHash = sdk.getSignedMessageHash(0, SIGNER, VALUE, NONCE, CALLDATA, updates);

        vm.expectRevert(IGasKillerSDKAuth.InvalidTransactionSignature.selector);
        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 0, userTx, _emptyNss());
    }

    // -- quorum + block guards -------------------------------------------------------------------

    function test_insufficientQuorum_reverts() public {
        bls.setStake(50, 100); // 50% < 66% threshold
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));
        bytes32 msgHash = sdk.getSignedMessageHash(0, SIGNER, VALUE, NONCE, CALLDATA, updates);

        vm.expectRevert(IGasKillerSDK.InsufficientQuorumThreshold.selector);
        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 0, _signedTx(), _emptyNss());
    }

    function test_thresholdBoundary_66of100_passes() public {
        bls.setStake(66, 100); // exactly 66% meets the threshold
        bytes memory updates = _storeUpdate(bytes32(uint256(2)), bytes32(uint256(7)));
        bytes32 msgHash = sdk.getSignedMessageHash(0, SIGNER, VALUE, NONCE, CALLDATA, updates);
        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 0, _signedTx(), _emptyNss());
        assertEq(vm.load(address(sdk), bytes32(uint256(2))), bytes32(uint256(7)));
    }

    function test_futureReferenceBlock_reverts() public {
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));
        bytes32 msgHash = sdk.getSignedMessageHash(0, SIGNER, VALUE, NONCE, CALLDATA, updates);
        vm.expectRevert(IGasKillerSDK.FutureBlockNumber.selector);
        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, uint32(block.number), updates, 0, _signedTx(), _emptyNss());
    }

    function test_staleReferenceBlock_reverts() public {
        vm.roll(2000);
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));
        bytes32 msgHash = sdk.getSignedMessageHash(0, SIGNER, VALUE, NONCE, CALLDATA, updates);
        // 300-block default staleness window: block 2000 - reference 1000 = 1000 > 300.
        vm.expectRevert(IGasKillerSDK.StaleBlockNumber.selector);
        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, 1000, updates, 0, _signedTx(), _emptyNss());
    }

    function test_wrongTransitionIndex_reverts() public {
        bytes memory updates = _storeUpdate(bytes32(uint256(1)), bytes32(uint256(1)));
        bytes32 msgHash = sdk.getSignedMessageHash(5, SIGNER, VALUE, NONCE, CALLDATA, updates);
        vm.expectRevert(IGasKillerSDK.InvalidTransitionIndex.selector);
        sdk.verifyAndUpdateWithAuth(msgHash, quorumNumbers, refBlock, updates, 5, _signedTx(), _emptyNss());
    }

    // -- interface advertisement -----------------------------------------------------------------

    function test_supportsInterface_advertisesAuth() public view {
        assertTrue(sdk.supportsInterface(type(IGasKillerSDKAuth).interfaceId), "auth iface not advertised");
        // The original interface id must be unchanged so existing ERC-165 checks keep working.
        assertTrue(sdk.supportsInterface(type(IGasKillerSDK).interfaceId), "base iface regressed");
    }
}
