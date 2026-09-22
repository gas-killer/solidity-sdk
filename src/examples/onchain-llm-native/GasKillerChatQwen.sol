// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {GKVM_ADDRESS} from "../../gkvm/GkVm.sol";
import {GkQwen} from "./gen/GkQwen.sol";

/// @title GasKillerChatQwen
/// @notice GasKillerChatNative with the real model behind it: the answer comes from the flagship
///         `qwen` guest (gas-analyzer crates/gkvm/guest/qwen — Qwen3 greedy inference, integer
///         only, bit-exact with the engine-v2 spec `Qwen3.sol` implements) over the
///         `qwen3-0.6b-onchain-v1` weight blob, served to the guest as a manifest-v3 artifact.
///         Settled exactly as GasKillerChatNative: ONE storage write plus the answer log.
/// @dev The consumer surface is GasKillerChatNative's — `ask(uint256[],uint256)`, the same
///      `ChatAnswered`, the same single-slot root — so every harness written for it applies.
///      Only the guest's wire ABI differs: `qwen` takes `abi.encode(bytes32[3] packedConfig,
///      uint32[] promptIds, uint256 maxNewTokens)` (Qwen3Engine.chat's arguments; the packed
///      config is the model's, fixed at deployment) and returns `abi.encode(string, uint32[])`.
///      Ids are narrowed to uint32 on the way in (a wider id reverts — it is not a token) and
///      widened on the way out.
contract GasKillerChatQwen is GasKillerSDK {
    /// @notice Domain separator for the chat root commitment (GasKillerChatNative's)
    bytes32 public constant CHAT_DOMAIN = keccak256("gaskiller.llm.chat.v1");
    /// @notice The single mutable storage slot (GasKillerChatNative's)
    bytes32 public constant CHAT_ROOT_SLOT = 0xa7b4acccdf168706d965d3a31619b52d79be92199169bd3cf552358a9b013c00;
    /// @notice keccak256 of the guest ELF operators must have installed to serve this consumer
    bytes32 public constant PROGRAM_HASH = GkQwen.PROGRAM_HASH;
    /// @notice The gkvm precompile: `GKVM_ADDRESS` in production, a GkVmFfiShim in forge tests
    address public immutable gkvm;
    /// @notice Merkle v3 root of the weight bundle (weights.bin, tokenizer.bin) the guest reads
    bytes32 public immutable artifactRoot;
    /// @dev Qwen3Engine's packedConfig for the model — dims, layer counts, quantization shifts
    bytes32 private immutable packedConfig0;
    bytes32 private immutable packedConfig1;
    bytes32 private immutable packedConfig2;

    /// @notice A prompt id does not fit the guest's uint32 token ids
    error TokenIdOutOfRange(uint256 id);

    /// @notice Emitted for every answered prompt in a tracked transition (GasKillerChatNative's)
    event ChatAnswered(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        uint256[] promptIds,
        string answer,
        uint256[] answerIds
    );

    /// @param _avsAddress The AVS service manager address
    /// @param _blsSigChecker The BLS signature checker address
    /// @param _gkvm The gkvm precompile (zero: the canonical GKVM_ADDRESS)
    /// @param _artifactRoot Manifest-v3 root of the weight bundle
    /// @param _packedConfig Qwen3Engine's packedConfig for the model
    constructor(
        address _avsAddress,
        address _blsSigChecker,
        address _gkvm,
        bytes32 _artifactRoot,
        bytes32[3] memory _packedConfig
    ) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        gkvm = _gkvm == address(0) ? GKVM_ADDRESS : _gkvm;
        artifactRoot = _artifactRoot;
        packedConfig0 = _packedConfig[0];
        packedConfig1 = _packedConfig[1];
        packedConfig2 = _packedConfig[2];
    }

    /// @notice Answer a prompt and fold the exchange into the chat root.
    /// @dev The tracked function: operators simulate it off-chain with the guest and the weights
    ///      installed and sign the single-STORE diff; the guest never executes in the applying
    ///      transaction.
    /// @param promptIds The pre-tokenized prompt (Qwen3 chat-templated)
    /// @param maxNewTokens Upper bound on generated tokens
    /// @return answer The generated answer text
    function ask(uint256[] calldata promptIds, uint256 maxNewTokens)
        external
        trackState
        returns (string memory answer)
    {
        uint256[] memory answerIds;
        (answer, answerIds) = _infer(promptIds, maxNewTokens);

        bytes32 newRoot = computeChatRoot(chatRoot(), promptIds, answer);
        assembly ("memory-safe") {
            sstore(CHAT_ROOT_SLOT, newRoot)
        }
        emit ChatAnswered(stateTransitionCount(), newRoot, promptIds, answer, answerIds);
    }

    /// @notice Run the guest without touching state (eth_call / operators / tests)
    function dryRun(uint256[] calldata promptIds, uint256 maxNewTokens)
        external
        view
        returns (string memory answer, uint256[] memory answerIds)
    {
        return _infer(promptIds, maxNewTokens);
    }

    /// @notice The model's packedConfig, as passed to the guest
    function packedConfig() public view returns (bytes32[3] memory config) {
        config = [packedConfig0, packedConfig1, packedConfig2];
    }

    /// @notice The current chat root (the contract's only mutable state)
    function chatRoot() public view returns (bytes32 root) {
        assembly ("memory-safe") {
            root := sload(CHAT_ROOT_SLOT)
        }
    }

    /// @notice Compute the chat root after folding one exchange into `previousRoot`
    /// @dev GasKillerChatNative's specification, unchanged.
    function computeChatRoot(bytes32 previousRoot, uint256[] memory promptIds, string memory answer)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(CHAT_DOMAIN, previousRoot, keccak256(abi.encodePacked(promptIds)), keccak256(bytes(answer)))
        );
    }

    function _infer(uint256[] calldata promptIds, uint256 maxNewTokens)
        private
        view
        returns (string memory answer, uint256[] memory answerIds)
    {
        uint32[] memory ids = new uint32[](promptIds.length);
        for (uint256 i = 0; i < promptIds.length; i++) {
            if (promptIds[i] > type(uint32).max) revert TokenIdOutOfRange(promptIds[i]);
            ids[i] = uint32(promptIds[i]);
        }
        bytes memory out = GkQwen.call(gkvm, artifactRoot, abi.encode(packedConfig(), ids, maxNewTokens));
        uint32[] memory narrow;
        (answer, narrow) = abi.decode(out, (string, uint32[]));
        answerIds = new uint256[](narrow.length);
        for (uint256 i = 0; i < narrow.length; i++) {
            answerIds[i] = narrow[i];
        }
    }
}
