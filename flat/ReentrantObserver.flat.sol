// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// src/examples/reentrant-checkpoint/ReentrantObserver.sol

/// The subset of the Gas Killer target this observer reads back mid-transition.
interface IReentrantProbe {
    function counter() external view returns (uint256);
    function lastObserved() external view returns (uint256);
}

/// @title ReentrantObserver
/// @notice An external contract that a Gas Killer target calls **during** a state
///         transition and that immediately **re-enters** the target to read its storage.
///         Its checks are deliberately load-bearing: if the target does not present the
///         *canonical intermediate* storage native execution would have had at the moment
///         of the call, `observe` reverts — which reverts the whole `verifyAndUpdate`
///         settlement. A settlement that lands therefore proves the re-entrant read saw
///         canonical state.
/// @dev The checks must hold in BOTH contexts the target's business function runs in:
///      - the off-chain EVMSketch trace (a direct `advance()` call), and
///      - the on-chain replay (`verifyAndUpdate` applying the canonical update program).
///      So it asserts only values that are identical in both — the post-increment
///      `counter` and the not-yet-`finalized` flag — never the in-transition latch, which
///      is up on replay but down during the trace.
contract ReentrantObserver {
    /// @notice Incremented once per successful observation. On-chain this only advances
    ///         when the re-entrant call actually executes inside a real settlement, so a
    ///         non-zero value is proof the re-entrant path ran on-chain.
    uint256 public confirmations;

    /// @notice The caller's `counter` did not equal the canonical post-increment value —
    ///         the target failed to switch into canonical state before calling out.
    error CounterNotCanonical(uint256 got, uint256 expected);
    /// @notice The final write (`lastObserved = counter`) had already been applied when
    ///         observed — the target presented its *final* state to the external call
    ///         instead of the intermediate one native execution would have shown.
    error FinalStateAppliedTooEarly();

    /// @notice Called re-entrantly by the Gas Killer target mid-transition.
    /// @param expectedCounter The canonical value `counter` must already hold.
    function observe(uint256 expectedCounter) external {
        IReentrantProbe target = IReentrantProbe(msg.sender);

        uint256 got = target.counter();
        if (got != expectedCounter) revert CounterNotCanonical(got, expectedCounter);

        // `lastObserved` is set to `counter` strictly AFTER this call. Because `counter`
        // strictly increments each transition, at this instant `lastObserved` still holds
        // the PREVIOUS transition's value, which differs from the current `counter`. If it
        // already equals `counter`, the final write leaked in ahead of us.
        if (target.lastObserved() == expectedCounter) revert FinalStateAppliedTooEarly();

        confirmations += 1;
    }
}
