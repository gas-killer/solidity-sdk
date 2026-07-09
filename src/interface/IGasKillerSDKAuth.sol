// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

/// @title IGasKillerSDKAuth
/// @notice Sender-authenticated, replay-protected settlement for Gas Killer tasks that originate
///         from a user's ordinary signed transaction (the Gas Killer JSON-RPC ingress).
/// @dev Kept separate from {IGasKillerSDK} so adding this capability does not change
///      `type(IGasKillerSDK).interfaceId`, which existing deployments and off-chain ERC-165 checks
///      depend on. A contract implementing this advertises it via `supportsInterface`.
///
///      Where the permissionless `verifyAndUpdate` path attributes nothing on-chain and trusts the
///      operator set for the sender used in simulation, this path reconstructs the exact EIP-1559
///      signing hash of the user's transaction and runs `ecrecover` in the contract, so the
///      executed call is cryptographically bound to the account that signed it — no trust in the
///      operators for *who* the sender was. Correctness of the storage diff itself remains the
///      operators' attested claim (the contract does not re-execute), exactly as before.
interface IGasKillerSDKAuth {
    /// @notice Thrown when the same `(signer, nonce)` pair is settled twice.
    error ReplayedTransaction();

    /// @notice Thrown when the transaction signature does not recover a valid signer
    ///         (`ecrecover` returned the zero address).
    error InvalidTransactionSignature();

    /// @notice The authenticating fields of a user's EIP-1559 transaction.
    /// @dev `chainId` and `to` are intentionally omitted: they are fixed on-chain to
    ///      `block.chainid` and `address(this)`, so a signature is only ever valid for the chain
    ///      and contract it was actually signed against — settling it elsewhere recovers a
    ///      different address and fails. Only empty-access-list type-2 transactions are supported.
    struct SignedTx {
        /// @notice The signer's transaction nonce (also the replay key).
        uint256 nonce;
        /// @notice EIP-1559 `maxPriorityFeePerGas` (part of the signed preimage).
        uint256 maxPriorityFeePerGas;
        /// @notice EIP-1559 `maxFeePerGas` (part of the signed preimage).
        uint256 maxFeePerGas;
        /// @notice Transaction gas limit (part of the signed preimage).
        uint256 gasLimit;
        /// @notice Wei value; becomes `msg.value` in the operators' simulation.
        uint256 value;
        /// @notice Transaction calldata; the call the operators simulated.
        bytes callData;
        /// @notice Signature y-parity (0 or 1).
        uint8 yParity;
        /// @notice Signature `r`.
        bytes32 r;
        /// @notice Signature `s`.
        bytes32 s;
    }

    /// @notice Verify BLS quorum signatures for a sender-authenticated task and apply its state
    ///         updates, then mark the sender's nonce as spent.
    /// @dev Reconstructs the EIP-1559 signing hash from `userTx` (with `chainId = block.chainid`
    ///      and `to = address(this)`), recovers `signer`, requires the operator-signed `msgHash`
    ///      to equal `getSignedMessageHash(transitionIndex, signer, value, nonce, callData,
    ///      storageUpdates)` — binding the attested diff to exactly the call `signer` authorized —
    ///      and rejects a reused `(signer, nonce)`.
    /// @param msgHash The operator-signed message hash
    /// @param quorumNumbers The quorum numbers to check signatures for
    /// @param referenceBlockNumber The block number to use as reference for the operator set
    /// @param storageUpdates The ABI-encoded storage updates
    /// @param transitionIndex The transition index
    /// @param userTx The user's signed EIP-1559 transaction fields
    /// @param nonSignerStakesAndSignature The non-signer stakes and signature data computed off-chain
    function verifyAndUpdateWithAuth(
        bytes32 msgHash,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        SignedTx calldata userTx,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature
    ) external;

    /// @notice Compute the expected message hash for a sender-authenticated transition.
    /// @dev Commits to the full `callData` (not just the selector) and to `signer`, `value`, and
    ///      `nonce`, so the operators' attestation is inseparable from the exact authorized call.
    /// @param transitionIndex The transition index
    /// @param signer The recovered transaction sender
    /// @param value The transaction value
    /// @param nonce The transaction nonce
    /// @param callData The transaction calldata
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The expected SHA-256 hash
    function getSignedMessageHash(
        uint256 transitionIndex,
        address signer,
        uint256 value,
        uint256 nonce,
        bytes calldata callData,
        bytes calldata storageUpdates
    ) external view returns (bytes32);

    /// @notice Whether `(signer, nonce)` has already been settled through this contract.
    /// @param signer The transaction sender
    /// @param nonce The transaction nonce
    /// @return `true` if the pair has been spent and can no longer settle
    function isNonceUsed(address signer, uint256 nonce) external view returns (bool);
}
