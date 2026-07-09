// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {DataContractLib} from "./DataContractLib.sol";
import {Qwen3} from "./Qwen3.sol";

/// @title Qwen3Engine
/// @notice Stateless engine-v2 inference: streams a chunked Qwen3-architecture model
///         (hundreds of MB of int8 weights across tens of thousands of data contracts)
///         and runs integer-only generation from pre-tokenized prompt ids, decoding
///         the answer to UTF-8 on-chain. Reached via STATICCALL, so nothing here ever
///         enters a Gas Killer state-update payload.
/// @dev Directory is TWO-LEVEL because 24k+ chunk addresses exceed one data contract:
///        root payload  = page data-contract addresses (20 bytes each)
///        page payloads = chunk addresses, concatenated globally as
///                        [weightChunk 0..W-1][tokenizerChunk 0..T-1]
///      with W = ceil(weightLen / 24575), T = ceil(tokLen / 24575) from the config.
///      Prompt tokenization happens off-chain (byte-level BPE with the chat template);
///      the prompt ids are calldata, so operators still simulate identical inputs.
///      Decoding is fully on-chain from the raw-bytes token table.
contract Qwen3Engine {
    /// @notice Domain separator for deriving overlay chunk addresses
    /// @dev In overlay mode (rootDirectory == address(0)) chunk i lives at
    ///      address(keccak256(abi.encodePacked(OVERLAY_DOMAIN, manifestHash, uint64(i)))),
    ///      indices spanning weight chunks then tokenizer chunks. The bytes are
    ///      mounted by the simulation environment (SimProfile code overlays pinned
    ///      into chainConfigHash) instead of being deployed — see
    ///      UNBOUNDED_V2_OVERLAYS.md. manifestHash =
    ///      keccak256(abi.encodePacked(keccak256(weightsBlob), keccak256(tokenizerBlob))).
    string public constant OVERLAY_DOMAIN = "gaskiller.llm.overlay.v1";

    /// @notice Thrown when the directory shape doesn't match the config
    error MalformedDirectory();

    /// @notice Thrown when deployed artifact lengths don't match the config
    error WeightLengthMismatch();

    /// @notice Thrown when the tokenizer blob is malformed or the wrong type
    error MalformedTokenTable();

    /// @notice Generate an answer from pre-tokenized prompt ids
    /// @param rootDirectory Root of the two-level chunk directory, or address(0) for
    ///        overlay mode (chunk addresses derived from `manifestHash`)
    /// @param manifestHash Overlay manifest hash (ignored in directory mode)
    /// @param packedConfig The packed model config from tools/qwen3_convert.py
    /// @param promptIds The prompt token ids (chat template applied off-chain)
    /// @param maxNewTokens Upper bound on generated tokens (clamped to context)
    /// @return answer The generated UTF-8 text (stop tokens omitted)
    /// @return answerIds The generated token ids (including a trailing stop token)
    function chat(
        address rootDirectory,
        bytes32 manifestHash,
        bytes32[3] memory packedConfig,
        uint32[] memory promptIds,
        uint256 maxNewTokens
    ) external view returns (string memory answer, uint32[] memory answerIds) {
        Qwen3.Config memory c = Qwen3.unpack(packedConfig);
        (address[] memory wChunks, address[] memory tChunks) = _resolve(rootDirectory, manifestHash, c);
        Qwen3.Store memory s = Qwen3.newStore(c, wChunks);
        answerIds = Qwen3.generate(c, s, promptIds, maxNewTokens);
        bytes memory table = _readAll(tChunks, c.tokLen);
        answer = string(_decode(table, answerIds, c.stop0, c.stop1));
    }

    /// @notice Validate config, directory shape and artifact lengths; reverts on mismatch
    /// @dev In overlay mode this only succeeds in an environment that has the overlay
    ///      mounted (an operator's simulation env, or anvil after setCode) — on the
    ///      bare chain the phantom addresses are empty. Consumers therefore skip this
    ///      at construction in overlay mode; operators call it before serving.
    /// @param rootDirectory Root of the two-level chunk directory, or address(0)
    /// @param manifestHash Overlay manifest hash (ignored in directory mode)
    /// @param packedConfig The packed model config
    function checkArtifacts(address rootDirectory, bytes32 manifestHash, bytes32[3] memory packedConfig) external view {
        Qwen3.Config memory c = Qwen3.unpack(packedConfig);
        Qwen3.layout(c); // validates weightLen consistency
        (address[] memory wChunks, address[] memory tChunks) = _resolve(rootDirectory, manifestHash, c);
        uint256 total = 0;
        for (uint256 i = 0; i < wChunks.length; ++i) {
            total += DataContractLib.payloadLength(wChunks[i]);
        }
        if (total != c.weightLen) revert WeightLengthMismatch();
        total = 0;
        for (uint256 i = 0; i < tChunks.length; ++i) {
            total += DataContractLib.payloadLength(tChunks[i]);
        }
        if (total != c.tokLen) revert WeightLengthMismatch();
        bytes memory table = _readAll(tChunks, c.tokLen);
        if (table.length < 9 || uint8(table[0]) != 1) revert MalformedTokenTable();
    }

    /// @notice Derive the overlay address of chunk `i` for a manifest
    /// @param manifestHash The overlay manifest hash
    /// @param i The global chunk index (weight chunks first, then tokenizer chunks)
    /// @return The phantom data-contract address
    function overlayChunkAddress(bytes32 manifestHash, uint256 i) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(OVERLAY_DOMAIN, manifestHash, uint64(i))))));
    }

    /// @notice Resolve chunk lists: two-level directory, or derived overlay addresses
    function _resolve(address rootDirectory, bytes32 manifestHash, Qwen3.Config memory c)
        private
        view
        returns (address[] memory wChunks, address[] memory tChunks)
    {
        uint256 nW = (c.weightLen + Qwen3.CHUNK - 1) / Qwen3.CHUNK;
        uint256 nT = (c.tokLen + Qwen3.CHUNK - 1) / Qwen3.CHUNK;
        if (rootDirectory == address(0)) {
            if (manifestHash == bytes32(0)) revert MalformedDirectory();
            wChunks = new address[](nW);
            tChunks = new address[](nT);
            for (uint256 i = 0; i < nW; ++i) {
                wChunks[i] = overlayChunkAddress(manifestHash, i);
            }
            for (uint256 i = 0; i < nT; ++i) {
                tChunks[i] = overlayChunkAddress(manifestHash, nW + i);
            }
            return (wChunks, tChunks);
        }
        bytes memory root = DataContractLib.read(rootDirectory);
        if (root.length == 0 || root.length % 20 != 0) revert MalformedDirectory();
        uint256 nPages = root.length / 20;

        wChunks = new address[](nW);
        tChunks = new address[](nT);
        uint256 seen = 0;
        for (uint256 p = 0; p < nPages; ++p) {
            bytes memory page = DataContractLib.read(_addrAt(root, p * 20));
            if (page.length % 20 != 0) revert MalformedDirectory();
            uint256 n = page.length / 20;
            for (uint256 i = 0; i < n; ++i) {
                address a = _addrAt(page, i * 20);
                if (seen < nW) wChunks[seen] = a;
                else if (seen < nW + nT) tChunks[seen - nW] = a;
                else revert MalformedDirectory();
                ++seen;
            }
        }
        if (seen != nW + nT) revert MalformedDirectory();
    }

    /// @notice Concatenate a chunk list into one bytes buffer of exactly `totalLen`
    function _readAll(address[] memory chunks, uint256 totalLen) private view returns (bytes memory out) {
        out = new bytes(totalLen);
        uint256 at = 0;
        for (uint256 i = 0; i < chunks.length; ++i) {
            at += DataContractLib.readInto(chunks[i], out, at);
        }
        if (at != totalLen) revert WeightLengthMismatch();
    }

    /// @notice Decode token ids to raw bytes via the on-chain token table
    /// @dev Table: [u8 type=1][u32 vocab][u32 stringsLen][(vocab+1) x u32 offs][strings].
    ///      Stop tokens are omitted from the output text.
    function _decode(bytes memory table, uint32[] memory ids, uint256 stop0, uint256 stop1)
        private
        pure
        returns (bytes memory out)
    {
        if (table.length < 9 || uint8(table[0]) != 1) revert MalformedTokenTable();
        uint256 vocab = _u32At(table, 1);
        uint256 stringsBase = 9 + (vocab + 1) * 4;
        uint256 total = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (id >= vocab) revert MalformedTokenTable();
            if (id == stop0 || id == stop1) continue;
            total += _u32At(table, 9 + (id + 1) * 4) - _u32At(table, 9 + id * 4);
        }
        out = new bytes(total);
        uint256 w = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (id == stop0 || id == stop1) continue;
            uint256 so = _u32At(table, 9 + id * 4);
            uint256 eo = _u32At(table, 9 + (id + 1) * 4);
            for (uint256 j = so; j < eo; ++j) {
                out[w++] = table[stringsBase + j];
            }
        }
    }

    /// @notice Read a big-endian uint32 at byte `off`
    function _u32At(bytes memory data, uint256 off) private pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := shr(224, mload(add(add(data, 0x20), off)))
        }
    }

    /// @notice Read a 20-byte address at byte `off`
    function _addrAt(bytes memory data, uint256 off) private pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(data, 0x20), off)))
        }
    }
}
