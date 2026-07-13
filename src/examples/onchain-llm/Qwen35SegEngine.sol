// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {DataContractLib} from "./DataContractLib.sol";
import {Qwen35} from "./Qwen35.sol";
import {Qwen35Seg} from "./Qwen35Seg.sol";

/// @title Qwen35SegForward
/// @notice Deployed home of the engine-v3 SEGMENT forward pass. Just as
///         `Qwen35Forward` split the monolithic `Qwen35.generate` out of
///         `Qwen35Engine` (the hybrid DeltaNet + gated-attention + MoE stack inlines
///         past EIP-170 when packed with directory resolution), `Qwen35Seg.forwardRange`
///         inlines the same three token-mixer kernels and cannot share a contract with
///         the directory/overlay resolution in `Qwen35SegEngine`. The engine reaches
///         this contract with a STATICCALL (zero state, never a Gas Killer payload).
contract Qwen35SegForward {
    /// @notice Run one segment: positions [span.posLo, span.posHi) through layers
    ///         [span.layerLo, span.layerHi), in monolithic (position-major) order
    /// @param c The unpacked model config
    /// @param s The chunked weight store (chunks resolved by the engine)
    /// @param q The segment request (span + tokenIds + xIn + stateIn)
    /// @return xOut Residual (or final-normed, when layerHi == nLayers) vectors leaving
    ///         the segment, one per processed position
    /// @return stateAppend This layer range's produced state, wire format (Qwen35Seg)
    /// @dev The checkpoint commitment is computed by the calling facade (Qwen35SegEngine),
    ///      not here — keeping this heavy contract under EIP-170 (see Qwen35Seg.forwardRange).
    function forwardRange(Qwen35.Config memory c, Qwen35.Store memory s, Qwen35Seg.Call memory q)
        external
        view
        returns (bytes memory xOut, bytes memory stateAppend)
    {
        return Qwen35Seg.forwardRange(c, s, q.span, q.tokenIds, q.xIn, q.stateIn);
    }
}

/// @title Qwen35SegEngine
/// @notice Stateless external-view facade for engine-v3 sharded-inference segments over
///         the HYBRID Qwen3.5-35B-A3B stack: exposes forwardRange (a positions x layers
///         rectangle of the transformer, dispatched per-layer to DeltaNet or gated
///         attention, then MoE) and argmaxRange (a vocab shard of the untied
///         classifier) over the same chunked weight store / overlay addressing as
///         Qwen35Engine. Zero storage; reached via STATICCALL, so segments return hash
///         commitments instead of logging.
/// @dev Directory / overlay resolution mirrors Qwen35Engine exactly (weight chunks only —
///      segments never touch the tokenizer). See Qwen35Seg for the hybrid state wire
///      format and the checkpoint-commitment definition. The forward pass itself lives
///      in a separately-deployed `Qwen35SegForward` (EIP-170), reached with a STATICCALL.
contract Qwen35SegEngine {
    /// @notice The deployed segment forward-pass contract (holds forwardRange)
    Qwen35SegForward public immutable forward;

    /// @notice Domain separator for deriving overlay chunk addresses (== Qwen35Engine's)
    string public constant OVERLAY_DOMAIN = "gaskiller.llm.overlay.v1";

    /// @notice Thrown when the directory shape doesn't match the config
    error MalformedDirectory();

    /// @notice Thrown when a nonzero expected-input hash doesn't match the input
    error WitnessMismatch();

    /// @param _forward The deployed Qwen35SegForward contract
    constructor(Qwen35SegForward _forward) {
        forward = _forward;
    }

    /// @notice Run one segment: positions [span.posLo, span.posHi) through layers
    ///         [span.layerLo, span.layerHi), in monolithic (position-major) order
    /// @param rootDirectory Root of the two-level chunk directory, or address(0) for
    ///        overlay mode (chunk addresses derived from `manifestHash`)
    /// @param manifestHash Overlay manifest hash (ignored in directory mode)
    /// @param packedConfig The packed model config from tools/convert_qwen35.py
    /// @param q The segment request: span (rectangle + pinned maxPos KV stride),
    ///        tokenIds (required iff layerLo == 0), xIn (residual vectors entering
    ///        layerLo; empty iff layerLo == 0), stateIn (the resume state for this
    ///        layer range; empty iff posLo == 0) and the optional expectXIn /
    ///        expectStateIn integrity witnesses (checked iff nonzero). Grouped as a
    ///        struct so the facade compiles under legacy codegen without via-IR.
    /// @return xOut Residual (or final-normed, when layerHi == nLayers) vectors leaving
    ///         the segment, one per processed position
    /// @return stateAppend This layer range's produced state, wire format (Qwen35Seg)
    /// @return chk The segment checkpoint commitment (see Qwen35Seg natspec)
    function forwardRange(
        address rootDirectory,
        bytes32 manifestHash,
        bytes32[4] memory packedConfig,
        Qwen35Seg.Call memory q
    ) external view returns (bytes memory xOut, bytes memory stateAppend, bytes32 chk) {
        if (q.expectXIn != bytes32(0) && keccak256(q.xIn) != q.expectXIn) {
            revert WitnessMismatch();
        }
        if (q.expectStateIn != bytes32(0) && keccak256(q.stateIn) != q.expectStateIn) revert WitnessMismatch();
        Qwen35.Config memory c = Qwen35.unpack(packedConfig);
        Qwen35Seg.validate(c, q.span, q.tokenIds, q.xIn, q.stateIn);
        Qwen35.Store memory s = Qwen35.newStore(c, _resolveWeights(rootDirectory, manifestHash, c));
        (xOut, stateAppend) = forward.forwardRange(c, s, q);
        chk = Qwen35Seg.segmentChk(q.span, q.tokenIds, q.xIn, q.stateIn, xOut, stateAppend);
    }

    /// @notice Untied-classifier argmax restricted to rows [vocabLo, vocabHi)
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
        bytes32[4] memory packedConfig,
        bytes memory xbFinal,
        uint256 vocabLo,
        uint256 vocabHi
    ) external view returns (int256 bestScore, uint256 bestId) {
        Qwen35.Config memory c = Qwen35.unpack(packedConfig);
        return Qwen35Seg.argmaxRange(
            c,
            Qwen35.newStore(c, _resolveWeights(rootDirectory, manifestHash, c)),
            Qwen35Seg.bytesToVec(xbFinal, c.dim),
            vocabLo,
            vocabHi
        );
    }

    /// @notice Derive the overlay address of chunk `i` for a manifest (== Qwen35Engine's)
    /// @param manifestHash The overlay manifest hash
    /// @param i The global chunk index (weight chunks first, then tokenizer chunks)
    /// @return The phantom data-contract address
    function overlayChunkAddress(bytes32 manifestHash, uint256 i) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(OVERLAY_DOMAIN, manifestHash, uint64(i))))));
    }

    /// @notice Resolve the weight chunk list: two-level directory, or derived overlay
    ///         addresses. Mirrors Qwen35Engine._resolve but returns only weight chunks
    ///         (segments never read the tokenizer).
    function _resolveWeights(address rootDirectory, bytes32 manifestHash, Qwen35.Config memory c)
        private
        view
        returns (address[] memory wChunks)
    {
        uint256 nW = (c.weightLen + Qwen35.CHUNK - 1) / Qwen35.CHUNK;
        uint256 nT = (c.tokLen + Qwen35.CHUNK - 1) / Qwen35.CHUNK;
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
