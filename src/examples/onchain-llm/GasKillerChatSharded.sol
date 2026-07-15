// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";

/// @title GasKillerChatSharded
/// @notice Settlement consumer for SHARDED on-chain LLM inference: the transformer
///         never executes inside the tracked call. Operators compute the answer
///         cooperatively off-chain — the inference is split into (position-range x
///         layer-range) segments executed by k-of-N committees through
///         `Qwen3SegEngine.forwardRange`/`argmaxRange`, chained by keccak
///         commitments into `pipelineRoot` — and each operator verifies the commit
///         chain (including the segments it executed itself) before signing the
///         round. The tracked function is a pure commit: ONE storage write plus
///         the answer logs, no external calls, no engine, no weights.
/// @dev Same single-slot commitment shape as GasKillerChat (PR #51 pattern);
///      correctness of `answerIds` is attested by the operator quorum exactly as
///      it is for GasKillerChat — the difference is only in HOW operators convince
///      themselves before signing (segment committee chain vs full replay).
contract GasKillerChatSharded is GasKillerSDK {
    /// @notice Domain separator for the sharded chat root commitment
    bytes32 public constant CHAT_DOMAIN = keccak256("gaskiller.llm.chat.sharded.v1");

    /// @notice The single mutable storage slot: a running commitment over all chats.
    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerChatSharded.chatRoot")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant CHAT_ROOT_SLOT = 0xe597cfa8f59f965a0e86ae80f2ca387818d5db7aa80c7b6cc22d6620d8839200;

    /// @notice Domain separator for the prefix-RESUME (warm-start) chat root fold.
    /// @dev Distinct from CHAT_DOMAIN so a resumed exchange can never alias a fresh one.
    bytes32 public constant RESUME_DOMAIN = keccak256("gaskiller.llm.chat.sharded.resume.v1");

    /// @notice Full sharded-pipeline roots this consumer has successfully settled — the
    ///         set a `fulfilResumed` call may warm-start (resume) from. Written by
    ///         `fulfil` and `fulfilResumed`; a resume from an unsettled root reverts.
    mapping(bytes32 => bool) public settledRoots;

    /// @notice Emitted for every answered prompt in a tracked transition
    /// @param transitionIndex The state transition that produced this answer
    /// @param newRoot The chat root after folding this exchange in
    /// @param pipelineRoot The commitment chain root of the sharded execution
    /// @param promptIds The prompt token ids
    /// @param answerIds The generated token ids (decode off-chain)
    event ChatAnswered(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        bytes32 indexed pipelineRoot,
        uint32[] promptIds,
        uint32[] answerIds
    );

    /// @notice Emitted when a prefix-RESUMED exchange settles (warm-started from `prefixRoot`)
    /// @param transitionIndex The state transition that produced this answer
    /// @param newRoot The chat root after folding this resumed exchange in
    /// @param pipelineRoot The commitment chain root of the resumed sharded execution
    /// @param prefixRoot The previously-settled root this exchange resumed from
    /// @param promptIds The prompt token ids
    /// @param answerIds The generated token ids (decode off-chain)
    event ChatResumed(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        bytes32 indexed pipelineRoot,
        bytes32 prefixRoot,
        uint32[] promptIds,
        uint32[] answerIds
    );

    /// @notice Emitted when a committee-verified warm prefix root is admitted as a resume anchor
    /// @param transitionIndex The state transition that admitted this prefix
    /// @param prefixRoot The warm prefix commitment root now valid to resume from
    /// @param prefixIds The prefix token ids (the fixed chat-template prefix, decode off-chain)
    event PrefixSettled(uint256 indexed transitionIndex, bytes32 indexed prefixRoot, uint32[] prefixIds);

    /// @notice Thrown when the pipeline root is missing
    error MissingPipelineRoot();

    /// @notice Thrown when `fulfilResumed` is asked to resume from a root that was never settled
    error PrefixNotSettled();

    /// @notice Deploy the settlement consumer
    /// @param _avsAddress The AVS service manager address
    /// @param _blsSigChecker The BLS signature checker contract
    constructor(address _avsAddress, address _blsSigChecker) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
    }

    /// @notice Commit a sharded-inference exchange and fold it into the chat root.
    /// @dev The tracked function: it performs no inference. The operator quorum
    ///      signs this diff only after verifying the segment commit chain whose
    ///      root is `pipelineRoot` (each operator checks the hash links, the
    ///      committee coverage, and the digests of the segments it executed).
    /// @param promptIds The pre-tokenized prompt (chat template applied off-chain)
    /// @param maxNewTokens The generation bound the pipeline ran with
    /// @param answerIds The generated token ids produced by the sharded pipeline
    /// @param pipelineRoot The commitment chain root of the sharded execution
    function fulfil(
        uint32[] calldata promptIds,
        uint256 maxNewTokens,
        uint32[] calldata answerIds,
        bytes32 pipelineRoot
    ) external trackState {
        if (pipelineRoot == bytes32(0)) revert MissingPipelineRoot();

        bytes32 newRoot = computeChatRoot(chatRoot(), promptIds, maxNewTokens, answerIds, pipelineRoot);
        assembly ("memory-safe") {
            sstore(CHAT_ROOT_SLOT, newRoot)
        }
        settledRoots[pipelineRoot] = true;
        emit ChatAnswered(stateTransitionCount(), newRoot, pipelineRoot, promptIds, answerIds);
    }

    /// @notice Admit a committee-verified WARM prefix root as a valid resume anchor.
    /// @dev A warm/prefill-only prefix run produces a `prefixRoot` that no `fulfil`/
    ///      `fulfilResumed` ever records, so `fulfilResumed` could not use it. This cheap
    ///      pure commit records that the operator quorum has verified the warm prefix
    ///      segment chain off-chain (the gate does that before signing) and anchors the
    ///      resumable prefix state to a committee-signed on-chain root — letting
    ///      `fulfilResumed` trust `prefixRoot` without re-executing the prefix. It performs
    ///      no inference: ONE storage write plus the log.
    /// @param prefixIds The fixed chat-template prefix token ids the warm run processed
    /// @param prefixRoot The warm prefix commitment root to admit as a resume anchor
    function settlePrefix(uint32[] calldata prefixIds, bytes32 prefixRoot) external trackState {
        if (prefixRoot == bytes32(0)) revert MissingPipelineRoot();
        settledRoots[prefixRoot] = true;
        emit PrefixSettled(stateTransitionCount(), prefixRoot, prefixIds);
    }

    /// @notice Commit a sharded-inference exchange that RESUMES from a previously-settled
    ///         warm prefix, and fold it into the chat root.
    /// @dev Additive latency path: a fixed chat-template prefix is run once through the
    ///      committee-verified pipeline (a normal `fulfil` whose `pipelineRoot` becomes a
    ///      resume anchor); real answers then resume from it instead of recomputing the
    ///      prefix. The tracked function is still a pure commit — no inference. The quorum
    ///      signs only after verifying the resumed segment commit chain off-chain.
    /// @param promptIds The pre-tokenized prompt (chat template applied off-chain)
    /// @param maxNewTokens The generation bound the pipeline ran with
    /// @param answerIds The generated token ids produced by the resumed pipeline
    /// @param pipelineRoot The commitment chain root of the resumed sharded execution
    /// @param prefixRoot The previously-settled root this exchange warm-starts from
    function fulfilResumed(
        uint32[] calldata promptIds,
        uint256 maxNewTokens,
        uint32[] calldata answerIds,
        bytes32 pipelineRoot,
        bytes32 prefixRoot
    ) external trackState {
        if (pipelineRoot == bytes32(0)) revert MissingPipelineRoot();
        if (!settledRoots[prefixRoot]) revert PrefixNotSettled();

        bytes32 newRoot =
            computeResumedChatRoot(chatRoot(), promptIds, maxNewTokens, answerIds, pipelineRoot, prefixRoot);
        assembly ("memory-safe") {
            sstore(CHAT_ROOT_SLOT, newRoot)
        }
        settledRoots[pipelineRoot] = true;
        emit ChatResumed(stateTransitionCount(), newRoot, pipelineRoot, prefixRoot, promptIds, answerIds);
    }

    /// @notice The current chat root (the contract's only mutable state)
    /// @return root The running commitment over all exchanges
    function chatRoot() public view returns (bytes32 root) {
        assembly ("memory-safe") {
            root := sload(CHAT_ROOT_SLOT)
        }
    }

    /// @notice Compute the chat root after folding one exchange into `previousRoot`
    /// @dev Public pure: the specification operators implement off-chain.
    /// @param previousRoot The chat root being extended
    /// @param promptIds The prompt token ids
    /// @param maxNewTokens The generation bound
    /// @param answerIds The generated token ids
    /// @param pipelineRoot The sharded execution commitment root
    /// @return The new chat root
    function computeChatRoot(
        bytes32 previousRoot,
        uint32[] memory promptIds,
        uint256 maxNewTokens,
        uint32[] memory answerIds,
        bytes32 pipelineRoot
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CHAT_DOMAIN,
                previousRoot,
                keccak256(abi.encodePacked(promptIds)),
                maxNewTokens,
                keccak256(abi.encodePacked(answerIds)),
                pipelineRoot
            )
        );
    }

    /// @notice Compute the chat root after folding one RESUMED exchange into `previousRoot`
    /// @dev Public pure spec operators implement off-chain. Folds BOTH `prefixRoot` and
    ///      `pipelineRoot` under RESUME_DOMAIN so a resumed root can never collide with a
    ///      fresh `computeChatRoot` output.
    /// @param previousRoot The chat root being extended
    /// @param promptIds The prompt token ids
    /// @param maxNewTokens The generation bound
    /// @param answerIds The generated token ids
    /// @param pipelineRoot The resumed sharded execution commitment root
    /// @param prefixRoot The previously-settled root this exchange warm-started from
    /// @return The new chat root
    function computeResumedChatRoot(
        bytes32 previousRoot,
        uint32[] memory promptIds,
        uint256 maxNewTokens,
        uint32[] memory answerIds,
        bytes32 pipelineRoot,
        bytes32 prefixRoot
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                RESUME_DOMAIN,
                previousRoot,
                keccak256(abi.encodePacked(promptIds)),
                maxNewTokens,
                keccak256(abi.encodePacked(answerIds)),
                pipelineRoot,
                prefixRoot
            )
        );
    }
}
