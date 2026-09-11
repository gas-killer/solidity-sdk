// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerChat} from "./GasKillerChat.sol";
import {Qwen3Engine} from "./Qwen3Engine.sol";

/// @title GasKillerChatUnchecked
/// @notice `GasKillerChat` in DIRECTORY mode for artifact sets too large to validate
///         inside a single transaction. Identical behaviour in every other respect —
///         same slot, same domain separator, same `ask`/`dryRun`/`computeChatRoot`,
///         same immutables — it only skips the constructor's `engine.checkArtifacts`.
/// @dev WHY THIS EXISTS: the deployed Qwen3-0.6B directory
///      (`0x9d1dDc25c098DA26417D0A061b647f3a3511D7b0`, 24,364 chunks + 20 pages)
///      costs a MEASURED 104.3M gas to walk in `Qwen3Engine.checkArtifacts`. That is
///      above Sepolia's ~60M block gas limit, so a directory-mode `GasKillerChat`
///      constructor is simply not mineable there — not "expensive", impossible.
///
///      WHY IT IS SAFE: `checkArtifacts` is a SHAPE assertion, never a content
///      commitment. It validates `Qwen3.layout` config consistency, `root.length % 20`,
///      per-page length, `seen == nW + nT`, the summed chunk payload lengths against
///      `c.weightLen` / `c.tokLen`, and `table[0] == 1`. It does not hash a single
///      weight byte, and in directory mode `weightsManifest` is zero and ignored — so
///      passing it proves nothing about WHICH model is behind the root. Everything it
///      would catch is caught again, unavoidably, on the first inference:
///      `Qwen3Engine.chat` calls `_resolve` on every single call, so a malformed
///      directory reverts `ask`/`dryRun` rather than returning a wrong answer. The
///      contract custodies no value; its only mutable state is a keccak chain, and
///      `weightsRoot` is immutable so nothing can be swapped post-deploy.
///
///      WHAT REPLACES IT (both stronger, both already part of the flow):
///        1. `tools/verify_onchain_directory.py` streams every chunk/page/root
///           `eth_getProof.codeHash` and compares it to `keccak(0x00 || payload)`
///           recomputed from the local blobs — this proves the on-chain bytes ARE the
///           model, which `checkArtifacts` cannot do.
///        2. `engine.checkArtifacts(root, 0, packedConfig)` as a POST-deploy `eth_call`
///           against a node started with a raised `--rpc.gascap` (>= 200M) — the exact
///           same assertion, just outside a block. This mirrors overlay mode, where the
///           check has always been a separate operator step (see
///           `script/e2e_operator_replay.sh`, `UNBOUNDED_V2_OVERLAYS.md`).
///        3. The operator quorum itself: every operator re-simulates the tracked `ask`
///           against the same reference block and the same on-chain chunks before
///           signing, so a broken directory can never be settled.
contract GasKillerChatUnchecked is GasKillerChat {
    /// @notice Deploy a directory-mode consumer WITHOUT the constructor artifact check
    /// @param _avsAddress The AVS service manager address
    /// @param _blsSigChecker The BLS signature checker contract
    /// @param _engine The deployed Qwen3Engine
    /// @param _weightsRoot Root directory data contract (must be nonzero — use the base
    ///        `GasKillerChat` for overlay mode, which already skips the check)
    /// @param _weightsManifest Overlay manifest hash (zero in directory mode)
    /// @param _packedConfig The packed model config
    constructor(
        address _avsAddress,
        address _blsSigChecker,
        Qwen3Engine _engine,
        address _weightsRoot,
        bytes32 _weightsManifest,
        bytes32[3] memory _packedConfig
    ) GasKillerChat(_avsAddress, _blsSigChecker, _engine, _weightsRoot, _weightsManifest, _packedConfig) {}

    /// @inheritdoc GasKillerChat
    /// @dev No-op: validated post-deploy instead (see the contract-level natspec).
    function _validateArtifacts(Qwen3Engine, address, bytes32, bytes32[3] memory) internal pure override {}
}
