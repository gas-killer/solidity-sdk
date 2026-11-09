// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {StateChangeHandlerLib, StateUpdateType} from "../StateChangeHandlerLib.sol";

/// @title StorageGuard
/// @notice Checks a signed program's `STORE` writes against a denylist of protected storage
///         ranges, so a quorum-signed update cannot overwrite slots such as an `Ownable` owner,
///         the `StateTracker` counter, the SDK's own configuration or EIP-1967 proxy slots.
/// @dev The list denies rather than allows. Honest writes to mappings and dynamic arrays land on
///      keccak-derived slots spread across the whole slot space, which an allowlist of ranges
///      cannot express, while every slot worth protecting is known at compile time. Reaching a
///      protected slot from an honest write would take a keccak preimage, so a hit means the
///      program is malicious and the whole program is rejected.
///
///      Ranges are inclusive `[start, end]` intervals, strictly ascending and non-overlapping
///      (`validateRanges`). `mask` is `FULL` to deny every write to the range, even one that
///      stores the value already there, which saves the SLOAD. A narrower mask protects
///      only some bits of one packed slot: a write passes when it leaves those bits as they are
///      in storage, which costs one SLOAD on a hit and nothing otherwise.
///
///      Three checkers, which agree on every input (the test suite fuzzes this):
///        - `checkEach`: stateless, one binary search per write.
///        - `checkEachLinear`: stateless, a scan from the first range; kept for comparison.
///        - `Cursor` + `advance`: one forward pass. Writes in ascending slot order walk the
///          ranges together, and once a write is past the last range every later ascending
///          write costs one comparison. A write below its predecessor re-seats the cursor by
///          binary search instead of reverting, so the order of the writes affects only gas,
///          never the verdict. Input sorted within each CALL/CREATE-bounded slice, as
///          gas-analyzer's canonical extraction emits it, pays one re-seat per slice.
///
///      Masked ranges are checked against storage as it stands when the check runs. A pre-pass
///      (`checkProgram`) therefore compares every write with the pre-program value, which is
///      what an inline check sees too as long as no earlier write in the program changed the
///      protected bits, since such a write would already have been rejected.
///
///      Not covered: a `CALL` update to `address(this)` can reach privileged functions directly,
///      so a consumer relying on this guard should also restrict self-calls. `NESTED` frames
///      are checked by each frame's own contract.
library StorageGuard {
    /// @notice One protected interval of storage slots.
    /// @param start First protected slot (inclusive).
    /// @param end Last protected slot (inclusive).
    /// @param mask Protected bits within the slot: `FULL` for every bit, anything narrower only
    ///        when `start == end`.
    struct ProtectedRange {
        uint256 start;
        uint256 end;
        bytes32 mask;
    }

    /// @notice Merge state carried across consecutive writes.
    /// @param next Index of the first range whose end is at or above the previous write's slot.
    /// @param prev The previous write's slot.
    struct Cursor {
        uint256 next;
        uint256 prev;
    }

    bytes32 internal constant FULL = bytes32(type(uint256).max);

    /// @notice A write would change protected bits.
    /// @param index Position of the offending op in its program (or in the caller's own sequence).
    /// @param slot The protected slot it writes.
    error ProtectedSlotWrite(uint256 index, bytes32 slot);

    /// @notice The range list is unsorted, overlapping, empty-masked or masks more than one slot.
    error InvalidRanges();

    /// @notice Reverts with `InvalidRanges` unless `ranges` is a well-formed denylist.
    function validateRanges(ProtectedRange[] memory ranges) internal pure {
        uint256 len = ranges.length;
        for (uint256 i = 0; i < len; ++i) {
            ProtectedRange memory r = ranges[i];
            if (r.start > r.end || r.mask == bytes32(0)) revert InvalidRanges();
            if (r.mask != FULL && r.start != r.end) revert InvalidRanges();
            if (i != 0 && r.start <= ranges[i - 1].end) revert InvalidRanges();
        }
    }

    // The hot paths below walk `ranges` in assembly. A `ProtectedRange[] memory` is a length
    // word followed by one pointer per element, and each element is three words: start, end,
    // mask. Every loop compares its index with the length before dereferencing it. A loop yields
    // `hit`, the pointer of the range covering the slot or zero, and only then calls `_reject`,
    // which reads the mask and decides.

    /// @notice Stateless check of one write: one binary search.
    function checkEach(ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value) internal view {
        uint256 s = uint256(slot);
        uint256 i = _lowerBound(ranges, s);
        uint256 hit;
        assembly ("memory-safe") {
            if lt(i, mload(ranges)) {
                let r := mload(add(add(ranges, 0x20), shl(5, i)))
                if iszero(gt(mload(r), s)) { hit := r }
            }
        }
        if (hit != 0) _reject(hit, index, slot, value);
    }

    /// @notice Stateless check of one write by linear scan; for comparison with `checkEach`.
    function checkEachLinear(ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value) internal view {
        uint256 s = uint256(slot);
        uint256 hit;
        assembly ("memory-safe") {
            let it := add(ranges, 0x20)
            for { let last := add(it, shl(5, mload(ranges))) } lt(it, last) { it := add(it, 0x20) } {
                let r := mload(it)
                if iszero(lt(mload(add(r, 0x20)), s)) {
                    if iszero(gt(mload(r), s)) { hit := r }
                    break
                }
            }
        }
        if (hit != 0) _reject(hit, index, slot, value);
    }

    /// @notice Checks one write and moves `c` past it. Start from a zeroed `Cursor`.
    function advance(Cursor memory c, ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value)
        internal
        view
    {
        uint256 s = uint256(slot);
        uint256 i = c.next;
        if (s < c.prev) i = _lowerBound(ranges, s);
        uint256 hit;
        assembly ("memory-safe") {
            let len := mload(ranges)
            let base := add(ranges, 0x20)
            for {} lt(i, len) { i := add(i, 1) } {
                if iszero(lt(mload(add(mload(add(base, shl(5, i))), 0x20)), s)) { break }
            }
            mstore(c, i)
            mstore(add(c, 0x20), s)
            if lt(i, len) {
                let r := mload(add(base, shl(5, i)))
                if iszero(gt(mload(r), s)) { hit := r }
            }
        }
        if (hit != 0) _reject(hit, index, slot, value);
    }

    /// @notice Checks every `STORE` in a decoded program with one cursor, before it runs.
    /// @dev Expects the same `(types, args)` pair `StateChangeHandlerLib._runStateUpdates` takes
    ///      and rejects the same malformed input (`InvalidArguments`, a short STORE payload).
    function checkProgram(StateUpdateType[] memory types, bytes[] memory args, ProtectedRange[] memory ranges)
        internal
        view
    {
        uint256 len = types.length;
        require(len == args.length, StateChangeHandlerLib.InvalidArguments());
        if (ranges.length == 0) return;
        Cursor memory c;
        for (uint256 i = 0; i < len; i = _inc(i)) {
            if (types[i] != StateUpdateType.STORE) continue;
            (bytes32 slot, bytes32 value) = abi.decode(args[i], (bytes32, bytes32));
            advance(c, ranges, i, slot, value);
        }
    }

    /// @notice `checkProgram` with a stateless check per write; for comparison.
    function checkProgramEach(StateUpdateType[] memory types, bytes[] memory args, ProtectedRange[] memory ranges)
        internal
        view
    {
        uint256 len = types.length;
        require(len == args.length, StateChangeHandlerLib.InvalidArguments());
        if (ranges.length == 0) return;
        for (uint256 i = 0; i < len; i = _inc(i)) {
            if (types[i] != StateUpdateType.STORE) continue;
            (bytes32 slot, bytes32 value) = abi.decode(args[i], (bytes32, bytes32));
            checkEach(ranges, i, slot, value);
        }
    }

    /// @dev Index of the first range whose end is at or above `s`, or `ranges.length` when there
    ///      is none. `lo < hi <= length` keeps `mid` in bounds and every sum below 2^256.
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

    /// @dev Increment for an index bounded by an array length, which cannot overflow.
    function _inc(uint256 i) private pure returns (uint256) {
        unchecked {
            return i + 1;
        }
    }

    /// @dev `range` points at a range covering `slot`. Reverts unless the range is masked and the
    ///      write leaves every masked bit as it is in storage.
    function _reject(uint256 range, uint256 index, bytes32 slot, bytes32 value) private view {
        bytes32 mask;
        assembly ("memory-safe") {
            mask := mload(add(range, 0x40))
        }
        if (mask != FULL) {
            bytes32 current;
            assembly ("memory-safe") {
                current := sload(slot)
            }
            if ((current ^ value) & mask == 0) return;
        }
        revert ProtectedSlotWrite(index, slot);
    }
}
