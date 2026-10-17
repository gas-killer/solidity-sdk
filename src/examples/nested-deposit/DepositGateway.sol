// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {GasKillerNestedSDK} from "../../GasKillerNestedSDK.sol";
import {DepositVault} from "./DepositVault.sol";

/// @title DepositGateway
/// @notice The root contract of the nested-deposit example: `deposit` forwards its ETH to the
///         vault, so settled nested, the tree's `NESTED` op moves value into the vault's frame.
/// @dev Both leaves bind value: the root leaf binds the `msg.value` the tree settles with, and
///      the vault's leaf binds what the `NESTED` op forwards it, so a deposit settles only with
///      its ETH and the vault is backed by every wei it credits.
contract DepositGateway is GasKillerNestedSDK {
    /// @notice Number of deposits forwarded (slot 0).
    uint256 public deposits;

    DepositVault public immutable vault;

    constructor(address _avsAddress, address _schnorrStakeRegistry, uint256 _receiptRounds) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
        // Deployed here so the vault can trust its creator as the only gateway, with no
        // separate wiring transaction to front-run.
        vault = new DepositVault(_avsAddress, _schnorrStakeRegistry, _receiptRounds);
    }

    function deposit(address account) external payable trackState {
        deposits += 1;
        vault.deposit{value: msg.value}(account);
    }
}
