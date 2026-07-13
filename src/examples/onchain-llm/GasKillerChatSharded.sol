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

    /// @notice Thrown when the pipeline root is missing
    error MissingPipelineRoot();

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
        emit ChatAnswered(stateTransitionCount(), newRoot, pipelineRoot, promptIds, answerIds);
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
}
