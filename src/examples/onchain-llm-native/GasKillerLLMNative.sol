// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {GKVM_ADDRESS} from "../../gkvm/GkVm.sol";

import {GkStories260k} from "./gen/GkStories260k.sol";

/// @title GasKillerLLMNative
/// @notice GasKillerLLM (../onchain-llm, engine v1: stories260K, 10,467,959,687 gas for a
///         200-token story as EVM bytecode) with LlamaEngine replaced by a native guest:
///         `guest/stories260k.py` — tokenizer, integer Llama-2 forward pass and greedy decode
///         in Python — running under the gkvm precompile inside the operators' simulation
///         environment (UNBOUNDED_V3), over the donor's weight and tokenizer blobs mounted as
///         artifacts. Settled exactly as the donor: ONE storage write plus the story log.
/// @dev Same single-slot commitment shape as GasKillerLLM, same STORY_DOMAIN and
///      STORY_ROOT_SLOT, same root fold — and, because the guest is the donor's integer
///      arithmetic op for op, the same stories token for token.
///      Differences, both from the binding's types: `tokens` is `uint256[]` where the donor has
///      `uint16[]` (a Python `int` maps to `uint256`), so StoryTold's signature is not the
///      donor's; and the prompt must be valid UTF-8 (a Python `str`) — anything else is a
///      deterministic `GkGuestTrap`, where the donor tokenizes raw bytes.
///      On a chain without the precompile — every real chain — `tellStory` and `dryRun` revert
///      `GkVmUnavailable`: the guest only ever runs off-chain, and `verifyAndUpdate` applies
///      the signed diff.
contract GasKillerLLMNative is GasKillerSDK {
    /// @notice Domain separator for the story root commitment
    bytes32 public constant STORY_DOMAIN = keccak256("gaskiller.llm.story.v1");

    /// @notice The single mutable storage slot: a running commitment over all stories.
    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerLLM.storyRoot")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant STORY_ROOT_SLOT = 0xf227dc6d74a5ce486a2c4397923c0fba0cddc6b15e8ee8f55a2b543f25517a00;

    /// @notice keccak256 of the guest ELF operators must have installed to serve this consumer
    bytes32 public constant PROGRAM_HASH = GkStories260k.PROGRAM_HASH;

    /// @notice The gkvm precompile: `GKVM_ADDRESS` in production, a GkVmFfiShim in forge tests
    address public immutable gkvm;

    /// @notice Merkle v3 root of the artifact bundle: [weight blob, tokenizer blob]
    bytes32 public immutable artifactRoot;

    /// @notice Emitted for every story told in a tracked transition
    /// @param transitionIndex The state transition that produced this story
    /// @param newRoot The story root after folding this story in
    /// @param prompt The prompt that was continued
    /// @param story The generated UTF-8 text
    /// @param tokens The generated token ids
    event StoryTold(
        uint256 indexed transitionIndex, bytes32 indexed newRoot, string prompt, string story, uint256[] tokens
    );

    /// @param _avsAddress The AVS service manager address
    /// @param _blsSigChecker The BLS signature checker contract
    /// @param _gkvm The gkvm precompile, or address(0) for the canonical `GKVM_ADDRESS`
    /// @param _artifactRoot Merkle v3 root of [weights, tokenizer]
    constructor(address _avsAddress, address _blsSigChecker, address _gkvm, bytes32 _artifactRoot) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        gkvm = _gkvm == address(0) ? GKVM_ADDRESS : _gkvm;
        artifactRoot = _artifactRoot;
    }

    /// @notice Generate a story from `prompt` and fold it into the story root.
    /// @dev The tracked function: operators simulate it off-chain with the guest installed and
    ///      sign the single-STORE diff; the guest never executes in the applying transaction.
    /// @param prompt The UTF-8 prompt to continue
    /// @param maxNewTokens Upper bound on generated tokens (clamped to the context size)
    /// @return story The generated story text
    function tellStory(string calldata prompt, uint256 maxNewTokens) external trackState returns (string memory story) {
        uint256[] memory tokens;
        (story, tokens) = GkStories260k.call(gkvm, artifactRoot, prompt, maxNewTokens);

        bytes32 newRoot = computeStoryRoot(storyRoot(), prompt, story);
        assembly ("memory-safe") {
            sstore(STORY_ROOT_SLOT, newRoot)
        }
        emit StoryTold(stateTransitionCount(), newRoot, prompt, story, tokens);
    }

    /// @notice Run the guest without touching state (eth_call / operators / tests)
    /// @param prompt The UTF-8 prompt to continue
    /// @param maxNewTokens Upper bound on generated tokens
    /// @return story The generated story text
    /// @return tokens The generated token ids
    function dryRun(string calldata prompt, uint256 maxNewTokens)
        external
        view
        returns (string memory story, uint256[] memory tokens)
    {
        return GkStories260k.call(gkvm, artifactRoot, prompt, maxNewTokens);
    }

    /// @notice The current story root (the contract's only mutable state)
    /// @return root The running commitment over all generated stories
    function storyRoot() public view returns (bytes32 root) {
        assembly ("memory-safe") {
            root := sload(STORY_ROOT_SLOT)
        }
    }

    /// @notice Compute the story root after folding one story into `previousRoot`
    /// @dev Public pure: the specification operators implement off-chain; GasKillerLLM's fold.
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
}
