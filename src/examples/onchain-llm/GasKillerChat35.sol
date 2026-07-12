// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";

import {Qwen35Engine} from "./Qwen35Engine.sol";

/// @title GasKillerChat35
/// @notice A 35B-parameter MoE chat model as a Gas Killer consumer: Qwen3.5-35B-A3B
///         answers on-chain through the streaming Qwen35Engine, with the
///         ~170B-gas-per-token generation executed off-chain under
///         `SimProfile::UnboundedV1` and settled as ONE storage write plus the
///         answer logs.
/// @dev Same single-slot commitment shape as GasKillerChat (engine v2):
///        - `ask` mutates only CHAT_ROOT_SLOT (StateTracker counter is gate-exempt);
///        - inference is a STATICCALL into the stateless engine; weights are
///          EXTCODECOPY reads of immutable data contracts — never in the payload;
///        - no block-environment reads; prompt ids are calldata, so every operator
///          simulating at the same reference block computes the same diff.
///      Prompts are pre-tokenized off-chain (byte-level BPE + chat template — see
///      SPEC §12); the answer text is decoded fully on-chain.
contract GasKillerChat35 is GasKillerSDK {
    /// @notice Domain separator for the chat root commitment
    bytes32 public constant CHAT_DOMAIN = keccak256("gaskiller.llm.chat.v1");

    /// @notice The single mutable storage slot: a running commitment over all chats.
    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerChat35.chatRoot")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant CHAT_ROOT_SLOT = 0xab078f5bd3e603f521786236c8b63b330ef228edf3c20fdff4d46eeb67c8de00;

    /// @notice The stateless streaming inference engine
    Qwen35Engine public immutable engine;

    /// @notice Root of the two-level chunk directory, or address(0) in overlay mode
    address public immutable weightsRoot;

    /// @notice Overlay manifest hash: keccak256(abi.encodePacked(keccak256(weightsBlob),
    ///         keccak256(tokenizerBlob))). In overlay mode this is the ONLY on-chain
    ///         commitment to the model — operators fetch the blobs out-of-band, verify
    ///         them against this hash, and mount them at the derived phantom addresses
    ///         (pinned into the simulation env / chainConfigHash; see
    ///         UNBOUNDED_V2_OVERLAYS.md). Zero in directory mode.
    bytes32 public immutable weightsManifest;

    /// @dev Packed model config words (see tools/convert_qwen35.py for the encoding)
    bytes32 private immutable _cfg0;
    bytes32 private immutable _cfg1;
    bytes32 private immutable _cfg2;
    bytes32 private immutable _cfg3;

    /// @notice Emitted for every answered prompt in a tracked transition
    /// @param transitionIndex The state transition that produced this answer
    /// @param newRoot The chat root after folding this exchange in
    /// @param promptIds The prompt token ids
    /// @param answer The generated UTF-8 answer
    /// @param answerIds The generated token ids
    event ChatAnswered(
        uint256 indexed transitionIndex, bytes32 indexed newRoot, uint32[] promptIds, string answer, uint32[] answerIds
    );

    /// @notice Thrown when neither a directory root nor a manifest hash is provided
    error MissingWeights();

    /// @notice Deploy the consumer and validate the on-chain model artifacts
    /// @dev Directory mode (`_weightsRoot != 0`): artifacts are on-chain data contracts,
    ///      validated here. Overlay mode (`_weightsRoot == 0, _weightsManifest != 0`):
    ///      the phantom chunks only exist in overlay-mounted simulation environments,
    ///      so no presence check is possible at construction — operators run
    ///      `engine.checkArtifacts` in their own env before serving.
    /// @param _avsAddress The AVS service manager address
    /// @param _blsSigChecker The BLS signature checker contract
    /// @param _engine The deployed Qwen35Engine
    /// @param _weightsRoot Root directory data contract, or address(0) for overlay mode
    /// @param _weightsManifest Overlay manifest hash (zero in directory mode)
    /// @param _packedConfig The packed model config
    constructor(
        address _avsAddress,
        address _blsSigChecker,
        Qwen35Engine _engine,
        address _weightsRoot,
        bytes32 _weightsManifest,
        bytes32[4] memory _packedConfig
    ) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        engine = _engine;
        weightsRoot = _weightsRoot;
        weightsManifest = _weightsManifest;
        _cfg0 = _packedConfig[0];
        _cfg1 = _packedConfig[1];
        _cfg2 = _packedConfig[2];
        _cfg3 = _packedConfig[3];
        if (_weightsRoot != address(0)) {
            _engine.checkArtifacts(_weightsRoot, _weightsManifest, _packedConfig);
        } else if (_weightsManifest == bytes32(0)) {
            revert MissingWeights();
        }
    }

    /// @notice Answer a prompt and fold the exchange into the chat root.
    /// @dev The tracked function: operators simulate it off-chain under the unbounded
    ///      profile and sign the single-STORE diff; the transformer never executes in
    ///      the applying transaction.
    /// @param promptIds The pre-tokenized prompt (chat template applied off-chain)
    /// @param maxNewTokens Upper bound on generated tokens
    /// @return answer The generated answer text
    function ask(uint32[] calldata promptIds, uint256 maxNewTokens) external trackState returns (string memory answer) {
        uint32[] memory answerIds;
        (answer, answerIds) =
            engine.chat(weightsRoot, weightsManifest, [_cfg0, _cfg1, _cfg2, _cfg3], promptIds, maxNewTokens);

        bytes32 newRoot = computeChatRoot(chatRoot(), promptIds, answer);
        assembly ("memory-safe") {
            sstore(CHAT_ROOT_SLOT, newRoot)
        }
        emit ChatAnswered(stateTransitionCount(), newRoot, promptIds, answer, answerIds);
    }

    /// @notice Run inference without touching state (eth_call / operators / tests)
    /// @param promptIds The pre-tokenized prompt
    /// @param maxNewTokens Upper bound on generated tokens
    /// @return answer The generated answer text
    /// @return answerIds The generated token ids
    function dryRun(uint32[] calldata promptIds, uint256 maxNewTokens)
        external
        view
        returns (string memory answer, uint32[] memory answerIds)
    {
        return engine.chat(weightsRoot, weightsManifest, [_cfg0, _cfg1, _cfg2, _cfg3], promptIds, maxNewTokens);
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
    /// @param answer The generated answer text
    /// @return The new chat root
    function computeChatRoot(bytes32 previousRoot, uint32[] memory promptIds, string memory answer)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(CHAT_DOMAIN, previousRoot, keccak256(abi.encodePacked(promptIds)), keccak256(bytes(answer)))
        );
    }

    /// @notice The packed model config words
    /// @return The four packed config words
    function packedConfig() external view returns (bytes32[4] memory) {
        return [_cfg0, _cfg1, _cfg2, _cfg3];
    }
}
