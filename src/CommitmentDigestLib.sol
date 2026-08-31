// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/// @title CommitmentDigestLib
/// @notice The Gas Killer commitment digest: the exact bytes operators sign to authorize a state
///         transition.
/// @dev One definition, four consumers that must agree byte-for-byte:
///      - `GasKillerSDK` and `SchnorrGasKillerSDK` reconstruct it to admit a settlement,
///      - `GasKillerSlasherBase` reconstructs it to identify the commitment being challenged,
///      - the off-chain operator signer in `gas-killer/service` builds the same preimage in Rust.
///
///      Disagreement is silent and total in either direction: a settlement whose digest the
///      slasher cannot reproduce is unslashable, and operators signing a digest the SDK does not
///      reconstruct can never reach quorum. The Rust side is pinned by a golden vector and by the
///      e2e parity check against `getMessageHash`; the three on-chain sites are pinned here, by
///      construction, and cross-checked in `GasKillerSlashingParity.t.sol`.
///
///      `target` is passed explicitly rather than read as `address(this)` because the slasher
///      computes digests on behalf of the contract that settled them, not itself.
library CommitmentDigestLib {
    /// @notice Compute the commitment digest for one state transition
    /// @param target The Gas Killer contract the transition applies to
    /// @param transitionIndex The transition index
    /// @param anchorHash The hash of the block the off-chain execution was anchored to
    /// @param callerAddress The msg.sender of the original call
    /// @param contractCalldata The full calldata of the original call
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The SHA-256 digest operators sign
    function commitmentHash(
        address target,
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        bytes calldata storageUpdates
    ) internal pure returns (bytes32) {
        return sha256(abi.encode(transitionIndex, target, anchorHash, callerAddress, contractCalldata, storageUpdates));
    }
}
