// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

// src/libraries/StorageGuard.sol

/// @title StorageGuard
/// @notice Checks a signed program's `STORE` writes against a denylist of protected storage
///         ranges, so a quorum-signed update cannot overwrite slots such as an `Ownable` owner,
///         the `StateTracker` counter, the SDK's own configuration or EIP-1967 proxy slots.
///         `StateChangeHandlerLib._run` calls `advance` right before every STORE executes.
/// @dev The list denies rather than allows. Honest writes to mappings and dynamic arrays land on
///      keccak-derived slots spread across the whole slot space, which an allowlist of ranges
///      cannot express, while every slot worth protecting is known at compile time. Reaching a
///      protected slot from an honest write would take a keccak preimage, so a hit means the
///      program is malicious and the whole program is rejected.
///
///      Ranges are inclusive `[start, end]` intervals, strictly ascending and non-overlapping.
///      **`advance` assumes this and does not check it**: an unsorted or overlapping list fails
///      open, silently letting writes to protected slots through. Run `validateRanges` once on the
///      list; `GasKillerSDK` does so in its constructor. Validating on every write would cost
///      O(k) per write, more than the check itself.
///
///      A write to a protected range is rejected when it would change a protected bit, and allowed
///      when it leaves every protected bit as it is in storage. `mask` is `FULL` to protect the
///      whole slot. A narrower mask protects only some bits of one packed slot. Allowing writes
///      that change nothing is what lets the SDK protect its own transition counter: gas-analyzer
///      copies the counter's new value into every program as a STORE, and `trackState` has already
///      written that same value by the time the program runs. Deciding costs one SLOAD, paid only
///      by a write that lands in a range.
///
///      `advance` makes one forward pass with a `Cursor`. Writes in ascending slot order walk the
///      ranges together, and once a write is past the last range every later ascending write costs
///      one comparison. Before walking, `advance` checks that the cursor's position is valid for
///      the slot, which holds exactly when no range before it reaches the slot. If it isn't, it
///      re-seats by binary search (`_lowerBound`) instead of reverting. That happens on a write
///      below the previous range, and also on a cursor carried over from another list, never
///      reset, or holding garbage. So neither the order of the writes nor the cursor's contents
///      can change the verdict, only the gas. Input sorted within each CALL/CREATE-bounded slice,
///      as gas-analyzer's canonical extraction emits it, pays at most one re-seat per slice.
///
///      Writes are judged against storage as it stands when the check runs, which is exact only
///      right before each write executes. That is how `_run` calls it. Comparison checkers, and a
///      pre-pass over a whole program with the extra rule a pre-pass needs, live in
///      `test/utils/StorageGuardVariants.sol`, where the tests check this library against them.
library StorageGuard {
    /// @notice One protected interval of storage slots.
    /// @param start First protected slot (inclusive).
    /// @param end Last protected slot (inclusive).
    /// @param mask Protected bits within each slot: `FULL` for every bit, anything narrower only
    ///        when `start == end`. A write is rejected when it would change a protected bit.
    struct ProtectedRange {
        uint256 start;
        uint256 end;
        bytes32 mask;
    }

    /// @notice Merge state carried across consecutive writes. Start from a zeroed one. Its contents
    ///         only steer the search: `advance` re-checks `next` on every write, so a stale or
    ///         foreign cursor costs gas but cannot let a write through.
    /// @param next Where the last write's search ended: a hint for the next write's search.
    struct Cursor {
        uint256 next;
    }

    bytes32 internal constant FULL = bytes32(type(uint256).max);

    /// @notice A write would change protected bits.
    /// @param index Position of the offending op in its program (or in the caller's own sequence).
    /// @param slot The protected slot it writes.
    error ProtectedSlotWrite(uint256 index, bytes32 slot);

    /// @notice The range list is unsorted, overlapping, empty-masked or masks more than one slot.
    error InvalidRanges();

    /// @notice Reverts with `InvalidRanges` unless `ranges` is a well-formed denylist.
    /// @dev Per range: `start <= end`, a nonzero mask, a partial mask only on a single slot, and a
    ///      start above the previous range's end. The first range has no predecessor, so it is
    ///      checked with `first` set rather than against a sentinel end.
    function validateRanges(ProtectedRange[] memory ranges) internal pure {
        bool bad;
        assembly ("memory-safe") {
            let it := add(ranges, 0x20)
            let last := add(it, shl(5, mload(ranges)))
            let prevEnd := 0
            for { let first := 1 } lt(it, last) { it := add(it, 0x20) } {
                let r := mload(it)
                let start := mload(r)
                let end := mload(add(r, 0x20))
                let mask := mload(add(r, 0x40))
                bad := or(bad, gt(start, end))
                bad := or(bad, iszero(mask))
                bad := or(bad, and(iszero(eq(mask, not(0))), iszero(eq(start, end))))
                bad := or(bad, and(iszero(first), iszero(gt(start, prevEnd))))
                prevEnd := end
                first := 0
            }
        }
        if (bad) revert InvalidRanges();
    }

    // `advance` and `_lowerBound` walk `ranges` in assembly. A `ProtectedRange[] memory` is a
    // length word followed by one pointer per element, and each element is three words: start,
    // end, mask. Every loop compares its index with the length before dereferencing it.

    /// @notice Checks one write against `ranges` and moves `c` past it. Reverts with
    ///         `ProtectedSlotWrite` if the write would change a protected bit.
    /// @dev `ranges` must have passed `validateRanges`; an unvalidated list can fail open.
    function advance(Cursor memory c, ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value)
        internal
        view
    {
        uint256 s = uint256(slot);
        uint256 i = c.next;
        // The forward walk from `i` is right only if no range before `i` reaches `s`. Ends ascend
        // strictly in a validated list, so that holds exactly when `i <= len` and (`i == 0` or
        // `ranges[i-1].end < s`). Otherwise re-seat. `i` is compared with `len` before
        // `ranges[i-1]` is read.
        bool reseat;
        assembly ("memory-safe") {
            let len := mload(ranges)
            reseat := gt(i, len)
            if and(iszero(reseat), gt(i, 0)) {
                reseat := iszero(lt(mload(add(mload(add(ranges, shl(5, i))), 0x20)), s))
            }
        }
        if (reseat) i = _lowerBound(ranges, s);
        uint256 hit;
        assembly ("memory-safe") {
            let len := mload(ranges)
            let base := add(ranges, 0x20)
            for {} lt(i, len) { i := add(i, 1) } {
                if iszero(lt(mload(add(mload(add(base, shl(5, i))), 0x20)), s)) { break }
            }
            mstore(c, i)
            if lt(i, len) {
                let r := mload(add(base, shl(5, i)))
                if iszero(gt(mload(r), s)) { hit := r }
            }
        }
        if (hit != 0) _reject(hit, index, slot, value);
    }

    /// @dev Index of the first range whose end is at or above `s`, or `ranges.length` when there
    ///      is none. The library's only binary search. `lo < hi <= length` keeps `mid` in bounds
    ///      and every sum below 2^256.
    function _lowerBound(ProtectedRange[] memory ranges, uint256 s) private pure returns (uint256 lo) {
        assembly ("memory-safe") {
            let base := add(ranges, 0x20)
            for { let hi := mload(ranges) } lt(lo, hi) {} {
                let mid := shr(1, add(lo, hi))
                switch lt(mload(add(mload(add(base, shl(5, mid))), 0x20)), s)
                case 1 { lo := add(mid, 1) }
                default { hi := mid }
            }
        }
    }

    /// @dev `range` points at a range covering `slot`. Reverts unless the write leaves every
    ///      protected bit as it is in storage.
    function _reject(uint256 range, uint256 index, bytes32 slot, bytes32 value) private view {
        bytes32 mask;
        bytes32 current;
        assembly ("memory-safe") {
            mask := mload(add(range, 0x40))
            current := sload(slot)
        }
        if ((current ^ value) & mask != 0) revert ProtectedSlotWrite(index, slot);
    }
}
