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

// src/examples/onchain-llm/Qwen3.sol

/// @title Qwen3
/// @notice Engine v2: integer-only Qwen3-architecture inference — QK-norm, decoupled
///         head dimension, grouped-query attention, SwiGLU — with weights STREAMED
///         per-tensor from data contracts through a reused scratch buffer, so models
///         far larger than any single EVM memory allocation (Qwen3-0.6B: 597MB) run
///         within sane memory-expansion gas.
/// @dev Numeric spec (mirrored bit-for-bit by tools/qwen3_int.py):
///        - Activations: Q24 signed in int256 words.
///        - 2D weights: per-row [u8 shift || int8|int16 x cols], value = w / 2^shift.
///        - 1D norm weights: [u8 shift][int16 x n].
///        - KV cache: int32 Q16, packed 8 per word (stored as sar(x_q24, 8)).
///        - exp: e_q24 = sar(expQ32(x_q24 << 8), 8) — reuses the proven Q32 kernel.
///        - RMSNorm eps is a per-model Q48 config constant.
///        - RoPE: interleaved-pair kernel over Q30 tables (HF half-dim convention is
///          pre-permuted into wq/wk/qk-norm rows at conversion time).
///        - Greedy argmax (first maximum wins), streaming over the tied classifier.
library Qwen3 {
    /// @notice Activation fraction bits
    uint256 internal constant F = 24;

    /// @notice Data-contract payload size (EIP-170 minus STOP prefix)
    uint256 internal constant CHUNK = 24_575;

    /// @notice Model hyperparameters, quantization and tokenizer metadata
    struct Config {
        uint256 dim;
        uint256 hidden;
        uint256 nLayers;
        uint256 nHeads;
        uint256 nKv;
        uint256 headDim;
        uint256 vocab;
        uint256 seqCap;
        uint256 tokType;
        uint256 wBits; // bytes per 2D weight (1 = int8, 2 = int16)
        uint256 epsQ48;
        uint256 invSqrtHd; // Q32
        uint256 weightLen;
        uint256 tokLen;
        uint256 stop0;
        uint256 stop1;
        uint256 kvd; // nKv * headDim
        uint256 qd; // nHeads * headDim
    }

    /// @notice Byte offsets into the weight blob (per-layer offsets are relative)
    struct Layout {
        uint256 embRowStride;
        uint256 layerBase; // offset of layer 0 == emb length
        uint256 layerLen;
        uint256 oQn;
        uint256 oKn;
        uint256 oWq;
        uint256 oWk;
        uint256 oWv;
        uint256 oWo;
        uint256 oLn2;
        uint256 oWg;
        uint256 oWu;
        uint256 oWd;
        uint256 normOff;
        uint256 ropeCosOff;
        uint256 ropeSinOff;
    }

    /// @notice Chunked weight store + reusable scratch buffers
    struct Store {
        address[] chunks;
        bytes big; // holds one streamed 2D tensor (or classifier slice)
        bytes small; // holds one streamed 1D norm tensor
        bytes rope; // holds this position's cos||sin rows
    }

    /// @notice Per-run scratch (activations + packed KV cache)
    struct Buffers {
        int256[] x;
        int256[] xb;
        int256[] q;
        int256[] k;
        int256[] v;
        int256[] xatt;
        int256[] g;
        int256[] u;
        uint256[] kCache; // packed int32 Q16, 8 per word
        uint256[] vCache;
        int256[] scores;
        uint256 maxPos;
    }

    /// @notice Thrown when the packed config is inconsistent
    error BadConfig();

    /// @notice Thrown when prompt length or token budget exceeds the context
    error ContextOverflow();

    /// @notice Thrown when a prompt token id is out of vocabulary range
    error BadToken();

    /// @notice Unpack the 3-word packed config emitted by tools/qwen3_convert.py
    /// @param w The packed words
    /// @return c The unpacked config
    function unpack(bytes32[3] memory w) internal pure returns (Config memory c) {
        uint256 w0 = uint256(w[0]);
        uint256 w1 = uint256(w[1]);
        uint256 w2 = uint256(w[2]);
        c.dim = w0 >> 240;
        c.hidden = (w0 >> 224) & 0xffff;
        c.nLayers = (w0 >> 216) & 0xff;
        c.nHeads = (w0 >> 208) & 0xff;
        c.nKv = (w0 >> 200) & 0xff;
        c.headDim = (w0 >> 184) & 0xffff;
        c.vocab = (w0 >> 152) & 0xffffffff;
        c.seqCap = (w0 >> 136) & 0xffff;
        c.tokType = (w0 >> 128) & 0xff;
        c.wBits = (w0 >> 120) & 0xff;
        c.epsQ48 = w1 >> 192;
        c.invSqrtHd = (w1 >> 128) & 0xffffffffffffffff;
        c.weightLen = (w1 >> 64) & 0xffffffffffffffff;
        c.tokLen = w2 >> 224;
        c.stop0 = (w2 >> 192) & 0xffffffff;
        c.stop1 = (w2 >> 160) & 0xffffffff;
        c.kvd = c.nKv * c.headDim;
        c.qd = c.nHeads * c.headDim;
        if (
            c.dim == 0 || c.hidden == 0 || c.nLayers == 0 || c.nHeads == 0 || c.nKv == 0 || c.headDim == 0
                || c.vocab == 0 || c.seqCap == 0 || c.nHeads % c.nKv != 0 || c.headDim % 2 != 0 || c.kvd % 8 != 0
                || (c.wBits != 1 && c.wBits != 2) || c.tokType != 1 || c.epsQ48 == 0
        ) revert BadConfig();
    }

    /// @notice Compute blob offsets; validates the total length against the config
    /// @param c The config
    /// @return o The layout
    function layout(Config memory c) internal pure returns (Layout memory o) {
        uint256 wB = c.wBits;
        o.embRowStride = 1 + c.dim * wB;
        o.layerBase = c.vocab * o.embRowStride;
        uint256 at = 0; // relative to layer base
        at += 1 + c.dim * 2; // ln1 at relative 0
        o.oQn = at;
        at += 1 + c.headDim * 2;
        o.oKn = at;
        at += 1 + c.headDim * 2;
        o.oWq = at;
        at += c.qd * (1 + c.dim * wB);
        o.oWk = at;
        at += c.kvd * (1 + c.dim * wB);
        o.oWv = at;
        at += c.kvd * (1 + c.dim * wB);
        o.oWo = at;
        at += c.dim * (1 + c.qd * wB);
        o.oLn2 = at;
        at += 1 + c.dim * 2;
        o.oWg = at;
        at += c.hidden * (1 + c.dim * wB);
        o.oWu = at;
        at += c.hidden * (1 + c.dim * wB);
        o.oWd = at;
        at += c.dim * (1 + c.hidden * wB);
        o.layerLen = at;
        o.normOff = o.layerBase + c.nLayers * o.layerLen;
        o.ropeCosOff = o.normOff + 1 + c.dim * 2;
        uint256 ropeLen = c.seqCap * (c.headDim / 2) * 4;
        o.ropeSinOff = o.ropeCosOff + ropeLen;
        if (o.ropeSinOff + ropeLen != c.weightLen) revert BadConfig();
    }

    /// @notice Allocate the store's scratch buffers for a config
    /// @param c The config
    /// @param chunks The weight chunk data contracts
    /// @return s The store
    function newStore(Config memory c, address[] memory chunks) internal pure returns (Store memory s) {
        s.chunks = chunks;
        uint256 big = c.hidden * (1 + c.dim * c.wBits); // wg/wu
        uint256 wd = c.dim * (1 + c.hidden * c.wBits);
        uint256 wq = c.qd * (1 + c.dim * c.wBits);
        uint256 wo = c.dim * (1 + c.qd * c.wBits);
        if (wd > big) big = wd;
        if (wq > big) big = wq;
        if (wo > big) big = wo;
        if (CLS_SLICE * (1 + c.dim * c.wBits) > big) big = CLS_SLICE * (1 + c.dim * c.wBits);
        s.big = new bytes(big);
        s.small = new bytes(1 + c.dim * 2);
        s.rope = new bytes(c.headDim * 4); // cos row || sin row
    }

    /// @notice Allocate per-run buffers for at most `maxPos` positions
    function newBuffers(Config memory c, uint256 maxPos) internal pure returns (Buffers memory b) {
        b.x = new int256[](c.dim);
        b.xb = new int256[](c.dim);
        b.q = new int256[](c.qd);
        b.k = new int256[](c.kvd);
        b.v = new int256[](c.kvd);
        b.xatt = new int256[](c.qd);
        b.g = new int256[](c.hidden);
        b.u = new int256[](c.hidden);
        uint256 kvWords = (c.nLayers * maxPos * c.kvd) / 8;
        b.kCache = new uint256[](kvWords);
        b.vCache = new uint256[](kvWords);
        b.scores = new int256[](maxPos);
        b.maxPos = maxPos;
    }

    /// @notice Rows per classifier streaming slice
    uint256 internal constant CLS_SLICE = 512;

    /// @notice Copy blob range [off, off+len) from the chunked store into `dest`
    /// @dev Chunks hold exactly CHUNK payload bytes each (except the last)
    function loadRange(Store memory s, uint256 off, uint256 len, bytes memory dest) internal view {
        require(len <= dest.length, "range>dest");
        uint256 destOff = 0;
        address[] memory chunks = s.chunks;
        while (len > 0) {
            uint256 ci = off / CHUNK;
            uint256 within = off % CHUNK;
            uint256 take = CHUNK - within;
            if (take > len) take = len;
            address chunk = chunks[ci];
            assembly ("memory-safe") {
                extcodecopy(chunk, add(add(dest, 0x20), destOff), add(1, within), take)
            }
            off += take;
            destOff += take;
            len -= take;
        }
    }

    /// @notice out[outOff+i] = sar(sum_j w[i][j] * x[j], rowShift_i) for streamed rows
    /// @dev buf holds `rows` rows of [u8 shift || wBits*cols weight bytes]
    function matmulRows(
        bytes memory buf,
        uint256 rows,
        uint256 cols,
        uint256 wBits,
        int256[] memory x,
        int256[] memory out,
        uint256 outOff
    ) internal pure {
        if (wBits == 1) {
            _matmulI8(buf, rows, cols, x, out, outOff);
        } else {
            _matmulI16(buf, rows, cols, x, out, outOff);
        }
    }

    /// @dev int8 rows; the hot kernel — 32 weights per MLOAD, fully unrolled
    function _matmulI8(
        bytes memory buf,
        uint256 rows,
        uint256 cols,
        int256[] memory x,
        int256[] memory out,
        uint256 outOff
    ) private pure {
        assembly ("memory-safe") {
            let xp := add(x, 0x20)
            let op := add(add(out, 0x20), shl(5, outOff))
            let rp := add(buf, 0x20)
            let full := and(cols, not(31))
            for { let i := 0 } lt(i, rows) { i := add(i, 1) } {
                let acc := 0
                let xq := xp
                for { let j := 0 } lt(j, full) { j := add(j, 32) } {
                    // 32 int8 weights per MLOAD, consumed 8 at a time: full unroll
                    // overflows via-IR stack scheduling once inlined into callers.
                    let word := mload(add(add(rp, 1), j))
                    for { let b := 0 } lt(b, 32) { b := add(b, 8) } {
                        let w := shl(mul(b, 8), word)
                        acc := add(acc, mul(signextend(0, byte(0, w)), mload(xq)))
                        acc := add(acc, mul(signextend(0, byte(1, w)), mload(add(xq, 0x20))))
                        acc := add(acc, mul(signextend(0, byte(2, w)), mload(add(xq, 0x40))))
                        acc := add(acc, mul(signextend(0, byte(3, w)), mload(add(xq, 0x60))))
                        acc := add(acc, mul(signextend(0, byte(4, w)), mload(add(xq, 0x80))))
                        acc := add(acc, mul(signextend(0, byte(5, w)), mload(add(xq, 0xa0))))
                        acc := add(acc, mul(signextend(0, byte(6, w)), mload(add(xq, 0xc0))))
                        acc := add(acc, mul(signextend(0, byte(7, w)), mload(add(xq, 0xe0))))
                        xq := add(xq, 0x100)
                    }
                }
                for { let j := full } lt(j, cols) { j := add(j, 1) } {
                    acc := add(acc, mul(signextend(0, shr(248, mload(add(add(rp, 1), j)))), mload(add(xp, shl(5, j)))))
                }
                mstore(op, sar(shr(248, mload(rp)), acc))
                op := add(op, 0x20)
                rp := add(rp, add(1, cols))
            }
        }
    }

    /// @dev int16 rows (fallback precision path)
    function _matmulI16(
        bytes memory buf,
        uint256 rows,
        uint256 cols,
        int256[] memory x,
        int256[] memory out,
        uint256 outOff
    ) private pure {
        assembly ("memory-safe") {
            let xp := add(x, 0x20)
            let op := add(add(out, 0x20), shl(5, outOff))
            let rp := add(buf, 0x20)
            for { let i := 0 } lt(i, rows) { i := add(i, 1) } {
                let acc := 0
                for { let j := 0 } lt(j, cols) { j := add(j, 1) } {
                    let wv := signextend(1, shr(240, mload(add(add(rp, 1), shl(1, j)))))
                    acc := add(acc, mul(wv, mload(add(xp, shl(5, j)))))
                }
                mstore(op, sar(shr(248, mload(rp)), acc))
                op := add(op, 0x20)
                rp := add(rp, add(1, shl(1, cols)))
            }
        }
    }

    /// @notice RMSNorm slice: out[outOff..outOff+n) = norm(x[xOff..xOff+n)) * g
    /// @dev g is a streamed 1D tensor in `buf`: [u8 shift][int16 x n]. Q24 semantics:
    ///      ss = sum(x^2)/n + epsQ48; s = isqrt(ss); out_i = sar(sdiv((x_i*g_i)<<24, s), gShift)
    function rmsnormSlice(
        bytes memory buf,
        int256[] memory x,
        uint256 xOff,
        int256[] memory out,
        uint256 outOff,
        uint256 n,
        uint256 epsQ48
    ) internal pure {
        uint256 ss;
        assembly ("memory-safe") {
            let xp := add(add(x, 0x20), shl(5, xOff))
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let v := mload(add(xp, shl(5, i)))
                ss := add(ss, mul(v, v))
            }
        }
        uint256 s = LlamaMath.isqrt(ss / n + epsQ48); // Q24
        assembly ("memory-safe") {
            let xp := add(add(x, 0x20), shl(5, xOff))
            let op := add(add(out, 0x20), shl(5, outOff))
            let gshift := shr(248, mload(add(buf, 0x20)))
            let gp := add(buf, 0x21)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let g := signextend(1, shr(240, mload(add(gp, shl(1, i)))))
                let num := shl(24, mul(mload(add(xp, shl(5, i))), g))
                mstore(add(op, shl(5, i)), sar(gshift, sdiv(num, s)))
            }
        }
    }

    /// @notice Rotate adjacent pairs in each head by this position's RoPE angle
    /// @dev s.rope holds cosRow || sinRow (int32 Q30 each, headDim/2 entries per row)
    function rope(Store memory s, int256[] memory arr, uint256 nHeads, uint256 hd) internal pure {
        bytes memory tbl = s.rope;
        uint256 half = hd / 2;
        assembly ("memory-safe") {
            let cosP := add(tbl, 0x20)
            let sinP := add(cosP, shl(2, half))
            let ap := add(arr, 0x20)
            for { let h := 0 } lt(h, nHeads) { h := add(h, 1) } {
                for { let p := 0 } lt(p, half) { p := add(p, 1) } {
                    let cv := signextend(3, shr(224, mload(add(cosP, shl(2, p)))))
                    let sv := signextend(3, shr(224, mload(add(sinP, shl(2, p)))))
                    let i0 := add(ap, shl(5, add(mul(h, hd), shl(1, p))))
                    let i1 := add(i0, 0x20)
                    let v0 := mload(i0)
                    let v1 := mload(i1)
                    mstore(i0, sar(30, sub(mul(v0, cv), mul(v1, sv))))
                    mstore(i1, sar(30, add(mul(v0, sv), mul(v1, cv))))
                }
            }
        }
    }

    /// @notice Store k/v (Q24) into the packed cache as int32 Q16 at position `pos`
    function cacheStore(Config memory c, Buffers memory b, uint256 l, uint256 pos) internal pure {
        uint256 kvd = c.kvd;
        uint256 base = (l * b.maxPos + pos) * kvd; // element index, 8 per word
        int256[] memory k = b.k;
        int256[] memory v = b.v;
        uint256[] memory kC = b.kCache;
        uint256[] memory vC = b.vCache;
        assembly ("memory-safe") {
            let kp := add(k, 0x20)
            let vp := add(v, 0x20)
            let kcp := add(add(kC, 0x20), shl(2, base)) // base/8 words * 32 bytes
            let vcp := add(add(vC, 0x20), shl(2, base))
            for { let w := 0 } lt(w, div(kvd, 8)) { w := add(w, 1) } {
                let kw := 0
                let vw := 0
                for { let sIdx := 0 } lt(sIdx, 8) { sIdx := add(sIdx, 1) } {
                    let j := add(mul(w, 8), sIdx)
                    let k16 := and(sar(8, mload(add(kp, shl(5, j)))), 0xffffffff)
                    let v16 := and(sar(8, mload(add(vp, shl(5, j)))), 0xffffffff)
                    kw := or(kw, shl(sub(224, mul(32, sIdx)), k16))
                    vw := or(vw, shl(sub(224, mul(32, sIdx)), v16))
                }
                mstore(add(kcp, shl(5, w)), kw)
                mstore(add(vcp, shl(5, w)), vw)
            }
        }
    }

    /// @notice Attention for one layer/position over the packed KV cache
    function attend(Config memory c, Buffers memory b, uint256 l, uint256 pos) internal pure {
        uint256 kvMul = c.nHeads / c.nKv;
        for (uint256 h = 0; h < c.nHeads; ++h) {
            _attendHead(c, b, l, h * c.headDim, (h / kvMul) * c.headDim, pos + 1);
        }
    }

    /// @dev scores_t = sar(sar(sum q*k16, 16) * invSqrtHd, 32); softmax via expQ24;
    ///      out_j = sdiv((sum e*v16) << 8, tot). k16/v16 are unpacked int32 Q16.
    function _attendHead(Config memory c, Buffers memory b, uint256 l, uint256 qOff, uint256 kvOff, uint256 steps)
        private
        pure
    {
        int256 mx = type(int256).min;
        uint256 kvd = c.kvd;
        {
            int256[] memory q = b.q;
            uint256[] memory kC = b.kCache;
            int256[] memory scores = b.scores;
            uint256 hd = c.headDim;
            int256 inv = int256(c.invSqrtHd);
            uint256 rowBase = l * b.maxPos * kvd + kvOff; // element index of t=0
            assembly ("memory-safe") {
                let qp := add(add(q, 0x20), shl(5, qOff))
                let sp := add(scores, 0x20)
                for { let t := 0 } lt(t, steps) { t := add(t, 1) } {
                    let eBase := add(rowBase, mul(t, kvd))
                    let acc := 0
                    for { let j := 0 } lt(j, hd) { j := add(j, 1) } {
                        let e := add(eBase, j)
                        let word := mload(add(add(kC, 0x20), shl(5, shr(3, e))))
                        let k16 := signextend(3, shr(sub(224, mul(32, and(e, 7))), word))
                        acc := add(acc, mul(mload(add(qp, shl(5, j))), k16))
                    }
                    let sc := sar(32, mul(sar(16, acc), inv))
                    mstore(add(sp, shl(5, t)), sc)
                    if sgt(sc, mx) { mx := sc }
                }
            }
        }
        uint256 tot = 0;
        {
            int256[] memory scores = b.scores;
            for (uint256 t = 0; t < steps; ++t) {
                uint256 e = LlamaMath.expQ32((scores[t] - mx) << 8) >> 8; // expQ24
                scores[t] = int256(e);
                tot += e;
            }
        }
        {
            int256[] memory scores = b.scores;
            uint256[] memory vC = b.vCache;
            int256[] memory xatt = b.xatt;
            uint256 hd = c.headDim;
            uint256 rowBase = l * b.maxPos * kvd + kvOff;
            assembly ("memory-safe") {
                let sp := add(scores, 0x20)
                let xp := add(add(xatt, 0x20), shl(5, qOff))
                for { let j := 0 } lt(j, hd) { j := add(j, 1) } {
                    let acc := 0
                    let e := add(rowBase, j)
                    for { let t := 0 } lt(t, steps) { t := add(t, 1) } {
                        let word := mload(add(add(vC, 0x20), shl(5, shr(3, e))))
                        let v16 := signextend(3, shr(sub(224, mul(32, and(e, 7))), word))
                        acc := add(acc, mul(mload(add(sp, shl(5, t))), v16))
                        e := add(e, kvd)
                    }
                    mstore(add(xp, shl(5, j)), sdiv(shl(8, acc), tot))
                }
            }
        }
    }

    /// @notice g[i] = silu(g[i]) * u[i], all Q24
    function swiglu(int256[] memory g, int256[] memory u) internal pure {
        uint256 n = g.length;
        uint256 one32 = 1 << 32;
        for (uint256 i = 0; i < n; ++i) {
            int256 z = g[i];
            uint256 sig;
            if (z >= 0) {
                sig = (one32 << 32) / (one32 + LlamaMath.expQ32(-(z << 8)));
            } else {
                uint256 e = LlamaMath.expQ32(z << 8);
                sig = (e << 32) / (one32 + e);
            }
            int256 sz = (z * int256(sig)) >> 32; // Q24
            g[i] = (sz * u[i]) >> 24;
        }
    }

    /// @notice x += y (residual)
    function addInto(int256[] memory x, int256[] memory y) internal pure {
        uint256 n = x.length;
        assembly ("memory-safe") {
            let xp := add(x, 0x20)
            let yp := add(y, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let p := add(xp, shl(5, i))
                mstore(p, add(mload(p), mload(add(yp, shl(5, i)))))
            }
        }
    }

    /// @notice One transformer pass; leaves the final normed hidden state in b.xb.
    ///         The classifier is NOT run here — callers invoke argmaxClassifier only
    ///         at generating positions, so teacher-forced prefill never streams the
    ///         155MB tied classifier.
    /// @param c The config
    /// @param o The layout
    /// @param s The chunked store
    /// @param b The buffers (KV cache persists across calls)
    /// @param token The current token id
    /// @param pos The current position
    function forward(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 token, uint256 pos)
        internal
        view
    {
        // embedding row -> Q24
        _loadEmbedding(c, o, s, token, b.x);

        // this position's rope rows (cos || sin)
        uint256 half = c.headDim / 2;
        loadRange(s, o.ropeCosOff + pos * half * 4, half * 4, s.rope);
        _loadRangeAt(s, o.ropeSinOff + pos * half * 4, half * 4, s.rope, half * 4);

        for (uint256 l = 0; l < c.nLayers; ++l) {
            _attnBlock(c, o, s, b, l, pos);
            _ffnBlock(c, o, s, b, l);
        }

        loadRange(s, o.normOff, 1 + c.dim * 2, s.small);
        rmsnormSlice(s.small, b.x, 0, b.xb, 0, c.dim, c.epsQ48);
    }

    /// @notice Attention block for one layer: norm, qkv, qk-norm, rope, attend, project
    /// @dev internal (not private) so Qwen3Seg can replay layer ranges segment-wise
    function _attnBlock(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 l, uint256 pos)
        internal
        view
    {
        uint256 lb = o.layerBase + l * o.layerLen;
        loadRange(s, lb, 1 + c.dim * 2, s.small); // ln1
        rmsnormSlice(s.small, b.x, 0, b.xb, 0, c.dim, c.epsQ48);

        loadRange(s, lb + o.oWq, c.qd * (1 + c.dim * c.wBits), s.big);
        matmulRows(s.big, c.qd, c.dim, c.wBits, b.xb, b.q, 0);
        loadRange(s, lb + o.oWk, c.kvd * (1 + c.dim * c.wBits), s.big);
        matmulRows(s.big, c.kvd, c.dim, c.wBits, b.xb, b.k, 0);
        loadRange(s, lb + o.oWv, c.kvd * (1 + c.dim * c.wBits), s.big);
        matmulRows(s.big, c.kvd, c.dim, c.wBits, b.xb, b.v, 0);

        loadRange(s, lb + o.oQn, 1 + c.headDim * 2, s.small);
        _qkNorm(c, s, b.q, c.nHeads);
        loadRange(s, lb + o.oKn, 1 + c.headDim * 2, s.small);
        _qkNorm(c, s, b.k, c.nKv);
        rope(s, b.q, c.nHeads, c.headDim);
        rope(s, b.k, c.nKv, c.headDim);

        cacheStore(c, b, l, pos);
        attend(c, b, l, pos);

        loadRange(s, lb + o.oWo, c.dim * (1 + c.qd * c.wBits), s.big);
        matmulRows(s.big, c.dim, c.qd, c.wBits, b.xatt, b.xb, 0);
        addInto(b.x, b.xb);
    }

    /// @notice Per-head RMSNorm over headDim using the streamed norm weights in s.small
    function _qkNorm(Config memory c, Store memory s, int256[] memory arr, uint256 heads) private pure {
        uint256 hd = c.headDim;
        for (uint256 h = 0; h < heads; ++h) {
            rmsnormSlice(s.small, arr, h * hd, arr, h * hd, hd, c.epsQ48);
        }
    }

    /// @notice FFN block for one layer: norm, gate/up, swiglu, down, residual
    /// @dev internal (not private) so Qwen3Seg can replay layer ranges segment-wise
    function _ffnBlock(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 l) internal view {
        uint256 lb = o.layerBase + l * o.layerLen;
        loadRange(s, lb + o.oLn2, 1 + c.dim * 2, s.small);
        rmsnormSlice(s.small, b.x, 0, b.xb, 0, c.dim, c.epsQ48);
        loadRange(s, lb + o.oWg, c.hidden * (1 + c.dim * c.wBits), s.big);
        matmulRows(s.big, c.hidden, c.dim, c.wBits, b.xb, b.g, 0);
        loadRange(s, lb + o.oWu, c.hidden * (1 + c.dim * c.wBits), s.big);
        matmulRows(s.big, c.hidden, c.dim, c.wBits, b.xb, b.u, 0);
        swiglu(b.g, b.u);
        loadRange(s, lb + o.oWd, c.dim * (1 + c.hidden * c.wBits), s.big);
        matmulRows(s.big, c.dim, c.hidden, c.wBits, b.g, b.xb, 0);
        addInto(b.x, b.xb);
    }

    /// @notice Streaming tied-classifier argmax: process CLS_SLICE emb rows at a time
    function argmaxClassifier(Config memory c, Layout memory o, Store memory s, int256[] memory xb)
        internal
        view
        returns (uint256 best)
    {
        int256 bestVal = type(int256).min;
        uint256 stride = o.embRowStride;
        int256[] memory sliceOut = new int256[](CLS_SLICE);
        for (uint256 row = 0; row < c.vocab; row += CLS_SLICE) {
            uint256 rows = c.vocab - row;
            if (rows > CLS_SLICE) rows = CLS_SLICE;
            loadRange(s, row * stride, rows * stride, s.big);
            matmulRows(s.big, rows, c.dim, c.wBits, xb, sliceOut, 0);
            for (uint256 i = 0; i < rows; ++i) {
                if (sliceOut[i] > bestVal) {
                    bestVal = sliceOut[i];
                    best = row + i;
                }
            }
        }
    }

    /// @notice Full logits for tests/inspection (materializes vocab-sized array)
    function logits(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 token, uint256 pos)
        internal
        view
        returns (int256[] memory out)
    {
        forward(c, o, s, b, token, pos);
        out = new int256[](c.vocab);
        uint256 stride = o.embRowStride;
        for (uint256 row = 0; row < c.vocab; row += CLS_SLICE) {
            uint256 rows = c.vocab - row;
            if (rows > CLS_SLICE) rows = CLS_SLICE;
            loadRange(s, row * stride, rows * stride, s.big);
            matmulRows(s.big, rows, c.dim, c.wBits, b.xb, out, row);
        }
    }

    /// @notice Greedy generation from pre-tokenized prompt ids
    /// @param c The config
    /// @param s The chunked store
    /// @param promptIds The prompt token ids (chat template applied off-chain)
    /// @param maxNew Upper bound on new tokens (clamped to seqCap - promptLen)
    /// @return genIds The generated token ids
    function generate(Config memory c, Store memory s, uint32[] memory promptIds, uint256 maxNew)
        internal
        view
        returns (uint32[] memory genIds)
    {
        Layout memory o = layout(c);
        uint256 pLen = promptIds.length;
        if (pLen == 0 || pLen >= c.seqCap) revert ContextOverflow();
        for (uint256 i = 0; i < pLen; ++i) {
            if (promptIds[i] >= c.vocab) revert BadToken();
        }
        uint256 maxPos = pLen + maxNew;
        if (maxPos > c.seqCap) maxPos = c.seqCap;

        Buffers memory b = newBuffers(c, maxPos);
        genIds = new uint32[](maxPos - pLen);
        uint256 nGen = 0;

        uint256 token = promptIds[0];
        for (uint256 pos = 0; pos + 1 < maxPos; ++pos) {
            forward(c, o, s, b, token, pos);
            uint256 next;
            if (pos + 1 < pLen) {
                next = promptIds[pos + 1];
            } else {
                next = argmaxClassifier(c, o, s, b.xb);
                genIds[nGen++] = uint32(next);
                if (next == c.stop0 || next == c.stop1) break;
            }
            token = next;
        }
        assembly ("memory-safe") {
            mstore(genIds, nGen)
        }
    }

    /// @notice x[i] = embedding row value scaled to Q24 (row shift <= 24)
    /// @dev internal (not private) so layer-0 segments in Qwen3Seg can load embeddings
    function _loadEmbedding(Config memory c, Layout memory o, Store memory s, uint256 token, int256[] memory x)
        internal
        view
    {
        loadRange(s, token * o.embRowStride, o.embRowStride, s.big);
        bytes memory buf = s.big;
        uint256 dim = c.dim;
        uint256 wB = c.wBits;
        assembly ("memory-safe") {
            let shift := shr(248, mload(add(buf, 0x20)))
            let up := sub(24, shift)
            let wp := add(buf, 0x21)
            let xp := add(x, 0x20)
            switch wB
            case 1 {
                for { let i := 0 } lt(i, dim) { i := add(i, 1) } {
                    let v := signextend(0, shr(248, mload(add(wp, i))))
                    mstore(add(xp, shl(5, i)), shl(up, v))
                }
            }
            default {
                for { let i := 0 } lt(i, dim) { i := add(i, 1) } {
                    let v := signextend(1, shr(240, mload(add(wp, shl(1, i)))))
                    mstore(add(xp, shl(5, i)), shl(up, v))
                }
            }
        }
    }

    /// @notice loadRange variant writing at a destination byte offset
    /// @dev internal (not private) so segments in Qwen3Seg can load per-position RoPE rows
    function _loadRangeAt(Store memory s, uint256 off, uint256 len, bytes memory dest, uint256 destOff) internal view {
        require(destOff + len <= dest.length, "range>dest");
        address[] memory chunks = s.chunks;
        while (len > 0) {
            uint256 ci = off / CHUNK;
            uint256 within = off % CHUNK;
            uint256 take = CHUNK - within;
            if (take > len) take = len;
            address chunk = chunks[ci];
            assembly ("memory-safe") {
                extcodecopy(chunk, add(add(dest, 0x20), destOff), add(1, within), take)
            }
            off += take;
            destOff += take;
            len -= take;
        }
    }
}

// src/examples/onchain-llm/Qwen35.sol

/// @title Qwen35
/// @notice Engine v3: integer-only Qwen3.5-MoE-architecture inference — hybrid
///         DeltaNet linear attention / gated full attention token mixers and a
///         256-expert top-8 MoE with a shared expert — with weights STREAMED
///         per-tensor from data contracts through a reused scratch buffer, so a
///         35B-parameter model (~35GB int8) runs within sane memory-expansion gas.
/// @dev Numeric spec: .context/qwen35/SPEC.md, mirrored bit-for-bit by
///      tools/qwen35_int.py. Everything not changed there behaves exactly as v2
///      (Qwen3.sol): Q24 activations, per-row int8 pow-2 weights, int16 pow-2
///      norms, int32 Q16 packed KV cache, expQ32 exponential, Q30 RoPE tables,
///      greedy argmax (first maximum wins). New in v3:
///        - DeltaNet: causal conv4 over packed Q16 conv state, l2-normed q/k,
///          softplus/sigmoid/exp gating (log2Q64 primitive), delta-rule update
///          of an int32 Q16 packed recurrent state, gated output norm.
///        - Full attention: 16/2 heads at head_dim 256, partial RoPE over the
///          first 64 dims, sigmoid output gate from the fused q/gate projection.
///        - MoE: int16 hi-precision router rows; top-8 SELECTED over raw logits
///          (ties to the lowest index), softmax weights computed only for the
///          selected experts afterward (SPEC §7 rev 2); 8 routed experts + 1 gated
///          shared expert, all streamed through one scratch.
///        - Untied classifier (lmHead) streamed in 512-row slices.
library Qwen35 {
    /// @notice Activation fraction bits
    uint256 internal constant F = 24;

    /// @notice Data-contract payload size (EIP-170 minus STOP prefix)
    uint256 internal constant CHUNK = 24_575;

    /// @notice Rows per classifier streaming slice
    uint256 internal constant CLS_SLICE = 512;

    /// @notice floor(ln2 * 2^64), converts log2Q64 output to natural log
    uint256 internal constant LN2_Q64 = 12786308645202655660;

    /// @notice Model hyperparameters, quantization and tokenizer metadata (§10)
    struct Config {
        uint256 dim;
        uint256 moeDim;
        uint256 nLayers;
        uint256 nHeads;
        uint256 nKv;
        uint256 headDim;
        uint256 vocab;
        uint256 seqCap;
        uint256 tokType;
        uint256 wBits; // bytes per 2D weight (1 = int8, 2 = int16)
        uint256 rot; // rotary dims per head
        uint256 fullInterval; // layer l is full attention iff (l+1) % fullInterval == 0
        uint256 topK;
        uint256 nExperts;
        uint256 sharedDim;
        uint256 epsQ48;
        uint256 invSqrtHd; // Q32
        uint256 weightLen;
        uint256 tokLen;
        uint256 stop0;
        uint256 stop1;
        uint256 nVH; // DeltaNet value heads
        uint256 nKH; // DeltaNet key heads
        uint256 dK; // DeltaNet key head dim
        uint256 dV; // DeltaNet value head dim
        uint256 convK; // DeltaNet causal-conv kernel size
        uint256 invSqrtDk; // Q32
        uint256 kvd; // nKv * headDim
        uint256 qd; // nHeads * headDim
        uint256 keyDim; // nKH * dK
        uint256 valueDim; // nVH * dV
        uint256 convDim; // 2*keyDim + valueDim
    }

    /// @notice Byte offsets into the weight blob (§3; per-layer offsets relative)
    struct Layout {
        uint256 embRowStride;
        uint256 layerBase; // offset of layer 0 == emb length
        uint256 linStride; // full byte stride of a DeltaNet layer
        uint256 fullStride; // full byte stride of a full-attention layer
        // DeltaNet mixer offsets, relative to the layer start (ln1 at 0)
        uint256 oWqkv;
        uint256 oWz;
        uint256 oWb;
        uint256 oWa;
        uint256 oConv;
        uint256 oExpA;
        uint256 oDtBias;
        uint256 oGnorm;
        uint256 oWout;
        uint256 linTail; // MoE tail start of a DeltaNet layer
        // full-attention mixer offsets, relative to the layer start
        uint256 oQn;
        uint256 oKn;
        uint256 oWqg;
        uint256 oWk;
        uint256 oWv;
        uint256 oWo;
        uint256 fullTail; // MoE tail start of a full-attention layer
        // MoE tail offsets, relative to the tail start (ln2 at 0)
        uint256 tRouter;
        uint256 tSharedGate;
        uint256 tSharedGateUp;
        uint256 tSharedDown;
        uint256 tExperts;
        uint256 expertLen;
        uint256 expertDownOff; // offset of down within one expert record
        // trailer
        uint256 normOff;
        uint256 lmHeadOff;
        uint256 ropeCosOff;
        uint256 ropeSinOff;
    }

    /// @notice Chunked weight store + reusable scratch buffers
    struct Store {
        address[] chunks;
        bytes big; // holds one streamed 2D tensor (or classifier slice)
        bytes small; // holds one streamed 1D norm tensor (or expA || dtBias)
        bytes rope; // holds this position's cos||sin rows (rot/2 pairs each)
    }

    /// @notice Per-run scratch (activations + packed per-layer state)
    struct Buffers {
        int256[] x;
        int256[] xb;
        int256[] qkv; // DeltaNet conv channels / attention q-block || gate-block
        int256[] z; // DeltaNet z projection / attention head outputs
        int256[] att; // DeltaNet per-head outputs, concatenated
        int256[] k;
        int256[] v;
        int256[] bg; // DeltaNet b projection (beta gates)
        int256[] ag; // DeltaNet a projection (decay gates)
        int256[] qh; // per-v-head q copy (post l2norm + scale)
        int256[] kh; // per-v-head k copy (post l2norm)
        int256[] dv; // delta-rule kvmem/delta scratch (dV)
        int256[] gu; // MoE gate rows || up rows
        int256[] shared; // shared-expert output
        int256[] moeAcc; // routed-expert accumulator
        int256[] y; // per-expert down output
        int256[] rl; // router logits -> softmax numerators
        uint256[] selIdx; // top-k expert ids, selection order
        uint256[] selW; // top-k Q32 weights, selection order
        int256[] scores;
        uint256[] kCache; // packed int32 Q16, 8 per word; full-attention layers only
        uint256[] vCache;
        uint256[] convState; // packed int32 Q16 rolling conv state, linear layers
        uint256[] sState; // packed int32 Q16 recurrent state S, linear layers
        uint256 maxPos;
    }

    /// @notice Delta-rule step parameters (§5.4)
    struct DeltaParams {
        uint256 sBase; // word offset of this head's S block in the packed state
        uint256 vOff; // offset of v_h inside the v array
        uint256 outOff; // offset of o_h inside the out array
        uint256 dK;
        uint256 dV;
        uint256 decay; // Q32, in (0, 2^32]
        uint256 beta; // Q32, in [0, 2^32]
    }

    /// @notice Thrown when the packed config is inconsistent
    error BadConfig();

    /// @notice Thrown when prompt length or token budget exceeds the context
    error ContextOverflow();

    /// @notice Thrown when a prompt token id is out of vocabulary range
    error BadToken();

    // ------------------------------------------------------ math primitives

    /// @notice Sigmoid: Q24 in, Q32 out in [0, 2^32] (§2.1)
    /// @dev Bit-identical to the v2 swiglu sigmoid factored into a helper.
    function sigQ32(int256 x) internal pure returns (uint256) {
        if (x >= 0) {
            return (uint256(1) << 64) / ((uint256(1) << 32) + LlamaMath.expQ32(-(x << 8)));
        }
        uint256 e = LlamaMath.expQ32(x << 8);
        return (e << 32) / ((uint256(1) << 32) + e);
    }

    /// @notice Binary logarithm: Q32 v in [2^32, 2^33) -> Q64 in [0, 2^64) (§2.2)
    /// @dev Classic square-and-extract over 64 fraction bits, floor rounding.
    function log2Q64(uint256 v) internal pure returns (uint256 r) {
        unchecked {
            for (uint256 i = 0; i < 64; ++i) {
                v = (v * v) >> 32;
                r <<= 1;
                if (v >= (1 << 33)) {
                    r |= 1;
                    v >>= 1;
                }
            }
        }
    }

    /// @notice softplus = ln(1 + e^x): Q24 in (any sign), Q24 out >= 0 (§2.3)
    function softplusQ24(int256 x) internal pure returns (int256) {
        int256 base = 0;
        if (x > 0) {
            base = x; // exact identity: softplus(x) = x + softplus(-x)
            x = -x;
        }
        uint256 e = LlamaMath.expQ32(x << 8); // Q32, in [0, 2^32]
        uint256 v = (uint256(1) << 32) + e; // 1 + e^x in [1, 2], Q32
        if (v >= (1 << 33)) v = (1 << 33) - 1; // clamp x=0 edge (e = 2^32)
        return base + int256((log2Q64(v) * LN2_Q64) >> 104);
    }

    /// @notice FLA l2norm in place: vec /= sqrt(sum(vec^2) + eps) (§2.4)
    /// @dev SUM of squares (contrast rmsnorm's mean); epsQ48 added to the Q48 sum.
    function l2normSlice(int256[] memory arr, uint256 off, uint256 n, uint256 epsQ48) internal pure {
        uint256 ss;
        assembly ("memory-safe") {
            let ap := add(add(arr, 0x20), shl(5, off))
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let v := mload(add(ap, shl(5, i)))
                ss := add(ss, mul(v, v))
            }
        }
        uint256 s = LlamaMath.isqrt(ss + epsQ48); // Q24, > 0
        assembly ("memory-safe") {
            let ap := add(add(arr, 0x20), shl(5, off))
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let ptr := add(ap, shl(5, i))
                mstore(ptr, sdiv(shl(24, mload(ptr)), s))
            }
        }
    }

    // -------------------------------------------------------- config/layout

    /// @notice Unpack the 4-word packed config emitted by tools/convert_qwen35.py
    /// @param w The packed words
    /// @return c The unpacked config
    function unpack(bytes32[4] memory w) internal pure returns (Config memory c) {
        uint256 w0 = uint256(w[0]);
        uint256 w1 = uint256(w[1]);
        uint256 w2 = uint256(w[2]);
        c.dim = w0 >> 240;
        c.moeDim = (w0 >> 224) & 0xffff;
        c.nLayers = (w0 >> 216) & 0xff;
        c.nHeads = (w0 >> 208) & 0xff;
        c.nKv = (w0 >> 200) & 0xff;
        c.headDim = (w0 >> 184) & 0xffff;
        c.vocab = (w0 >> 152) & 0xffffffff;
        c.seqCap = (w0 >> 136) & 0xffff;
        c.tokType = (w0 >> 128) & 0xff;
        c.wBits = (w0 >> 120) & 0xff;
        c.rot = (w0 >> 104) & 0xffff;
        c.fullInterval = (w0 >> 96) & 0xff;
        c.topK = (w0 >> 88) & 0xff;
        c.nExperts = (w0 >> 72) & 0xffff;
        c.sharedDim = (w0 >> 56) & 0xffff;
        c.epsQ48 = w1 >> 192;
        c.invSqrtHd = (w1 >> 128) & 0xffffffffffffffff;
        c.weightLen = (w1 >> 64) & 0xffffffffffffffff;
        c.tokLen = w2 >> 224;
        c.stop0 = (w2 >> 192) & 0xffffffff;
        c.stop1 = (w2 >> 160) & 0xffffffff;
        c.nVH = (w2 >> 152) & 0xff;
        c.nKH = (w2 >> 144) & 0xff;
        c.dK = (w2 >> 128) & 0xffff;
        c.dV = (w2 >> 112) & 0xffff;
        c.convK = (w2 >> 104) & 0xff;
        c.invSqrtDk = uint256(w[3]) >> 192;
        c.kvd = c.nKv * c.headDim;
        c.qd = c.nHeads * c.headDim;
        c.keyDim = c.nKH * c.dK;
        c.valueDim = c.nVH * c.dV;
        c.convDim = 2 * c.keyDim + c.valueDim;
        if (
            c.dim == 0 || c.moeDim == 0 || c.nLayers == 0 || c.nHeads == 0 || c.nKv == 0 || c.headDim == 0
                || c.vocab == 0 || c.seqCap == 0 || c.nHeads % c.nKv != 0 || c.rot == 0 || c.rot % 2 != 0
                || c.rot > c.headDim || c.kvd % 8 != 0 || c.fullInterval == 0 || c.topK == 0 || c.topK > c.nExperts
                || c.sharedDim == 0 || (c.wBits != 1 && c.wBits != 2) || c.tokType != 1 || c.epsQ48 == 0 || c.nVH == 0
                || c.nKH == 0 || c.nVH % c.nKH != 0 || c.dK == 0 || c.dV == 0 || c.dV % 8 != 0 || c.convK < 2
                || c.convDim % 8 != 0 || c.invSqrtDk == 0 || c.invSqrtHd == 0
        ) revert BadConfig();
    }

    /// @notice Compute blob offsets; validates the total length against the config
    /// @param c The config
    /// @return o The layout
    function layout(Config memory c) internal pure returns (Layout memory o) {
        uint256 wB = c.wBits;
        uint256 rowLen = 1 + c.dim * wB; // row(dim)
        uint256 nd = 1 + 2 * c.dim; // norm(dim)
        o.embRowStride = rowLen;
        o.layerBase = c.vocab * rowLen;
        // DeltaNet mixer (after ln1 at relative 0)
        uint256 at = nd;
        o.oWqkv = at;
        at += c.convDim * rowLen;
        o.oWz = at;
        at += c.valueDim * rowLen;
        o.oWb = at;
        at += c.nVH * rowLen;
        o.oWa = at;
        at += c.nVH * rowLen;
        o.oConv = at;
        at += c.convDim * (1 + c.convK * wB);
        o.oExpA = at;
        at += 4 * c.nVH;
        o.oDtBias = at;
        at += 4 * c.nVH;
        o.oGnorm = at;
        at += 1 + 2 * c.dV;
        o.oWout = at;
        at += c.dim * (1 + c.valueDim * wB);
        o.linTail = at;
        // full-attention mixer
        at = nd;
        o.oQn = at;
        at += 1 + 2 * c.headDim;
        o.oKn = at;
        at += 1 + 2 * c.headDim;
        o.oWqg = at;
        at += 2 * c.qd * rowLen;
        o.oWk = at;
        at += c.kvd * rowLen;
        o.oWv = at;
        at += c.kvd * rowLen;
        o.oWo = at;
        at += c.dim * (1 + c.qd * wB);
        o.fullTail = at;
        // MoE tail (ln2 at relative 0)
        at = nd;
        o.tRouter = at;
        at += c.nExperts * (1 + 2 * c.dim); // router: ALWAYS int16 hi-precision rows (§1/§3)
        o.tSharedGate = at;
        at += rowLen;
        o.tSharedGateUp = at;
        at += 2 * c.sharedDim * rowLen;
        o.tSharedDown = at;
        at += c.dim * (1 + c.sharedDim * wB);
        o.tExperts = at;
        o.expertDownOff = 2 * c.moeDim * rowLen;
        o.expertLen = o.expertDownOff + c.dim * (1 + c.moeDim * wB);
        uint256 tailLen = at + c.nExperts * o.expertLen;
        o.linStride = o.linTail + tailLen;
        o.fullStride = o.fullTail + tailLen;
        uint256 nFull = c.nLayers / c.fullInterval;
        o.normOff = o.layerBase + nFull * o.fullStride + (c.nLayers - nFull) * o.linStride;
        o.lmHeadOff = o.normOff + nd;
        o.ropeCosOff = o.lmHeadOff + c.vocab * rowLen;
        uint256 ropeLen = c.seqCap * (c.rot / 2) * 4;
        o.ropeSinOff = o.ropeCosOff + ropeLen;
        if (o.ropeSinOff + ropeLen != c.weightLen) revert BadConfig();
    }

    /// @notice Byte offset of layer `l` in the blob (strides are type-dependent)
    function layerOffset(Config memory c, Layout memory o, uint256 l) internal pure returns (uint256) {
        uint256 nFullBefore = l / c.fullInterval;
        return o.layerBase + nFullBefore * o.fullStride + (l - nFullBefore) * o.linStride;
    }

    /// @notice Allocate the store's scratch buffers for a config
    /// @param c The config
    /// @param chunks The weight chunk data contracts
    /// @return s The store
    function newStore(Config memory c, address[] memory chunks) internal pure returns (Store memory s) {
        s.chunks = chunks;
        uint256 wB = c.wBits;
        uint256 rowLen = 1 + c.dim * wB;
        uint256 big = c.convDim * rowLen; // wqkv
        big = _max(big, c.valueDim * rowLen); // wz
        big = _max(big, c.nVH * rowLen); // wb/wa
        big = _max(big, c.convDim * (1 + c.convK * wB)); // conv taps
        big = _max(big, c.dim * (1 + c.valueDim * wB)); // wout
        big = _max(big, 2 * c.qd * rowLen); // wqg
        big = _max(big, c.kvd * rowLen); // wk/wv
        big = _max(big, c.dim * (1 + c.qd * wB)); // wo
        big = _max(big, c.nExperts * (1 + 2 * c.dim)); // router: int16 hi-precision rows
        big = _max(big, 2 * c.sharedDim * rowLen); // sharedGateUp
        big = _max(big, c.dim * (1 + c.sharedDim * wB)); // sharedDown
        big = _max(big, 2 * c.moeDim * rowLen); // expert gateUp
        big = _max(big, c.dim * (1 + c.moeDim * wB)); // expert down
        big = _max(big, CLS_SLICE * rowLen); // classifier slice
        s.big = new bytes(big);
        uint256 small = 1 + 2 * c.dim;
        small = _max(small, 1 + 2 * c.headDim);
        small = _max(small, 1 + 2 * c.dV);
        small = _max(small, 8 * c.nVH); // expA || dtBias
        s.small = new bytes(small);
        s.rope = new bytes(c.rot * 4); // cos row || sin row, rot/2 int32 pairs each
    }

    /// @notice Allocate per-run buffers for at most `maxPos` positions
    /// @dev Conv state and recurrent S persist across positions (zero-initialised);
    ///      the KV cache covers only the nLayers/fullInterval full-attention layers.
    function newBuffers(Config memory c, uint256 maxPos) internal pure returns (Buffers memory b) {
        b.x = new int256[](c.dim);
        b.xb = new int256[](c.dim);
        b.qkv = new int256[](_max(c.convDim, 2 * c.qd));
        uint256 vLen = _max(c.valueDim, c.qd);
        b.z = new int256[](vLen);
        b.att = new int256[](vLen);
        b.k = new int256[](c.kvd);
        b.v = new int256[](c.kvd);
        b.bg = new int256[](c.nVH);
        b.ag = new int256[](c.nVH);
        b.qh = new int256[](c.dK);
        b.kh = new int256[](c.dK);
        b.dv = new int256[](c.dV);
        b.gu = new int256[](2 * _max(c.moeDim, c.sharedDim));
        b.shared = new int256[](c.dim);
        b.moeAcc = new int256[](c.dim);
        b.y = new int256[](c.dim);
        b.rl = new int256[](c.nExperts);
        b.selIdx = new uint256[](c.topK);
        b.selW = new uint256[](c.topK);
        b.scores = new int256[](maxPos);
        uint256 nFull = c.nLayers / c.fullInterval;
        uint256 nLin = c.nLayers - nFull;
        b.kCache = new uint256[]((nFull * maxPos * c.kvd) / 8);
        b.vCache = new uint256[]((nFull * maxPos * c.kvd) / 8);
        b.convState = new uint256[](nLin * (c.convK - 1) * (c.convDim / 8));
        b.sState = new uint256[]((nLin * c.nVH * c.dK * c.dV) / 8);
        b.maxPos = maxPos;
    }

    // ------------------------------------------------------------ streaming

    /// @notice Copy blob range [off, off+len) from the chunked store into `dest`
    /// @dev Chunks hold exactly CHUNK payload bytes each (except the last)
    function loadRange(Store memory s, uint256 off, uint256 len, bytes memory dest, uint256 destOff) internal view {
        require(destOff + len <= dest.length, "range>dest");
        address[] memory chunks = s.chunks;
        while (len > 0) {
            uint256 ci = off / CHUNK;
            uint256 within = off % CHUNK;
            uint256 take = CHUNK - within;
            if (take > len) take = len;
            address chunk = chunks[ci];
            assembly ("memory-safe") {
                extcodecopy(chunk, add(add(dest, 0x20), destOff), add(1, within), take)
            }
            off += take;
            destOff += take;
            len -= take;
        }
    }

    // ------------------------------------------------------ DeltaNet kernels

    /// @notice Causal conv + SiLU over the packed rolling conv state (§5.2)
    /// @dev `conv` holds convDim rows of [u8 shift || wBits*convK taps], tap 0
    ///      oldest. State entry (t, c) lives at word stateBase + t*convDim/8 +
    ///      c/8, slot c%8 (slot 0 in the top 32 bits), as int32 Q16 of the
    ///      PRE-conv projection values. qkv[c] Q24 in; silu(conv) Q24 out;
    ///      state rolled with sar(qkv[c], 8) AFTER the taps are consumed.
    function convStep(
        uint256[] memory state,
        uint256 stateBase,
        bytes memory conv,
        int256[] memory qkv,
        uint256 convDim,
        uint256 convK,
        uint256 wBits
    ) internal pure {
        assembly ("memory-safe") {
            function eget(base, rowWords, t, c) -> v {
                let w := mload(add(base, shl(5, add(mul(t, rowWords), shr(3, c)))))
                v := signextend(3, shr(sub(224, shl(5, and(c, 7))), w))
            }
            function eset(base, rowWords, t, c, v) {
                let p := add(base, shl(5, add(mul(t, rowWords), shr(3, c))))
                let sh := sub(224, shl(5, and(c, 7)))
                mstore(p, or(and(mload(p), not(shl(sh, 0xffffffff))), shl(sh, and(v, 0xffffffff))))
            }
            function tap(row, wB, t) -> v {
                switch wB
                case 1 { v := signextend(0, byte(0, mload(add(add(row, 1), t)))) }
                default { v := signextend(1, shr(240, mload(add(add(row, 1), shl(1, t))))) }
            }
            let rowWords := shr(3, convDim)
            let sp := add(add(state, 0x20), shl(5, stateBase))
            let rp := add(conv, 0x20)
            let rowLen := add(1, mul(wBits, convK))
            let xp := add(qkv, 0x20)
            let kEnd := sub(convK, 1)
            for { let c := 0 } lt(c, convDim) { c := add(c, 1) } {
                let row := add(rp, mul(c, rowLen))
                let xptr := add(xp, shl(5, c))
                let s3 := sar(8, mload(xptr)) // current value -> Q16 int32
                let acc := mul(tap(row, wBits, kEnd), s3) // newest tap * current
                for { let t := 0 } lt(t, kEnd) { t := add(t, 1) } {
                    acc := add(acc, mul(tap(row, wBits, t), eget(sp, rowWords, t, c)))
                }
                // y = sar(acc, rowShift) << 8: Q16 -> Q24 (SiLU applied below)
                mstore(xptr, shl(8, sar(byte(0, mload(row)), acc)))
                // roll AFTER computing acc
                for { let t := 0 } lt(t, sub(kEnd, 1)) { t := add(t, 1) } {
                    eset(sp, rowWords, t, c, eget(sp, rowWords, add(t, 1), c))
                }
                eset(sp, rowWords, sub(kEnd, 1), c, s3)
            }
        }
        for (uint256 ch = 0; ch < convDim; ++ch) {
            int256 yv = qkv[ch];
            qkv[ch] = (yv * int256(sigQ32(yv))) >> 32; // SiLU, Q24
        }
    }

    /// @notice One delta-rule recurrence step for one v-head (§5.4)
    /// @dev Exact order: decay, predict, correct, output — steps read the UPDATED
    ///      state, and entries round-trip through int32 truncation after the decay
    ///      and correct steps (packed-storage semantics are part of the spec).
    ///        1. S[k][v] = sar(S[k][v] * decay, 32)
    ///        2. kvmem[v] = sar(sum_k S[k][v]*k[k], 16)
    ///        3. delta[v] = sar((v[v] - kvmem[v]) * beta, 32)
    ///        4. S[k][v] += sar(k[k] * delta[v], 32)
    ///        5. o[v]    = sar(sum_k S[k][v]*q[k], 16)
    /// @param S The packed recurrent state (int32 Q16, 8 per word, v fastest)
    /// @param q The normalized+scaled query (dK entries, Q24)
    /// @param k The normalized key (dK entries, Q24)
    /// @param vArr The value source; v_h at [p.vOff, p.vOff+dV) (Q24)
    /// @param scratch kvmem/delta scratch, at least dV entries (clobbered)
    /// @param out o_h written at [p.outOff, p.outOff+dV) (Q24)
    /// @param p The step parameters
    function deltaStep(
        uint256[] memory S,
        int256[] memory q,
        int256[] memory k,
        int256[] memory vArr,
        int256[] memory scratch,
        int256[] memory out,
        DeltaParams memory p
    ) internal pure {
        assembly ("memory-safe") {
            let dK := mload(add(p, 0x60))
            let dV := mload(add(p, 0x80))
            let dVw := shr(3, dV)
            let sp := add(add(S, 0x20), shl(5, mload(p)))
            let kp := add(k, 0x20)
            let scp := add(scratch, 0x20)
            // pass A: decay all entries (step 1), accumulating kvmem (step 2)
            {
                let decay := mload(add(p, 0xa0))
                for { let i := 0 } lt(i, dV) { i := add(i, 1) } { mstore(add(scp, shl(5, i)), 0) }
                for { let kk := 0 } lt(kk, dK) { kk := add(kk, 1) } {
                    let kv := mload(add(kp, shl(5, kk)))
                    let rowP := add(sp, shl(5, mul(kk, dVw)))
                    for { let w := 0 } lt(w, dVw) { w := add(w, 1) } {
                        let wp := add(rowP, shl(5, w))
                        let word := mload(wp)
                        let nw := 0
                        let vp := add(scp, shl(8, w))
                        for { let sl := 0 } lt(sl, 8) { sl := add(sl, 1) } {
                            let sh := sub(224, shl(5, sl))
                            let s := signextend(3, sar(32, mul(signextend(3, shr(sh, word)), decay)))
                            nw := or(nw, shl(sh, and(s, 0xffffffff)))
                            let ap := add(vp, shl(5, sl))
                            mstore(ap, add(mload(ap), mul(s, kv)))
                        }
                        mstore(wp, nw)
                    }
                }
            }
            // step 3: scratch[v] = delta[v] = sar((v_h[v] - sar(kvacc,16)) * beta, 32)
            {
                let beta := mload(add(p, 0xc0))
                let vhp := add(add(vArr, 0x20), shl(5, mload(add(p, 0x20))))
                for { let i := 0 } lt(i, dV) { i := add(i, 1) } {
                    let ptr := add(scp, shl(5, i))
                    let kvmem := sar(16, mload(ptr))
                    mstore(ptr, sar(32, mul(sub(mload(add(vhp, shl(5, i))), kvmem), beta)))
                }
            }
            // pass B: correct (step 4), accumulating the output (step 5)
            let op := add(add(out, 0x20), shl(5, mload(add(p, 0x40))))
            for { let i := 0 } lt(i, dV) { i := add(i, 1) } { mstore(add(op, shl(5, i)), 0) }
            let qp := add(q, 0x20)
            for { let kk := 0 } lt(kk, dK) { kk := add(kk, 1) } {
                let kv := mload(add(kp, shl(5, kk)))
                let qv := mload(add(qp, shl(5, kk)))
                let rowP := add(sp, shl(5, mul(kk, dVw)))
                for { let w := 0 } lt(w, dVw) { w := add(w, 1) } {
                    let wp := add(rowP, shl(5, w))
                    let word := mload(wp)
                    let nw := 0
                    for { let sl := 0 } lt(sl, 8) { sl := add(sl, 1) } {
                        let sh := sub(224, shl(5, sl))
                        let ep := shl(5, add(shl(3, w), sl))
                        let s := signextend(3, shr(sh, word))
                        s := signextend(3, add(s, sar(32, mul(kv, mload(add(scp, ep))))))
                        nw := or(nw, shl(sh, and(s, 0xffffffff)))
                        let ap := add(op, ep)
                        mstore(ap, add(mload(ap), mul(s, qv)))
                    }
                    mstore(wp, nw)
                }
            }
            // o[v] = sar(acc, 16): Q40 -> Q24
            for { let i := 0 } lt(i, dV) { i := add(i, 1) } {
                let ptr := add(op, shl(5, i))
                mstore(ptr, sar(16, mload(ptr)))
            }
        }
    }

    /// @notice DeltaNet token mixer for one layer (§5.1-§5.5); adds into b.x
    /// @dev `internal` (not `private`) so the sharded segment engine (Qwen35Seg) can
    ///      replay the exact monolithic kernel — visibility only, behaviour unchanged.
    function _deltaBlock(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 l) internal view {
        uint256 lb = layerOffset(c, o, l);
        uint256 linIdx = l - (l / c.fullInterval); // index among linear layers
        uint256 wB = c.wBits;
        uint256 rowLen = 1 + c.dim * wB;
        // §5.1 projections
        loadRange(s, lb + o.oWqkv, c.convDim * rowLen, s.big, 0);
        Qwen3.matmulRows(s.big, c.convDim, c.dim, wB, b.xb, b.qkv, 0);
        loadRange(s, lb + o.oWz, c.valueDim * rowLen, s.big, 0);
        Qwen3.matmulRows(s.big, c.valueDim, c.dim, wB, b.xb, b.z, 0);
        loadRange(s, lb + o.oWb, c.nVH * rowLen, s.big, 0);
        Qwen3.matmulRows(s.big, c.nVH, c.dim, wB, b.xb, b.bg, 0);
        loadRange(s, lb + o.oWa, c.nVH * rowLen, s.big, 0);
        Qwen3.matmulRows(s.big, c.nVH, c.dim, wB, b.xb, b.ag, 0);
        // §5.2 causal conv + SiLU (rolls the packed conv state)
        loadRange(s, lb + o.oConv, c.convDim * (1 + c.convK * wB), s.big, 0);
        convStep(b.convState, linIdx * (c.convK - 1) * (c.convDim / 8), s.big, b.qkv, c.convDim, c.convK, wB);
        // §5.3-§5.4 per-v-head recurrence; expA || dtBias staged in s.small
        loadRange(s, lb + o.oExpA, 8 * c.nVH, s.small, 0);
        uint256 kvMul = c.nVH / c.nKH;
        for (uint256 h = 0; h < c.nVH; ++h) {
            _deltaHead(c, s, b, linIdx, h, h / kvMul);
        }
        // §5.5 gated output norm, then gate with silu(z)
        loadRange(s, lb + o.oGnorm, 1 + 2 * c.dV, s.small, 0);
        _headNorm(c, s, b.att, c.nVH, c.dV);
        for (uint256 j = 0; j < c.valueDim; ++j) {
            int256 zv = b.z[j];
            int256 sz = (zv * int256(sigQ32(zv))) >> 32; // silu(z), Q24
            b.att[j] = (b.att[j] * sz) >> 24;
        }
        loadRange(s, lb + o.oWout, c.dim * (1 + c.valueDim * wB), s.big, 0);
        Qwen3.matmulRows(s.big, c.dim, c.valueDim, wB, b.att, b.xb, 0);
        Qwen3.addInto(b.x, b.xb);
    }

    /// @notice Head prep (§5.3) + delta-rule step (§5.4) for v-head `h`
    /// @dev s.small holds expA (nVH int32 Q24) || dtBias (nVH int32 Q24).
    ///      q/k of k-head `kh` are copied per v-head, l2-normed AFTER the
    ///      repeat_interleave (results identical per spec note), q scaled by
    ///      1/sqrt(dK) in Q32.
    function _deltaHead(Config memory c, Store memory s, Buffers memory b, uint256 linIdx, uint256 h, uint256 kh)
        private
        pure
    {
        uint256 dK = c.dK;
        for (uint256 i = 0; i < dK; ++i) {
            b.qh[i] = b.qkv[kh * dK + i];
            b.kh[i] = b.qkv[c.keyDim + kh * dK + i];
        }
        l2normSlice(b.qh, 0, dK, c.epsQ48);
        l2normSlice(b.kh, 0, dK, c.epsQ48);
        int256 invS = int256(c.invSqrtDk);
        for (uint256 i = 0; i < dK; ++i) {
            b.qh[i] = (b.qh[i] * invS) >> 32;
        }
        DeltaParams memory p;
        p.beta = sigQ32(b.bg[h]); // Q32
        int256 sp = softplusQ24(b.ag[h] + _i32At(s.small, 4 * c.nVH + 4 * h)); // a + dtBias
        int256 gneg = (_i32At(s.small, 4 * h) * sp) >> 24; // expA * softplus, Q24 >= 0
        p.decay = LlamaMath.expQ32(-(gneg << 8)); // Q32 in (0, 2^32]
        p.sBase = (linIdx * c.nVH + h) * (dK * c.dV / 8);
        p.vOff = 2 * c.keyDim + h * c.dV;
        p.outOff = h * c.dV;
        p.dK = dK;
        p.dV = c.dV;
        deltaStep(b.sState, b.qh, b.kh, b.qkv, b.dv, b.att, p);
    }

    // ------------------------------------------------------ full attention

    /// @notice Rotate adjacent pairs in the FIRST `rot` dims of each head (§4.2)
    /// @dev tbl holds cosRow || sinRow (int32 Q30 each, rot/2 entries per row);
    ///      head stride is `hd`, only rot/2 pairs per head are rotated.
    function ropePartial(bytes memory tbl, int256[] memory arr, uint256 nHeads, uint256 hd, uint256 rot) internal pure {
        uint256 half = rot / 2;
        assembly ("memory-safe") {
            let cosP := add(tbl, 0x20)
            let sinP := add(cosP, shl(2, half))
            let ap := add(arr, 0x20)
            for { let h := 0 } lt(h, nHeads) { h := add(h, 1) } {
                for { let pi := 0 } lt(pi, half) { pi := add(pi, 1) } {
                    let cv := signextend(3, shr(224, mload(add(cosP, shl(2, pi)))))
                    let sv := signextend(3, shr(224, mload(add(sinP, shl(2, pi)))))
                    let i0 := add(ap, shl(5, add(mul(h, hd), shl(1, pi))))
                    let i1 := add(i0, 0x20)
                    let v0 := mload(i0)
                    let v1 := mload(i1)
                    mstore(i0, sar(30, sub(mul(v0, cv), mul(v1, sv))))
                    mstore(i1, sar(30, add(mul(v0, sv), mul(v1, cv))))
                }
            }
        }
    }

    /// @notice Store k/v (Q24) into the packed cache as int32 Q16 at position `pos`
    /// @param fullIdx The full-attention layer index (0..nLayers/fullInterval-1)
    function cacheStore(Config memory c, Buffers memory b, uint256 fullIdx, uint256 pos) internal pure {
        uint256 kvd = c.kvd;
        uint256 base = (fullIdx * b.maxPos + pos) * kvd; // element index, 8 per word
        int256[] memory k = b.k;
        int256[] memory v = b.v;
        uint256[] memory kC = b.kCache;
        uint256[] memory vC = b.vCache;
        assembly ("memory-safe") {
            let kp := add(k, 0x20)
            let vp := add(v, 0x20)
            let kcp := add(add(kC, 0x20), shl(2, base)) // base/8 words * 32 bytes
            let vcp := add(add(vC, 0x20), shl(2, base))
            for { let w := 0 } lt(w, div(kvd, 8)) { w := add(w, 1) } {
                let kw := 0
                let vw := 0
                for { let sIdx := 0 } lt(sIdx, 8) { sIdx := add(sIdx, 1) } {
                    let j := add(mul(w, 8), sIdx)
                    let k16 := and(sar(8, mload(add(kp, shl(5, j)))), 0xffffffff)
                    let v16 := and(sar(8, mload(add(vp, shl(5, j)))), 0xffffffff)
                    kw := or(kw, shl(sub(224, mul(32, sIdx)), k16))
                    vw := or(vw, shl(sub(224, mul(32, sIdx)), v16))
                }
                mstore(add(kcp, shl(5, w)), kw)
                mstore(add(vcp, shl(5, w)), vw)
            }
        }
    }

    /// @notice Gated attention for one full layer/position over the packed KV cache
    /// @dev q-block lives in b.qkv[0..qd), gate-block in b.qkv[qd..2qd); head
    ///      outputs land gated in b.z[0..qd).
    function attend(Config memory c, Buffers memory b, uint256 fullIdx, uint256 pos) internal pure {
        uint256 kvMul = c.nHeads / c.nKv;
        for (uint256 h = 0; h < c.nHeads; ++h) {
            _attendHead(c, b, fullIdx, h * c.headDim, (h / kvMul) * c.headDim, pos + 1);
        }
    }

    /// @dev scores_t = sar(sar(sum q*k16, 16) * invSqrtHd, 32); softmax via expQ24;
    ///      att_j = sdiv((sum e*v16) << 8, tot), then the sigmoid output gate:
    ///      out_j = sar(att_j * sigQ32(gate_j), 32) with gate_j = qkv[qd + qOff + j].
    function _attendHead(Config memory c, Buffers memory b, uint256 fullIdx, uint256 qOff, uint256 kvOff, uint256 steps)
        private
        pure
    {
        int256 mx = type(int256).min;
        uint256 kvd = c.kvd;
        {
            int256[] memory q = b.qkv;
            uint256[] memory kC = b.kCache;
            int256[] memory scores = b.scores;
            uint256 hd = c.headDim;
            int256 inv = int256(c.invSqrtHd);
            uint256 rowBase = fullIdx * b.maxPos * kvd + kvOff; // element index of t=0
            assembly ("memory-safe") {
                let qp := add(add(q, 0x20), shl(5, qOff))
                let sp := add(scores, 0x20)
                for { let t := 0 } lt(t, steps) { t := add(t, 1) } {
                    let eBase := add(rowBase, mul(t, kvd))
                    let acc := 0
                    for { let j := 0 } lt(j, hd) { j := add(j, 1) } {
                        let e := add(eBase, j)
                        let word := mload(add(add(kC, 0x20), shl(5, shr(3, e))))
                        let k16 := signextend(3, shr(sub(224, mul(32, and(e, 7))), word))
                        acc := add(acc, mul(mload(add(qp, shl(5, j))), k16))
                    }
                    let sc := sar(32, mul(sar(16, acc), inv))
                    mstore(add(sp, shl(5, t)), sc)
                    if sgt(sc, mx) { mx := sc }
                }
            }
        }
        uint256 tot = 0;
        {
            int256[] memory scores = b.scores;
            for (uint256 t = 0; t < steps; ++t) {
                uint256 e = LlamaMath.expQ32((scores[t] - mx) << 8) >> 8; // expQ24
                scores[t] = int256(e);
                tot += e;
            }
        }
        {
            int256[] memory scores = b.scores;
            uint256[] memory vC = b.vCache;
            int256[] memory xatt = b.z;
            uint256 hd = c.headDim;
            uint256 rowBase = fullIdx * b.maxPos * kvd + kvOff;
            assembly ("memory-safe") {
                let sp := add(scores, 0x20)
                let xp := add(add(xatt, 0x20), shl(5, qOff))
                for { let j := 0 } lt(j, hd) { j := add(j, 1) } {
                    let acc := 0
                    let e := add(rowBase, j)
                    for { let t := 0 } lt(t, steps) { t := add(t, 1) } {
                        let word := mload(add(add(vC, 0x20), shl(5, shr(3, e))))
                        let v16 := signextend(3, shr(sub(224, mul(32, and(e, 7))), word))
                        acc := add(acc, mul(mload(add(sp, shl(5, t))), v16))
                        e := add(e, kvd)
                    }
                    mstore(add(xp, shl(5, j)), sdiv(shl(8, acc), tot))
                }
            }
        }
        {
            int256[] memory qg = b.qkv;
            int256[] memory xatt = b.z;
            uint256 gBase = c.qd + qOff;
            uint256 hd = c.headDim;
            for (uint256 j = 0; j < hd; ++j) {
                xatt[qOff + j] = (xatt[qOff + j] * int256(sigQ32(qg[gBase + j]))) >> 32;
            }
        }
    }

    /// @notice Full-attention token mixer for one layer (§6); adds into b.x
    /// @dev `internal` for the sharded segment engine (Qwen35Seg); behaviour unchanged.
    function _attnBlock(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 l, uint256 pos)
        internal
        view
    {
        uint256 lb = layerOffset(c, o, l);
        uint256 fullIdx = (l + 1) / c.fullInterval - 1; // index among full layers
        uint256 wB = c.wBits;
        uint256 rowLen = 1 + c.dim * wB;
        loadRange(s, lb + o.oWqg, 2 * c.qd * rowLen, s.big, 0);
        Qwen3.matmulRows(s.big, 2 * c.qd, c.dim, wB, b.xb, b.qkv, 0);
        loadRange(s, lb + o.oWk, c.kvd * rowLen, s.big, 0);
        Qwen3.matmulRows(s.big, c.kvd, c.dim, wB, b.xb, b.k, 0);
        loadRange(s, lb + o.oWv, c.kvd * rowLen, s.big, 0);
        Qwen3.matmulRows(s.big, c.kvd, c.dim, wB, b.xb, b.v, 0);
        loadRange(s, lb + o.oQn, 1 + 2 * c.headDim, s.small, 0);
        _headNorm(c, s, b.qkv, c.nHeads, c.headDim);
        loadRange(s, lb + o.oKn, 1 + 2 * c.headDim, s.small, 0);
        _headNorm(c, s, b.k, c.nKv, c.headDim);
        ropePartial(s.rope, b.qkv, c.nHeads, c.headDim, c.rot);
        ropePartial(s.rope, b.k, c.nKv, c.headDim, c.rot);
        cacheStore(c, b, fullIdx, pos);
        attend(c, b, fullIdx, pos);
        loadRange(s, lb + o.oWo, c.dim * (1 + c.qd * wB), s.big, 0);
        Qwen3.matmulRows(s.big, c.dim, c.qd, wB, b.z, b.xb, 0);
        Qwen3.addInto(b.x, b.xb);
    }

    // ---------------------------------------------------------------- MoE

    /// @notice g[i] = silu(gu[i]) * gu[n+i] in place over the fused gate||up buffer
    function swigluSlice(int256[] memory gu, uint256 n) internal pure {
        for (uint256 i = 0; i < n; ++i) {
            int256 z = gu[i];
            int256 sz = (z * int256(sigQ32(z))) >> 32; // Q24
            gu[i] = (sz * gu[n + i]) >> 24;
        }
    }

    /// @notice Top-k over softmax numerators: k passes of strict argmax (§7)
    /// @dev First maximum wins (ties to the lowest index); selected entries are
    ///      replaced by -1 (all entries must be non-negative). idx/w are filled
    ///      in selection order with w_i = (e_i << 32) / tot.
    /// @return tot The sum of the selected numerators
    function selectTopK(int256[] memory e, uint256 k, uint256[] memory idx, uint256[] memory w)
        internal
        pure
        returns (uint256 tot)
    {
        uint256 n = e.length;
        for (uint256 t = 0; t < k; ++t) {
            int256 bestVal = -1;
            uint256 best = 0;
            for (uint256 i = 0; i < n; ++i) {
                if (e[i] > bestVal) {
                    bestVal = e[i];
                    best = i;
                }
            }
            idx[t] = best;
            w[t] = uint256(bestVal);
            e[best] = -1;
            tot += uint256(bestVal);
        }
        for (uint256 t = 0; t < k; ++t) {
            w[t] = (w[t] << 32) / tot;
        }
    }

    /// @notice Top-k SELECTION over raw (possibly negative) router logits (§7 rev 2)
    /// @dev k passes of strict `>` argmax directly on `rl` (first maximum wins, ties
    ///      to the lowest index); selected entries are excluded from later passes via
    ///      an explicit `taken` flag (rl may be negative, so -1/sentinel-in-place is
    ///      not usable here as it is in `selectTopK`). Does NOT touch `rl` or compute
    ///      softmax — see SPEC §7: selection is over raw logits, weights are computed
    ///      afterward only for the selected k.
    /// @param rl Router logits, Q24 (untouched)
    /// @param k Number of experts to select
    /// @param idx Output: selected expert ids, in selection order (highest first)
    function selectTopKIndices(int256[] memory rl, uint256 k, uint256[] memory idx) internal pure {
        uint256 n = rl.length;
        bool[] memory taken = new bool[](n);
        for (uint256 t = 0; t < k; ++t) {
            int256 bestVal = type(int256).min;
            uint256 best = 0;
            for (uint256 i = 0; i < n; ++i) {
                if (!taken[i] && rl[i] > bestVal) {
                    bestVal = rl[i];
                    best = i;
                }
            }
            idx[t] = best;
            taken[best] = true;
        }
    }

    /// @notice MoE block (§7 rev 2): shared expert + top-k-by-raw-logit routed
    ///         experts; adds into b.x. Input is b.xb (post-ln2).
    /// @dev `internal` for the sharded segment engine (Qwen35Seg); behaviour unchanged.
    function _moeBlock(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 tailBase)
        internal
        view
    {
        uint256 sg = _sharedExpert(c, o, s, b, tailBase);
        _routerSelect(c, o, s, b, tailBase);
        _routedExperts(c, o, s, b, tailBase);
        int256 sgi = int256(sg);
        int256[] memory x = b.x;
        int256[] memory moeAcc = b.moeAcc;
        int256[] memory shared = b.shared;
        for (uint256 j = 0; j < c.dim; ++j) {
            x[j] += moeAcc[j] + ((shared[j] * sgi) >> 32);
        }
    }

    /// @dev Shared expert: swiglu MLP into b.shared; returns its sigmoid gate (Q32)
    function _sharedExpert(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 tailBase)
        private
        view
        returns (uint256 sg)
    {
        uint256 wB = c.wBits;
        uint256 rowLen = 1 + c.dim * wB;
        loadRange(s, tailBase + o.tSharedGate, rowLen, s.big, 0);
        Qwen3.matmulRows(s.big, 1, c.dim, wB, b.xb, b.rl, 0);
        sg = sigQ32(b.rl[0]);
        loadRange(s, tailBase + o.tSharedGateUp, 2 * c.sharedDim * rowLen, s.big, 0);
        Qwen3.matmulRows(s.big, 2 * c.sharedDim, c.dim, wB, b.xb, b.gu, 0);
        swigluSlice(b.gu, c.sharedDim);
        loadRange(s, tailBase + o.tSharedDown, c.dim * (1 + c.sharedDim * wB), s.big, 0);
        Qwen3.matmulRows(s.big, c.dim, c.sharedDim, wB, b.gu, b.shared, 0);
    }

    /// @dev Router (§7 rev 2): int16 hi-precision rows (ALWAYS wBits=2, regardless of
    ///      the model's general wBits — SPEC §1/§3 "hi-precision rows"), top-k
    ///      SELECTION over the raw logits (not softmax numerators — selection-order
    ///      tie-breaks differ), softmax weights computed only for the selected k with
    ///      mx = rl[sel[0]] (the value at the globally-selected max, not a re-scan).
    function _routerSelect(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 tailBase)
        private
        view
    {
        loadRange(s, tailBase + o.tRouter, c.nExperts * (1 + 2 * c.dim), s.big, 0);
        Qwen3.matmulRows(s.big, c.nExperts, c.dim, 2, b.xb, b.rl, 0);
        int256[] memory rl = b.rl;
        uint256[] memory selIdx = b.selIdx;
        uint256 k = c.topK;
        selectTopKIndices(rl, k, selIdx);
        int256 mx = rl[selIdx[0]]; // == global max (first-selected is the argmax)
        uint256[] memory selW = b.selW;
        uint256 tot;
        for (uint256 t = 0; t < k; ++t) {
            uint256 ei = LlamaMath.expQ32((rl[selIdx[t]] - mx) << 8) >> 8; // expQ24
            selW[t] = ei;
            tot += ei;
        }
        for (uint256 t = 0; t < k; ++t) {
            selW[t] = (selW[t] << 32) / tot;
        }
    }

    /// @dev Routed experts in selection order: acc_j += sar(down(swiglu) * w, 32)
    function _routedExperts(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 tailBase)
        private
        view
    {
        uint256 wB = c.wBits;
        uint256 rowLen = 1 + c.dim * wB;
        int256[] memory moeAcc = b.moeAcc;
        for (uint256 j = 0; j < c.dim; ++j) {
            moeAcc[j] = 0;
        }
        for (uint256 t = 0; t < c.topK; ++t) {
            uint256 eb = tailBase + o.tExperts + b.selIdx[t] * o.expertLen;
            loadRange(s, eb, 2 * c.moeDim * rowLen, s.big, 0);
            Qwen3.matmulRows(s.big, 2 * c.moeDim, c.dim, wB, b.xb, b.gu, 0);
            swigluSlice(b.gu, c.moeDim);
            loadRange(s, eb + o.expertDownOff, c.dim * (1 + c.moeDim * wB), s.big, 0);
            Qwen3.matmulRows(s.big, c.dim, c.moeDim, wB, b.gu, b.y, 0);
            int256 wq = int256(b.selW[t]);
            int256[] memory y = b.y;
            for (uint256 j = 0; j < c.dim; ++j) {
                moeAcc[j] += (y[j] * wq) >> 32;
            }
        }
    }

    // -------------------------------------------------------- forward pass

    /// @notice One transformer pass; leaves the final normed hidden state in b.xb.
    ///         The classifier is NOT run here — callers invoke argmaxClassifier only
    ///         at generating positions, so teacher-forced prefill never streams the
    ///         509MB untied classifier.
    /// @param c The config
    /// @param o The layout
    /// @param s The chunked store
    /// @param b The buffers (KV cache, conv state and S persist across calls)
    /// @param token The current token id
    /// @param pos The current position
    function forward(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 token, uint256 pos)
        internal
        view
    {
        _loadEmbedding(c, o, s, token, b.x);
        // this position's rope rows (cos || sin), rot/2 int32 entries each
        uint256 half = c.rot / 2;
        loadRange(s, o.ropeCosOff + pos * half * 4, half * 4, s.rope, 0);
        loadRange(s, o.ropeSinOff + pos * half * 4, half * 4, s.rope, half * 4);

        for (uint256 l = 0; l < c.nLayers; ++l) {
            uint256 lb = layerOffset(c, o, l);
            _normInto(c, s, b, lb); // ln1
            uint256 tailBase;
            if ((l + 1) % c.fullInterval == 0) {
                _attnBlock(c, o, s, b, l, pos);
                tailBase = lb + o.fullTail;
            } else {
                _deltaBlock(c, o, s, b, l);
                tailBase = lb + o.linTail;
            }
            _normInto(c, s, b, tailBase); // ln2 at tail start
            _moeBlock(c, o, s, b, tailBase);
        }

        _normInto(c, s, b, o.normOff); // finalNorm
    }

    /// @dev Stream the norm tensor at blob offset `off` and rmsnorm b.x into b.xb
    /// @dev `internal` for the sharded segment engine (Qwen35Seg); behaviour unchanged.
    function _normInto(Config memory c, Store memory s, Buffers memory b, uint256 off) internal view {
        loadRange(s, off, 1 + 2 * c.dim, s.small, 0);
        Qwen3.rmsnormSlice(s.small, b.x, 0, b.xb, 0, c.dim, c.epsQ48);
    }

    /// @dev Per-head RMSNorm in place over `stride`-sized heads with the streamed
    ///      norm weights in s.small
    function _headNorm(Config memory c, Store memory s, int256[] memory arr, uint256 heads, uint256 stride)
        private
        pure
    {
        for (uint256 h = 0; h < heads; ++h) {
            Qwen3.rmsnormSlice(s.small, arr, h * stride, arr, h * stride, stride, c.epsQ48);
        }
    }

    /// @notice Streaming untied-classifier argmax: CLS_SLICE lmHead rows at a time
    function argmaxClassifier(Config memory c, Layout memory o, Store memory s, int256[] memory xb)
        internal
        view
        returns (uint256 best)
    {
        int256 bestVal = type(int256).min;
        uint256 stride = 1 + c.dim * c.wBits;
        int256[] memory sliceOut = new int256[](CLS_SLICE);
        for (uint256 row = 0; row < c.vocab; row += CLS_SLICE) {
            uint256 rows = c.vocab - row;
            if (rows > CLS_SLICE) rows = CLS_SLICE;
            loadRange(s, o.lmHeadOff + row * stride, rows * stride, s.big, 0);
            Qwen3.matmulRows(s.big, rows, c.dim, c.wBits, xb, sliceOut, 0);
            for (uint256 i = 0; i < rows; ++i) {
                if (sliceOut[i] > bestVal) {
                    bestVal = sliceOut[i];
                    best = row + i;
                }
            }
        }
    }

    /// @notice Full logits for tests/inspection (materializes vocab-sized array)
    function logits(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 token, uint256 pos)
        internal
        view
        returns (int256[] memory out)
    {
        forward(c, o, s, b, token, pos);
        out = new int256[](c.vocab);
        uint256 stride = 1 + c.dim * c.wBits;
        for (uint256 row = 0; row < c.vocab; row += CLS_SLICE) {
            uint256 rows = c.vocab - row;
            if (rows > CLS_SLICE) rows = CLS_SLICE;
            loadRange(s, o.lmHeadOff + row * stride, rows * stride, s.big, 0);
            Qwen3.matmulRows(s.big, rows, c.dim, c.wBits, b.xb, out, row);
        }
    }

    /// @notice Greedy generation from pre-tokenized prompt ids
    /// @param c The config
    /// @param s The chunked store
    /// @param promptIds The prompt token ids (chat template applied off-chain)
    /// @param maxNew Upper bound on new tokens (clamped to seqCap - promptLen)
    /// @return genIds The generated token ids
    function generate(Config memory c, Store memory s, uint32[] memory promptIds, uint256 maxNew)
        internal
        view
        returns (uint32[] memory genIds)
    {
        Layout memory o = layout(c);
        uint256 pLen = promptIds.length;
        if (pLen == 0 || pLen >= c.seqCap) revert ContextOverflow();
        for (uint256 i = 0; i < pLen; ++i) {
            if (promptIds[i] >= c.vocab) revert BadToken();
        }
        uint256 maxPos = pLen + maxNew;
        if (maxPos > c.seqCap) maxPos = c.seqCap;

        Buffers memory b = newBuffers(c, maxPos);
        genIds = new uint32[](maxPos - pLen);
        uint256 nGen = 0;

        uint256 token = promptIds[0];
        for (uint256 pos = 0; pos + 1 < maxPos; ++pos) {
            forward(c, o, s, b, token, pos);
            uint256 next;
            if (pos + 1 < pLen) {
                next = promptIds[pos + 1];
            } else {
                next = argmaxClassifier(c, o, s, b.xb);
                genIds[nGen++] = uint32(next);
                if (next == c.stop0 || next == c.stop1) break;
            }
            token = next;
        }
        assembly ("memory-safe") {
            mstore(genIds, nGen)
        }
    }

    // ------------------------------------------------------------- helpers

    /// @notice x[i] = embedding row value scaled to Q24 (row shift <= 24)
    /// @dev `internal` for the sharded segment engine (Qwen35Seg); behaviour unchanged.
    function _loadEmbedding(Config memory c, Layout memory o, Store memory s, uint256 token, int256[] memory x)
        internal
        view
    {
        loadRange(s, token * o.embRowStride, o.embRowStride, s.big, 0);
        bytes memory buf = s.big;
        uint256 dim = c.dim;
        uint256 wB = c.wBits;
        assembly ("memory-safe") {
            let shift := shr(248, mload(add(buf, 0x20)))
            let up := sub(24, shift)
            let wp := add(buf, 0x21)
            let xp := add(x, 0x20)
            switch wB
            case 1 {
                for { let i := 0 } lt(i, dim) { i := add(i, 1) } {
                    let v := signextend(0, shr(248, mload(add(wp, i))))
                    mstore(add(xp, shl(5, i)), shl(up, v))
                }
            }
            default {
                for { let i := 0 } lt(i, dim) { i := add(i, 1) } {
                    let v := signextend(1, shr(240, mload(add(wp, shl(1, i)))))
                    mstore(add(xp, shl(5, i)), shl(up, v))
                }
            }
        }
    }

    /// @notice Read a big-endian int32 at byte `off`
    function _i32At(bytes memory data, uint256 off) private pure returns (int256 v) {
        assembly ("memory-safe") {
            v := signextend(3, shr(224, mload(add(add(data, 0x20), off))))
        }
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }
}

// src/examples/onchain-llm/Qwen35Seg.sol

/// @title Qwen35Seg
/// @notice Sharded-inference segment logic over the engine-v3 (Qwen3.5-35B-A3B)
///         HYBRID kernels. One inference is split into hash-committed segments — a
///         rectangle of positions [posLo, posHi) x layers [layerLo, layerHi) — that
///         execute independently (different processes/nodes) and reassemble
///         bit-exactly. NOTHING numeric is reimplemented here: every segment replays
///         the exact monolithic code paths (Qwen35._attnBlock / _deltaBlock /
///         _moeBlock / _normInto / _loadEmbedding, Qwen3.rmsnormSlice / matmulRows),
///         so bit-exactness is inherited, not re-proven.
/// @dev  THE HYBRID DIFFERENCE vs the 0.6B dense engine (Qwen3Seg): the wire-format
///       state threaded between segments is layer-TYPE dependent, not KV-only —
///
///       * FULL-ATTENTION layers (l with (l+1) % fullInterval == 0): a standard KV
///         cache (int32 Q16, 8 per 32-byte word, big-endian lanes), position-indexed
///         exactly as Qwen3Seg — carried per-position [0, posLo) in and [posLo, posHi)
///         out (append semantics).
///       * DeltaNet layers (all others): the RECURRENT state — the causal-conv state
///         C (SPEC §5.2) and the delta-rule state S (SPEC §5.4) — a single SNAPSHOT
///         that is mutated in place per position. It is carried as "state after
///         positions [0, posLo)" in and "state after [0, posHi)" out (replace
///         semantics). DeltaNet has no position dependence (no RoPE), so the snapshot
///         depends only on how many positions have been folded in, not on maxPos.
///       * MoE is stateless per token (the router selects experts deterministically
///         from the layer input); it carries no wire-format state.
///
///       ---------------------------------------------------------------------------
///       STATE WIRE FORMAT (canonical, deterministic, layer-major).
///
///       `stateIn` — the resume state, context = positions [0, posLo):
///         * If posLo == 0: EMPTY (0 bytes). All recurrent/KV state is fresh-zero, so
///           nothing is carried (mirrors "kvIn empty when posLo == 0" in the 0.6B and
///           "xIn empty when layerLo == 0").
///         * If posLo  > 0:
///             for l in [layerLo, layerHi):
///               if FULL(l):
///                 K slice, positions [0, posLo)   (posLo * kvd * 4 bytes)
///                 V slice, positions [0, posLo)   (posLo * kvd * 4 bytes)
///               if DeltaNet(l):
///                 conv snapshot after [0, posLo)  ((convK-1) * convDim * 4 bytes)
///                 S    snapshot after [0, posLo)  (nVH * dK * dV * 4 bytes)
///
///       `stateAppend` — the result state produced by this segment (always present):
///             for l in [layerLo, layerHi):
///               if FULL(l):
///                 K slice, positions [posLo, posHi)   ((posHi-posLo) * kvd * 4 bytes)
///                 V slice, positions [posLo, posHi)   ((posHi-posLo) * kvd * 4 bytes)
///               if DeltaNet(l):
///                 conv snapshot after [0, posHi)      ((convK-1) * convDim * 4 bytes)
///                 S    snapshot after [0, posHi)      (nVH * dK * dV * 4 bytes)
///
///       A driver threads state per absolute layer: for FULL layers it ACCUMULATES the
///       KV append (concatenate, exactly as the 0.6B), for DeltaNet layers it REPLACES
///       the running snapshot with the append. Every packed run — KV slices, conv and
///       S snapshots — is a verbatim word-for-word copy of the packed words the
///       monolithic engine holds (int32 Q16, 8 per word), so hydration is a straight
///       copy into the same word positions the monolithic run occupies, provided the
///       SAME maxPos is pinned across every segment of a run (the KV stride bakes it
///       in; DeltaNet snapshots are maxPos-independent).
///
///       Segment checkpoint commitment:
///         chk = keccak256(abi.encodePacked(
///             "gaskiller.seg35.v1", posLo, posHi, layerLo, layerHi,
///             keccak256(abi.encodePacked(tokenIds)),
///             keccak256(xIn), keccak256(stateIn),
///             keccak256(xOut), keccak256(stateAppend)))
library Qwen35Seg {
    /// @notice Domain separator for engine-v3 segment checkpoint commitments
    /// @dev Distinct from the 0.6B's "gaskiller.seg.v1" so cross-model commitments
    ///      can never collide.
    string internal constant CHK_DOMAIN = "gaskiller.seg35.v1";

    /// @notice Thrown when the segment rectangle is empty or out of bounds
    error BadRange();

    /// @notice Thrown when tokenIds/xIn/stateIn lengths don't match the rectangle
    error BadSegmentInput();

    /// @notice A segment rectangle: positions [posLo, posHi) x layers [layerLo, layerHi)
    /// @dev maxPos is the KV-cache stride of the WHOLE run and must be identical across
    ///      every segment of that run (see the wire-format note above).
    struct Span {
        uint256 maxPos;
        uint256 posLo;
        uint256 posHi;
        uint256 layerLo;
        uint256 layerHi;
    }

    /// @notice A full segment request (grouped to keep legacy-codegen stack pressure
    ///         low in external facades — see the unroll/stack hazard notes in Qwen35)
    /// @dev expectXIn / expectStateIn are optional integrity witnesses: when nonzero
    ///      the facade requires keccak256(xIn) / keccak256(stateIn) to match first.
    struct Call {
        Span span;
        uint32[] tokenIds;
        bytes xIn;
        bytes stateIn;
        bytes32 expectXIn;
        bytes32 expectStateIn;
    }

    /// @dev Bundled segment-execution context (single stack slot under legacy codegen)
    struct Ctx {
        Qwen35.Config c;
        Qwen35.Layout o;
        Qwen35.Store s;
        Qwen35.Buffers b;
        Span r;
        uint32[] tokenIds;
        bytes xIn;
        bytes xOut;
    }

    /// @notice Process positions [posLo, posHi) through layers [layerLo, layerHi) in
    ///         the exact order the monolithic loop would (position-major), dispatching
    ///         each layer to its kernel (DeltaNet vs full attention), then the MoE tail.
    /// @param c The config
    /// @param s The chunked store
    /// @param r The segment rectangle (+ pinned maxPos stride)
    /// @param tokenIds Token ids for the processed positions (required iff layerLo == 0)
    /// @param xIn If layerLo > 0: concat of (posHi-posLo) residual vectors entering
    ///        layerLo (int256[dim] raw words, 32*dim bytes each). Empty iff layerLo == 0.
    /// @param stateIn The resume state (see library natspec); empty iff posLo == 0
    /// @return xOut Concat of residual vectors leaving layerHi-1 per position; if
    ///         layerHi == nLayers the final rmsnorm is applied so each vector is the
    ///         b.xb-equivalent that feeds the classifier directly
    /// @return stateAppend This layer range's produced state (see library natspec)
    /// @dev Input validation (`validate`) and the checkpoint commitment (`segmentChk`)
    ///      are deliberately NOT done here: the facade (Qwen35SegEngine) performs both
    ///      at the trust boundary, keeping this — the heaviest inlined code path (three
    ///      hybrid token-mixer kernels + MoE) — under EIP-170 in its own contract.
    function forwardRange(
        Qwen35.Config memory c,
        Qwen35.Store memory s,
        Span memory r,
        uint32[] memory tokenIds,
        bytes memory xIn,
        bytes memory stateIn
    ) internal view returns (bytes memory xOut, bytes memory stateAppend) {
        Ctx memory t;
        t.c = c;
        t.o = Qwen35.layout(c);
        t.s = s;
        t.b = Qwen35.newBuffers(c, r.maxPos);
        t.r = r;
        t.tokenIds = tokenIds;
        t.xIn = xIn;
        hydrateState(c, t.b, r, stateIn);
        _processPositions(t);
        xOut = t.xOut;
        stateAppend = serializeState(c, t.b, r);
    }

    /// @notice The untied-classifier argmax restricted to rows [vocabLo, vocabHi)
    /// @dev Replays argmaxClassifier's slice-streaming loop with its exact first-max-
    ///      wins semantics (strict `>` over ascending rows). MERGE RULE for shards:
    ///      compare (score, id) — higher score wins; on equal score the LOWER id wins.
    ///      Because each shard scans ascending rows with strict `>`, merging ascending
    ///      disjoint shards under this rule reproduces the monolithic first-max-wins
    ///      result exactly.
    /// @param c The config
    /// @param s The chunked store
    /// @param xb The final normed hidden state (a last-stage xOut vector)
    /// @param vocabLo First classifier row (inclusive)
    /// @param vocabHi Last classifier row (exclusive)
    /// @return bestScore The maximum logit over the range
    /// @return bestId The first row attaining it (lowest id on ties)
    function argmaxRange(
        Qwen35.Config memory c,
        Qwen35.Store memory s,
        int256[] memory xb,
        uint256 vocabLo,
        uint256 vocabHi
    ) internal view returns (int256 bestScore, uint256 bestId) {
        Qwen35.Layout memory o = Qwen35.layout(c);
        if (vocabLo >= vocabHi || vocabHi > c.vocab) revert BadRange();
        if (xb.length != c.dim) revert BadSegmentInput();
        bestScore = type(int256).min;
        bestId = vocabLo;
        uint256 stride = 1 + c.dim * c.wBits;
        int256[] memory sliceOut = new int256[](Qwen35.CLS_SLICE);
        for (uint256 row = vocabLo; row < vocabHi; row += Qwen35.CLS_SLICE) {
            uint256 rows = vocabHi - row;
            if (rows > Qwen35.CLS_SLICE) rows = Qwen35.CLS_SLICE;
            Qwen35.loadRange(s, o.lmHeadOff + row * stride, rows * stride, s.big, 0);
            Qwen3.matmulRows(s.big, rows, c.dim, c.wBits, xb, sliceOut, 0);
            for (uint256 i = 0; i < rows; ++i) {
                if (sliceOut[i] > bestScore) {
                    bestScore = sliceOut[i];
                    bestId = row + i;
                }
            }
        }
    }

    /// @notice Compute the segment checkpoint commitment
    /// @dev Binds `tokenIds` so layer-0 segments commit their claimed token inputs, not
    ///      only their outputs — an audit/challenge protocol can then falsify a segment
    ///      from the commitment alone, without carrying the claimed prompt out-of-band.
    function segmentChk(
        Span memory r,
        uint32[] memory tokenIds,
        bytes memory xIn,
        bytes memory stateIn,
        bytes memory xOut,
        bytes memory stateAppend
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                CHK_DOMAIN,
                r.posLo,
                r.posHi,
                r.layerLo,
                r.layerHi,
                keccak256(abi.encodePacked(tokenIds)),
                keccak256(xIn),
                keccak256(stateIn),
                keccak256(xOut),
                keccak256(stateAppend)
            )
        );
    }

    /// @notice Hydrate the wire-format resume state into freshly allocated buffers
    /// @dev Writes into the exact word positions the monolithic run would occupy. When
    ///      posLo == 0 the state is fresh-zero, so stateIn must be empty and nothing is
    ///      copied (newBuffers already zero-initialises the caches / conv / S state).
    function hydrateState(Qwen35.Config memory c, Qwen35.Buffers memory b, Span memory r, bytes memory stateIn)
        internal
        pure
    {
        if (r.layerLo >= r.layerHi || r.layerHi > c.nLayers || r.posLo > b.maxPos) revert BadRange();
        if (r.posLo == 0) {
            if (stateIn.length != 0) revert BadSegmentInput();
            return;
        }
        uint256 kvWords = r.posLo * c.kvd / 8; // words per K (or V) slice
        uint256 convWords = (c.convK - 1) * c.convDim / 8;
        uint256 sWords = c.nVH * c.dK * c.dV / 8;
        uint256 off = 0;
        for (uint256 l = r.layerLo; l < r.layerHi; ++l) {
            if (_isFull(c, l)) {
                uint256 dstWord = _fullIdx(c, l) * b.maxPos * c.kvd / 8;
                _copyBytesToWords(stateIn, off, b.kCache, dstWord, kvWords);
                off += kvWords * 32;
                _copyBytesToWords(stateIn, off, b.vCache, dstWord, kvWords);
                off += kvWords * 32;
            } else {
                uint256 li = _linIdx(c, l);
                _copyBytesToWords(stateIn, off, b.convState, li * convWords, convWords);
                off += convWords * 32;
                _copyBytesToWords(stateIn, off, b.sState, li * sWords, sWords);
                off += sWords * 32;
            }
        }
        if (off != stateIn.length) revert BadSegmentInput();
    }

    /// @notice Serialize the produced state for layers [layerLo, layerHi) into the
    ///         canonical wire format (KV append for full layers, snapshot for DeltaNet)
    function serializeState(Qwen35.Config memory c, Qwen35.Buffers memory b, Span memory r)
        internal
        pure
        returns (bytes memory out)
    {
        if (r.layerLo >= r.layerHi || r.layerHi > c.nLayers || r.posLo >= r.posHi || r.posHi > b.maxPos) {
            revert BadRange();
        }
        uint256 kvWords = (r.posHi - r.posLo) * c.kvd / 8;
        uint256 convWords = (c.convK - 1) * c.convDim / 8;
        uint256 sWords = c.nVH * c.dK * c.dV / 8;
        out = new bytes(_stateAppendLen(c, r));
        uint256 off = 0;
        for (uint256 l = r.layerLo; l < r.layerHi; ++l) {
            if (_isFull(c, l)) {
                uint256 srcWord = (_fullIdx(c, l) * b.maxPos + r.posLo) * c.kvd / 8;
                _copyWordsToBytes(b.kCache, srcWord, out, off, kvWords);
                off += kvWords * 32;
                _copyWordsToBytes(b.vCache, srcWord, out, off, kvWords);
                off += kvWords * 32;
            } else {
                uint256 li = _linIdx(c, l);
                _copyWordsToBytes(b.convState, li * convWords, out, off, convWords);
                off += convWords * 32;
                _copyWordsToBytes(b.sState, li * sWords, out, off, sWords);
                off += sWords * 32;
            }
        }
    }

    /// @notice Byte length of the canonical `stateIn` for a rectangle (0 iff posLo == 0)
    function stateInLen(Qwen35.Config memory c, Span memory r) internal pure returns (uint256 len) {
        if (r.posLo == 0) return 0;
        for (uint256 l = r.layerLo; l < r.layerHi; ++l) {
            if (_isFull(c, l)) len += 2 * r.posLo * c.kvd * 4;
            else len += (c.convK - 1) * c.convDim * 4 + c.nVH * c.dK * c.dV * 4;
        }
    }

    /// @notice Byte length of the canonical `stateAppend` for a rectangle
    function _stateAppendLen(Qwen35.Config memory c, Span memory r) private pure returns (uint256 len) {
        uint256 pc = r.posHi - r.posLo;
        for (uint256 l = r.layerLo; l < r.layerHi; ++l) {
            if (_isFull(c, l)) len += 2 * pc * c.kvd * 4;
            else len += (c.convK - 1) * c.convDim * 4 + c.nVH * c.dK * c.dV * 4;
        }
    }

    /// @notice Decode a raw-words byte blob (32*dim bytes) into an int256[dim] vector
    function bytesToVec(bytes memory blob, uint256 dim) internal pure returns (int256[] memory xb) {
        if (blob.length != dim * 32) revert BadSegmentInput();
        xb = new int256[](dim);
        _copyBytesToWords(blob, 0, _asWords(xb), 0, dim);
    }

    // ------------------------------------------------------------ internals

    /// @dev True iff layer `l` is a full-attention layer (SPEC §0)
    function _isFull(Qwen35.Config memory c, uint256 l) private pure returns (bool) {
        return (l + 1) % c.fullInterval == 0;
    }

    /// @dev Index of full-attention layer `l` among full-attention layers
    function _fullIdx(Qwen35.Config memory c, uint256 l) private pure returns (uint256) {
        return (l + 1) / c.fullInterval - 1;
    }

    /// @dev Index of DeltaNet layer `l` among linear layers
    function _linIdx(Qwen35.Config memory c, uint256 l) private pure returns (uint256) {
        return l - l / c.fullInterval;
    }

    /// @dev Position-major replay of the monolithic loop restricted to the rectangle
    function _processPositions(Ctx memory t) private view {
        t.xOut = new bytes((t.r.posHi - t.r.posLo) * t.c.dim * 32);
        uint256 half = t.c.rot / 2;
        for (uint256 pos = t.r.posLo; pos < t.r.posHi; ++pos) {
            uint256 rel = pos - t.r.posLo;
            if (t.r.layerLo == 0) {
                Qwen35._loadEmbedding(t.c, t.o, t.s, t.tokenIds[rel], t.b.x);
            } else {
                _copyBytesToWords(t.xIn, rel * t.c.dim * 32, _asWords(t.b.x), 0, t.c.dim);
            }
            // this position's RoPE rows (cos || sin), rot/2 int32 entries each — loaded
            // exactly as Qwen35.forward does (harmless if the range has no full layer)
            Qwen35.loadRange(t.s, t.o.ropeCosOff + pos * half * 4, half * 4, t.s.rope, 0);
            Qwen35.loadRange(t.s, t.o.ropeSinOff + pos * half * 4, half * 4, t.s.rope, half * 4);
            _processLayers(t, pos);
            if (t.r.layerHi == t.c.nLayers) {
                // final stage: apply the model-final rmsnorm so xOut feeds argmax directly
                Qwen35._normInto(t.c, t.s, t.b, t.o.normOff);
                _copyWordsToBytes(_asWords(t.b.xb), 0, t.xOut, rel * t.c.dim * 32, t.c.dim);
            } else {
                _copyWordsToBytes(_asWords(t.b.x), 0, t.xOut, rel * t.c.dim * 32, t.c.dim);
            }
        }
    }

    /// @dev One position through layers [layerLo, layerHi): ln1, token mixer (dispatch),
    ///      ln2, MoE — the exact monolithic per-layer sequence (Qwen35.forward).
    function _processLayers(Ctx memory t, uint256 pos) private view {
        for (uint256 l = t.r.layerLo; l < t.r.layerHi; ++l) {
            uint256 lb = Qwen35.layerOffset(t.c, t.o, l);
            Qwen35._normInto(t.c, t.s, t.b, lb); // ln1
            uint256 tailBase;
            if (_isFull(t.c, l)) {
                Qwen35._attnBlock(t.c, t.o, t.s, t.b, l, pos);
                tailBase = lb + t.o.fullTail;
            } else {
                Qwen35._deltaBlock(t.c, t.o, t.s, t.b, l);
                tailBase = lb + t.o.linTail;
            }
            Qwen35._normInto(t.c, t.s, t.b, tailBase); // ln2 at tail start
            Qwen35._moeBlock(t.c, t.o, t.s, t.b, tailBase);
        }
    }

    /// @notice Rectangle + input-length validation (called by the facade before the
    ///         forward-pass STATICCALL, so the heavy forward contract stays EIP-170)
    function validate(
        Qwen35.Config memory c,
        Span memory r,
        uint32[] memory tokenIds,
        bytes memory xIn,
        bytes memory stateIn
    ) internal pure {
        if (r.layerLo >= r.layerHi || r.layerHi > c.nLayers) revert BadRange();
        if (r.posLo >= r.posHi || r.posHi > r.maxPos || r.maxPos > c.seqCap) revert BadRange();
        uint256 n = r.posHi - r.posLo;
        if (r.layerLo == 0) {
            if (tokenIds.length != n || xIn.length != 0) revert BadSegmentInput();
            for (uint256 i = 0; i < n; ++i) {
                if (tokenIds[i] >= c.vocab) revert BadSegmentInput();
            }
        } else {
            if (xIn.length != n * c.dim * 32) revert BadSegmentInput();
        }
        if (stateIn.length != stateInLen(c, r)) revert BadSegmentInput();
    }

    /// @dev Reinterpret an int256[] as uint256[] (identical memory layout)
    function _asWords(int256[] memory a) private pure returns (uint256[] memory w) {
        assembly ("memory-safe") {
            w := a
        }
    }

    /// @dev Copy `nWords` 32-byte words from a byte blob into a word array
    function _copyBytesToWords(bytes memory src, uint256 srcOff, uint256[] memory dst, uint256 dstWord, uint256 nWords)
        private
        pure
    {
        require(srcOff + nWords * 32 <= src.length, "src overrun");
        require(dstWord + nWords <= dst.length, "dst overrun");
        assembly ("memory-safe") {
            let sp := add(add(src, 0x20), srcOff)
            let dp := add(add(dst, 0x20), shl(5, dstWord))
            for { let i := 0 } lt(i, nWords) { i := add(i, 1) } {
                mstore(add(dp, shl(5, i)), mload(add(sp, shl(5, i))))
            }
        }
    }

    /// @dev Copy `nWords` 32-byte words from a word array into a byte blob
    function _copyWordsToBytes(uint256[] memory src, uint256 srcWord, bytes memory dst, uint256 dstOff, uint256 nWords)
        private
        pure
    {
        require(srcWord + nWords <= src.length, "src overrun");
        require(dstOff + nWords * 32 <= dst.length, "dst overrun");
        assembly ("memory-safe") {
            let sp := add(add(src, 0x20), shl(5, srcWord))
            let dp := add(add(dst, 0x20), dstOff)
            for { let i := 0 } lt(i, nWords) { i := add(i, 1) } {
                mstore(add(dp, shl(5, i)), mload(add(sp, shl(5, i))))
            }
        }
    }
}
