// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {LlamaMath} from "./LlamaMath.sol";
import {LlamaTokenizer} from "./LlamaTokenizer.sol";

/// @title Llama2
/// @notice A from-scratch, integer-only Llama-2-architecture forward pass in pure
///         Solidity: RMSNorm, RoPE, grouped-query attention, SwiGLU FFN and greedy
///         decoding — the full llama2.c `forward()`/`generate()` ported to Q32
///         fixed-point EVM arithmetic.
/// @dev Weight blob layout (produced by tools/convert.py; all big-endian):
///        int16 tensors in run.c order — tokEmb[vocab*dim], rmsAtt[L*dim],
///        wq[L*dim*dim], wk[L*dim*kvd], wv[L*dim*kvd], wo[L*dim*dim], rmsFfn[L*dim],
///        w1[L*dim*hidden], w2[L*hidden*dim], w3[L*dim*hidden], rmsFinal[dim] —
///        then int32 Q30 RoPE tables ropeCos/ropeSin[seqLen*hs/2] and, only when the
///        classifier is unshared, int16 wcls[vocab*dim].
///      Each int16 tensor T carries a per-tensor power-of-two scale (config shift sT):
///      real value = int16 / 2^sT. Activations are Q32 in one int256 word each.
///      Every operation mirrors tools/reference.py bit-for-bit.
library Llama2 {
    using LlamaTokenizer for LlamaTokenizer.Tok;

    /// @notice RMSNorm epsilon: round(1e-5 * 2^32), added in Q64
    int256 internal constant EPS_Q64 = int256(42950) << 32;

    /// @notice Model hyperparameters and quantization shifts, unpacked from 3 words
    struct Config {
        uint256 dim;
        uint256 hidden;
        uint256 nLayers;
        uint256 nHeads;
        uint256 nKv;
        uint256 vocab;
        uint256 seqLen;
        uint256 hs;
        uint256 kvd;
        bool sharedCls;
        uint256 sTokEmb;
        uint256 sRmsAtt;
        uint256 sWq;
        uint256 sWk;
        uint256 sWv;
        uint256 sWo;
        uint256 sRmsFfn;
        uint256 sW1;
        uint256 sW2;
        uint256 sW3;
        uint256 sRmsFinal;
        uint256 sWcls;
        uint256 invSqrtHs;
        uint256 weightLen;
        uint256 tokLen;
    }

    /// @notice Byte offsets of each tensor within the weight blob
    struct Layout {
        uint256 tokEmb;
        uint256 rmsAtt;
        uint256 wq;
        uint256 wk;
        uint256 wv;
        uint256 wo;
        uint256 rmsFfn;
        uint256 w1;
        uint256 w2;
        uint256 w3;
        uint256 rmsFinal;
        uint256 ropeCos;
        uint256 ropeSin;
        uint256 wcls;
    }

    /// @notice Scratch memory for one generation run
    struct Buffers {
        int256[] x; // residual stream, dim
        int256[] xb; // normed input, dim
        int256[] q; // query, dim
        int256[] k; // key, kvd
        int256[] v; // value, kvd
        int256[] xatt; // attention output, dim
        int256[] xo; // projected output, dim
        int256[] h1; // FFN gate (reused for silu(h1)*h3), hidden
        int256[] h3; // FFN up, hidden
        int256[] logits; // vocab
        int256[] kCache; // nLayers * maxPos * kvd
        int256[] vCache; // nLayers * maxPos * kvd
        int256[] scores; // attention scores then weights, maxPos
        uint256 maxPos;
    }

    /// @notice Thrown when the packed config is inconsistent with the blob length
    error BadConfig();

    /// @notice Thrown when the prompt alone reaches the model's sequence length
    error PromptTooLong();

    /// @notice Unpack the 3-word packed config emitted by tools/convert.py
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
        c.vocab = (w0 >> 184) & 0xffff;
        c.seqLen = (w0 >> 168) & 0xffff;
        c.hs = (w0 >> 160) & 0xff;
        c.kvd = (w0 >> 144) & 0xffff;
        c.sharedCls = (w0 >> 136) & 0xff != 0;
        c.sTokEmb = w1 >> 248;
        c.sRmsAtt = (w1 >> 240) & 0xff;
        c.sWq = (w1 >> 232) & 0xff;
        c.sWk = (w1 >> 224) & 0xff;
        c.sWv = (w1 >> 216) & 0xff;
        c.sWo = (w1 >> 208) & 0xff;
        c.sRmsFfn = (w1 >> 200) & 0xff;
        c.sW1 = (w1 >> 192) & 0xff;
        c.sW2 = (w1 >> 184) & 0xff;
        c.sW3 = (w1 >> 176) & 0xff;
        c.sRmsFinal = (w1 >> 168) & 0xff;
        c.sWcls = (w1 >> 160) & 0xff;
        c.invSqrtHs = w2 >> 192;
        c.weightLen = (w2 >> 160) & 0xffffffff;
        c.tokLen = (w2 >> 128) & 0xffffffff;
        if (
            c.dim == 0 || c.hidden == 0 || c.nLayers == 0 || c.nHeads == 0 || c.nKv == 0 || c.vocab == 0
                || c.seqLen == 0 || c.nHeads % c.nKv != 0 || c.hs * c.nHeads != c.dim || c.kvd != c.hs * c.nKv
                || c.hs % 2 != 0 || c.sTokEmb > 32
        ) revert BadConfig();
    }

    /// @notice Compute tensor byte offsets for a config; validates total blob length
    /// @param c The config
    /// @return o The layout
    function layout(Config memory c) internal pure returns (Layout memory o) {
        uint256 L = c.nLayers;
        o.tokEmb = 0;
        o.rmsAtt = o.tokEmb + c.vocab * c.dim * 2;
        o.wq = o.rmsAtt + L * c.dim * 2;
        o.wk = o.wq + L * c.dim * c.dim * 2;
        o.wv = o.wk + L * c.dim * c.kvd * 2;
        o.wo = o.wv + L * c.dim * c.kvd * 2;
        o.rmsFfn = o.wo + L * c.dim * c.dim * 2;
        o.w1 = o.rmsFfn + L * c.dim * 2;
        o.w2 = o.w1 + L * c.dim * c.hidden * 2;
        o.w3 = o.w2 + L * c.hidden * c.dim * 2;
        o.rmsFinal = o.w3 + L * c.dim * c.hidden * 2;
        o.ropeCos = o.rmsFinal + c.dim * 2;
        o.ropeSin = o.ropeCos + c.seqLen * (c.hs / 2) * 4;
        uint256 end = o.ropeSin + c.seqLen * (c.hs / 2) * 4;
        if (c.sharedCls) {
            o.wcls = o.tokEmb;
        } else {
            o.wcls = end;
            end += c.vocab * c.dim * 2;
        }
        if (end != c.weightLen) revert BadConfig();
    }

    /// @notice Allocate scratch buffers for a run of at most `maxPos` positions
    /// @param c The config
    /// @param maxPos The number of sequence positions the run may touch
    /// @return b The buffers
    function newBuffers(Config memory c, uint256 maxPos) internal pure returns (Buffers memory b) {
        b.x = new int256[](c.dim);
        b.xb = new int256[](c.dim);
        b.q = new int256[](c.dim);
        b.k = new int256[](c.kvd);
        b.v = new int256[](c.kvd);
        b.xatt = new int256[](c.dim);
        b.xo = new int256[](c.dim);
        b.h1 = new int256[](c.hidden);
        b.h3 = new int256[](c.hidden);
        b.logits = new int256[](c.vocab);
        b.kCache = new int256[](c.nLayers * maxPos * c.kvd);
        b.vCache = new int256[](c.nLayers * maxPos * c.kvd);
        b.scores = new int256[](maxPos);
        b.maxPos = maxPos;
    }

    /// @notice One transformer forward pass; leaves next-token logits (Q32) in b.logits
    /// @param c The config
    /// @param o The tensor layout
    /// @param w The weight blob
    /// @param b The scratch buffers (KV cache persists across calls)
    /// @param token The current token id
    /// @param pos The current sequence position
    function forward(Config memory c, Layout memory o, bytes memory w, Buffers memory b, uint256 token, uint256 pos)
        internal
        pure
    {
        uint256 dim = c.dim;

        // token embedding -> Q32 residual stream
        _loadEmbedding(w, o.tokEmb + token * dim * 2, c.sTokEmb, b.x);

        for (uint256 l = 0; l < c.nLayers; ++l) {
            // attention block
            _rmsnorm(w, o.rmsAtt + l * dim * 2, c.sRmsAtt, b.x, b.xb);
            _matmul(w, o.wq + l * dim * dim * 2, b.xb, b.q, dim, c.sWq);
            _matmul(w, o.wk + l * dim * c.kvd * 2, b.xb, b.k, c.kvd, c.sWk);
            _matmul(w, o.wv + l * dim * c.kvd * 2, b.xb, b.v, c.kvd, c.sWv);
            _rope(w, o, b.q, c.nHeads, c.hs, pos);
            _rope(w, o, b.k, c.nKv, c.hs, pos);
            _attend(c, b, l, pos);
            _matmul(w, o.wo + l * dim * dim * 2, b.xatt, b.xo, dim, c.sWo);
            _addInto(b.x, b.xo);

            // FFN block: w2( silu(w1 x) * (w3 x) )
            _rmsnorm(w, o.rmsFfn + l * dim * 2, c.sRmsFfn, b.x, b.xb);
            _matmul(w, o.w1 + l * dim * c.hidden * 2, b.xb, b.h1, c.hidden, c.sW1);
            _matmul(w, o.w3 + l * dim * c.hidden * 2, b.xb, b.h3, c.hidden, c.sW3);
            _swiglu(b.h1, b.h3);
            _matmul(w, o.w2 + l * c.hidden * dim * 2, b.h1, b.xo, dim, c.sW2);
            _addInto(b.x, b.xo);
        }

        _rmsnorm(w, o.rmsFinal, c.sRmsFinal, b.x, b.xb);
        _matmul(w, o.wcls, b.xb, b.logits, c.vocab, c.sWcls);
    }

    /// @notice Greedy generation: encode prompt, run the model, decode the new tokens
    /// @dev Mirrors reference.py Model.generate: prompt tokens are teacher-forced, new
    ///      tokens picked by argmax (first maximum wins), generation stops on BOS/EOS.
    /// @param c The config
    /// @param w The weight blob
    /// @param tok The loaded tokenizer
    /// @param promptText The UTF-8 prompt
    /// @param maxNew Upper bound on newly generated tokens (clamped to seqLen)
    /// @return story The decoded generated bytes
    /// @return genIds The generated token ids
    function generate(
        Config memory c,
        bytes memory w,
        LlamaTokenizer.Tok memory tok,
        bytes memory promptText,
        uint256 maxNew
    ) internal pure returns (bytes memory story, uint16[] memory genIds) {
        Layout memory o = layout(c);
        uint16[] memory promptIds = tok.encode(promptText);
        if (promptIds.length >= c.seqLen) revert PromptTooLong();
        uint256 maxPos = promptIds.length + maxNew;
        if (maxPos > c.seqLen) maxPos = c.seqLen;

        Buffers memory b = newBuffers(c, maxPos);
        genIds = new uint16[](maxPos - promptIds.length);
        uint256 nGen = 0;

        uint256 token = promptIds[0];
        for (uint256 pos = 0; pos + 1 < maxPos; ++pos) {
            forward(c, o, w, b, token, pos);
            uint256 next;
            if (pos + 1 < promptIds.length) {
                next = promptIds[pos + 1];
            } else {
                next = _argmax(b.logits);
                genIds[nGen++] = uint16(next);
                if (next == LlamaTokenizer.BOS || next == LlamaTokenizer.EOS) break;
            }
            token = next;
        }

        assembly ("memory-safe") {
            mstore(genIds, nGen)
        }
        story = tok.decode(genIds, nGen, promptIds[promptIds.length - 1]);
    }

    /// @notice x[i] = int16 embedding value scaled up to Q32
    function _loadEmbedding(bytes memory w, uint256 off, uint256 shift, int256[] memory x) private pure {
        uint256 up = 32 - shift;
        assembly ("memory-safe") {
            let wp := add(add(w, 0x20), off)
            let n := mload(x)
            let xp := add(x, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let v := signextend(1, shr(240, mload(add(wp, shl(1, i)))))
                mstore(add(xp, shl(5, i)), shl(up, v))
            }
        }
    }

    /// @notice out = W x, where W is rows x len(x) int16 row-major at byte `off`
    /// @dev Raw products accumulate in a single int256 (no overflow: |w| < 2^15,
    ///      |x_i| far below 2^200), one floor-shift per output element.
    function _matmul(bytes memory w, uint256 off, int256[] memory x, int256[] memory out, uint256 rows, uint256 shift)
        private
        pure
    {
        assembly ("memory-safe") {
            let cols := mload(x)
            let xp := add(x, 0x20)
            let op := add(out, 0x20)
            let wr := add(add(w, 0x20), off)
            let rowBytes := shl(1, cols)
            for { let i := 0 } lt(i, rows) { i := add(i, 1) } {
                let acc := 0
                for { let j := 0 } lt(j, cols) { j := add(j, 1) } {
                    let wv := signextend(1, shr(240, mload(add(wr, shl(1, j)))))
                    acc := add(acc, mul(wv, mload(add(xp, shl(5, j)))))
                }
                mstore(add(op, shl(5, i)), sar(shift, acc))
                wr := add(wr, rowBytes)
            }
        }
    }

    /// @notice out_i = x_i * g_i / rms(x), g int16 at byte `gOff` with shift `gShift`
    function _rmsnorm(bytes memory w, uint256 gOff, uint256 gShift, int256[] memory x, int256[] memory out)
        private
        pure
    {
        uint256 dim = x.length;
        uint256 ss;
        assembly ("memory-safe") {
            let xp := add(x, 0x20)
            for { let i := 0 } lt(i, dim) { i := add(i, 1) } {
                let v := mload(add(xp, shl(5, i)))
                ss := add(ss, mul(v, v))
            }
        }
        uint256 s = LlamaMath.isqrt(ss / dim + uint256(EPS_Q64)); // rms in Q32, > 0
        assembly ("memory-safe") {
            let xp := add(x, 0x20)
            let op := add(out, 0x20)
            let gp := add(add(w, 0x20), gOff)
            for { let i := 0 } lt(i, dim) { i := add(i, 1) } {
                let g := signextend(1, shr(240, mload(add(gp, shl(1, i)))))
                let num := shl(32, mul(mload(add(xp, shl(5, i))), g))
                mstore(add(op, shl(5, i)), sar(gShift, sdiv(num, s)))
            }
        }
    }

    /// @notice Rotate adjacent pairs within each head by the position's RoPE angle
    /// @dev Tables are int32 Q30: v0' = (v0 c - v1 s) >> 30, v1' = (v0 s + v1 c) >> 30
    function _rope(bytes memory w, Layout memory o, int256[] memory arr, uint256 nHeads, uint256 hs, uint256 pos)
        private
        pure
    {
        uint256 half = hs / 2;
        uint256 cosOff = o.ropeCos + pos * half * 4;
        uint256 sinOff = o.ropeSin + pos * half * 4;
        assembly ("memory-safe") {
            let base := add(w, 0x20)
            let ap := add(arr, 0x20)
            for { let h := 0 } lt(h, nHeads) { h := add(h, 1) } {
                for { let p := 0 } lt(p, half) { p := add(p, 1) } {
                    let cv := signextend(3, shr(224, mload(add(base, add(cosOff, shl(2, p))))))
                    let sv := signextend(3, shr(224, mload(add(base, add(sinOff, shl(2, p))))))
                    let i0 := add(ap, shl(5, add(mul(h, hs), shl(1, p))))
                    let i1 := add(i0, 0x20)
                    let v0 := mload(i0)
                    let v1 := mload(i1)
                    mstore(i0, sar(30, sub(mul(v0, cv), mul(v1, sv))))
                    mstore(i1, sar(30, add(mul(v0, sv), mul(v1, cv))))
                }
            }
        }
    }

    /// @notice Grouped-query attention over the KV cache for one layer/position
    function _attend(Config memory c, Buffers memory b, uint256 l, uint256 pos) private pure {
        uint256 kvd = c.kvd;
        uint256 cacheRow = (l * b.maxPos + pos) * kvd;

        // append k, v to this layer's cache
        for (uint256 j = 0; j < kvd; ++j) {
            b.kCache[cacheRow + j] = b.k[j];
            b.vCache[cacheRow + j] = b.v[j];
        }

        uint256 kvMul = c.nHeads / c.nKv;
        for (uint256 h = 0; h < c.nHeads; ++h) {
            _attendHead(c, b, l * b.maxPos * kvd, h * c.hs, (h / kvMul) * c.hs, pos + 1);
        }
    }

    /// @notice One attention head: scores, softmax, weighted value sum
    /// @dev scores_t = (q . k_t >> 32) * invSqrtHs >> 32; softmax via expQ32 after
    ///      max-subtraction; output = truncated-division weighted sum of values.
    /// @param layerBase Word index of this layer's first KV cache row
    /// @param qOff Word offset of this head within q / xatt
    /// @param kvOff Word offset of this head's KV group within a cache row
    /// @param steps Number of cache positions to attend over (pos + 1)
    function _attendHead(
        Config memory c,
        Buffers memory b,
        uint256 layerBase,
        uint256 qOff,
        uint256 kvOff,
        uint256 steps
    ) private pure {
        int256 mx = type(int256).min;
        {
            int256[] memory q = b.q;
            int256[] memory kC = b.kCache;
            int256[] memory scores = b.scores;
            uint256 hs = c.hs;
            uint256 kvd = c.kvd;
            int256 inv = int256(c.invSqrtHs);
            uint256 base = layerBase + kvOff;
            assembly ("memory-safe") {
                let qp := add(add(q, 0x20), shl(5, qOff))
                let sp := add(scores, 0x20)
                for { let t := 0 } lt(t, steps) { t := add(t, 1) } {
                    let kp := add(add(kC, 0x20), shl(5, add(base, mul(t, kvd))))
                    let acc := 0
                    for { let j := 0 } lt(j, hs) { j := add(j, 1) } {
                        acc := add(acc, mul(mload(add(qp, shl(5, j))), mload(add(kp, shl(5, j)))))
                    }
                    let sc := sar(32, mul(sar(32, acc), inv))
                    mstore(add(sp, shl(5, t)), sc)
                    if sgt(sc, mx) { mx := sc }
                }
            }
        }
        uint256 tot = 0;
        {
            int256[] memory scores = b.scores;
            for (uint256 t = 0; t < steps; ++t) {
                uint256 e = LlamaMath.expQ32(scores[t] - mx);
                scores[t] = int256(e);
                tot += e;
            }
        }
        {
            int256[] memory scores = b.scores;
            int256[] memory vC = b.vCache;
            int256[] memory xatt = b.xatt;
            uint256 hs = c.hs;
            uint256 rowBytes = c.kvd << 5;
            uint256 base = layerBase + kvOff;
            assembly ("memory-safe") {
                let sp := add(scores, 0x20)
                let xp := add(add(xatt, 0x20), shl(5, qOff))
                for { let j := 0 } lt(j, hs) { j := add(j, 1) } {
                    let acc := 0
                    let vp := add(add(vC, 0x20), shl(5, add(base, j)))
                    for { let t := 0 } lt(t, steps) { t := add(t, 1) } {
                        acc := add(acc, mul(mload(add(sp, shl(5, t))), mload(vp)))
                        vp := add(vp, rowBytes)
                    }
                    mstore(add(xp, shl(5, j)), sdiv(acc, tot))
                }
            }
        }
    }

    /// @notice h1_i = silu(h1_i) * h3_i, all Q32
    /// @dev silu(z) = z * sigmoid(z); sigmoid via expQ32 on the negative half-line only
    function _swiglu(int256[] memory h1, int256[] memory h3) private pure {
        uint256 n = h1.length;
        int256 one = LlamaMath.ONE;
        for (uint256 i = 0; i < n; ++i) {
            int256 z = h1[i];
            uint256 sig;
            if (z >= 0) {
                sig = (uint256(one) << 32) / (uint256(one) + LlamaMath.expQ32(-z));
            } else {
                uint256 e = LlamaMath.expQ32(z);
                sig = (e << 32) / (uint256(one) + e);
            }
            int256 sz = (z * int256(sig)) >> 32;
            h1[i] = (sz * h3[i]) >> 32;
        }
    }

    /// @notice x_i += y_i (residual connection)
    function _addInto(int256[] memory x, int256[] memory y) private pure {
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

    /// @notice Index of the maximum logit; first maximum wins
    function _argmax(int256[] memory logits) private pure returns (uint256 best) {
        int256 bestVal = logits[0];
        uint256 n = logits.length;
        for (uint256 i = 1; i < n; ++i) {
            if (logits[i] > bestVal) {
                bestVal = logits[i];
                best = i;
            }
        }
    }
}
