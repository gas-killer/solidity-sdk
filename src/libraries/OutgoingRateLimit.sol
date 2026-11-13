// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../GasKillerSDK.sol";

/// @title OutgoingRateLimit
/// @notice A token bucket over the ETH signed programs send out of a `GasKillerSDK` contract: at
///         most `limit` wei per `period`, refilling continuously, so a compromised quorum can
///         drain at most that instead of the whole balance at once.
/// @dev Runs on the SDK's `OutgoingBucket` (`GasKillerSDK._outgoingBucket()`), which lives in the
///      SDK's protected config namespace: a signed program can't refill it with a `STORE`. Call
///      `spend` from `_authorizeCall` for every op; ops that send nothing return straight away.
///      The drop-in contracts in `src/extensions/GasKillerOutgoingRateLimit.sol` do exactly that.
///
///      All of a contract's programs share the bucket, whether they settle alone, in a batch or
///      as frames of a nested tree. Only value sent by signed programs counts: the contract's own
///      functions, called natively, spend nothing. It limits ETH only; a token transfer moves no
///      value, so restrict those in `_authorizeCall`. Timestamps are kept in 32 bits, which holds
///      until 2106.
library OutgoingRateLimit {
    /// @notice An op would send more than the budget holds.
    /// @param index The op's position in its program.
    /// @param value Wei the op sends.
    /// @param available Wei the budget held.
    error OutgoingRateLimitExceeded(uint256 index, uint256 value, uint256 available);

    /// @notice A limit above `type(uint96).max`, or a period of zero or above `type(uint32).max`.
    error InvalidOutgoingRateLimit();

    /// @notice The budget was reset to `limit` wei per `period` seconds, full.
    event OutgoingRateLimitSet(uint256 limit, uint256 period);

    /// @notice Sets the limit and period, and fills the budget.
    /// @dev **Do not call from a `trackState` function**, for the same reason as the SDK's config
    ///      setters: the budget is protected storage, so a program carrying the write can never
    ///      settle. Call it from a constructor, an initializer or an admin function that is not
    ///      `trackState`. Until it is called, the budget is empty and every op that sends value
    ///      reverts; behind a proxy, call it from the initializer.
    /// @param limit Most wei signed programs may send in one `period`; zero sends none.
    /// @param period Seconds over which the full `limit` refills.
    function set(GasKillerSDK.OutgoingBucket storage b, uint256 limit, uint256 period) internal {
        require(limit <= type(uint96).max && period != 0 && period <= type(uint32).max, InvalidOutgoingRateLimit());
        b.limit = uint96(limit);
        b.available = uint96(limit);
        b.period = uint32(period);
        b.updated = uint32(block.timestamp);
        emit OutgoingRateLimitSet(limit, period);
    }

    /// @notice Spends `value` from the budget, or reverts with `OutgoingRateLimitExceeded`.
    /// @dev One `SLOAD` and one `SSTORE` of the packed slot. Solidity packs the struct from the
    ///      low bits up: `limit` (0-95), `available` (96-191), `period` (192-223), `updated`
    ///      (224-255). `test_bucketPackingMatchesTheStruct` pins that.
    function spend(GasKillerSDK.OutgoingBucket storage b, uint256 index, uint256 value) internal {
        if (value == 0) return;
        uint256 word;
        assembly ("memory-safe") {
            word := sload(b.slot)
        }
        uint256 left = _refilled(word);
        if (value > left) revert OutgoingRateLimitExceeded(index, value, left);
        // Keep `limit` and `period`; replace `available` and `updated`. `left - value` can't
        // underflow (checked just above) and fits in 96 bits because `left` never exceeds `limit`.
        unchecked {
            word = (word & _KEEP) | ((left - value) << 96) | (uint256(uint32(block.timestamp)) << 224);
        }
        assembly ("memory-safe") {
            sstore(b.slot, word)
        }
    }

    /// @notice What the budget holds now, its limit and its period.
    function allowance(GasKillerSDK.OutgoingBucket storage b)
        internal
        view
        returns (uint256 available, uint256 limit, uint256 period)
    {
        uint256 word;
        assembly ("memory-safe") {
            word := sload(b.slot)
        }
        return (_refilled(word), uint96(word), uint32(word >> 192));
    }

    /// @dev The `limit` and `period` bits of the packed slot.
    uint256 private constant _KEEP = uint256(type(uint96).max) | (uint256(type(uint32).max) << 192);

    /// @dev `available` plus the refill since `updated`, up to `limit`. An unset budget (zero
    ///      limit and period) holds nothing.
    ///      Unchecked: `elapsed` doesn't underflow because `updated` is never ahead of the clock
    ///      (until the 32-bit timestamp wraps in 2106), its product with a 96-bit limit fits in
    ///      128 bits, and `period` is nonzero whenever the division runs.
    function _refilled(uint256 word) private view returns (uint256 available) {
        unchecked {
            uint256 limit = uint96(word);
            uint256 period = uint32(word >> 192);
            uint256 elapsed = uint32(block.timestamp) - (word >> 224);
            available = uint96(word >> 96) + (elapsed >= period ? limit : elapsed * limit / period);
            if (available > limit) available = limit;
        }
    }
}
