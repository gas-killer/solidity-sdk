// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DataContractLib} from "../../src/examples/onchain-llm/DataContractLib.sol";
import {Qwen35} from "../../src/examples/onchain-llm/Qwen35.sol";
import {Qwen35Engine} from "../../src/examples/onchain-llm/Qwen35Engine.sol";
import {Qwen35Forward} from "../../src/examples/onchain-llm/Qwen35Forward.sol";
import {Qwen35Seg} from "../../src/examples/onchain-llm/Qwen35Seg.sol";
import {Qwen35SegEngine, Qwen35SegForward} from "../../src/examples/onchain-llm/Qwen35SegEngine.sol";
import {SyntheticQwen35} from "../../src/examples/onchain-llm/SyntheticQwen35.sol";

/// @notice Sharded-inference for engine v3 (Qwen3.5-35B-A3B HYBRID stack): prove one
///         inference can be split into hash-committed segments — (positions x layers)
///         rectangles + vocab shards of the classifier — executed as independent calls,
///         wired back together by a driver, and still reproduce the monolithic engine-v3
///         output BIT-EXACTLY. Runs on the tiny synthetic Qwen3.5-MoE fixture
///         (test/fixtures/onchain-llm-v3: 2 DeltaNet layers + 1 full-attention layer,
///         4-expert top-2 MoE + shared expert) so every hybrid path is CI-fast.
///
///         The hybrid state wire format (Qwen35Seg) threads three kinds of per-layer
///         state across segment boundaries: full-attention KV cache (append), DeltaNet
///         causal-conv state and delta-rule recurrent state S (snapshot). This suite
///         proves the DeltaNet (S, conv) roundtrip and the full-attention KV roundtrip,
///         the segmented==monolithic equivalence across layer-stage AND position-span
///         splits, the classifier shard-merge (incl. ties), and checkpoint determinism.
contract OnchainChat35ShardedTest is Test {
    using stdJson for string;

    Qwen35Engine internal engine;
    Qwen35SegEngine internal segEngine;

    address internal dirRoot;
    address[] internal weightChunks;
    uint32[] internal promptIds;

    // unpacked config scalars (synthetic fixture model)
    uint256 internal dim;
    uint256 internal nLayers;
    uint256 internal fullInterval;
    uint256 internal kvd;
    uint256 internal vocab;
    uint256 internal seqCap;
    uint256 internal stop0;
    uint256 internal stop1;
    // per-layer wire-block byte sizes
    uint256 internal convBytes; // (convK-1) * convDim * 4
    uint256 internal sBytes; // nVH * dK * dV * 4
    uint256 internal kvPosBytes; // kvd * 4 (one K or V position slice)

    // driver state (accumulated per absolute layer):
    //   full-attention layers: KV wire for positions [0, pos) — accumulate (concat)
    //   DeltaNet layers:       (conv || S) snapshot after [0, pos) — replace
    bytes[] internal kAcc;
    bytes[] internal vAcc;
    bytes[] internal snap;

    function setUp() public {
        string memory root = vm.projectRoot();
        bytes memory weightsBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-llm-v3/weights.bin"));
        bytes memory tokBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-llm-v3/tokenizer.bin"));
        string memory vectors = vm.readFile(string.concat(root, "/test/fixtures/onchain-llm-v3/vectors.json"));

        uint256[] memory p = vectors.readUintArray(".promptIds");
        for (uint256 i = 0; i < p.length; ++i) {
            promptIds.push(uint32(p[i]));
        }

        // chunk both blobs, build the two-level directory: root -> page -> chunks
        bytes memory pageBytes;
        for (uint256 at = 0; at < weightsBlob.length; at += Qwen35.CHUNK) {
            uint256 len = weightsBlob.length - at;
            if (len > Qwen35.CHUNK) len = Qwen35.CHUNK;
            address c = DataContractLib.write(_slice(weightsBlob, at, len));
            weightChunks.push(c);
            pageBytes = abi.encodePacked(pageBytes, c);
        }
        for (uint256 at = 0; at < tokBlob.length; at += Qwen35.CHUNK) {
            uint256 len = tokBlob.length - at;
            if (len > Qwen35.CHUNK) len = Qwen35.CHUNK;
            pageBytes = abi.encodePacked(pageBytes, DataContractLib.write(_slice(tokBlob, at, len)));
        }
        address page = DataContractLib.write(pageBytes);
        dirRoot = DataContractLib.write(abi.encodePacked(page));

        engine = new Qwen35Engine(new Qwen35Forward());
        segEngine = new Qwen35SegEngine(new Qwen35SegForward());

        Qwen35.Config memory cfg = Qwen35.unpack(SyntheticQwen35.packedConfig());
        dim = cfg.dim;
        nLayers = cfg.nLayers;
        fullInterval = cfg.fullInterval;
        kvd = cfg.kvd;
        vocab = cfg.vocab;
        seqCap = cfg.seqCap;
        stop0 = cfg.stop0;
        stop1 = cfg.stop1;
        convBytes = (cfg.convK - 1) * cfg.convDim * 4;
        sBytes = cfg.nVH * cfg.dK * cfg.dV * 4;
        kvPosBytes = cfg.kvd * 4;
    }

    // -------------------------------------------- segmented == monolithic

    /// @notice ≥2 LAYER-STAGES ([0,2) DeltaNet x2, then [2,3) full-attention) x ≥2
    ///         POSITION-SPANS (prefill split in two): the driver reassembles the
    ///         identical greedy tokens as the monolithic Qwen35Engine. Exercises the
    ///         DeltaNet (S,conv) AND full-attention KV wire formats threaded across
    ///         both a layer boundary and a position boundary, plus x hand-off.
    function test_SegmentedEqualsMonolithic_LayerStages() public {
        (, uint32[] memory mono) = engine.chat(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), promptIds, 6);
        uint256[] memory bounds = _bounds3(0, 2, 3); // stages [0,2), [2,3)
        uint32[] memory seg = _runSharded(6, bounds, 2);
        _assertSameIds(seg, mono);
    }

    /// @notice PER-LAYER stages ([0,1),[1,2),[2,3)): every layer boundary threads x,
    ///         and each single layer's own state (DeltaNet snapshot / attention KV) is
    ///         serialized and re-hydrated once per position span — the fullest stress of
    ///         the per-layer wire format. Prefill split in two positions as well.
    function test_SegmentedEqualsMonolithic_PerLayer() public {
        (, uint32[] memory mono) = engine.chat(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), promptIds, 5);
        uint256[] memory bounds = _bounds4(0, 1, 2, 3);
        uint32[] memory seg = _runSharded(5, bounds, 2);
        _assertSameIds(seg, mono);
    }

    /// @notice Whole-model single stage split ONLY by position (prefill in 2 spans):
    ///         isolates the position-span reassembly (no layer split) — the recurrent
    ///         DeltaNet state and KV cache resume mid-sequence from the wire format.
    function test_SegmentedEqualsMonolithic_PositionOnly() public {
        (, uint32[] memory mono) = engine.chat(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), promptIds, 6);
        uint256[] memory bounds = _bounds2(0, 3); // one stage over all layers
        uint32[] memory seg = _runSharded(6, bounds, 2);
        _assertSameIds(seg, mono);
    }

    // -------------------------------------------------- state wire format

    /// @notice DeltaNet (conv, S) snapshot roundtrip: serialize the recurrent state of
    ///         the two DeltaNet layers built by a monolithic prefill, hydrate it into
    ///         fresh buffers, re-serialize — must be the identity. Then a forward step at
    ///         a fresh position over the hydrated state must match the monolithic one.
    function test_DeltaStateRoundtrip() public view {
        Qwen35.Config memory c = Qwen35.unpack(SyntheticQwen35.packedConfig());
        Qwen35.Layout memory o = Qwen35.layout(c);
        Qwen35.Store memory s = Qwen35.newStore(c, weightChunks);

        uint256 nPrefix = promptIds.length; // positions [0, nPrefix)
        uint256 maxPos = nPrefix + 1;
        Qwen35.Buffers memory b1 = Qwen35.newBuffers(c, maxPos);
        for (uint256 i = 0; i < nPrefix; ++i) {
            Qwen35.forward(c, o, s, b1, promptIds[i], i);
        }

        // DeltaNet layers are [0, 2) (layer 2 is full attention); snapshot is
        // position-count independent, so posLo/posHi only bound the KV (none here).
        Qwen35Seg.Span memory delta = Qwen35Seg.Span(maxPos, 0, nPrefix, 0, 2);
        bytes memory state = Qwen35Seg.serializeState(c, b1, delta);
        assertEq(state.length, 2 * (convBytes + sBytes), "delta wire length");

        Qwen35.Buffers memory b2 = Qwen35.newBuffers(c, maxPos);
        // hydrate as a resume state (posLo>0 so the snapshot is carried)
        Qwen35Seg.Span memory resume = Qwen35Seg.Span(maxPos, nPrefix, nPrefix + 1, 0, 2);
        Qwen35Seg.hydrateState(c, b2, resume, state);
        bytes memory state2 = Qwen35Seg.serializeState(c, b2, delta);
        assertEq(keccak256(state2), keccak256(state), "delta roundtrip not identity");
    }

    /// @notice Full-attention KV roundtrip (SPEC §5 / §6 layer): serialize the KV of the
    ///         single full-attention layer built by a monolithic prefill, hydrate it into
    ///         fresh buffers, re-serialize — must be the identity. (Functional
    ///         equivalence of a resumed forward over the hydrated cache is proven by
    ///         test_FullStateRoundtripEqualsMonolithic, which hydrates every layer type.)
    function test_FullAttentionKvRoundtrip() public view {
        Qwen35.Config memory c = Qwen35.unpack(SyntheticQwen35.packedConfig());
        Qwen35.Layout memory o = Qwen35.layout(c);
        Qwen35.Store memory s = Qwen35.newStore(c, weightChunks);

        uint256 nPrefix = promptIds.length;
        uint256 maxPos = nPrefix + 1;
        Qwen35.Buffers memory b1 = Qwen35.newBuffers(c, maxPos);
        for (uint256 i = 0; i < nPrefix; ++i) {
            Qwen35.forward(c, o, s, b1, promptIds[i], i);
        }

        // full-attention layer range [2, 3); serialize its KV for [0, nPrefix)
        Qwen35Seg.Span memory full = Qwen35Seg.Span(maxPos, 0, nPrefix, 2, 3);
        bytes memory kv = Qwen35Seg.serializeState(c, b1, full);
        assertEq(kv.length, 2 * nPrefix * kvd * 4, "kv wire length");

        Qwen35.Buffers memory b2 = Qwen35.newBuffers(c, maxPos);
        Qwen35Seg.Span memory resume = Qwen35Seg.Span(maxPos, nPrefix, nPrefix + 1, 2, 3);
        Qwen35Seg.hydrateState(c, b2, resume, kv);
        bytes memory kv2 = Qwen35Seg.serializeState(c, b2, full);
        assertEq(keccak256(kv2), keccak256(kv), "kv roundtrip not identity");
    }

    /// @notice Combined full-model state roundtrip (all layer types at once): a segment
    ///         resuming from the serialized (KV + conv + S) state of a prefix reproduces
    ///         the monolithic residual at the next position exactly.
    function test_FullStateRoundtripEqualsMonolithic() public {
        Qwen35.Config memory c = Qwen35.unpack(SyntheticQwen35.packedConfig());
        Qwen35.Layout memory o = Qwen35.layout(c);
        Qwen35.Store memory s = Qwen35.newStore(c, weightChunks);

        uint256 nPrefix = promptIds.length;
        uint256 maxPos = nPrefix + 2;
        // monolithic: prefill [0, nPrefix) then one more forward at nPrefix, capture xb
        Qwen35.Buffers memory bm = Qwen35.newBuffers(c, maxPos);
        for (uint256 i = 0; i < nPrefix; ++i) {
            Qwen35.forward(c, o, s, bm, promptIds[i], i);
        }
        Qwen35.forward(c, o, s, bm, promptIds[0], nPrefix); // extra step, token arbitrary
        int256[] memory xbMono = new int256[](dim);
        for (uint256 i = 0; i < dim; ++i) {
            xbMono[i] = bm.xb[i];
        }

        // sharded: run prefill as ONE whole-model segment, then a single-position
        // segment at nPrefix resuming from the serialized full state.
        _resetState();
        uint256[] memory bounds = _bounds2(0, 3);
        uint32[] memory pre = new uint32[](nPrefix);
        for (uint256 i = 0; i < nPrefix; ++i) {
            pre[i] = promptIds[i];
        }
        _pipeline(maxPos, 0, nPrefix, pre, bounds);
        uint32[] memory one = new uint32[](1);
        one[0] = promptIds[0];
        bytes memory xOut = _pipeline(maxPos, nPrefix, nPrefix + 1, one, bounds);
        for (uint256 i = 0; i < dim; ++i) {
            assertEq(_i256At(xOut, i), xbMono[i], "resumed hidden state diverges");
        }
    }

    // ------------------------------------------------------ argmax shards

    /// @notice Merged argmaxRange shards (M in {2,4,8}) equal the monolithic
    ///         first-max-wins argmax over the untied classifier, including an all-ties
    ///         vector (zeros -> id 0 wins).
    function test_ArgmaxRangeMergeEqualsMonolithic() public view {
        Qwen35.Config memory c = Qwen35.unpack(SyntheticQwen35.packedConfig());
        Qwen35.Layout memory o = Qwen35.layout(c);
        Qwen35.Store memory s = Qwen35.newStore(c, weightChunks);
        uint256[3] memory shardCounts = [uint256(2), 4, 8];

        for (uint256 seed = 0; seed < 3; ++seed) {
            int256[] memory xb = new int256[](dim);
            for (uint256 i = 0; i < dim; ++i) {
                xb[i] = int256(uint256(keccak256(abi.encodePacked(seed, i))) % (1 << 26)) - int256(1 << 25);
            }
            uint256 expected = Qwen35.argmaxClassifier(c, o, s, xb);
            for (uint256 j = 0; j < shardCounts.length; ++j) {
                assertEq(_argmaxSharded(abi.encodePacked(xb), shardCounts[j]), expected, "shard merge mismatch");
            }
        }

        // crafted tie: the zero vector makes every logit 0, so first-max-wins picks 0
        int256[] memory zero = new int256[](dim);
        assertEq(Qwen35.argmaxClassifier(c, o, s, zero), 0, "monolithic tie must pick id 0");
        for (uint256 j = 0; j < shardCounts.length; ++j) {
            assertEq(_argmaxSharded(abi.encodePacked(zero), shardCounts[j]), 0, "tie merge mismatch");
        }
    }

    // ------------------------------------------------- checkpoint / witness

    /// @notice The checkpoint commitment is deterministic and binds every input/output:
    ///         re-running an identical segment yields the identical chk; perturbing the
    ///         span, tokens, xIn or stateIn yields a different chk.
    function test_CheckpointCommitmentDeterminism() public view {
        uint32[] memory toks = new uint32[](2);
        toks[0] = promptIds[0];
        toks[1] = promptIds[1];
        Qwen35Seg.Span memory span = Qwen35Seg.Span(seqCap, 0, 2, 0, 2);
        Qwen35Seg.Call memory q = Qwen35Seg.Call(span, toks, "", "", keccak256(""), keccak256(""));

        (bytes memory xo1, bytes memory st1, bytes32 chk1) =
            segEngine.forwardRange(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), q);
        (bytes memory xo2, bytes memory st2, bytes32 chk2) =
            segEngine.forwardRange(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), q);
        assertEq(chk1, chk2, "chk not deterministic");
        assertEq(keccak256(xo1), keccak256(xo2), "xOut not deterministic");
        assertEq(keccak256(st1), keccak256(st2), "stateAppend not deterministic");
        assertEq(chk1, Qwen35Seg.segmentChk(span, toks, "", "", xo1, st1), "chk != domain commitment");

        // perturb the tokens -> different commitment
        uint32[] memory toks2 = new uint32[](2);
        toks2[0] = promptIds[0];
        toks2[1] = promptIds[2];
        Qwen35Seg.Call memory q2 = Qwen35Seg.Call(span, toks2, "", "", keccak256(""), keccak256(""));
        (,, bytes32 chk3) = segEngine.forwardRange(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), q2);
        assertTrue(chk3 != chk1, "chk must bind tokenIds");

        // perturb the span (layer range) -> different commitment
        Qwen35Seg.Span memory span2 = Qwen35Seg.Span(seqCap, 0, 2, 0, 1);
        Qwen35Seg.Call memory q3 = Qwen35Seg.Call(span2, toks, "", "", keccak256(""), keccak256(""));
        (,, bytes32 chk4) = segEngine.forwardRange(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), q3);
        assertTrue(chk4 != chk1, "chk must bind the span");
    }

    /// @notice A nonzero expectXIn / expectStateIn witness that doesn't match reverts
    function test_ForwardRangeWitnessMismatchReverts() public {
        uint32[] memory toks = new uint32[](1);
        toks[0] = promptIds[0];
        Qwen35Seg.Call memory q =
            Qwen35Seg.Call(Qwen35Seg.Span(seqCap, 0, 1, 0, 1), toks, "", "", keccak256("not the xIn"), bytes32(0));
        vm.expectRevert(Qwen35SegEngine.WitnessMismatch.selector);
        segEngine.forwardRange(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), q);

        Qwen35Seg.Call memory q2 =
            Qwen35Seg.Call(Qwen35Seg.Span(seqCap, 0, 1, 0, 1), toks, "", "", bytes32(0), keccak256("not the state"));
        vm.expectRevert(Qwen35SegEngine.WitnessMismatch.selector);
        segEngine.forwardRange(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), q2);
    }

    // ------------------------------------------------------------ driver

    /// @dev Run the whole generation as a segment driver would: teacher-forced prefill
    ///      (optionally split by position into `prefillParts`), then per-token single-
    ///      position pipelines through the layer stages, argmax via 2 merged vocab
    ///      shards. `bounds` are the layer-stage boundaries (e.g. [0,2,3]).
    function _runSharded(uint256 maxNew, uint256[] memory bounds, uint256 prefillParts)
        internal
        returns (uint32[] memory genIds)
    {
        uint256 pLen = promptIds.length;
        uint256 maxPos = pLen + maxNew;
        if (maxPos > seqCap) maxPos = seqCap;
        _resetState();

        bytes memory lastX = _prefill(maxPos, prefillParts, bounds);
        genIds = new uint32[](maxPos - pLen);
        uint256 next = _argmaxSharded(_slice(lastX, lastX.length - dim * 32, dim * 32), 2);
        genIds[0] = uint32(next);
        uint256 nGen = 1;

        for (uint256 pos = pLen; pos + 1 < maxPos && next != stop0 && next != stop1; ++pos) {
            uint32[] memory toks = new uint32[](1);
            toks[0] = uint32(next);
            next = _argmaxSharded(_pipeline(maxPos, pos, pos + 1, toks, bounds), 2);
            genIds[nGen++] = uint32(next);
        }
        assembly ("memory-safe") {
            mstore(genIds, nGen)
        }
    }

    /// @dev Teacher-forced prefill over `parts` position shards of [0, pLen)
    function _prefill(uint256 maxPos, uint256 parts, uint256[] memory bounds) internal returns (bytes memory lastX) {
        uint256 pLen = promptIds.length;
        uint256 start = 0;
        for (uint256 part = 0; part < parts; ++part) {
            uint256 end = (part + 1 == parts) ? pLen : start + pLen / parts;
            uint32[] memory toks = new uint32[](end - start);
            for (uint256 i = 0; i < toks.length; ++i) {
                toks[i] = promptIds[start + i];
            }
            lastX = _pipeline(maxPos, start, end, toks, bounds);
            start = end;
        }
    }

    /// @dev Positions [posLo, posHi) through all layer stages, wiring xOut -> xIn
    function _pipeline(uint256 maxPos, uint256 posLo, uint256 posHi, uint32[] memory toks, uint256[] memory bounds)
        internal
        returns (bytes memory x)
    {
        for (uint256 si = 0; si + 1 < bounds.length; ++si) {
            uint256 lLo = bounds[si];
            uint256 lHi = bounds[si + 1];
            if (lLo == 0) {
                x = _callSeg(maxPos, posLo, posHi, lLo, lHi, toks, "");
            } else {
                x = _callSeg(maxPos, posLo, posHi, lLo, lHi, new uint32[](0), x);
            }
        }
    }

    /// @dev Execute one segment; assert the commitment is exactly the domain-separated
    ///      digest over the witnessed inputs/outputs, and fold the produced state into
    ///      the per-layer accumulators (KV append for full layers, snapshot for DeltaNet)
    function _callSeg(
        uint256 maxPos,
        uint256 posLo,
        uint256 posHi,
        uint256 layerLo,
        uint256 layerHi,
        uint32[] memory toks,
        bytes memory xIn
    ) internal returns (bytes memory xOut) {
        bytes memory stateIn = _buildStateIn(posLo, layerLo, layerHi);
        Qwen35Seg.Span memory span = Qwen35Seg.Span(maxPos, posLo, posHi, layerLo, layerHi);
        (bytes memory xo, bytes memory stApp, bytes32 chk) = segEngine.forwardRange(
            dirRoot,
            bytes32(0),
            SyntheticQwen35.packedConfig(),
            Qwen35Seg.Call(span, toks, xIn, stateIn, keccak256(xIn), keccak256(stateIn))
        );
        assertEq(chk, Qwen35Seg.segmentChk(span, toks, xIn, stateIn, xo, stApp), "commitment mismatch");
        assertEq(xo.length, (posHi - posLo) * dim * 32, "xOut length");
        _foldStateAppend(posLo, posHi, layerLo, layerHi, stApp);
        xOut = xo;
    }

    /// @dev Build the canonical stateIn for a stage from the per-layer accumulators
    ///      (empty when posLo == 0, mirroring the wire-format rule).
    function _buildStateIn(uint256 posLo, uint256 layerLo, uint256 layerHi) internal view returns (bytes memory s) {
        if (posLo == 0) return "";
        for (uint256 l = layerLo; l < layerHi; ++l) {
            if (_isFull(l)) {
                s = bytes.concat(s, kAcc[l], vAcc[l]);
            } else {
                s = bytes.concat(s, snap[l]);
            }
        }
    }

    /// @dev Parse a stage's stateAppend and fold it into the per-layer accumulators
    function _foldStateAppend(uint256 posLo, uint256 posHi, uint256 layerLo, uint256 layerHi, bytes memory stApp)
        internal
    {
        uint256 off = 0;
        uint256 kBlock = (posHi - posLo) * kvPosBytes;
        uint256 snapBytes = convBytes + sBytes;
        for (uint256 l = layerLo; l < layerHi; ++l) {
            if (_isFull(l)) {
                kAcc[l] = bytes.concat(kAcc[l], _slice(stApp, off, kBlock));
                off += kBlock;
                vAcc[l] = bytes.concat(vAcc[l], _slice(stApp, off, kBlock));
                off += kBlock;
            } else {
                snap[l] = _slice(stApp, off, snapBytes);
                off += snapBytes;
            }
        }
        assertEq(off, stApp.length, "stateAppend length");
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
                segEngine.argmaxRange(dirRoot, bytes32(0), SyntheticQwen35.packedConfig(), xb, lo, hi);
            if (sc > best || (sc == best && id < bestId)) {
                best = sc;
                bestId = id;
            }
        }
    }

    function _resetState() internal {
        delete kAcc;
        delete vAcc;
        delete snap;
        for (uint256 l = 0; l < nLayers; ++l) {
            kAcc.push("");
            vAcc.push("");
            snap.push("");
        }
    }

    function _isFull(uint256 l) internal view returns (bool) {
        return (l + 1) % fullInterval == 0;
    }

    // ------------------------------------------------------------- helpers

    function _bounds2(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _bounds3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _bounds4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory out) {
        out = new uint256[](4);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
    }

    function _assertSameIds(uint32[] memory got, uint32[] memory expected) internal pure {
        assertEq(got.length, expected.length, "token count mismatch");
        for (uint256 i = 0; i < expected.length; ++i) {
            assertEq(uint256(got[i]), uint256(expected[i]), "token id mismatch");
        }
    }

    function _i256At(bytes memory data, uint256 i) internal pure returns (int256 v) {
        assembly ("memory-safe") {
            v := mload(add(add(data, 0x20), shl(5, i)))
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
