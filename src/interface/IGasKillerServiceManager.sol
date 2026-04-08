// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/// @title IGasKillerServiceManager
/// @notice GasKiller-specific interface exposing quorum threshold and block staleness constants
/// @dev Implemented by GasKillerServiceManagerWrapper; read by GasKillerSDK at runtime
interface IGasKillerServiceManager {
    /// @notice Numerator used when computing the quorum threshold
    function QUORUM_THRESHOLD() external view returns (uint256);

    /// @notice Denominator used when computing the quorum threshold (representing the full operator count)
    function THRESHOLD_DENOMINATOR() external view returns (uint256);

    /// @notice Maximum number of blocks a reference block may lag behind the current block
    function BLOCK_STALE_MEASURE() external view returns (uint256);
}
