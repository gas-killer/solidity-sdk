// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {StorageGuard} from "../../src/libraries/StorageGuard.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../../src/StateChangeHandlerLib.sol";

/// @title StorageGuardVariants
/// @notice Alternative StorageGuard checkers, kept out of the library on purpose. The tests check
///         that the library agrees with them, and the benchmark measures them against it. Not for
///         production use: consumers get one per-write checker (`checkEach`), the cursor
///         (`advance`) and the pre-pass (`checkProgram`).
library StorageGuardVariants {
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

    /// @dev Mirrors `StorageGuard._reject` for an inline check (never blind).
    function _reject(uint256 range, uint256 index, bytes32 slot, bytes32 value) private view {
        bytes32 mask;
        assembly ("memory-safe") {
            mask := mload(add(range, 0x40))
        }
        if (mask != StorageGuard.FULL) {
            bytes32 current;
            assembly ("memory-safe") {
                current := sload(slot)
            }
            if ((current ^ value) & mask == 0) return;
        }
        revert StorageGuard.ProtectedSlotWrite(index, slot);
    }

    /// @notice `StorageGuard.checkProgram` with a stateless `checkEach` per write instead of the
    ///         cursor. Same contract: validates `ranges`, rejects the same malformed input, and
    ///         rejects masked writes after a code-running op.
    function checkProgramEach(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges
    ) internal view {
        uint256 len = types.length;
        require(len == args.length, StateChangeHandlerLib.InvalidArguments());
        StorageGuard.validateRanges(ranges);
        bool ranCode;
        for (uint256 i = 0; i < len; ++i) {
            StateUpdateType t = types[i];
            if (t != StateUpdateType.STORE) {
                ranCode = ranCode || t == StateUpdateType.CALL || t == StateUpdateType.CREATE
                    || t == StateUpdateType.CREATE2 || t == StateUpdateType.NESTED;
                continue;
            }
            (bytes32 slot, bytes32 value) = abi.decode(args[i], (bytes32, bytes32));
            if (ranCode && _inMaskedRange(ranges, uint256(slot))) {
                revert StorageGuard.MaskedWriteAfterExternalCode(i, slot);
            }
            StorageGuard.checkEach(ranges, i, slot, value);
        }
    }

    function _inMaskedRange(StorageGuard.ProtectedRange[] memory ranges, uint256 s) private pure returns (bool) {
        for (uint256 i = 0; i < ranges.length; ++i) {
            if (ranges[i].start <= s && s <= ranges[i].end) return ranges[i].mask != StorageGuard.FULL;
        }
        return false;
    }
}
