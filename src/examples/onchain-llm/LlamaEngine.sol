// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {DataContractLib} from "./DataContractLib.sol";
import {Llama2} from "./Llama2.sol";
import {LlamaTokenizer} from "./LlamaTokenizer.sol";

/// @title LlamaEngine
/// @notice The stateless on-chain inference engine: loads a model from data contracts
///         and runs the integer-only Llama-2 forward pass + greedy decoding. Deployed
///         once and shared; consumers reach it with STATICCALL, which never enters a
///         Gas Killer state-update payload.
/// @dev Split from GasKillerLLM so each deployed contract stays under EIP-170 without
///      optimizer requirements. The engine holds no state and takes everything —
///      weights directory, packed config, prompt — per call.
contract LlamaEngine {
    using LlamaTokenizer for LlamaTokenizer.Tok;

    /// @notice Thrown when the directory payload is not 20-byte aligned or too short
    error MalformedDirectory();

    /// @notice Thrown when the deployed chunk payloads don't match the config lengths
    error WeightLengthMismatch();

    /// @notice Run tokenize -> transformer -> greedy decode entirely on-chain
    /// @param weightsDirectory Data contract listing tokenizer + weight chunk addresses
    /// @param packedConfig The packed model config from tools/convert.py
    /// @param prompt The UTF-8 prompt to continue
    /// @param maxNewTokens Upper bound on generated tokens (clamped to the context size)
    /// @return story The generated UTF-8 text
    /// @return tokens The generated token ids
    function run(address weightsDirectory, bytes32[3] memory packedConfig, string memory prompt, uint256 maxNewTokens)
        external
        view
        returns (string memory story, uint16[] memory tokens)
    {
        Llama2.Config memory cfg = Llama2.unpack(packedConfig);
        (address tokPtr, address[] memory chunks) = _directory(weightsDirectory);

        bytes memory weights = new bytes(cfg.weightLen);
        uint256 at = 0;
        for (uint256 i = 0; i < chunks.length; ++i) {
            at += DataContractLib.readInto(chunks[i], weights, at);
        }
        if (at != cfg.weightLen) revert WeightLengthMismatch();
        LlamaTokenizer.Tok memory tok = LlamaTokenizer.load(DataContractLib.read(tokPtr));

        bytes memory storyBytes;
        (storyBytes, tokens) = Llama2.generate(cfg, weights, tok, bytes(prompt), maxNewTokens);
        story = string(storyBytes);
    }

    /// @notice Validate that config parses, layout is consistent and artifacts match
    /// @dev Reverts on any mismatch; consumers call this at deploy time to fail fast.
    /// @param weightsDirectory Data contract listing tokenizer + weight chunk addresses
    /// @param packedConfig The packed model config from tools/convert.py
    function checkArtifacts(address weightsDirectory, bytes32[3] memory packedConfig) external view {
        Llama2.Config memory cfg = Llama2.unpack(packedConfig);
        Llama2.layout(cfg);
        (address tokPtr, address[] memory chunks) = _directory(weightsDirectory);
        uint256 total = 0;
        for (uint256 i = 0; i < chunks.length; ++i) {
            total += DataContractLib.payloadLength(chunks[i]);
        }
        if (total != cfg.weightLen || DataContractLib.payloadLength(tokPtr) != cfg.tokLen) {
            revert WeightLengthMismatch();
        }
    }

    /// @notice Decode a directory data contract into tokenizer + chunk addresses
    /// @param weightsDirectory The directory data contract
    /// @return tokPtr The tokenizer data contract
    /// @return chunks The weight chunk data contracts, in blob order
    function _directory(address weightsDirectory) private view returns (address tokPtr, address[] memory chunks) {
        bytes memory dir = DataContractLib.read(weightsDirectory);
        if (dir.length < 40 || dir.length % 20 != 0) revert MalformedDirectory();
        uint256 n = dir.length / 20 - 1;
        tokPtr = _addrAt(dir, 0);
        chunks = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            chunks[i] = _addrAt(dir, (i + 1) * 20);
        }
    }

    /// @notice Read a 20-byte address at byte `off` in `data`
    function _addrAt(bytes memory data, uint256 off) private pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(data, 0x20), off)))
        }
    }
}
