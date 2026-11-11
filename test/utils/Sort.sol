// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/// @title Sort
/// @notice Insertion sort for test fixtures, shared by the StorageGuard tests and benchmark.
///         Quadratic, so only for the small arrays fixtures build, outside any measured region.
library Sort {
    /// @notice Sorts `keys[from:to]` ascending, moving `values` along with them.
    function sortPairs(bytes32[] memory keys, bytes32[] memory values, uint256 from, uint256 to) internal pure {
        for (uint256 i = from + 1; i < to; ++i) {
            (bytes32 k, bytes32 v) = (keys[i], values[i]);
            uint256 j = i;
            while (j > from && keys[j - 1] > k) {
                (keys[j], values[j]) = (keys[j - 1], values[j - 1]);
                --j;
            }
            (keys[j], values[j]) = (k, v);
        }
    }

    /// @notice Sorts `a[from:to]` ascending.
    function sortRange(bytes32[] memory a, uint256 from, uint256 to) internal pure {
        sortPairs(a, new bytes32[](a.length), from, to);
    }

    /// @notice Sorts `a` ascending. `bytes32` compares as an unsigned big-endian integer, so
    ///         sorting the same words as `bytes32[]` orders them as `uint256`.
    function sort(uint256[] memory a) internal pure {
        bytes32[] memory words;
        assembly ("memory-safe") {
            words := a
        }
        sortRange(words, 0, words.length);
    }
}
