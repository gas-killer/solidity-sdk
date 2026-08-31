// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

// src/schnorr/interface/ISchnorrNonceRegistry.sol

/// @title ISchnorrNonceRegistry
/// @notice Read surface of the nonce-batch commitment registry: nodes resolve which batch
///         (Merkle root) covers an absolute slot, exactly the way they read stakes from
///         the stake registry. The chain never stores or opens nonce points — full batches
///         travel p2p and are verified off-chain against these roots.
interface ISchnorrNonceRegistry {
    /// @notice Emitted for every registered batch; nodes watch this to pull the batch p2p.
    event NonceBatchRegistered(
        address indexed operatorId, uint64 indexed batchIndex, uint64 startSlot, uint64 count, bytes32 root
    );

    /// @notice One past the operator's last committed slot (0 if no batches).
    function coverage(address operatorId) external view returns (uint64);

    /// @notice Number of batches an operator has registered.
    function batchCount(address operatorId) external view returns (uint256);

    /// @notice The batch covering `slot` for `operatorId`.
    /// @return batchIndex  the batch's position in the operator's list.
    /// @return root        the batch's Merkle root.
    /// @return offset      `slot`'s leaf index within the batch.
    function batchAt(address operatorId, uint64 slot)
        external
        view
        returns (uint64 batchIndex, bytes32 root, uint64 offset);
}
