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

// src/interface/IGasKillerSDK.sol

/// @title IGasKillerSDK
/// @notice Interface for GasKillerSDK contracts
/// @dev Defines the core functionality that GasKillerSDK implementations must provide.
///      State updates are approved by an ECDSA operator quorum verified by EigenLayer's
///      `ECDSAStakeRegistry` (ERC-1271 `isValidSignature`): operators sign the task
///      digest with their registered signing keys, and the registry checks each
///      signature and the signed stake weight at the reference block.
interface IGasKillerSDK is IERC165 {
    // Custom errors

    /// @notice Thrown when `transitionIndex + 1` does not equal the current `stateTransitionCount`
    error InvalidTransitionIndex();

    /// @notice Thrown when the reconstructed message hash does not match `msgHash`
    error InvalidSignature();

    /// @notice Thrown when the provided storage updates cannot be decoded or applied
    error InvalidStorageUpdates();

    /// @notice Thrown when an unrecognised state update operation type is encountered
    error InvalidOperation();

    /// @notice Thrown when the stake registry does not return the ERC-1271 magic value
    error InvalidQuorumSignature();

    /// @notice Thrown when `referenceBlockNumber` is older than `blockStaleMeasure` blocks ago
    error StaleBlockNumber();

    /// @notice Thrown when `referenceBlockNumber` is greater than or equal to the current block number
    error FutureBlockNumber();

    /// @notice Verify the operators' ECDSA quorum signatures and apply the encoded state updates
    /// @param msgHash The hash of the message to verify (sha256 of the encoded task)
    /// @param referenceBlockNumber The block number at which operator signing keys and
    ///        stake weights are evaluated by the stake registry
    /// @param storageUpdates The storage updates to verify and apply
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param operators Operator addresses that signed, in strictly ascending order
    /// @param signatures 65-byte `r || s || v` ECDSA signatures over `msgHash`,
    ///        index-aligned with `operators`
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        address[] calldata operators,
        bytes[] calldata signatures
    ) external;
}
