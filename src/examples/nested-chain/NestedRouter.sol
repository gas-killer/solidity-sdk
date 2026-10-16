// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {NestedVault} from "./NestedVault.sol";

/// @title NestedRouter
/// @notice The root contract of the nested-chain example. A traced `process` call settles as
///         one tree: the router's frame, the vault's frame and the ledger's frame, under a
///         single quorum signature submitted to `verifyAndUpdateTree`.
contract NestedRouter is GasKillerSDK {
    /// @notice Number of processed requests (slot 0).
    uint256 public processed;

    NestedVault public immutable vault;

    constructor(address _avsAddress, address _schnorrStakeRegistry, NestedVault _vault) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
        vault = _vault;
    }

    function process(address user, uint256[] calldata weights) external trackState {
        processed += 1;
        vault.credit(user, weights);
    }
}
