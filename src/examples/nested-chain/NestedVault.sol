// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {NestedLedger} from "./NestedLedger.sol";

/// @title NestedVault
/// @notice The middle contract of the nested-chain example. Credits a user with a weighted
///         sum of their inputs and records the credit in the ledger.
contract NestedVault is GasKillerSDK {
    event Credited(address indexed user, uint256 amount);

    /// @notice Total credit per user (slot 0).
    mapping(address => uint256) public credits;

    NestedLedger public immutable ledger;

    constructor(address _avsAddress, address _schnorrStakeRegistry, NestedLedger _ledger) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
        ledger = _ledger;
    }

    function credit(address user, uint256[] calldata weights) external trackState returns (uint256 amount) {
        for (uint256 i = 0; i < weights.length; ++i) {
            amount += weights[i] * (i + 1);
        }
        credits[user] += amount;
        ledger.record(user, amount);
        emit Credited(user, amount);
    }
}
