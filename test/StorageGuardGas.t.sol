// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";

/// @notice Gas cost of `StorageGuard`'s checkers (issue #107): the per-write binary search
///         (`checkEach`), the per-write linear scan (`checkEachLinear`) and the sorted-merge
///         cursor (`advance`).
///
///         Every cell runs in its own external call so memory expansion from one cell cannot
///         inflate another, and every figure is the checker's loop minus a baseline loop that
///         reads the same arrays without checking, divided by the write count. That is the
///         marginal cost per `STORE` of an inline check in `StateChangeHandlerLib._run`, which
///         already has each slot decoded. `test_prepass` adds the cost of a separate pre-pass
///         that decodes every STORE a second time (`checkProgram`).
///
///         For scale: the SSTORE each check sits next to costs 2,900 (warm, existing value),
///         5,000 (cold, existing value) or 22,100 (cold, zero to nonzero), but only 100 when the
///         slot was already written earlier in the transaction.
///
///         Reference measurements (n = 128, forge 1.5.1, solc 0.8.33, cancun), gas per write:
///
///           order     k  | binary  linear  merge
///           sorted    1  |   294     205    195
///           sorted    4  |   540-602 281-350 261-290
///           sorted   16  |   730-864 281-832 290-301
///           sliced   16  |   730-864 281-832 377-504
///           unsorted 16  |   730-864 281-832 656-826
///
///         The merge is flat in k on sorted input and beats the binary search at every k > 1.
///         The linear scan is close behind at k <= 4, and on writes below every high range at any
///         k. On unsorted input the merge loses to the binary search, since each re-seat pays for a
///         search and then a walk. A pre-pass (`test_prepass`) adds about 350 gas per write to decode
///         the STORE a second time, so the check belongs inline in `_run`.
///
///         Matrix: writes n ∈ {1, 8, 32, 128}, ranges k ∈ {1, 4, 16} (slot 0 plus k-1
///         keccak-derived high slots, the shape of real protected sets), layouts low
///         (slots 1..n), scattered (mapping entries) and mixed, orders sorted, sliced (sorted
///         within chunks of 8, as between CALL/CREATE boundaries) and unsorted.
///
///         Run with plain `forge test --match-contract StorageGuardGas -vv`. `--gas-report`
///         measures something else.
contract StorageGuardGasTest is Test {
    uint256 constant LOW = 0;
    uint256 constant SCATTERED = 1;
    uint256 constant MIXED = 2;

    uint256 constant SORTED = 0;
    uint256 constant SLICED = 1;
    uint256 constant UNSORTED = 2;

    /// @dev Ceilings on the per-write marginal, about 15% above the worst measured cell, so a
    ///      toolchain change does not trip them but an accidental blowup does.
    uint256 constant CEIL_EACH = 1000;
    uint256 constant CEIL_MERGE = 1100;
    uint256 constant CEIL_LINEAR = 1000;
    uint256 constant CEIL_PREPASS = 1500;
    /// @dev Most the merge may grow from k = 1 to k = 16 on sorted input (measured: about 105).
    uint256 constant MERGE_K_GROWTH = 150;

    /// @dev No fixture XORs to this, so the comparison that keeps baseline loops live never fires.
    bytes32 constant SENTINEL = keccak256("StorageGuardGas.sentinel");

    struct Cell {
        uint256 each;
        uint256 linear;
        uint256 merge;
    }

    string[3] layoutName = ["low      ", "scattered", "mixed    "];
    string[3] orderName = ["sorted  ", "sliced  ", "unsorted"];

    // ---------------------------------------------------------------- fixtures

    function _ranges(uint256 k) internal pure returns (StorageGuard.ProtectedRange[] memory rs) {
        uint256[] memory high = new uint256[](k - 1);
        for (uint256 i = 0; i < k - 1; ++i) {
            high[i] = uint256(keccak256(abi.encode("protected", i)));
        }
        _sort(high);
        rs = new StorageGuard.ProtectedRange[](k);
        rs[0] = StorageGuard.ProtectedRange(0, 0, StorageGuard.FULL);
        for (uint256 i = 0; i < k - 1; ++i) {
            rs[i + 1] = StorageGuard.ProtectedRange(high[i], high[i], StorageGuard.FULL);
        }
    }

    function _writes(uint256 n, uint256 layout, uint256 order) internal pure returns (bytes32[] memory s) {
        s = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            bool low = layout == LOW || (layout == MIXED && i % 2 == 0);
            s[i] = low ? bytes32(i + 1) : keccak256(abi.encode(address(uint160(0x1000 + i)), uint256(5)));
        }
        // Scramble first so every order starts from the same unordered multiset.
        for (uint256 i = n; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode("shuffle", i))) % i;
            (s[i - 1], s[j]) = (s[j], s[i - 1]);
        }
        if (order == SORTED) _sortRange(s, 0, n);
        if (order == SLICED) {
            for (uint256 from = 0; from < n; from += 8) {
                _sortRange(s, from, from + 8 > n ? n : from + 8);
            }
        }
    }

    // ---------------------------------------------------------------- measured cells

    function cell(uint256 n, uint256 k, uint256 layout, uint256 order) external view returns (Cell memory c) {
        StorageGuard.ProtectedRange[] memory rs = _ranges(k);
        bytes32[] memory s = _writes(n, layout, order);
        bytes32[] memory v = new bytes32[](n);
        StorageGuard.Cursor memory cur;

        uint256 g = gasleft();
        bytes32 acc;
        for (uint256 i = 0; i < n; ++i) {
            acc ^= s[i] ^ v[i];
        }
        uint256 base = g - gasleft();

        g = gasleft();
        for (uint256 i = 0; i < n; ++i) {
            StorageGuard.checkEach(rs, i, s[i], v[i]);
        }
        c.each = _marginal(g - gasleft(), base, n);

        g = gasleft();
        for (uint256 i = 0; i < n; ++i) {
            StorageGuard.checkEachLinear(rs, i, s[i], v[i]);
        }
        c.linear = _marginal(g - gasleft(), base, n);

        g = gasleft();
        for (uint256 i = 0; i < n; ++i) {
            StorageGuard.advance(cur, rs, i, s[i], v[i]);
        }
        c.merge = _marginal(g - gasleft(), base, n);

        if (acc == SENTINEL) c.each = type(uint256).max; // keeps the baseline loop live
    }

    /// @dev Per-write cost of a separate pre-pass over a program of n STOREs, on top of a loop
    ///      that only decodes them (which `_run` does anyway).
    function prepass(uint256 n, uint256 k, uint256 layout, uint256 order)
        external
        view
        returns (uint256 decodeOnly, uint256 progEach, uint256 progMerge)
    {
        StorageGuard.ProtectedRange[] memory rs = _ranges(k);
        bytes32[] memory s = _writes(n, layout, order);
        StateUpdateType[] memory t = new StateUpdateType[](n);
        bytes[] memory a = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = abi.encode(s[i], bytes32(0));
        }

        uint256 g = gasleft();
        bytes32 acc;
        for (uint256 i = 0; i < n; ++i) {
            if (t[i] != StateUpdateType.STORE) continue;
            (bytes32 slot, bytes32 value) = abi.decode(a[i], (bytes32, bytes32));
            acc ^= slot ^ value;
        }
        decodeOnly = (g - gasleft()) / n;

        g = gasleft();
        StorageGuard.checkProgramEach(t, a, rs);
        progEach = (g - gasleft()) / n;

        g = gasleft();
        StorageGuard.checkProgram(t, a, rs);
        progMerge = (g - gasleft()) / n;

        if (acc == SENTINEL) decodeOnly = type(uint256).max;
    }

    // ---------------------------------------------------------------- reports

    function test_matrix() public view {
        uint256[4] memory ns = [uint256(1), 8, 32, 128];
        uint256[3] memory ks = [uint256(1), 4, 16];
        console2.log("per-write marginal gas (each = binary search, linear = scan, merge = cursor)");
        console2.log("layout     order     n    k   |  each linear merge");
        for (uint256 layout = 0; layout < 3; ++layout) {
            for (uint256 order = 0; order < 3; ++order) {
                for (uint256 ni = 0; ni < 4; ++ni) {
                    for (uint256 ki = 0; ki < 3; ++ki) {
                        Cell memory c = this.cell(ns[ni], ks[ki], layout, order);
                        _row(layout, order, ns[ni], ks[ki], c);
                        assertLe(c.each, CEIL_EACH, "each ceiling");
                        assertLe(c.merge, CEIL_MERGE, "merge ceiling");
                        assertLe(c.linear, CEIL_LINEAR, "linear ceiling");
                    }
                }
            }
        }
    }

    /// @notice The issue's claim: on sorted input one forward pass makes the cost per write
    ///         independent of the number of ranges, while the binary search grows with it.
    function test_mergeIsFlatInRangeCountOnSortedInput() public view {
        for (uint256 layout = 0; layout < 3; ++layout) {
            Cell memory k1 = this.cell(128, 1, layout, SORTED);
            Cell memory k16 = this.cell(128, 16, layout, SORTED);
            assertLe(k16.merge, k1.merge + MERGE_K_GROWTH, "merge grows with k");
            assertLt(k16.merge, k16.each, "merge not below binary search at k=16");
        }
    }

    function test_prepass() public view {
        uint256[3] memory ks = [uint256(1), 4, 16];
        console2.log("pre-pass over n=32 STOREs, gas per write (decode-only is the floor)");
        console2.log("layout     order     k   |  decode  each  merge");
        for (uint256 layout = 0; layout < 3; ++layout) {
            for (uint256 order = 0; order < 3; ++order) {
                for (uint256 ki = 0; ki < 3; ++ki) {
                    (uint256 d, uint256 e, uint256 m) = this.prepass(32, ks[ki], layout, order);
                    console2.log(
                        string.concat(
                            layoutName[layout],
                            "  ",
                            orderName[order],
                            "  ",
                            _pad(ks[ki], 2),
                            "  |  ",
                            _pad(d, 6),
                            _pad(e, 6),
                            _pad(m, 7)
                        )
                    );
                    assertLe(e, CEIL_PREPASS, "prepass each ceiling");
                    assertLe(m, CEIL_PREPASS, "prepass merge ceiling");
                }
            }
        }
    }

    // ---------------------------------------------------------------- helpers

    function _marginal(uint256 used, uint256 base, uint256 n) internal pure returns (uint256) {
        return used > base ? (used - base) / n : 0;
    }

    function _row(uint256 layout, uint256 order, uint256 n, uint256 k, Cell memory c) internal view {
        console2.log(
            string.concat(
                layoutName[layout],
                "  ",
                orderName[order],
                "  ",
                _pad(n, 3),
                "  ",
                _pad(k, 2),
                "  |  ",
                _pad(c.each, 4),
                _pad(c.linear, 7),
                _pad(c.merge, 6)
            )
        );
    }

    function _pad(uint256 x, uint256 width) internal pure returns (string memory out) {
        out = vm.toString(x);
        while (bytes(out).length < width) {
            out = string.concat(" ", out);
        }
    }

    function _sort(uint256[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; ++i) {
            uint256 x = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > x) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = x;
        }
    }

    function _sortRange(bytes32[] memory a, uint256 from, uint256 to) internal pure {
        for (uint256 i = from + 1; i < to; ++i) {
            bytes32 x = a[i];
            uint256 j = i;
            while (j > from && a[j - 1] > x) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = x;
        }
    }
}
