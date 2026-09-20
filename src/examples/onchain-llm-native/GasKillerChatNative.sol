// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {GKVM_ADDRESS} from "../../gkvm/GkVm.sol";

import {GkAnswer} from "./gen/GkAnswer.sol";

/// @title GasKillerChatNative
/// @notice GasKillerChat with the on-chain engine replaced by a native guest: the answer is
///         computed by `guest/answer.py` running under the gkvm precompile inside the
///         operators' simulation environment (UNBOUNDED_V3), and settled — exactly as in V2 —
///         as ONE storage write plus the answer log.
/// @dev Same single-slot commitment shape as GasKillerChat, same CHAT_DOMAIN and CHAT_ROOT_SLOT:
///        - `ask` mutates only CHAT_ROOT_SLOT (StateTracker counter is gate-exempt);
///        - inference is one STATICCALL into `gkvm` through the binding `gk build` generated
///          from answer.py's type hints — no engine, no data contracts, no hand-written
///          marshalling;
///        - no block-environment reads; prompt ids are calldata, so every operator simulating
///          at the same reference block computes the same diff.
///      Token ids are `uint256` where GasKillerChat has `uint32`: a Python `int` maps to
///      `uint256`, and the consumer takes the binding's types as they come. The root fold is
///      unaffected (`abi.encodePacked` pads array elements to 32 bytes either way); the
///      ChatAnswered signature is not the V2 one.
///      On a chain without the precompile — every real chain — `ask` and `dryRun` revert
///      `GkVmUnavailable`: the guest only ever runs off-chain, and `verifyAndUpdate` applies
///      the signed diff.
contract GasKillerChatNative is GasKillerSDK {
    /// @notice Domain separator for the chat root commitment
    bytes32 public constant CHAT_DOMAIN = keccak256("gaskiller.llm.chat.v1");

    /// @notice The single mutable storage slot: a running commitment over all chats.
    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerChat.chatRoot")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant CHAT_ROOT_SLOT = 0xa7b4acccdf168706d965d3a31619b52d79be92199169bd3cf552358a9b013c00;

    /// @notice keccak256 of the guest ELF operators must have installed to serve this consumer
    bytes32 public constant PROGRAM_HASH = GkAnswer.PROGRAM_HASH;

    /// @notice The gkvm precompile: `GKVM_ADDRESS` in production, a GkVmFfiShim in forge tests
    address public immutable gkvm;

    /// @notice Merkle v3 root of the guest's artifact bundle (zero: answer.py mounts none)
    bytes32 public immutable artifactRoot;

    /// @notice Emitted for every answered prompt in a tracked transition
    /// @param transitionIndex The state transition that produced this answer
    /// @param newRoot The chat root after folding this exchange in
    /// @param promptIds The prompt token ids
    /// @param answer The generated UTF-8 answer
    /// @param answerIds The generated token ids
    event ChatAnswered(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        uint256[] promptIds,
        string answer,
        uint256[] answerIds
    );

    /// @param _avsAddress The AVS service manager address
    /// @param _blsSigChecker The BLS signature checker contract
    /// @param _gkvm The gkvm precompile, or address(0) for the canonical `GKVM_ADDRESS`
    /// @param _artifactRoot The guest's artifact root (zero for no artifact)
    constructor(address _avsAddress, address _blsSigChecker, address _gkvm, bytes32 _artifactRoot) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        gkvm = _gkvm == address(0) ? GKVM_ADDRESS : _gkvm;
        artifactRoot = _artifactRoot;
    }

    /// @notice Answer a prompt and fold the exchange into the chat root.
    /// @dev The tracked function: operators simulate it off-chain with the guest installed and
    ///      sign the single-STORE diff; the guest never executes in the applying transaction.
    /// @param promptIds The pre-tokenized prompt
    /// @param maxNewTokens Upper bound on generated tokens
    /// @return answer The generated answer text
    function ask(uint256[] calldata promptIds, uint256 maxNewTokens)
        external
        trackState
        returns (string memory answer)
    {
        uint256[] memory answerIds;
        (answer, answerIds) = GkAnswer.call(gkvm, artifactRoot, promptIds, maxNewTokens);

        bytes32 newRoot = computeChatRoot(chatRoot(), promptIds, answer);
        assembly ("memory-safe") {
            sstore(CHAT_ROOT_SLOT, newRoot)
        }
        emit ChatAnswered(stateTransitionCount(), newRoot, promptIds, answer, answerIds);
    }

    /// @notice Run the guest without touching state (eth_call / operators / tests)
    /// @param promptIds The pre-tokenized prompt
    /// @param maxNewTokens Upper bound on generated tokens
    /// @return answer The generated answer text
    /// @return answerIds The generated token ids
    function dryRun(uint256[] calldata promptIds, uint256 maxNewTokens)
        external
        view
        returns (string memory answer, uint256[] memory answerIds)
    {
        return GkAnswer.call(gkvm, artifactRoot, promptIds, maxNewTokens);
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
    function computeChatRoot(bytes32 previousRoot, uint256[] memory promptIds, string memory answer)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(CHAT_DOMAIN, previousRoot, keccak256(abi.encodePacked(promptIds)), keccak256(bytes(answer)))
        );
    }
}
