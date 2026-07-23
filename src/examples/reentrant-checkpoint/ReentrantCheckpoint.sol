// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {SchnorrGasKillerSDK} from "../../schnorr/SchnorrGasKillerSDK.sol";

interface IReentrantObserver {
    function observe(uint256 expectedCounter) external;
}

/// @title ReentrantCheckpoint
/// @notice A Gas Killer example whose task makes a **re-entrant external call in the
///         middle of its state transition**, to prove the aggregate-Schnorr settlement
///         path handles re-entrancy safely when the off-chain executor uses the
///         **canonical** state encoding (`STATE_ENCODING=canonical`).
///
/// @dev The task `advance()` is what the off-chain EVMSketch traces; the resulting update
///      program is applied on-chain by the inherited `SchnorrGasKillerSDK.verifyAndUpdate`
///      (the business logic never runs on-chain). `advance()`:
///        1. increments `counter` (the canonical intermediate write),
///        2. calls `observer.observe(counter)`, which **re-enters** this contract to read
///           `counter` / `finalized` and reverts unless they are canonical, then
///        3. sets the final state (`finalized`, `lastObserved`).
///
///      Under the canonical encoder the program is
///        `[Store(counter,N), Call(observe(N)), Store(lastObserved,N)]`
///      so on replay the target's storage is brought to `counter=N` (with `lastObserved`
///      still at its previous value) **before** the `Call`, exactly matching native
///      execution — the observer's re-entrant read passes and the transition settles. If
///      the program failed to present canonical intermediate state (wrong `counter`, or
///      the final `lastObserved` write applied too early), the observer would revert and
///      `verifyAndUpdate` would revert with it.
///
///      Re-entrant *reads* (via the getters below) are intentionally NOT covered by the
///      `TransitionGuard` — only `verifyAndUpdate` is — so this legitimate re-entrancy
///      works while the cross-transition re-entrancy attack the guard blocks still fails.
contract ReentrantCheckpoint is SchnorrGasKillerSDK {
    /// @notice The canonical counter, incremented once per `advance()` transition (slot 0).
    uint256 public counter;
    /// @notice The counter value recorded AFTER the mid-transition external call returns
    ///         (slot 1). Equal to `counter` only once a transition has fully finalized.
    uint256 public lastObserved;

    /// @notice The external contract re-entered mid-transition.
    address public immutable observer;

    event Advanced(uint256 counter);

    constructor(address _avsAddress, address _schnorrStakeRegistry, address _observer) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
        observer = _observer;
    }

    /// @notice The Gas Killer task. Traced off-chain; its canonical update program settles
    ///         on-chain via `verifyAndUpdate`. Makes a re-entrant external call between its
    ///         intermediate (`counter`) and final (`lastObserved`) storage writes.
    function advance() external trackState {
        counter += 1;

        // Re-enters this contract to read canonical intermediate state. Reverts (and thus
        // fails the whole settlement) unless `counter` already holds the new value and the
        // final `lastObserved` write has not yet been applied.
        IReentrantObserver(observer).observe(counter);

        lastObserved = counter;
        emit Advanced(counter);
    }
}
