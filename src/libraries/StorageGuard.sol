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
///      Ranges are inclusive `[start, end]` intervals, strictly ascending and non-overlapping.
///      **The per-write checkers (`checkEach`, `advance`) assume this and do not check it**: an
///      unsorted or overlapping list fails open, silently letting writes to protected slots
///      through. Their caller must run `validateRanges` once on the list, in a constructor, or
///      before the loop when the list is built at run time. Validating on every write would cost
///      O(k) per write, more than the check itself. `checkProgram` validates the list itself,
///      once per program.
///
///      A write to a protected range is rejected when it would change a protected bit, and allowed
///      when it leaves every protected bit as it is in storage. `mask` is `FULL` to protect the
///      whole slot. A narrower mask protects only some bits of one packed slot. Allowing writes
///      that change nothing is what lets the SDK protect its own transition counter: gas-analyzer
///      copies the counter's new value into every program as a STORE, and `trackState` has already
///      written that same value by the time the program runs. Deciding costs one SLOAD, paid only
///      by a write that lands in a range.
///
///      Two per-write checkers, which agree on every input (the test suite fuzzes them against a
///      naive model and against benchmark-only variants in `test/utils/StorageGuardVariants.sol`):
///        - `checkEach`: stateless, one binary search per write.
///        - `Cursor` + `advance`: one forward pass. Writes in ascending slot order walk the
///          ranges together, and once a write is past the last range every later ascending
///          write costs one comparison. Before walking, `advance` checks that the cursor's
///          position is valid for the slot, which holds exactly when no range before it reaches
///          the slot. If it isn't, it re-seats by binary search instead of reverting. That
///          happens on a write below the previous range, and also on a cursor carried over from
///          another list, never reset, or holding garbage. So neither the order of the writes nor
///          the cursor's contents can change the verdict, only the gas. Input sorted within each
///          CALL/CREATE-bounded slice, as gas-analyzer's canonical extraction emits it, pays at
///          most one re-seat per slice.
///
///      Writes are judged against storage as it stands when the check runs, so the per-write
///      checkers are exact only when called right before each write executes, which is how
///      `StateChangeHandlerLib._run` uses them. A pre-pass (`checkProgram`) sees storage as it was
///      before the program. A STORE can't make the two differ on protected bits: any STORE that
///      changed them would itself have been rejected. But a CALL, CREATE, CREATE2 or NESTED op
///      runs code that can legitimately change them, for example by re-entering an owner-gated
///      setter, and a later STORE could then quietly put the old bits back. So once a pre-pass
///      has passed such an op, it rejects every later write to a protected range
///      (`ProtectedWriteAfterExternalCode`).
///
///      Not covered: a `CALL` update to `address(this)` can reach privileged functions directly,
///      so a consumer relying on this guard should also restrict self-calls. `NESTED` frames
///      are checked by each frame's own contract.
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
    /// @param blind Set by a pre-pass once it has passed an op that runs code. Storage may then
    ///        differ from what the write will see, so any hit is rejected. Leave it false when
    ///        checking inline, right before each write. A stale `true` only over-rejects.
    struct Cursor {
        uint256 next;
        bool blind;
    }

    bytes32 internal constant FULL = bytes32(type(uint256).max);

    /// @notice A write would change protected bits.
    /// @param index Position of the offending op in its program (or in the caller's own sequence).
    /// @param slot The protected slot it writes.
    error ProtectedSlotWrite(uint256 index, bytes32 slot);

    /// @notice A pre-pass found a write to a protected range after an op that runs code. The
    ///      pre-pass can only compare with storage as it was before the program, and that code may
    ///      have changed the protected bits since.
    /// @param index Position of the offending `STORE` in its program.
    /// @param slot The protected slot it writes.
    error ProtectedWriteAfterExternalCode(uint256 index, bytes32 slot);

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

    // The hot paths below walk `ranges` in assembly. A `ProtectedRange[] memory` is a length
    // word followed by one pointer per element, and each element is three words: start, end,
    // mask. Every loop compares its index with the length before dereferencing it. A loop yields
    // `hit`, the pointer of the range covering the slot or zero, and only then calls `_reject`,
    // which reads the mask and decides.

    /// @notice Stateless check of one write: one binary search.
    /// @dev `ranges` must have passed `validateRanges`; an unvalidated list can fail open.
    function checkEach(ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value) internal view {
        uint256 hit = _covering(ranges, uint256(slot));
        if (hit != 0) _reject(hit, index, slot, value, false);
    }

    /// @notice Checks one write and moves `c` past it. Start from a zeroed `Cursor`.
    /// @dev `ranges` must have passed `validateRanges`; an unvalidated list can fail open.
    function advance(Cursor memory c, ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value)
        internal
        view
    {
        uint256 s = uint256(slot);
        uint256 hit;
        assembly ("memory-safe") {
            let len := mload(ranges)
            let base := add(ranges, 0x20)
            let i := mload(c)
            // The forward walk from `i` is right only if no range before `i` reaches `s`. Ends
            // ascend strictly in a validated list, so that holds exactly when `i <= len` and
            // (`i == 0` or `ranges[i-1].end < s`). Otherwise re-seat by binary search. `i` is
            // compared with `len` before `ranges[i-1]` is read.
            let reseat := gt(i, len)
            if and(iszero(reseat), gt(i, 0)) {
                reseat := iszero(lt(mload(add(mload(add(base, shl(5, sub(i, 1)))), 0x20)), s))
            }
            if reseat {
                i := 0
                for { let hi := len } lt(i, hi) {} {
                    let mid := shr(1, add(i, hi))
                    switch lt(mload(add(mload(add(base, shl(5, mid))), 0x20)), s)
                    case 1 { i := add(mid, 1) }
                    default { hi := mid }
                }
            }
            for {} lt(i, len) { i := add(i, 1) } {
                if iszero(lt(mload(add(mload(add(base, shl(5, i))), 0x20)), s)) { break }
            }
            mstore(c, i)
            if lt(i, len) {
                let r := mload(add(base, shl(5, i)))
                if iszero(gt(mload(r), s)) { hit := r }
            }
        }
        if (hit != 0) _reject(hit, index, slot, value, c.blind);
    }

    /// @notice Checks every `STORE` in a decoded program with one cursor, before it runs.
    /// @dev Expects the same `(types, args)` pair `StateChangeHandlerLib._runStateUpdates` takes.
    ///      Rejects the malformed input it inspects the same way `_runStateUpdates` would, whatever
    ///      `ranges` holds, an empty list included: mismatched lengths (`InvalidArguments`) and a
    ///      STORE payload too short to decode. It doesn't decode non-STORE payloads; those are
    ///      checked when `_runStateUpdates` executes them.
    ///      After the first op that runs code, a write to a protected range reverts with
    ///      `ProtectedWriteAfterExternalCode`, since its protected bits can no longer be predicted.
    ///      Settlement doesn't use this: `StateChangeHandlerLib._run` checks inline, which is exact.
    ///      Validates `ranges` first (`InvalidRanges`), even for a program with no STOREs.
    function checkProgram(StateUpdateType[] memory types, bytes[] memory args, ProtectedRange[] memory ranges)
        internal
        view
    {
        uint256 len = types.length;
        require(len == args.length, StateChangeHandlerLib.InvalidArguments());
        validateRanges(ranges);
        Cursor memory c;
        for (uint256 i = 0; i < len; i = _inc(i)) {
            StateUpdateType t = types[i];
            if (t != StateUpdateType.STORE) {
                if (!c.blind) c.blind = _runsCode(t);
                continue;
            }
            (bytes32 slot, bytes32 value) = abi.decode(args[i], (bytes32, bytes32));
            advance(c, ranges, i, slot, value);
        }
    }

    /// @dev Pointer to the range covering `s`, or zero. Binary-searches for the first range whose
    ///      end is at or above `s`, then checks its start. `lo < hi <= length` keeps `mid` in
    ///      bounds and every sum below 2^256; `advance` inlines the same search to re-seat.
    function _covering(ProtectedRange[] memory ranges, uint256 s) private pure returns (uint256 hit) {
        assembly ("memory-safe") {
            let len := mload(ranges)
            let base := add(ranges, 0x20)
            let lo := 0
            for { let hi := len } lt(lo, hi) {} {
                let mid := shr(1, add(lo, hi))
                switch lt(mload(add(mload(add(base, shl(5, mid))), 0x20)), s)
                case 1 { lo := add(mid, 1) }
                default { hi := mid }
            }
            if lt(lo, len) {
                let r := mload(add(base, shl(5, lo)))
                if iszero(gt(mload(r), s)) { hit := r }
            }
        }
    }

    /// @dev Ops that execute code which can write this contract's storage. LOGs don't.
    function _runsCode(StateUpdateType t) private pure returns (bool) {
        return t == StateUpdateType.CALL || t == StateUpdateType.CREATE || t == StateUpdateType.CREATE2
            || t == StateUpdateType.NESTED;
    }

    /// @dev Increment for an index bounded by an array length, which cannot overflow.
    function _inc(uint256 i) private pure returns (uint256) {
        unchecked {
            return i + 1;
        }
    }

    /// @dev `range` points at a range covering `slot`. Reverts unless the write leaves every
    ///      protected bit as it is in storage. `blind` means storage may not be what it will be
    ///      when the write runs (a pre-pass past code-running ops), so the hit can't be judged and
    ///      is rejected.
    function _reject(uint256 range, uint256 index, bytes32 slot, bytes32 value, bool blind) private view {
        if (blind) revert ProtectedWriteAfterExternalCode(index, slot);
        bytes32 mask;
        bytes32 current;
        assembly ("memory-safe") {
            mask := mload(add(range, 0x40))
            current := sload(slot)
        }
        if ((current ^ value) & mask != 0) revert ProtectedSlotWrite(index, slot);
    }
}
