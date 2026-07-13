// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {LlamaMath} from "./LlamaMath.sol";

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
