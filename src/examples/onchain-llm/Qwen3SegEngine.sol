// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {DataContractLib} from "./DataContractLib.sol";
import {Qwen3} from "./Qwen3.sol";
import {Qwen3Seg} from "./Qwen3Seg.sol";

/// @title Qwen3SegEngine
/// @notice Stateless external-view facade for sharded-inference-v0 segments: exposes
///         forwardRange (a positions x layers rectangle of the transformer) and
///         argmaxRange (a vocab shard of the tied classifier) over the same chunked
///         weight store / overlay addressing as Qwen3Engine. Zero storage; reached
///         via STATICCALL, so segments return hash commitments instead of logging.
/// @dev Directory / overlay resolution mirrors Qwen3Engine exactly (weight chunks
///      only — segments never touch the tokenizer). See Qwen3Seg for the KV wire
///      format and the checkpoint-commitment definition.
contract Qwen3SegEngine {
    /// @notice Domain separator for deriving overlay chunk addresses (== Qwen3Engine's)
    string public constant OVERLAY_DOMAIN = "gaskiller.llm.overlay.v1";

    /// @notice Thrown when the directory shape doesn't match the config
    error MalformedDirectory();

    /// @notice Thrown when a nonzero expected-input hash doesn't match the input
    error WitnessMismatch();

    /// @notice Run one segment: positions [span.posLo, span.posHi) through layers
    ///         [span.layerLo, span.layerHi), in monolithic (position-major) order
    /// @param rootDirectory Root of the two-level chunk directory, or address(0) for
    ///        overlay mode (chunk addresses derived from `manifestHash`)
    /// @param manifestHash Overlay manifest hash (ignored in directory mode)
    /// @param packedConfig The packed model config from tools/qwen3_convert.py
    /// @param q The segment request: span (rectangle + pinned maxPos KV stride),
    ///        tokenIds (required iff layerLo == 0), xIn (residual vectors entering
    ///        layerLo; empty iff layerLo == 0), kvIn (this layer range's KV for
    ///        positions [0, posLo) in the wire format) and the optional
    ///        expectXIn / expectKvIn integrity witnesses (checked iff nonzero).
    ///        Grouped as a struct so the facade compiles under legacy codegen
    ///        without via-IR (flattened, the decode is stack-too-deep).
    /// @return xOut Residual (or final-normed, when layerHi == nLayers) vectors leaving
    ///         the segment, one per processed position
    /// @return kvAppend This layer range's KV for positions [posLo, posHi), wire format
    /// @return chk The segment checkpoint commitment (see Qwen3Seg natspec)
    function forwardRange(
        address rootDirectory,
        bytes32 manifestHash,
        bytes32[3] memory packedConfig,
        Qwen3Seg.Call memory q
    ) external view returns (bytes memory xOut, bytes memory kvAppend, bytes32 chk) {
        if (q.expectXIn != bytes32(0) && keccak256(q.xIn) != q.expectXIn) {
            revert WitnessMismatch();
        }
        if (q.expectKvIn != bytes32(0) && keccak256(q.kvIn) != q.expectKvIn) revert WitnessMismatch();
        Qwen3.Config memory c = Qwen3.unpack(packedConfig);
        return Qwen3Seg.forwardRange(
            c, Qwen3.newStore(c, _resolveWeights(rootDirectory, manifestHash, c)), q.span, q.tokenIds, q.xIn, q.kvIn
        );
    }

    /// @notice Tied-classifier argmax restricted to rows [vocabLo, vocabHi)
    /// @dev Shard merge rule: higher score wins; on equal score the LOWER id wins.
    ///      Merging ascending disjoint shards under this rule equals the monolithic
    ///      first-max-wins argmax exactly (each shard scans ascending rows, strict >).
    /// @param rootDirectory Root of the two-level chunk directory, or address(0)
    /// @param manifestHash Overlay manifest hash (ignored in directory mode)
    /// @param packedConfig The packed model config
    /// @param xbFinal The final normed hidden state as raw words (32*dim bytes) —
    ///        exactly a last-stage forwardRange xOut vector
    /// @param vocabLo First classifier row (inclusive)
    /// @param vocabHi Last classifier row (exclusive)
    /// @return bestScore The maximum logit over the range
    /// @return bestId The first row attaining it (lowest id on ties)
    function argmaxRange(
        address rootDirectory,
        bytes32 manifestHash,
        bytes32[3] memory packedConfig,
        bytes memory xbFinal,
        uint256 vocabLo,
        uint256 vocabHi
    ) external view returns (int256 bestScore, uint256 bestId) {
        Qwen3.Config memory c = Qwen3.unpack(packedConfig);
        return Qwen3Seg.argmaxRange(
            c,
            Qwen3.newStore(c, _resolveWeights(rootDirectory, manifestHash, c)),
            Qwen3Seg.bytesToVec(xbFinal, c.dim),
            vocabLo,
            vocabHi
        );
    }

    /// @notice Derive the overlay address of chunk `i` for a manifest (== Qwen3Engine's)
    /// @param manifestHash The overlay manifest hash
    /// @param i The global chunk index (weight chunks first, then tokenizer chunks)
    /// @return The phantom data-contract address
    function overlayChunkAddress(bytes32 manifestHash, uint256 i) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(OVERLAY_DOMAIN, manifestHash, uint64(i))))));
    }

    /// @notice Resolve the weight chunk list: two-level directory, or derived overlay
    ///         addresses. Mirrors Qwen3Engine._resolve but returns only weight chunks
    ///         (segments never read the tokenizer).
    function _resolveWeights(address rootDirectory, bytes32 manifestHash, Qwen3.Config memory c)
        private
        view
        returns (address[] memory wChunks)
    {
        uint256 nW = (c.weightLen + Qwen3.CHUNK - 1) / Qwen3.CHUNK;
        uint256 nT = (c.tokLen + Qwen3.CHUNK - 1) / Qwen3.CHUNK;
        if (rootDirectory == address(0)) {
            if (manifestHash == bytes32(0)) revert MalformedDirectory();
            wChunks = new address[](nW);
            for (uint256 i = 0; i < nW; ++i) {
                wChunks[i] = overlayChunkAddress(manifestHash, i);
            }
            return wChunks;
        }
        bytes memory root = DataContractLib.read(rootDirectory);
        if (root.length == 0 || root.length % 20 != 0) revert MalformedDirectory();
        uint256 nPages = root.length / 20;

        wChunks = new address[](nW);
        uint256 seen = 0;
        for (uint256 p = 0; p < nPages; ++p) {
            bytes memory page = DataContractLib.read(_addrAt(root, p * 20));
            if (page.length % 20 != 0) revert MalformedDirectory();
            uint256 n = page.length / 20;
            for (uint256 i = 0; i < n; ++i) {
                if (seen < nW) wChunks[seen] = _addrAt(page, i * 20);
                else if (seen >= nW + nT) revert MalformedDirectory();
                ++seen;
            }
        }
        if (seen != nW + nT) revert MalformedDirectory();
    }

    /// @notice Read a 20-byte address at byte `off`
    function _addrAt(bytes memory data, uint256 off) private pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(data, 0x20), off)))
        }
    }
}
