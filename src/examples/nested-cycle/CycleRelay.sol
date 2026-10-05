// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {CycleRoot} from "./CycleRoot.sol";

/// @title CycleRelay
/// @notice The middle contract of the nested-cycle example: records the value it was handed and
///         calls back into the root.
contract CycleRelay is GasKillerSDK {
    /// @notice The last value relayed (slot 0).
    uint256 public relayed;

    CycleRoot public immutable root;

    constructor(address _avsAddress, address _schnorrStakeRegistry, CycleRoot _root) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
        root = _root;
    }

    function relay(uint256 n) external trackState {
        relayed = n;
        root.finish(n);
    }
}
