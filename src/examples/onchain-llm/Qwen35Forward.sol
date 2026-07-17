// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Qwen35} from "./Qwen35.sol";

/// @title Qwen35Forward
/// @notice Deployed home of the engine-v3 forward pass. `Qwen35.generate` alone
///         inlines to ~20KB (DeltaNet + gated attention + MoE, vs v2's single GQA/SwiGLU
///         mixer) because Solidity inlines every `internal` library call at each call
///         site; packing it into `Qwen35Engine` alongside directory resolution and token
///         decoding blew EIP-170 by ~1.4KB. Split out exactly as v1 split `LlamaEngine`
///         from `GasKillerLLM`: `Qwen35Engine` reaches this contract with a STATICCALL
///         (still zero state, still never enters a Gas Killer payload) instead of
///         inlining the forward pass directly.
contract Qwen35Forward {
    /// @notice Run greedy generation from pre-tokenized prompt ids
    /// @param c The unpacked model config
    /// @param s The chunked weight store
    /// @param promptIds The prompt token ids (chat template applied off-chain)
    /// @param maxNewTokens Upper bound on generated tokens (clamped to context)
    /// @return genIds The generated token ids
    function generate(Qwen35.Config memory c, Qwen35.Store memory s, uint32[] memory promptIds, uint256 maxNewTokens)
        external
        view
        returns (uint32[] memory genIds)
    {
        return Qwen35.generate(c, s, promptIds, maxNewTokens);
    }

    /// @notice Full logits for one forward pass (tests / inspection only)
    /// @param c The unpacked model config
    /// @param o The blob layout
    /// @param s The chunked weight store
    /// @param b The per-run buffers
    /// @param token The current token id
    /// @param pos The current position
    /// @return out The vocab-sized logits vector
    function logits(
        Qwen35.Config memory c,
        Qwen35.Layout memory o,
        Qwen35.Store memory s,
        Qwen35.Buffers memory b,
        uint256 token,
        uint256 pos
    ) external view returns (int256[] memory out) {
        return Qwen35.logits(c, o, s, b, token, pos);
    }
}
