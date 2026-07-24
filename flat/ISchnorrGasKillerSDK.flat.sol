// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.6.2 ^0.8.27;

// lib/forge-std/src/interfaces/IERC165.sol

interface IERC165 {
    /// @notice Query if a contract implements an interface
    /// @param interfaceID The interface identifier, as specified in ERC-165
    /// @dev Interface identification is specified in ERC-165. This function
    /// uses less than 30,000 gas.
    /// @return `true` if the contract implements `interfaceID` and
    /// `interfaceID` is not 0xffffffff, `false` otherwise
    function supportsInterface(bytes4 interfaceID) external view returns (bool);
}

// src/schnorr/interface/ISchnorrGasKillerSDK.sol

/// @title ISchnorrGasKillerSDK
/// @notice Interface for SchnorrGasKillerSDK contracts
/// @dev Defines the core functionality that SchnorrGasKillerSDK implementations must
///      provide. State updates are approved by an operator quorum expressed as a
///      **single** aggregate Schnorr signature verified by a `SchnorrStakeRegistry`
///      (constant gas, non-signer subtraction) instead of `N` per-operator ECDSA
///      signatures. Deliberately single-function so
///      `type(ISchnorrGasKillerSDK).interfaceId` equals the `verifyAndUpdate`
///      selector — the router's ERC-165 preflight probes exactly this ID.
interface ISchnorrGasKillerSDK is IERC165 {
    /// @notice Verify the operators' aggregate Schnorr quorum signature and apply the
    ///         encoded state updates
    /// @param msgHash The hash of the message to verify (sha256 of the encoded task)
    /// @param referenceBlockNumber The block number at which operator keys and stake
    ///        weights are evaluated by the stake registry
    /// @param storageUpdates The storage updates to verify and apply
    /// @param transitionIndex The transition index
    /// @param anchorHash The hash of the block the off-chain execution was anchored to
    /// @param callerAddress The msg.sender of the original call
    /// @param contractCalldata The full calldata of the original call
    /// @param s Aggregate Schnorr response scalar
    /// @param Raddr Aggregate nonce address `address(R)`
    /// @param nonSigners Operators that did not sign, in strictly ascending order
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) external;
}
