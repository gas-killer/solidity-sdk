// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

// src/schnorr/interface/ISchnorrOperatorRegistry.sol

/// @title ISchnorrOperatorRegistry
/// @notice The operator-lookup surface of the Schnorr stake registry, split out from
///         [`ISchnorrStakeRegistry`] so contracts that need to know *who is registered*
///         (rather than *is this quorum signature valid*) depend only on that.
/// @dev Kept separate deliberately: `ISchnorrStakeRegistry` is the SDK's verification
///      surface and every SDK unit test mocks it, so widening it would force unrelated
///      mocks to grow a member they never consult. `SchnorrNonceRegistry` is the first
///      consumer — it gates batch commitments on stake-registry membership, which is
///      where the proof of possession binding key to identity is enforced.
interface ISchnorrOperatorRegistry {
    /// @notice The registered operator record for an identity address (the concrete
    ///         registry's public `operators` mapping getter).
    /// @dev `registered` is false both for unknown identities and for exit tombstones —
    ///      it is the only field that governs membership. An exited operator keeps
    ///      readable `x`, `y`, `weight` and `exitBlock` so its identity stays
    ///      attributable after it leaves the set.
    /// @param operatorId the operator identity (`pointAddress(x, y)`).
    /// @return x          pubkey x-coordinate.
    /// @return y          pubkey y-coordinate.
    /// @return weight     stake weight.
    /// @return registered whether the operator is in the active set.
    /// @return exitBlock  block of the operator's most recent exit; 0 if it never exited.
    function operators(address operatorId)
        external
        view
        returns (uint256 x, uint256 y, uint96 weight, bool registered, uint48 exitBlock);
}
