// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Qwen3} from "./Qwen3.sol";

/// @title Qwen3Seg
/// @notice Sharded-inference v0 segment logic over the engine-v2 (Qwen3) kernels.
///         One inference is split into hash-committed segments — a rectangle of
///         positions [posLo, posHi) x layers [layerLo, layerHi) — that execute
///         independently (different processes/nodes) and reassemble bit-exactly.
///         NOTHING numeric is reimplemented here: every segment replays the exact
///         monolithic code paths (Qwen3._attnBlock / _ffnBlock / rmsnormSlice /
///         matmulRows / _loadEmbedding), so bit-exactness is inherited, not re-proven.
/// @dev KV WIRE FORMAT (canonical, layer-major). For a layer range [layerLo, layerHi)
///      and a position range [posA, posB):
///
///        for l in [layerLo, layerHi):
///            K slice of layer l, positions [posA, posB)   ((posB-posA) * kvd * 4 bytes)
///            V slice of layer l, positions [posA, posB)   ((posB-posA) * kvd * 4 bytes)
///
///      Each slice is the verbatim run of packed cache words the monolithic engine
///      holds for that (layer, position range): int32 Q16 values, 8 per 32-byte word,
///      big-endian lanes (element e occupies bits [224 - 32*(e%8), +32)), element
///      index (l*maxPos + pos)*kvd + j. Because positions are contiguous within a
///      layer at stride maxPos, hydration is a straight word copy into the same word
///      positions the monolithic run would occupy — provided the SAME maxPos is
///      pinned across every segment of a run (the stride bakes it in).
///
///      Total length = (layerHi-layerLo) * 2 * (posB-posA) * kvd * 4 bytes.
///
///      Segment checkpoint commitment:
///        chk = keccak256(abi.encodePacked(
///            "gaskiller.seg.v1", posLo, posHi, layerLo, layerHi,
///            keccak256(abi.encodePacked(tokenIds)),
///            keccak256(xIn), keccak256(kvIn), keccak256(xOut), keccak256(kvAppend)))
library Qwen3Seg {
    /// @notice Domain separator for segment checkpoint commitments
    string internal constant CHK_DOMAIN = "gaskiller.seg.v1";

    /// @notice Thrown when the segment rectangle is empty or out of bounds
    error BadRange();

    /// @notice Thrown when tokenIds/xIn/kvIn lengths don't match the rectangle
    error BadSegmentInput();

    /// @notice A segment rectangle: positions [posLo, posHi) x layers [layerLo, layerHi)
    /// @dev maxPos is the KV-cache stride of the WHOLE run and must be identical
    ///      across every segment of that run (see the wire-format note above)
    struct Span {
        uint256 maxPos;
        uint256 posLo;
        uint256 posHi;
        uint256 layerLo;
        uint256 layerHi;
    }

    /// @notice A full segment request (grouped to keep legacy-codegen stack pressure
    ///         low in external facades — see the unroll/stack hazard note in Qwen3)
    /// @dev expectXIn / expectKvIn are optional integrity witnesses: when nonzero the
    ///      facade requires keccak256(xIn) / keccak256(kvIn) to match before running
    struct Call {
        Span span;
        uint32[] tokenIds;
        bytes xIn;
        bytes kvIn;
        bytes32 expectXIn;
        bytes32 expectKvIn;
    }

    /// @notice Process positions [posLo, posHi) through layers [layerLo, layerHi) in
    ///         the exact order the monolithic loop would (position-major)
    /// @param c The config
    /// @param s The chunked store
    /// @param r The segment rectangle (+ pinned maxPos stride)
    /// @param tokenIds Token ids for the processed positions (required iff layerLo == 0)
    /// @param xIn If layerLo > 0: concat of (posHi-posLo) residual vectors entering
    ///        layerLo (int256[dim] raw words, 32*dim bytes each). Must be empty when
    ///        layerLo == 0 (inputs come from embeddings, keeping chk unambiguous).
    /// @param kvIn This layer range's KV for positions [0, posLo) in the wire format
    /// @return xOut Concat of residual vectors leaving layerHi-1 per position; if
    ///         layerHi == nLayers the final rmsnorm is applied so each vector is the
    ///         b.xb-equivalent that feeds the classifier directly
    /// @return kvAppend This layer range's KV for positions [posLo, posHi)
    /// @return chk The segment checkpoint commitment (see library natspec)
    function forwardRange(
        Qwen3.Config memory c,
        Qwen3.Store memory s,
        Span memory r,
        uint32[] memory tokenIds,
        bytes memory xIn,
        bytes memory kvIn
    ) internal view returns (bytes memory xOut, bytes memory kvAppend, bytes32 chk) {
        _validate(c, r, tokenIds, xIn, kvIn);
        Ctx memory t;
        t.c = c;
        t.o = Qwen3.layout(c);
        t.s = s;
        t.b = Qwen3.newBuffers(c, r.maxPos);
        t.r = r;
        t.tokenIds = tokenIds;
        t.xIn = xIn;
        hydrateKv(c, t.b, r.layerLo, r.layerHi, r.posLo, kvIn);
        _processPositions(t);
        xOut = t.xOut;
        kvAppend = serializeKv(c, t.b, r.layerLo, r.layerHi, r.posLo, r.posHi);
        chk = segmentChk(r, tokenIds, xIn, kvIn, xOut, kvAppend);
    }

    /// @notice The tied-classifier argmax restricted to rows [vocabLo, vocabHi)
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
        Qwen3.Config memory c,
        Qwen3.Store memory s,
        int256[] memory xb,
        uint256 vocabLo,
        uint256 vocabHi
    ) internal view returns (int256 bestScore, uint256 bestId) {
        Qwen3.Layout memory o = Qwen3.layout(c);
        if (vocabLo >= vocabHi || vocabHi > c.vocab) revert BadRange();
        if (xb.length != c.dim) revert BadSegmentInput();
        bestScore = type(int256).min;
        bestId = vocabLo;
        uint256 stride = o.embRowStride;
        int256[] memory sliceOut = new int256[](Qwen3.CLS_SLICE);
        for (uint256 row = vocabLo; row < vocabHi; row += Qwen3.CLS_SLICE) {
            uint256 rows = vocabHi - row;
            if (rows > Qwen3.CLS_SLICE) rows = Qwen3.CLS_SLICE;
            Qwen3.loadRange(s, row * stride, rows * stride, s.big);
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
    /// @dev v1 binds `tokenIds` so layer-0 segments commit their claimed token
    ///      inputs, not only their outputs — an audit/challenge protocol can then
    ///      falsify a segment from the commitment alone, without carrying the
    ///      claimed prompt out-of-band.
    function segmentChk(
        Span memory r,
        uint32[] memory tokenIds,
        bytes memory xIn,
        bytes memory kvIn,
        bytes memory xOut,
        bytes memory kvAppend
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
                keccak256(kvIn),
                keccak256(xOut),
                keccak256(kvAppend)
            )
        );
    }

    /// @notice Hydrate wire-format KV for positions [0, posCount) of layers
    ///         [layerLo, layerHi) into freshly allocated caches at stride b.maxPos
    /// @dev Writes into the exact word positions the monolithic run would occupy
    function hydrateKv(
        Qwen3.Config memory c,
        Qwen3.Buffers memory b,
        uint256 layerLo,
        uint256 layerHi,
        uint256 posCount,
        bytes memory kvIn
    ) internal pure {
        if (layerLo >= layerHi || layerHi > c.nLayers || posCount > b.maxPos) revert BadRange();
        uint256 sliceWords = posCount * c.kvd / 8;
        if (kvIn.length != (layerHi - layerLo) * 2 * sliceWords * 32) revert BadSegmentInput();
        for (uint256 l = layerLo; l < layerHi; ++l) {
            uint256 srcOff = (l - layerLo) * 2 * sliceWords * 32;
            uint256 dstWord = l * b.maxPos * c.kvd / 8;
            _copyBytesToWords(kvIn, srcOff, b.kCache, dstWord, sliceWords);
            _copyBytesToWords(kvIn, srcOff + sliceWords * 32, b.vCache, dstWord, sliceWords);
        }
    }

    /// @notice Serialize the KV cache for positions [posA, posB) of layers
    ///         [layerLo, layerHi) into the canonical wire format
    function serializeKv(
        Qwen3.Config memory c,
        Qwen3.Buffers memory b,
        uint256 layerLo,
        uint256 layerHi,
        uint256 posA,
        uint256 posB
    ) internal pure returns (bytes memory out) {
        if (layerLo >= layerHi || layerHi > c.nLayers || posA >= posB || posB > b.maxPos) {
            revert BadRange();
        }
        uint256 sliceWords = (posB - posA) * c.kvd / 8;
        out = new bytes((layerHi - layerLo) * 2 * sliceWords * 32);
        for (uint256 l = layerLo; l < layerHi; ++l) {
            uint256 srcWord = (l * b.maxPos + posA) * c.kvd / 8;
            uint256 dstOff = (l - layerLo) * 2 * sliceWords * 32;
            _copyWordsToBytes(b.kCache, srcWord, out, dstOff, sliceWords);
            _copyWordsToBytes(b.vCache, srcWord, out, dstOff + sliceWords * 32, sliceWords);
        }
    }

    /// @notice Decode a raw-words byte blob (32*dim bytes) into an int256[dim] vector
    function bytesToVec(bytes memory blob, uint256 dim) internal pure returns (int256[] memory xb) {
        if (blob.length != dim * 32) revert BadSegmentInput();
        xb = new int256[](dim);
        _copyBytesToWords(blob, 0, _asWords(xb), 0, dim);
    }

    /// @dev Bundled segment-execution context (single stack slot under legacy codegen)
    struct Ctx {
        Qwen3.Config c;
        Qwen3.Layout o;
        Qwen3.Store s;
        Qwen3.Buffers b;
        Span r;
        uint32[] tokenIds;
        bytes xIn;
        bytes xOut;
    }

    /// @dev Position-major replay of the monolithic loop restricted to the rectangle
    function _processPositions(Ctx memory t) private view {
        t.xOut = new bytes((t.r.posHi - t.r.posLo) * t.c.dim * 32);
        for (uint256 pos = t.r.posLo; pos < t.r.posHi; ++pos) {
            uint256 rel = pos - t.r.posLo;
            if (t.r.layerLo == 0) {
                Qwen3._loadEmbedding(t.c, t.o, t.s, t.tokenIds[rel], t.b.x);
            } else {
                _copyBytesToWords(t.xIn, rel * t.c.dim * 32, _asWords(t.b.x), 0, t.c.dim);
            }
            _loadRope(t.c, t.o, t.s, pos);
            for (uint256 l = t.r.layerLo; l < t.r.layerHi; ++l) {
                Qwen3._attnBlock(t.c, t.o, t.s, t.b, l, pos);
                Qwen3._ffnBlock(t.c, t.o, t.s, t.b, l);
            }
            if (t.r.layerHi == t.c.nLayers) {
                // final stage: apply the model-final rmsnorm so xOut feeds argmax directly
                Qwen3.loadRange(t.s, t.o.normOff, 1 + t.c.dim * 2, t.s.small);
                Qwen3.rmsnormSlice(t.s.small, t.b.x, 0, t.b.xb, 0, t.c.dim, t.c.epsQ48);
                _copyWordsToBytes(_asWords(t.b.xb), 0, t.xOut, rel * t.c.dim * 32, t.c.dim);
            } else {
                _copyWordsToBytes(_asWords(t.b.x), 0, t.xOut, rel * t.c.dim * 32, t.c.dim);
            }
        }
    }

    /// @dev Load this position's RoPE cos||sin rows exactly as Qwen3.forward does
    function _loadRope(Qwen3.Config memory c, Qwen3.Layout memory o, Qwen3.Store memory s, uint256 pos) private view {
        uint256 half = c.headDim / 2;
        Qwen3.loadRange(s, o.ropeCosOff + pos * half * 4, half * 4, s.rope);
        Qwen3._loadRangeAt(s, o.ropeSinOff + pos * half * 4, half * 4, s.rope, half * 4);
    }

    /// @dev Rectangle + input-length validation
    function _validate(
        Qwen3.Config memory c,
        Span memory r,
        uint32[] memory tokenIds,
        bytes memory xIn,
        bytes memory kvIn
    ) private pure {
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
        if (kvIn.length != (r.layerHi - r.layerLo) * 2 * r.posLo * c.kvd * 4) revert BadSegmentInput();
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
