// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../../GasKillerSDK.sol";

/// @title NestedLedger
/// @notice The innermost contract of the nested-chain example (`NestedRouter` → `NestedVault`
///         → `NestedLedger`). Keeps a hash chain over every credit it records, which makes
///         `record` deliberately expensive to execute natively.
/// @dev `record` is `trackState`, so when the vault calls it inside a traced task it becomes
///      its own nested frame and settles through `applyNested` without running the hash chain.
contract NestedLedger is GasKillerSDK {
    error InvalidConfiguration();

    event Recorded(address indexed user, uint256 amount, bytes32 head);

    /// @notice Head of the hash chain over every recorded credit (slot 0).
    bytes32 public head;
    /// @notice Number of credits recorded (slot 1).
    uint256 public entries;

    /// @notice Hash rounds per recorded credit.
    uint256 public immutable rounds;

    constructor(address _avsAddress, address _schnorrStakeRegistry, uint256 _rounds) {
        if (_rounds == 0) revert InvalidConfiguration();
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
        rounds = _rounds;
    }

    function record(address user, uint256 amount) external trackState {
        bytes32 h = head;
        for (uint256 i = 0; i < rounds; ++i) {
            h = keccak256(abi.encode(h, user, amount, i));
        }
        head = h;
        entries += 1;
        emit Recorded(user, amount, h);
    }
}
