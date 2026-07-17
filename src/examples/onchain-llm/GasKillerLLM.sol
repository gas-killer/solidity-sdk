// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";

import {Llama2} from "./Llama2.sol";
import {LlamaEngine} from "./LlamaEngine.sol";

/// @title GasKillerLLM
/// @notice A complete large-language-model inference pipeline on-chain: a Llama-2
///         architecture transformer whose forward pass, tokenizer and greedy decoder run
///         entirely in Solidity (see LlamaEngine), wrapped as a Gas Killer SDK consumer
///         so the multi-billion-gas generation executes off-chain under
///         `SimProfile::UnboundedV1` while the chain only ever pays for ONE storage
///         write plus the story logs.
/// @dev Designed for the UnboundedV1 shape gate (gas-analyzer PR #166):
///        - `tellStory` mutates exactly one slot (STORY_ROOT_SLOT); the StateTracker
///          counter bump from `trackState` is gate-exempt.
///        - No state-changing CALL/CREATE/SELFDESTRUCT/TSTORE anywhere in the tracked
///          path; inference happens through a STATICCALL to the stateless LlamaEngine
///          and EXTCODECOPY reads of immutable weight data contracts — reads never
///          enter the extracted payload.
///        - No block-environment reads: output depends only on calldata and the
///          story root at the reference block, so every operator computes the same
///          diff bit-for-bit (all arithmetic is integer, greedy argmax sampling).
///      Model weights live in `weightsDirectory`, a data contract whose payload is
///      `tokenizerPointer (20 bytes) || weightChunk0 (20 bytes) || ... || weightChunkN`.
contract GasKillerLLM is GasKillerSDK {
    /// @notice Domain separator for the story root commitment
    bytes32 public constant STORY_DOMAIN = keccak256("gaskiller.llm.story.v1");

    /// @notice The single mutable storage slot: a running commitment over all stories.
    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerLLM.storyRoot")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant STORY_ROOT_SLOT = 0xf227dc6d74a5ce486a2c4397923c0fba0cddc6b15e8ee8f55a2b543f25517a00;

    /// @notice The stateless on-chain inference engine
    LlamaEngine public immutable engine;

    /// @notice Directory data contract holding the tokenizer and weight-chunk pointers
    address public immutable weightsDirectory;

    /// @dev Packed model config words (see tools/convert.py for the encoding)
    bytes32 private immutable _cfg0;
    bytes32 private immutable _cfg1;
    bytes32 private immutable _cfg2;

    /// @notice Emitted for every story generated through a tracked transition
    /// @param transitionIndex The state transition that produced this story
    /// @param newRoot The story root after folding this story in
    /// @param prompt The UTF-8 prompt
    /// @param story The generated UTF-8 story
    /// @param tokens The generated token ids
    event StoryTold(
        uint256 indexed transitionIndex, bytes32 indexed newRoot, string prompt, string story, uint16[] tokens
    );

    /// @notice Deploy the consumer and validate the on-chain model artifacts
    /// @param _avsAddress The AVS service manager address
    /// @param _blsSigChecker The BLS signature checker contract
    /// @param _engine The deployed LlamaEngine
    /// @param _weightsDirectory Directory data contract (tokenizer + weight chunk addresses)
    /// @param _packedConfig The packed model config from tools/convert.py
    constructor(
        address _avsAddress,
        address _blsSigChecker,
        LlamaEngine _engine,
        address _weightsDirectory,
        bytes32[3] memory _packedConfig
    ) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        engine = _engine;
        weightsDirectory = _weightsDirectory;
        _cfg0 = _packedConfig[0];
        _cfg1 = _packedConfig[1];
        _cfg2 = _packedConfig[2];

        // Fail fast: config must parse, layout and deployed artifacts must be consistent
        _engine.checkArtifacts(_weightsDirectory, _packedConfig);
    }

    /// @notice Generate a story from `prompt` and fold it into the story root.
    /// @dev This is the tracked function: Gas Killer operators simulate it off-chain
    ///      under the unbounded profile and sign the resulting single-STORE diff, so the
    ///      full transformer never executes on-chain. Calling it directly on-chain works
    ///      too (the standalone reference path) — it is just astronomically expensive.
    /// @param prompt The UTF-8 prompt to continue
    /// @param maxNewTokens Upper bound on generated tokens (clamped to the context size)
    /// @return story The generated story text
    function tellStory(string calldata prompt, uint256 maxNewTokens) external trackState returns (string memory story) {
        uint16[] memory tokens;
        (story, tokens) = engine.run(weightsDirectory, [_cfg0, _cfg1, _cfg2], prompt, maxNewTokens);

        bytes32 newRoot = computeStoryRoot(storyRoot(), prompt, story);
        assembly ("memory-safe") {
            sstore(STORY_ROOT_SLOT, newRoot)
        }
        emit StoryTold(stateTransitionCount(), newRoot, prompt, story, tokens);
    }

    /// @notice Run inference without touching state (for eth_call / operators / tests)
    /// @param prompt The UTF-8 prompt to continue
    /// @param maxNewTokens Upper bound on generated tokens
    /// @return story The generated story text
    /// @return tokens The generated token ids
    function dryRun(string calldata prompt, uint256 maxNewTokens)
        external
        view
        returns (string memory story, uint16[] memory tokens)
    {
        return engine.run(weightsDirectory, [_cfg0, _cfg1, _cfg2], prompt, maxNewTokens);
    }

    /// @notice The current story root (the contract's only mutable state)
    /// @return root The running commitment over all generated stories
    function storyRoot() public view returns (bytes32 root) {
        assembly ("memory-safe") {
            root := sload(STORY_ROOT_SLOT)
        }
    }

    /// @notice Compute the story root after folding one story into `previousRoot`
    /// @dev Public pure: this doubles as the specification operators implement off-chain.
    /// @param previousRoot The story root being extended
    /// @param prompt The prompt of the new story
    /// @param story The generated story text
    /// @return The new story root
    function computeStoryRoot(bytes32 previousRoot, string memory prompt, string memory story)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(STORY_DOMAIN, previousRoot, keccak256(bytes(prompt)), keccak256(bytes(story))));
    }

    /// @notice The unpacked model configuration
    /// @return The config decoded from the packed immutable words
    function config() public view returns (Llama2.Config memory) {
        return Llama2.unpack([_cfg0, _cfg1, _cfg2]);
    }
}
