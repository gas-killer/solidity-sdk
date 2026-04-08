// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IGasKillerServiceManager} from "../../src/interface/IGasKillerServiceManager.sol";

/// @notice Minimal mock of IGasKillerServiceManager for use in tests
contract MockGasKillerServiceManager is IGasKillerServiceManager {
    uint256 public constant QUORUM_THRESHOLD = 66;
    uint256 public constant THRESHOLD_DENOMINATOR = 100;
    uint256 public constant BLOCK_STALE_MEASURE = 300;
}
