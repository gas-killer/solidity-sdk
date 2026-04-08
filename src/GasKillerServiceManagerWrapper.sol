// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IServiceManager} from "@eigenlayer-middleware/interfaces/IServiceManager.sol";

import {IGasKillerServiceManager} from "./interface/IGasKillerServiceManager.sol";

/// @title GasKillerServiceManagerWrapper
/// @notice Wraps a deployed ServiceManager (e.g. from eigenlayer-bls-local) and
///         exposes GasKiller-specific constants
/// @dev All calls other than the three constants above are forwarded to the underlying
///      SERVICE_MANAGER via `call`. Note that msg.sender is NOT preserved —
///      authorization-gated write functions should be called directly on the
///      underlying SERVICE_MANAGER address.
contract GasKillerServiceManagerWrapper is IGasKillerServiceManager {
    /// @notice Numerator used when computing the quorum threshold
    uint256 public constant QUORUM_THRESHOLD = 2;

    /// @notice Denominator used when computing the quorum threshold (representing the full operator count)
    uint256 public constant THRESHOLD_DENOMINATOR = 3;

    /// @notice Maximum number of blocks a reference block may lag behind the current block
    uint256 public constant BLOCK_STALE_MEASURE = 300;

    /// @notice The underlying ServiceManager this contract wraps
    IServiceManager public immutable SERVICE_MANAGER;

    /// @param _serviceManager The address of the deployed ServiceManager to wrap
    constructor(address _serviceManager) {
        require(_serviceManager != address(0), "zero address");
        SERVICE_MANAGER = IServiceManager(_serviceManager);
    }

    /// @notice Forward any unrecognized call to the underlying SERVICE_MANAGER
    /// @dev Uses `call` so msg.sender is the wrapper, not the original caller
    fallback() external payable {
        address target = address(SERVICE_MANAGER);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := call(gas(), target, callvalue(), 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
