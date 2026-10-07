// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {CycleRoot} from "./CycleRoot.sol";

/// @title CycleRelay
/// @notice The middle contract of the nested-cycle example: records the value it was handed and
///         calls back into the root.
contract CycleRelay is GasKillerSDK {
    error RootAlreadySet();

    /// @notice The last value relayed (slot 0).
    uint256 public relayed;

    CycleRoot public root;

    constructor(address _avsAddress, address _schnorrStakeRegistry) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
    }

    /// @dev The root needs this contract's address and this contract needs the root's, so one
    ///      side is wired after deployment.
    function setRoot(CycleRoot _root) external {
        if (address(root) != address(0)) revert RootAlreadySet();
        root = _root;
    }

    function relay(uint256 n) external trackState {
        relayed = n;
        root.finish(n);
    }
}
