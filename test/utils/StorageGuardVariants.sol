// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {StorageGuard} from "../../src/libraries/StorageGuard.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../../src/StateChangeHandlerLib.sol";

/// @title StorageGuardVariants
/// @notice Alternative StorageGuard checkers, kept out of the library on purpose: settlement uses
///         only `StorageGuard.advance`. The tests check that the library agrees with these, and the
///         benchmark measures them against it. Not for production use.
///
///         - `checkEach`: stateless binary search per write. Its search is its own copy, so the
///           equivalence tests compare two independent implementations.
///         - `checkEachLinear`: stateless linear scan.
///         - `checkProgram` / `checkProgramEach`: a pre-pass over a whole decoded program before
///           it runs, using `advance` or `checkEach` per STORE.
///
/// @dev A pre-pass sees storage as it was before the program, not as each write will see it. A
///      STORE can't make the two differ on protected bits: any STORE that changed them would
///      itself have been rejected. But a CALL, CREATE, CREATE2 or NESTED op runs code that can
///      legitimately change them, for example by re-entering an owner-gated setter, and a later
///      STORE could then quietly put the old bits back. So once a pre-pass has passed such an op,
///      it rejects every later write to a protected range (`ProtectedWriteAfterExternalCode`).
///      This is why settlement checks inline instead.
library StorageGuardVariants {
    /// @notice A pre-pass found a write to a protected range after an op that runs code. The
    ///         pre-pass can only compare with storage as it was before the program, and that code
    ///         may have changed the protected bits since.
    /// @param index Position of the offending `STORE` in its program.
    /// @param slot The protected slot it writes.
    error ProtectedWriteAfterExternalCode(uint256 index, bytes32 slot);

    // Same layout and loop discipline as the library: a `ProtectedRange[] memory` is a length word
    // followed by one pointer per element; each element is start, end, mask. Every loop compares
    // its index with the length before dereferencing it.

    /// @notice Stateless check of one write: one binary search. `ranges` must have passed
    ///         `StorageGuard.validateRanges`.
    function checkEach(StorageGuard.ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value)
        internal
        view
    {
        uint256 hit = _covering(ranges, uint256(slot));
        if (hit != 0) _reject(hit, index, slot, value);
    }

    /// @notice Stateless check of one write by linear scan from the first range. Written in
    ///         assembly like the library's own loops, so the benchmark compares searches rather
    ///         than compiler overhead. `ranges` must have passed `StorageGuard.validateRanges`.
    function checkEachLinear(StorageGuard.ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value)
        internal
        view
    {
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
        // Same shape as the library: the decision is a separate call made only on a hit, so the
        // benchmark compares the searches and nothing else.
        if (hit != 0) _reject(hit, index, slot, value);
    }

    /// @notice Checks every `STORE` in a decoded program with one `StorageGuard.Cursor`, before it
    ///         runs.
    /// @dev Expects the `(types, args)` pair `StateChangeHandlerLib._runStateUpdates` takes and
    ///      rejects the malformed input it inspects the same way: mismatched lengths
    ///      (`InvalidArguments`) and a STORE payload too short to decode, whatever `ranges` holds.
    ///      It doesn't decode non-STORE payloads. Validates `ranges` first (`InvalidRanges`).
    ///      After the first op that runs code, a write to a protected range reverts with
    ///      `ProtectedWriteAfterExternalCode`.
    function checkProgram(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges
    ) internal view {
        _checkProgram(types, args, ranges, true);
    }

    /// @notice `checkProgram` with a stateless `checkEach` per write instead of the cursor.
    function checkProgramEach(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges
    ) internal view {
        _checkProgram(types, args, ranges, false);
    }

    function _checkProgram(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges,
        bool useCursor
    ) private view {
        uint256 len = types.length;
        require(len == args.length, StateChangeHandlerLib.InvalidArguments());
        StorageGuard.validateRanges(ranges);
        StorageGuard.Cursor memory c;
        bool ranCode;
        for (uint256 i = 0; i < len; ++i) {
            StateUpdateType t = types[i];
            if (t != StateUpdateType.STORE) {
                ranCode = ranCode || t == StateUpdateType.CALL || t == StateUpdateType.CREATE
                    || t == StateUpdateType.CREATE2 || t == StateUpdateType.NESTED;
                continue;
            }
            (bytes32 slot, bytes32 value) = abi.decode(args[i], (bytes32, bytes32));
            if (ranCode && _covering(ranges, uint256(slot)) != 0) revert ProtectedWriteAfterExternalCode(i, slot);
            if (useCursor) StorageGuard.advance(c, ranges, i, slot, value);
            else checkEach(ranges, i, slot, value);
        }
    }

    /// @dev Pointer to the range covering `s`, or zero: binary search for the first range whose
    ///      end is at or above `s`, then a start check. `lo < hi <= length` keeps `mid` in bounds.
    function _covering(StorageGuard.ProtectedRange[] memory ranges, uint256 s) private pure returns (uint256 hit) {
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

    /// @dev Mirrors `StorageGuard._reject`.
    function _reject(uint256 range, uint256 index, bytes32 slot, bytes32 value) private view {
        bytes32 mask;
        bytes32 current;
        assembly ("memory-safe") {
            mask := mload(add(range, 0x40))
            current := sload(slot)
        }
        if ((current ^ value) & mask != 0) revert StorageGuard.ProtectedSlotWrite(index, slot);
    }
}
