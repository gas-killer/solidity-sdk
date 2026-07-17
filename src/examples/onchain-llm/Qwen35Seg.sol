// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Qwen3} from "./Qwen3.sol";
import {Qwen35} from "./Qwen35.sol";

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
