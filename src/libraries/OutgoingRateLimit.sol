// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../GasKillerSDK.sol";

/// @title OutgoingRateLimit
/// @notice A token bucket over the ETH signed programs send out of a `GasKillerSDK` contract: at
///         most `limit` wei per `period`, refilling continuously, so a compromised quorum can
///         drain at most that instead of the whole balance at once.
/// @dev Runs on the SDK's `OutgoingBucket` (`GasKillerSDK._outgoingBucket()`), which lives in the
///      SDK's protected config namespace: a signed program can't refill it with a `STORE`. Call
///      `spend` from `_authorizeCall` for every op. It skips ops that send nothing and ops whose
///      target is the contract itself (an allowed self-call keeps its value). The drop-in
///      contracts in `src/extensions/GasKillerOutgoingRateLimit.sol` do exactly that.
///
///      All of a contract's programs share the bucket, whether they settle alone, in a batch or
///      as frames of a nested tree. Only value sent by signed programs counts: the contract's own
///      functions, called natively, spend nothing, so a balance a program credits with a `STORE`
///      and the contract later pays out isn't limited. It limits ETH only; a token transfer moves no
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

    /// @notice The budget was set to `limit` wei per `period` seconds.
    event OutgoingRateLimitSet(uint256 limit, uint256 period);

    /// @notice Sets the limit and period. The first call fills the budget; a later one keeps what
    ///         the budget holds now, capped at the new limit, so lowering the limit during a drain
    ///         doesn't hand out a fresh budget, and raising it refills at the new rate from there.
    /// @dev **Do not call from a `trackState` function**, for the same reason as the SDK's config
    ///      setters: the budget is protected storage, so a program carrying the write can never
    ///      settle. Call it from a constructor, an initializer or an admin function that is not
    ///      `trackState`. Until it is called, the budget is empty and every op that sends value
    ///      reverts; behind a proxy, call it from the initializer.
    /// @param limit Most wei signed programs may send in one `period`; zero sends none.
    /// @param period Seconds over which the full `limit` refills.
    function set(GasKillerSDK.OutgoingBucket storage b, uint256 limit, uint256 period) internal {
        require(limit <= type(uint96).max && period != 0 && period <= type(uint32).max, InvalidOutgoingRateLimit());
        uint256 available = limit;
        if (b.period != 0) {
            uint256 word;
            assembly ("memory-safe") {
                word := sload(b.slot)
            }
            (uint256 held,) = _refilled(word);
            if (held < available) available = held;
        }
        b.limit = uint96(limit);
        b.available = uint96(available);
        b.period = uint32(period);
        b.updated = uint32(block.timestamp);
        emit OutgoingRateLimitSet(limit, period);
    }

    /// @notice Spends `value` from the budget, or reverts with `OutgoingRateLimitExceeded`.
    ///         Spends nothing when `value` is zero or `target` is the running contract itself:
    ///         value an allowed self-call sends stays in the contract.
    /// @dev One `SLOAD` and one `SSTORE` of the packed slot. Solidity packs the struct from the
    ///      low bits up: `limit` (0-95), `available` (96-191), `period` (192-223), `updated`
    ///      (224-255). `test_bucketPackingMatchesTheStruct` pins that.
    function spend(GasKillerSDK.OutgoingBucket storage b, uint256 index, address target, uint256 value) internal {
        if (value == 0 || target == address(this)) return;
        uint256 word;
        assembly ("memory-safe") {
            word := sload(b.slot)
        }
        (uint256 left, uint256 updated) = _refilled(word);
        if (value > left) revert OutgoingRateLimitExceeded(index, value, left);
        // Keep `limit` and `period`; replace `available` and `updated`. `left - value` can't
        // underflow (checked just above) and fits in 96 bits because `left` never exceeds `limit`;
        // `updated` is a 32-bit timestamp.
        unchecked {
            word = (word & _KEEP) | ((left - value) << 96) | (updated << 224);
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
        (available,) = _refilled(word);
        return (available, uint96(word), uint32(word >> 192));
    }

    /// @dev The `limit` and `period` bits of the packed slot.
    uint256 private constant _KEEP = uint256(type(uint96).max) | (uint256(type(uint32).max) << 192);

    /// @dev `available` plus the refill since `updated`, up to `limit`, and the timestamp to store
    ///      with it. An unset budget (zero limit and period) holds nothing.
    ///      The refill rounds down, so the timestamp moves forward only by the time the credited
    ///      wei took to accrue: the remainder carries over to the next spend instead of being lost.
    ///      Otherwise spends closer together than `period / limit` seconds would each credit
    ///      nothing, and the budget would never refill. Once the budget is full there is nothing
    ///      to carry, and the timestamp is now.
    ///      Unchecked: `elapsed` doesn't underflow because `updated` is never ahead of the clock
    ///      (until the 32-bit timestamp wraps in 2106), its product with a 96-bit limit fits in
    ///      128 bits, `period` is nonzero whenever the division runs, and so is `limit` when the
    ///      budget isn't full. The carried time is under `elapsed`, so `updated` stays at or after
    ///      its old value.
    function _refilled(uint256 word) private view returns (uint256 available, uint256 updated) {
        unchecked {
            uint256 limit = uint96(word);
            uint256 period = uint32(word >> 192);
            uint256 now_ = uint32(block.timestamp);
            uint256 elapsed = now_ - (word >> 224);
            if (elapsed >= period) return (limit, now_);
            uint256 accrued = elapsed * limit;
            available = uint96(word >> 96) + accrued / period;
            if (available >= limit) return (limit, now_);
            updated = now_ - (accrued % period) / limit;
        }
    }
}
