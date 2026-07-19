// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// src/interface/IHeliosLightClient.sol

/**
 * @title IHeliosLightClient
 * @notice Interface for Helios Ethereum light client
 * @dev Used for trustless block hash verification
 */
interface IHeliosLightClient {
    /**
     * @notice Check if a block hash is valid and verified by the light client
     * @param blockHash The block hash to verify
     * @return True if the block hash is valid
     */
    function isBlockHashValid(bytes32 blockHash) external view returns (bool);

    /**
     * @notice Get the block hash for a given block number
     * @param blockNumber The block number to query
     * @return The block hash for the given block number
     */
    function getBlockHash(uint256 blockNumber) external view returns (bytes32);
}
