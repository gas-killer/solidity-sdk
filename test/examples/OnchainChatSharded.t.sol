// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DataContractLib} from "../../src/examples/onchain-llm/DataContractLib.sol";
import {Qwen3} from "../../src/examples/onchain-llm/Qwen3.sol";
import {Qwen3Engine} from "../../src/examples/onchain-llm/Qwen3Engine.sol";
import {Qwen3Seg} from "../../src/examples/onchain-llm/Qwen3Seg.sol";
import {Qwen3SegEngine} from "../../src/examples/onchain-llm/Qwen3SegEngine.sol";
import {SyntheticQwen} from "../../src/examples/onchain-llm/SyntheticQwen.sol";

/// @notice Sharded-inference v0: prove one inference can be split into hash-committed
///         segments (positions x layers rectangles + vocab shards of the classifier)
///         executed as independent calls, wired back together by a driver, and still
///         reproduce the monolithic engine-v2 output bit-exactly. Runs on the tiny
///         synthetic Qwen-architecture fixture so all paths are CI-fast.
contract OnchainChatShardedTest is Test {
    using stdJson for string;

    Qwen3Engine internal engine;
    Qwen3SegEngine internal segEngine;

    address internal dirRoot;
    address[] internal weightChunks;
    string internal vectors;
    uint32[] internal promptIds;

    // unpacked config scalars (synthetic fixture model)
    uint256 internal dim;
    uint256 internal nLayers;
    uint256 internal kvd;
    uint256 internal vocab;
    uint256 internal seqCap;
    uint256 internal stop0;
    uint256 internal stop1;

    // driver state: accumulated wire-format K/V per absolute layer (positions [0, pos))
    bytes[] internal kAcc;
    bytes[] internal vAcc;

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
            pageBytes = abi.encodePacked(pageBytes, DataContractLib.write(_slice(tokBlob, at, len)));
        }
        address page = DataContractLib.write(pageBytes);
        dirRoot = DataContractLib.write(abi.encodePacked(page));

        engine = new Qwen3Engine();
        segEngine = new Qwen3SegEngine();

        Qwen3.Config memory c = Qwen3.unpack(SyntheticQwen.packedConfig());
        dim = c.dim;
        nLayers = c.nLayers;
        kvd = c.kvd;
        vocab = c.vocab;
        seqCap = c.seqCap;
        stop0 = c.stop0;
        stop1 = c.stop1;
    }

    // -------------------------------------------- segmented == monolithic

    /// @notice S=2 layer split ([0,1) and [1,2)): batched prefill + per-token segment
    ///         pipeline reproduces the monolithic generation bit-exactly
    function test_SegmentedEqualsMonolithic_S2() public {
        (, uint32[] memory mono) = engine.chat(dirRoot, bytes32(0), SyntheticQwen.packedConfig(), promptIds, 16);
        uint32[] memory seg = _runSharded(16, 1);
        _assertSameIds(seg, mono);
    }

    /// @notice S=4 segments: the synthetic fixture has nLayers == 2, so a 4-way LAYER
    ///         split is impossible — instead the prefill is split 2 ways by POSITION
    ///         as well ([0,2) and [2,4) per layer range = 4 hash-linked prefill
    ///         segments), which additionally exercises kvIn hydration at posLo > 0
    function test_SegmentedEqualsMonolithic_S4() public {
        (, uint32[] memory mono) = engine.chat(dirRoot, bytes32(0), SyntheticQwen.packedConfig(), promptIds, 6);
        uint32[] memory seg = _runSharded(6, 2);
        _assertSameIds(seg, mono);
    }

    /// @notice A nonzero expectXIn witness that doesn't match xIn must revert
    function test_ForwardRangeWitnessMismatchReverts() public {
        uint32[] memory toks = new uint32[](1);
        toks[0] = promptIds[0];
        Qwen3Seg.Call memory q =
            Qwen3Seg.Call(Qwen3Seg.Span(4, 0, 1, 0, 1), toks, "", "", keccak256("not the xIn"), bytes32(0));
        vm.expectRevert(Qwen3SegEngine.WitnessMismatch.selector);
        segEngine.forwardRange(dirRoot, bytes32(0), SyntheticQwen.packedConfig(), q);
    }

    // ------------------------------------------------------ argmax shards

    /// @notice Merged argmaxRange shards (M in {2,4,8}) equal the monolithic
    ///         first-max-wins argmax, including an all-ties vector
    function test_ArgmaxRangeMergeEqualsMonolithic() public view {
        Qwen3.Config memory c = Qwen3.unpack(SyntheticQwen.packedConfig());
        Qwen3.Layout memory o = Qwen3.layout(c);
        Qwen3.Store memory s = Qwen3.newStore(c, weightChunks);
        uint256[3] memory shardCounts = [uint256(2), 4, 8];

        for (uint256 seed = 0; seed < 3; ++seed) {
            int256[] memory xb = new int256[](dim);
            for (uint256 i = 0; i < dim; ++i) {
                // pseudo-random Q24-scale activations
                xb[i] = int256(uint256(keccak256(abi.encodePacked(seed, i))) % (1 << 26)) - int256(1 << 25);
            }
            uint256 expected = Qwen3.argmaxClassifier(c, o, s, xb);
            for (uint256 j = 0; j < shardCounts.length; ++j) {
                assertEq(_argmaxSharded(abi.encodePacked(xb), shardCounts[j]), expected, "shard merge mismatch");
            }
        }

        // crafted tie: the zero vector makes every logit 0, so first-max-wins picks 0
        int256[] memory zero = new int256[](dim);
        assertEq(Qwen3.argmaxClassifier(c, o, s, zero), 0, "monolithic tie must pick id 0");
        for (uint256 j = 0; j < shardCounts.length; ++j) {
            assertEq(_argmaxSharded(abi.encodePacked(zero), shardCounts[j]), 0, "tie merge mismatch");
        }
    }

    // -------------------------------------------------- KV wire format

    /// @notice serialize -> hydrate -> serialize is the identity, and a forward pass
    ///         at a mid-sequence position over the hydrated cache is bit-identical
    ///         to one over the monolithically built cache
    function test_KvWireFormatRoundtrip() public view {
        Qwen3.Config memory c = Qwen3.unpack(SyntheticQwen.packedConfig());
        Qwen3.Layout memory o = Qwen3.layout(c);
        Qwen3.Store memory s = Qwen3.newStore(c, weightChunks);

        uint256 nPrefix = promptIds.length; // positions [0, nPrefix)
        uint256 maxPos = nPrefix + 1; // same stride on both sides — it bakes into the cache
        Qwen3.Buffers memory b1 = Qwen3.newBuffers(c, maxPos);
        for (uint256 i = 0; i < nPrefix; ++i) {
            Qwen3.forward(c, o, s, b1, promptIds[i], i);
        }

        bytes memory kv = Qwen3Seg.serializeKv(c, b1, 0, nLayers, 0, nPrefix);
        assertEq(kv.length, nLayers * 2 * nPrefix * kvd * 4, "wire length");

        Qwen3.Buffers memory b2 = Qwen3.newBuffers(c, maxPos);
        Qwen3Seg.hydrateKv(c, b2, 0, nLayers, nPrefix, kv);
        bytes memory kv2 = Qwen3Seg.serializeKv(c, b2, 0, nLayers, 0, nPrefix);
        assertEq(keccak256(kv2), keccak256(kv), "roundtrip not identity");

        // mid-sequence attention equivalence: full forward at position nPrefix
        Qwen3.forward(c, o, s, b1, promptIds[0], nPrefix);
        Qwen3.forward(c, o, s, b2, promptIds[0], nPrefix);
        for (uint256 i = 0; i < dim; ++i) {
            assertEq(b1.xb[i], b2.xb[i], "hydrated attention diverges");
        }
    }

    // ------------------------------------------------------------ driver

    /// @dev One segment call (single-layer range), with chain-link + commitment checks
    struct SegCall {
        uint256 maxPos;
        uint256 posLo;
        uint256 posHi;
        uint256 layer;
        uint32[] toks;
        bytes xIn;
        bytes32 upstream; // keccak256 of the upstream stage's xOut (when xIn nonempty)
    }

    /// @dev Run the whole generation as a segment driver would: batched prefill
    ///      (optionally split by position into `prefillParts`), then per-token
    ///      single-position pipelines through the per-layer segments, argmax via
    ///      2 merged vocab shards. Layer split is S=2 ([0,1), [1,2)).
    function _runSharded(uint256 maxNew, uint256 prefillParts) internal returns (uint32[] memory genIds) {
        uint256 pLen = promptIds.length;
        uint256 maxPos = pLen + maxNew;
        if (maxPos > seqCap) maxPos = seqCap;
        _resetKv();

        bytes memory lastX = _prefill(maxPos, prefillParts);
        genIds = new uint32[](maxPos - pLen);
        // first generated token comes from the last prompt position's final-norm output
        uint256 next = _argmaxSharded(_slice(lastX, lastX.length - dim * 32, dim * 32), 2);
        genIds[0] = uint32(next);
        uint256 nGen = 1;

        for (uint256 pos = pLen; pos + 1 < maxPos && next != stop0 && next != stop1; ++pos) {
            uint32[] memory toks = new uint32[](1);
            toks[0] = uint32(next);
            next = _argmaxSharded(_pipeline(maxPos, pos, pos + 1, toks), 2);
            genIds[nGen++] = uint32(next);
        }
        assembly ("memory-safe") {
            mstore(genIds, nGen)
        }
    }

    /// @dev Teacher-forced prefill over `parts` position shards of [0, pLen)
    function _prefill(uint256 maxPos, uint256 parts) internal returns (bytes memory lastX) {
        uint256 pLen = promptIds.length;
        uint256 start = 0;
        for (uint256 part = 0; part < parts; ++part) {
            uint256 end = (part + 1 == parts) ? pLen : start + pLen / parts;
            uint32[] memory toks = new uint32[](end - start);
            for (uint256 i = 0; i < toks.length; ++i) {
                toks[i] = promptIds[start + i];
            }
            lastX = _pipeline(maxPos, start, end, toks);
            start = end;
        }
    }

    /// @dev Positions [posLo, posHi) through all layer segments, wiring xOut -> xIn
    function _pipeline(uint256 maxPos, uint256 posLo, uint256 posHi, uint32[] memory toks)
        internal
        returns (bytes memory x)
    {
        x = _callSeg(SegCall(maxPos, posLo, posHi, 0, toks, "", bytes32(0)));
        for (uint256 l = 1; l < nLayers; ++l) {
            x = _callSeg(SegCall(maxPos, posLo, posHi, l, new uint32[](0), x, keccak256(x)));
        }
    }

    /// @dev Execute one segment; asserts the checkpoint chain link and that chk is
    ///      exactly the domain-separated commitment over the witnessed inputs/outputs
    function _callSeg(SegCall memory q) internal returns (bytes memory xOut) {
        if (q.xIn.length > 0) {
            assertEq(keccak256(q.xIn), q.upstream, "checkpoint chain broken");
        }
        bytes memory kvIn = bytes.concat(kAcc[q.layer], vAcc[q.layer]);
        Qwen3Seg.Span memory span = Qwen3Seg.Span(q.maxPos, q.posLo, q.posHi, q.layer, q.layer + 1);
        (bytes memory xo, bytes memory kvApp, bytes32 chk) = segEngine.forwardRange(
            dirRoot,
            bytes32(0),
            SyntheticQwen.packedConfig(),
            Qwen3Seg.Call(span, q.toks, q.xIn, kvIn, keccak256(q.xIn), keccak256(kvIn))
        );
        assertEq(chk, Qwen3Seg.segmentChk(span, q.toks, q.xIn, kvIn, xo, kvApp), "commitment mismatch");
        assertEq(xo.length, (q.posHi - q.posLo) * dim * 32, "xOut length");

        // fold this segment's KV append into the accumulated wire-format cache
        uint256 blk = (q.posHi - q.posLo) * kvd * 4;
        assertEq(kvApp.length, 2 * blk, "kvAppend length");
        kAcc[q.layer] = bytes.concat(kAcc[q.layer], _slice(kvApp, 0, blk));
        vAcc[q.layer] = bytes.concat(vAcc[q.layer], _slice(kvApp, blk, blk));
        xOut = xo;
    }

    /// @dev Merge rule: higher score wins; on equal score the LOWER id wins
    function _argmaxSharded(bytes memory xb, uint256 m) internal view returns (uint256 bestId) {
        int256 best = type(int256).min;
        bestId = type(uint256).max;
        uint256 step = vocab / m;
        for (uint256 i = 0; i < m; ++i) {
            uint256 lo = i * step;
            uint256 hi = (i + 1 == m) ? vocab : lo + step;
            (int256 sc, uint256 id) =
                segEngine.argmaxRange(dirRoot, bytes32(0), SyntheticQwen.packedConfig(), xb, lo, hi);
            if (sc > best || (sc == best && id < bestId)) {
                best = sc;
                bestId = id;
            }
        }
    }

    function _resetKv() internal {
        delete kAcc;
        delete vAcc;
        for (uint256 l = 0; l < nLayers; ++l) {
            kAcc.push("");
            vAcc.push("");
        }
    }

    function _assertSameIds(uint32[] memory got, uint32[] memory expected) internal pure {
        assertEq(got.length, expected.length, "token count mismatch");
        for (uint256 i = 0; i < expected.length; ++i) {
            assertEq(uint256(got[i]), uint256(expected[i]), "token id mismatch");
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        assembly ("memory-safe") {
            let src := add(add(data, 0x20), start)
            let dst := add(out, 0x20)
            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } { mstore(add(dst, i), mload(add(src, i))) }
        }
    }
}
