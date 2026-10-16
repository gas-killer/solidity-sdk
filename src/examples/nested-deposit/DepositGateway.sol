// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {DepositVault} from "./DepositVault.sol";

/// @title DepositGateway
/// @notice The root contract of the nested-deposit example: `deposit` forwards its ETH to the
///         vault, so settled nested, the tree's `NESTED` op moves value into the vault's frame.
/// @dev The root leaf does not bind `msg.value` (gas-killer/solidity-sdk#104), so the root
///      must not be where deposits are credited. The vault credits them instead, inside a frame
///      whose leaf binds the value it receives, so the vault is backed by every wei it credits.
///      The gateway does not bind who pays: over-payment is not refunded and ETH can be forced
///      in, and any balance left here can fund a later settlement sent with less than its
///      deposit. A balance check in `deposit` would not help, since settlement never runs it.
contract DepositGateway is GasKillerSDK {
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
