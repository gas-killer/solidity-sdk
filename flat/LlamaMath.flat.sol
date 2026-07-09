// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

// src/examples/onchain-llm/LlamaMath.sol

/// @title LlamaMath
/// @notice From-scratch fixed-point primitives for integer-only transformer inference.
/// @dev Formats: activations are Q32 (value * 2^32) carried in int256; intermediate
///      products use Q64. All operations are pure integer EVM opcodes, so results are
///      bit-identical across every operator simulating the model — the property that
///      lets a BLS quorum sign a single agreed state diff.
///
///      The Python mirror of every function here lives in tools/reference.py; the
///      Foundry suite pins them together with exact-match vectors.
library LlamaMath {
    /// @notice 1.0 in Q32
    int256 internal constant ONE = 1 << 32;

    /// @notice floor(log2(e) * 2^32), used to convert exp() to a base-2 problem
    int256 internal constant LOG2E_Q32 = 6196328018;

    /// @notice Thrown when expQ32 is called with a positive argument
    error ExpArgPositive();

    /// @notice Floor integer square root: the largest r with r*r <= a
    /// @dev Newton's method from a power-of-two overestimate; 7 iterations suffice
    ///      for 256-bit inputs, the final clamp lands on the floor exactly.
    /// @param a The radicand
    /// @return r floor(sqrt(a))
    function isqrt(uint256 a) internal pure returns (uint256 r) {
        if (a == 0) return 0;
        unchecked {
            // Power-of-two overestimate: r = 2^(floor(log2(a))/2 + 1) >= sqrt(a)
            uint256 x = a;
            uint256 s = 0;
            if (x >> 128 != 0) {
                x >>= 128;
                s += 128;
            }
            if (x >> 64 != 0) {
                x >>= 64;
                s += 64;
            }
            if (x >> 32 != 0) {
                x >>= 32;
                s += 32;
            }
            if (x >> 16 != 0) {
                x >>= 16;
                s += 16;
            }
            if (x >> 8 != 0) {
                x >>= 8;
                s += 8;
            }
            if (x >> 4 != 0) {
                x >>= 4;
                s += 4;
            }
            if (x >> 2 != 0) {
                x >>= 2;
                s += 2;
            }
            if (x >> 1 != 0) {
                s += 1;
            }
            r = uint256(1) << ((s >> 1) + 1);
            // Newton: monotone decreasing toward floor(sqrt(a)) from above
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            uint256 q = a / r;
            if (r > q) r = q;
        }
    }

    /// @notice exp(x) for Q32 x <= 0; result Q32 in [0, 2^32]
    /// @dev Base-2 reduction: exp(x) = 2^(x*log2(e)) = 2^n * 2^f with integer n <= 0 and
    ///      f in [0,1). 2^f is a bit-product over 32 fraction bits using the constants
    ///      C_i = 2^(2^-(i+1)) in Q64, derived by the pure-integer chain
    ///      C_0 = isqrt(2 << 128), C_i = isqrt(C_{i-1} << 64) — reproducible on-chain.
    /// @param x The Q32 exponent, must be <= 0
    /// @return Q32 result
    function expQ32(int256 x) internal pure returns (uint256) {
        if (x > 0) revert ExpArgPositive();
        unchecked {
            int256 y = (x * LOG2E_Q32) >> 32; // x * log2(e), Q32 (SAR)
            if (y <= -(int256(64) << 32)) return 0; // underflows Q32 entirely
            int256 n = y >> 32; // floor(y), in [-64, 0]
            uint256 f = uint256(y - (n << 32)); // fraction in [0, 2^32)
            uint256 acc = 1 << 64; // 2^f accumulator, Q64
            if (f & 0x80000000 != 0) acc = (acc * 0x16A09E667F3BCC908) >> 64;
            if (f & 0x40000000 != 0) acc = (acc * 0x1306FE0A31B7152DE) >> 64;
            if (f & 0x20000000 != 0) acc = (acc * 0x1172B83C7D517ADCD) >> 64;
            if (f & 0x10000000 != 0) acc = (acc * 0x10B5586CF9890F629) >> 64;
            if (f & 0x08000000 != 0) acc = (acc * 0x1059B0D31585743AE) >> 64;
            if (f & 0x04000000 != 0) acc = (acc * 0x102C9A3E778060EE6) >> 64;
            if (f & 0x02000000 != 0) acc = (acc * 0x10163DA9FB33356D7) >> 64;
            if (f & 0x01000000 != 0) acc = (acc * 0x100B1AFA5ABCBED60) >> 64;
            if (f & 0x00800000 != 0) acc = (acc * 0x10058C86DA1C09EA1) >> 64;
            if (f & 0x00400000 != 0) acc = (acc * 0x1002C605E2E8CEC4F) >> 64;
            if (f & 0x00200000 != 0) acc = (acc * 0x100162F3904051FA0) >> 64;
            if (f & 0x00100000 != 0) acc = (acc * 0x1000B175EFFDC76B9) >> 64;
            if (f & 0x00080000 != 0) acc = (acc * 0x100058BA01FB9F96C) >> 64;
            if (f & 0x00040000 != 0) acc = (acc * 0x10002C5CC37DA9491) >> 64;
            if (f & 0x00020000 != 0) acc = (acc * 0x1000162E525EE0546) >> 64;
            if (f & 0x00010000 != 0) acc = (acc * 0x10000B17255775C03) >> 64;
            if (f & 0x00008000 != 0) acc = (acc * 0x1000058B91B5BC9AD) >> 64;
            if (f & 0x00004000 != 0) acc = (acc * 0x100002C5C89D5EC6C) >> 64;
            if (f & 0x00002000 != 0) acc = (acc * 0x10000162E43F4F830) >> 64;
            if (f & 0x00001000 != 0) acc = (acc * 0x100000B1721BCFC99) >> 64;
            if (f & 0x00000800 != 0) acc = (acc * 0x10000058B90CF1E6D) >> 64;
            if (f & 0x00000400 != 0) acc = (acc * 0x1000002C5C863B73E) >> 64;
            if (f & 0x00000200 != 0) acc = (acc * 0x100000162E430E5A1) >> 64;
            if (f & 0x00000100 != 0) acc = (acc * 0x1000000B172183551) >> 64;
            if (f & 0x00000080 != 0) acc = (acc * 0x100000058B90C0B48) >> 64;
            if (f & 0x00000040 != 0) acc = (acc * 0x10000002C5C8601CC) >> 64;
            if (f & 0x00000020 != 0) acc = (acc * 0x1000000162E42FFF0) >> 64;
            if (f & 0x00000010 != 0) acc = (acc * 0x10000000B17217FBA) >> 64;
            if (f & 0x00000008 != 0) acc = (acc * 0x1000000058B90BFCD) >> 64;
            if (f & 0x00000004 != 0) acc = (acc * 0x100000002C5C85FE2) >> 64;
            if (f & 0x00000002 != 0) acc = (acc * 0x10000000162E42FF0) >> 64;
            if (f & 0x00000001 != 0) acc = (acc * 0x100000000B17217F7) >> 64;
            // 2^n * acc, Q64 -> Q32: shift by 32 - n, n in [-64, 0] so shift in [32, 96]
            return acc >> uint256(int256(32) - n);
        }
    }
}
