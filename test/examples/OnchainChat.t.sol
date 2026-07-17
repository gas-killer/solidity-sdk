// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {DataContractLib} from "../../src/examples/onchain-llm/DataContractLib.sol";
import {GasKillerChat} from "../../src/examples/onchain-llm/GasKillerChat.sol";
import {Qwen3} from "../../src/examples/onchain-llm/Qwen3.sol";
import {Qwen3Engine} from "../../src/examples/onchain-llm/Qwen3Engine.sol";
import {SyntheticQwen} from "../../src/examples/onchain-llm/SyntheticQwen.sol";

import {MockBLSSignatureChecker} from "./OnchainLLM.t.sol";

/// @notice Tests the engine-v2 (streaming, Qwen3-architecture) stack against
///         bit-exact vectors from tools/qwen3_int.py, using a tiny synthetic
///         Qwen-architecture model so all new code paths run fast in CI. The real
///         Qwen3-0.6B uses the identical code with artifacts generated locally
///         (see tools/ and the example README).
contract OnchainChatTest is Test {
    using stdJson for string;

    /// @dev keccak256("gasKiller.stateTracker") - 1 (StateTracker slot, gate-exempt)
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    address internal avsAddress = address(0x1234);

    GasKillerChat internal chat;
    Qwen3Engine internal engine;
    MockBLSSignatureChecker internal blsChecker;

    address[] internal weightChunks;
    address[] internal tokChunks;
    string internal vectors;
    uint32[] internal promptIds;

    event ChatAnswered(
        uint256 indexed transitionIndex, bytes32 indexed newRoot, uint32[] promptIds, string answer, uint32[] answerIds
    );

    function setUp() public {
        string memory root = vm.projectRoot();
        bytes memory weightsBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-llm-v2/weights.bin"));
        bytes memory tokBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-llm-v2/tokenizer.bin"));
        vectors = vm.readFile(string.concat(root, "/test/fixtures/onchain-llm-v2/vectors.json"));

        uint256[] memory p = vectors.readUintArray(".promptIds");
        for (uint256 i = 0; i < p.length; ++i) {
            promptIds.push(uint32(p[i]));
        }

        // chunk both blobs, build the two-level directory: root -> page -> chunks
        bytes memory pageBytes;
        for (uint256 at = 0; at < weightsBlob.length; at += Qwen3.CHUNK) {
            uint256 len = weightsBlob.length - at;
            if (len > Qwen3.CHUNK) len = Qwen3.CHUNK;
            address c = DataContractLib.write(_slice(weightsBlob, at, len));
            weightChunks.push(c);
            pageBytes = abi.encodePacked(pageBytes, c);
        }
        for (uint256 at = 0; at < tokBlob.length; at += Qwen3.CHUNK) {
            uint256 len = tokBlob.length - at;
            if (len > Qwen3.CHUNK) len = Qwen3.CHUNK;
            address c = DataContractLib.write(_slice(tokBlob, at, len));
            tokChunks.push(c);
            pageBytes = abi.encodePacked(pageBytes, c);
        }
        address page = DataContractLib.write(pageBytes);
        address dirRoot = DataContractLib.write(abi.encodePacked(page));

        blsChecker = new MockBLSSignatureChecker();
        engine = new Qwen3Engine();
        chat = new GasKillerChat(
            avsAddress, address(blsChecker), engine, dirRoot, bytes32(0), SyntheticQwen.packedConfig()
        );
    }

    // ------------------------------------------------------------- forward

    function test_LogitsPos0MatchesReference() public view {
        Qwen3.Config memory cfg = Qwen3.unpack(SyntheticQwen.packedConfig());
        Qwen3.Layout memory o = Qwen3.layout(cfg);
        Qwen3.Store memory s = Qwen3.newStore(cfg, weightChunks);
        Qwen3.Buffers memory b = Qwen3.newBuffers(cfg, 1);
        int256[] memory got = Qwen3.logits(cfg, o, s, b, promptIds[0], 0);

        int256[] memory expected = abi.decode(vm.parseBytes(vectors.readString(".logitsPos0")), (int256[]));
        assertEq(got.length, expected.length, "logit count mismatch");
        for (uint256 i = 0; i < expected.length; ++i) {
            assertEq(got[i], expected[i], "logit mismatch");
        }
    }

    function test_ChatShortMatchesReference() public view {
        _assertGeneration(".genShort");
    }

    function test_ChatLongMatchesReference() public view {
        _assertGeneration(".genLong");
    }

    function _assertGeneration(string memory key) internal view {
        uint256 maxNew = vectors.readUint(string.concat(key, ".maxNew"));
        (string memory answer, uint32[] memory ids) = chat.dryRun(promptIds, maxNew);
        uint256[] memory expected = vectors.readUintArray(string.concat(key, ".ids"));
        assertEq(ids.length, expected.length, "id count mismatch");
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(uint256(ids[i]), expected[i], "token id mismatch");
        }
        assertEq(
            keccak256(bytes(answer)),
            keccak256(vm.parseBytes(vectors.readString(string.concat(key, ".textHex")))),
            "decoded text mismatch"
        );
    }

    // ------------------------------------------------- Gas Killer consumer

    function test_AskWritesSingleAppSlot() public {
        (string memory answer, uint32[] memory answerIds) = chat.dryRun(promptIds, 6);
        bytes32 expectedRoot = chat.computeChatRoot(chat.chatRoot(), promptIds, answer);

        vm.record();
        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatAnswered(1, expectedRoot, promptIds, answer, answerIds);
        chat.ask(promptIds, 6);

        (, bytes32[] memory writes) = vm.accesses(address(chat));
        assertGt(writes.length, 0, "no writes recorded");
        for (uint256 i = 0; i < writes.length; ++i) {
            assertTrue(writes[i] == chat.CHAT_ROOT_SLOT() || writes[i] == TRACKER_SLOT, "unexpected storage write");
        }
        assertEq(chat.chatRoot(), expectedRoot, "chat root not updated");
        assertEq(chat.stateTransitionCount(), 1, "transition not tracked");
    }

    function test_VerifyAndUpdateAppliesChatDiff() public {
        vm.roll(100);

        (string memory answer, uint32[] memory answerIds) = chat.dryRun(promptIds, 6);
        uint256 transitionIndex = chat.stateTransitionCount();
        bytes32 newRoot = chat.computeChatRoot(chat.chatRoot(), promptIds, answer);

        StateUpdateType[] memory types = new StateUpdateType[](2);
        bytes[] memory args = new bytes[](2);
        types[0] = StateUpdateType.STORE;
        args[0] = abi.encode(chat.CHAT_ROOT_SLOT(), newRoot);
        types[1] = StateUpdateType.LOG3;
        args[1] = abi.encode(
            abi.encode(promptIds, answer, answerIds),
            keccak256("ChatAnswered(uint256,bytes32,uint32[],string,uint32[])"),
            bytes32(transitionIndex + 1),
            newRoot
        );
        bytes memory storageUpdates = abi.encode(types, args);
        bytes32 msgHash = sha256(abi.encode(transitionIndex, address(chat), GasKillerChat.ask.selector, storageUpdates));

        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;
        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatAnswered(transitionIndex + 1, newRoot, promptIds, answer, answerIds);
        chat.verifyAndUpdate(
            msgHash, hex"00", uint32(block.number - 1), storageUpdates, transitionIndex, GasKillerChat.ask.selector, sig
        );

        assertEq(chat.chatRoot(), newRoot, "diff not applied");
    }

    // -------------------------------------------------------- overlay mode

    /// @notice Overlay mode: chunks mounted at derived phantom addresses (vm.etch
    ///         plays the role of the operator's pinned simulation overlay) must
    ///         produce byte-identical output to directory mode.
    function test_OverlayModeMatchesDirectoryMode() public {
        string memory root = vm.projectRoot();
        bytes memory weightsBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-llm-v2/weights.bin"));
        bytes memory tokBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-llm-v2/tokenizer.bin"));
        bytes32 manifest = keccak256(abi.encodePacked(keccak256(weightsBlob), keccak256(tokBlob)));

        uint256 idx = 0;
        for (uint256 at = 0; at < weightsBlob.length; at += Qwen3.CHUNK) {
            uint256 len = weightsBlob.length - at;
            if (len > Qwen3.CHUNK) len = Qwen3.CHUNK;
            vm.etch(
                engine.overlayChunkAddress(manifest, idx++), abi.encodePacked(hex"00", _slice(weightsBlob, at, len))
            );
        }
        for (uint256 at = 0; at < tokBlob.length; at += Qwen3.CHUNK) {
            uint256 len = tokBlob.length - at;
            if (len > Qwen3.CHUNK) len = Qwen3.CHUNK;
            vm.etch(engine.overlayChunkAddress(manifest, idx++), abi.encodePacked(hex"00", _slice(tokBlob, at, len)));
        }

        GasKillerChat overlayChat = new GasKillerChat(
            avsAddress, address(blsChecker), engine, address(0), manifest, SyntheticQwen.packedConfig()
        );
        engine.checkArtifacts(address(0), manifest, SyntheticQwen.packedConfig());

        (string memory answer, uint32[] memory ids) = overlayChat.dryRun(promptIds, 6);
        uint256[] memory expected = vectors.readUintArray(".genShort.ids");
        assertEq(ids.length, expected.length, "id count mismatch");
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(uint256(ids[i]), expected[i], "token id mismatch");
        }
        assertEq(
            keccak256(bytes(answer)),
            keccak256(vm.parseBytes(vectors.readString(".genShort.textHex"))),
            "decoded text mismatch"
        );
    }

    /// @notice Overlay mode requires a manifest hash
    function test_OverlayConstructorRequiresManifest() public {
        vm.expectRevert(GasKillerChat.MissingWeights.selector);
        new GasKillerChat(avsAddress, address(blsChecker), engine, address(0), bytes32(0), SyntheticQwen.packedConfig());
    }

    /// @notice Overlay-mode construction succeeds without mounted chunks (the bare
    ///         chain can't see them); inference then fails until an overlay is mounted.
    function test_OverlayConstructorSkipsPresenceCheck() public {
        GasKillerChat bare = new GasKillerChat(
            avsAddress, address(blsChecker), engine, address(0), keccak256("unmounted"), SyntheticQwen.packedConfig()
        );
        vm.expectRevert();
        bare.dryRun(promptIds, 1);
    }

    function test_ConstructorRejectsMismatchedConfig() public {
        bytes32[3] memory cfg = SyntheticQwen.packedConfig();
        cfg[1] = bytes32(uint256(cfg[1]) ^ (uint256(1) << 70)); // corrupt weightLen
        address dirRoot = chat.weightsRoot();
        vm.expectRevert();
        new GasKillerChat(avsAddress, address(blsChecker), engine, dirRoot, bytes32(0), cfg);
    }

    // ------------------------------------------------------------- helpers

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        assembly ("memory-safe") {
            let src := add(add(data, 0x20), start)
            let dst := add(out, 0x20)
            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } { mstore(add(dst, i), mload(add(src, i))) }
        }
    }
}
