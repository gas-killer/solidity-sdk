// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {LlamaMath} from "./LlamaMath.sol";
import {Qwen3} from "./Qwen3.sol";

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
    function _deltaBlock(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 l) private view {
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
    function _attnBlock(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 l, uint256 pos)
        private
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
    function _moeBlock(Config memory c, Layout memory o, Store memory s, Buffers memory b, uint256 tailBase)
        private
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
    function _normInto(Config memory c, Store memory s, Buffers memory b, uint256 off) private view {
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
    function _loadEmbedding(Config memory c, Layout memory o, Store memory s, uint256 token, int256[] memory x)
        private
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
