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

// src/examples/onchain-llm/LlamaTokenizer.sol

/// @title LlamaTokenizer
/// @notice From-scratch SentencePiece-style BPE tokenizer over a compact byte blob,
///         mirroring llama2.c's `encode()`/`decode()` (greedy highest-score merges,
///         dummy-prefix space, byte-fallback tokens, BOS/EOS handling).
/// @dev Blob layout (big-endian), V = vocab size:
///        [0:2]         uint16 V
///        [2:3]         uint8  maxTokenLength (must be <= 31 so a token fits one word)
///        [3 : 3+4V]    int32  score per token (Q16: round(score * 2^16))
///        [3+4V : 3+5V] uint8  byte length per token
///        [3+5V : 3+7V] uint16 offset of each token string within the strings region
///        [3+7V : ]     bytes  concatenated token strings
///      Token ids: 0 = <unk>, 1 = BOS, 2 = EOS, 3..258 = byte-fallback "<0xNN>".
library LlamaTokenizer {
    /// @notice Beginning-of-sequence token id
    uint256 internal constant BOS = 1;

    /// @notice End-of-sequence token id
    uint256 internal constant EOS = 2;

    /// @notice Parsed view over a tokenizer blob
    /// @param blob The raw tokenizer bytes
    /// @param vocab Number of tokens
    /// @param maxLen Maximum token string length in bytes
    /// @param scoresOff Byte offset of the score table within `blob`
    /// @param lensOff Byte offset of the length table
    /// @param offsOff Byte offset of the string-offset table
    /// @param strsOff Byte offset of the strings region
    struct Tok {
        bytes blob;
        uint256 vocab;
        uint256 maxLen;
        uint256 scoresOff;
        uint256 lensOff;
        uint256 offsOff;
        uint256 strsOff;
    }

    /// @notice Thrown when the blob header is inconsistent with its byte length
    error MalformedTokenizerBlob();

    /// @notice Parse and validate a tokenizer blob
    /// @param blob The raw tokenizer bytes
    /// @return t The parsed view
    function load(bytes memory blob) internal pure returns (Tok memory t) {
        if (blob.length < 3) revert MalformedTokenizerBlob();
        uint256 v = (uint256(uint8(blob[0])) << 8) | uint256(uint8(blob[1]));
        uint256 maxLen = uint256(uint8(blob[2]));
        if (maxLen == 0 || maxLen > 31 || blob.length < 3 + 7 * v) {
            revert MalformedTokenizerBlob();
        }
        t = Tok(blob, v, maxLen, 3, 3 + 4 * v, 3 + 5 * v, 3 + 7 * v);
    }

    /// @notice A token's string, returned as (left-aligned word, length)
    /// @param t The tokenizer
    /// @param id The token id
    /// @return word The token bytes left-aligned in a bytes32, zero-padded
    /// @return len The token byte length
    function tokenStr(Tok memory t, uint256 id) internal pure returns (bytes32 word, uint256 len) {
        bytes memory blob = t.blob;
        uint256 lensOff = t.lensOff;
        uint256 offsOff = t.offsOff;
        uint256 strsOff = t.strsOff;
        assembly ("memory-safe") {
            let base := add(blob, 0x20)
            len := shr(248, mload(add(base, add(lensOff, id))))
            let so := shr(240, mload(add(base, add(offsOff, mul(id, 2)))))
            word := mload(add(base, add(strsOff, so)))
            // mask to len bytes (len <= 31 guaranteed by load())
            word := and(word, not(shr(mul(len, 8), not(0))))
        }
    }

    /// @notice A token's merge score (Q16 int32)
    /// @param t The tokenizer
    /// @param id The token id
    /// @return score The score
    function tokenScore(Tok memory t, uint256 id) internal pure returns (int256 score) {
        bytes memory blob = t.blob;
        uint256 scoresOff = t.scoresOff;
        assembly ("memory-safe") {
            score := signextend(3, shr(224, mload(add(add(blob, 0x20), add(scoresOff, mul(id, 4))))))
        }
    }

    /// @notice Find the id of an exact token string, or -1
    /// @param t The tokenizer
    /// @param word The candidate bytes, left-aligned
    /// @param len The candidate length
    /// @return The token id, or -1 when absent
    function find(Tok memory t, bytes32 word, uint256 len) internal pure returns (int256) {
        if (len > t.maxLen) return -1;
        uint256 v = t.vocab;
        for (uint256 id = 0; id < v; ++id) {
            (bytes32 w, uint256 l) = tokenStr(t, id);
            if (l == len && w == word) return int256(id);
        }
        return -1;
    }

    /// @notice Encode UTF-8 text into token ids: BOS + dummy-prefix space + greedy BPE
    /// @dev Mirrors llama2.c encode(): each input byte starts as its single-byte token
    ///      (or byte-fallback id byte+3), then the highest-score adjacent merge is applied
    ///      repeatedly; ties resolve to the leftmost pair via strict `>` comparison.
    /// @param t The tokenizer
    /// @param text The input bytes
    /// @return ids The encoded token ids, starting with BOS
    function encode(Tok memory t, bytes memory text) internal pure returns (uint16[] memory ids) {
        uint256 rawLen = text.length;
        // working buffer: BOS + optional dummy space + one id per byte
        uint16[] memory buf = new uint16[](rawLen + 2);
        uint256 n = 0;
        buf[n++] = uint16(BOS);
        if (rawLen > 0) {
            int256 sp = find(t, bytes32(" "), 1);
            buf[n++] = sp >= 0 ? uint16(uint256(sp)) : uint16(uint256(uint8(bytes1(" "))) + 3);
        }
        for (uint256 i = 0; i < rawLen; ++i) {
            bytes1 c = text[i];
            int256 id = find(t, bytes32(c), 1);
            buf[n++] = id >= 0 ? uint16(uint256(id)) : uint16(uint256(uint8(c)) + 3);
        }
        // greedy merge loop over buf[1..n) (BOS at index 0 never merges: its string
        // "\n<s>\n" cannot appear inside a merged piece shorter than maxLen anyway,
        // but excluding it mirrors run.c, which merges only the text tokens)
        while (true) {
            int256 bestScore = type(int256).min;
            int256 bestId = -1;
            uint256 bestIdx = 0;
            for (uint256 i = 1; i + 1 < n; ++i) {
                int256 id = _mergeId(t, buf[i], buf[i + 1]);
                if (id >= 0 && tokenScore(t, uint256(id)) > bestScore) {
                    bestScore = tokenScore(t, uint256(id));
                    bestId = id;
                    bestIdx = i;
                }
            }
            if (bestId < 0) break;
            buf[bestIdx] = uint16(uint256(bestId));
            for (uint256 i = bestIdx + 1; i + 1 < n; ++i) {
                buf[i] = buf[i + 1];
            }
            --n;
        }
        ids = new uint16[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = buf[i];
        }
    }

    /// @notice Decode token ids into bytes
    /// @dev Mirrors llama2.c decode(): strips the leading space of the piece following
    ///      BOS and maps byte-fallback tokens "<0xNN>" to their raw byte.
    /// @param t The tokenizer
    /// @param tokens The token ids to decode
    /// @param count Number of entries of `tokens` to decode
    /// @param prev The token id preceding tokens[0] (BOS strips a leading space)
    /// @return out The decoded bytes
    function decode(Tok memory t, uint16[] memory tokens, uint256 count, uint256 prev)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(count * t.maxLen);
        uint256 w = 0;
        for (uint256 i = 0; i < count; ++i) {
            (bytes32 word, uint256 len) = tokenStr(t, tokens[i]);
            uint256 start = 0;
            if (prev == BOS && len > 0 && word[0] == " ") start = 1;
            // byte-fallback "<0xNN>" -> raw byte (uppercase hex, as written by llama2.c)
            if (len == 6 && word[0] == "<" && word[1] == "0" && word[2] == "x" && word[5] == ">") {
                out[w++] = bytes1(uint8(_hexNibble(word[3]) * 16 + _hexNibble(word[4])));
            } else {
                for (uint256 j = start; j < len; ++j) {
                    out[w++] = word[j];
                }
            }
            prev = tokens[i];
        }
        assembly ("memory-safe") {
            mstore(out, w)
        }
    }

    /// @notice Vocab id of the concatenation of tokens `a` and `b`, or -1
    function _mergeId(Tok memory t, uint256 a, uint256 b) private pure returns (int256) {
        (bytes32 wa, uint256 la) = tokenStr(t, a);
        (bytes32 wb, uint256 lb) = tokenStr(t, b);
        return find(t, wa | (wb >> (la * 8)), la + lb);
    }

    /// @notice Parse one hex character (0-9, A-F, a-f)
    /// @param c The character
    /// @return The nibble value
    function _hexNibble(bytes1 c) private pure returns (uint8) {
        uint8 b = uint8(c);
        if (b >= 48 && b <= 57) return b - 48;
        if (b >= 65 && b <= 70) return b - 55;
        return b - 87;
    }
}

// src/examples/onchain-llm/Llama2.sol

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
