// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {CycleRelay} from "./CycleRelay.sol";

/// @title CycleRoot
/// @notice The nested-cycle example: `start` calls the relay, which calls back `finish` on
///         this contract (A → B → A). Settled nested, this contract applies two frames of one
///         tree, the second re-entering while the first is still applying.
/// @dev `finish` checks that it observes the intermediate state `start` left behind. On replay
///      that check never runs, so the example's test checks the same property with an
///      observer call inside the re-entered frame.
contract CycleRoot is GasKillerSDK {
    error NotRelay();
    error UnexpectedCounter(uint256 counter, uint256 expected);

    /// @notice Incremented by every `start` (slot 0).
    uint256 public counter;
    /// @notice The counter value `finish` last confirmed (slot 1).
    uint256 public settled;

    CycleRelay public immutable relay;

    constructor(address _avsAddress, address _schnorrStakeRegistry, CycleRelay _relay) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
        relay = _relay;
    }

    function start() external trackState {
        counter += 1;
        relay.relay(counter);
    }

    function finish(uint256 expected) external trackState {
        if (msg.sender != address(relay)) revert NotRelay();
        if (counter != expected) revert UnexpectedCounter(counter, expected);
        settled = expected;
    }
}
