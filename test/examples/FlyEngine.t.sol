// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DataContractLib} from "../../src/examples/onchain-llm/DataContractLib.sol";
import {FlyEngine} from "../../src/examples/onchain-fly/FlyEngine.sol";
import {FlyTypes} from "../../src/examples/onchain-fly/FlyTypes.sol";

/// @notice FlyEngine against bit-exact vectors from tools/fly_int.py on the 64-neuron synthetic graph
///         (tools/fly_synth.py): genesis, warm-up, step, segment composition, decide, rasterize, overlay
///         parity, tamper rejection, artifact checks, and a gas probe (HANDOFF §7.3).
contract FlyEngineTest is Test {
    using stdJson for string;

    uint256 internal constant CHUNK = 24_575;

    FlyEngine internal engine;
    string internal vectors;
    bytes32[3] internal cfg;
    address internal graphRoot;
    address internal warmRoot;
    bytes internal ptrBlob;
    bytes internal edgesBlob;
    bytes internal metaBlob;

    function setUp() public {
        string memory root = vm.projectRoot();
        ptrBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-fly/ptr.bin"));
        edgesBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-fly/edges.bin"));
        metaBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-fly/meta.bin"));
        vectors = vm.readFile(string.concat(root, "/test/fixtures/onchain-fly/vectors.json"));
        string[] memory words = vectors.readStringArray(".packedConfig");
        for (uint256 i = 0; i < 3; ++i) {
            cfg[i] = bytes32(vm.parseUint(words[i]));
        }
        engine = new FlyEngine();
        bytes[] memory blobs = new bytes[](3);
        blobs[0] = ptrBlob;
        blobs[1] = edgesBlob;
        blobs[2] = metaBlob;
        graphRoot = _directory(blobs);
        bytes[] memory warm = new bytes[](1);
        warm[0] = vm.parseBytes(vectors.readString(".warm.stateOut"));
        warmRoot = _directory(warm);
    }

    // ------------------------------------------------------------------ fixtures

    function _directory(bytes[] memory blobs) internal returns (address) {
        bytes memory pageBytes;
        for (uint256 b = 0; b < blobs.length; ++b) {
            for (uint256 at = 0; at < blobs[b].length; at += CHUNK) {
                uint256 len = blobs[b].length - at;
                if (len > CHUNK) len = CHUNK;
                address c = DataContractLib.write(_slice(blobs[b], at, len));
                pageBytes = abi.encodePacked(pageBytes, c);
            }
        }
        address page = DataContractLib.write(pageBytes);
        return DataContractLib.write(abi.encodePacked(page));
    }

    function _slice(bytes memory b, uint256 at, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = b[at + i];
        }
    }

    function _u32s(uint256[] memory xs) internal pure returns (uint32[] memory out) {
        out = new uint32[](xs.length);
        for (uint256 i = 0; i < xs.length; ++i) {
            out[i] = uint32(xs[i]);
        }
    }

    function _stepInput(bytes memory stateIn, bytes memory driveIn, uint32[] memory ids, uint256 nSteps)
        internal
        view
        returns (FlyEngine.StepInput memory a)
    {
        a.graphRoot = graphRoot;
        a.cfg = cfg;
        a.stateIn = stateIn;
        a.driveIn = driveIn;
        a.readoutIds = ids;
        a.nSteps = nSteps;
        a.expectStateIn = keccak256(stateIn);
    }

    /// @dev Zero the per-call `count` field of every neuron word (bytes 20..24 of each 32-byte word)
    function _stripCounts(bytes memory wire) internal pure returns (bytes memory out) {
        out = wire;
        uint256 n = uint256(uint32(bytes4(_sliceBytes(wire, 1, 4))));
        for (uint256 i = 0; i < n; ++i) {
            uint256 off = 128 + 32 * i + 20;
            out[off] = 0;
            out[off + 1] = 0;
            out[off + 2] = 0;
            out[off + 3] = 0;
        }
    }

    function _sliceBytes(bytes memory b, uint256 at, uint256 len) internal pure returns (bytes memory) {
        return _slice(b, at, len);
    }

    function _observation() internal view returns (FlyTypes.Observation memory o) {
        string memory k = ".decide.observation";
        o.windowId = uint32(vectors.readUint(string.concat(k, ".windowId")));
        uint256[] memory buy = vectors.readUintArray(string.concat(k, ".buyQuote"));
        uint256[] memory sell = vectors.readUintArray(string.concat(k, ".sellQuote"));
        for (uint256 i = 0; i < 16; ++i) {
            o.buyQuote[i] = uint64(buy[i]);
            o.sellQuote[i] = uint64(sell[i]);
        }
        o.volRef = uint64(vectors.readUint(string.concat(k, ".volRef")));
        o.spotQ64 = uint128(vm.parseUint(vectors.readString(string.concat(k, ".spotQ64"))));
        o.twapQ64 = uint128(vm.parseUint(vectors.readString(string.concat(k, ".twapQ64"))));
        o.feeIncomeQuote = uint64(vectors.readUint(string.concat(k, ".feeIncomeQuote")));
        o.lpLossQuote = uint64(vectors.readUint(string.concat(k, ".lpLossQuote")));
    }

    // ------------------------------------------------------------------ tests

    function test_GenesisMatchesReference() public view {
        bytes memory got = engine.genesisState(cfg);
        assertEq(keccak256(got), keccak256(vm.parseBytes(vectors.readString(".genesis"))), "genesis wire mismatch");
    }

    function test_WarmupMatchesReference() public view {
        uint256 steps = vectors.readUint(".warm.steps");
        (bytes memory out, bytes32 commitment) = engine.warmup(graphRoot, cfg, steps);
        assertEq(keccak256(out), keccak256(vm.parseBytes(vectors.readString(".warm.stateOut"))), "warm state mismatch");
        assertEq(commitment, vectors.readBytes32(".warm.warmCommitment"), "warm commitment mismatch");
    }

    function test_StepMatchesReference() public view {
        FlyEngine.StepInput memory a = _stepInput(
            vm.parseBytes(vectors.readString(".step.stateIn")),
            vm.parseBytes(vectors.readString(".step.driveIn")),
            _u32s(vectors.readUintArray(".step.readoutIds")),
            vectors.readUint(".step.nSteps")
        );
        (bytes memory out, uint32[] memory counts, bytes32 chk) = engine.step(a);
        assertEq(keccak256(out), keccak256(vm.parseBytes(vectors.readString(".step.stateOut"))), "stateOut mismatch");
        uint256[] memory expected = vectors.readUintArray(".step.readoutCounts");
        assertEq(counts.length, expected.length, "count length");
        for (uint256 i = 0; i < counts.length; ++i) {
            assertEq(uint256(counts[i]), expected[i], "readout count mismatch");
        }
        assertEq(chk, vectors.readBytes32(".step.chk"), "chk mismatch");
    }

    /// @notice step([0,t1)) then step([t1,T)) reproduces step([0,T)) exactly (modulo per-call counts, which add up)
    function test_StepComposesExactly() public view {
        bytes memory gen = vm.parseBytes(vectors.readString(".step.stateIn"));
        bytes memory drive = vm.parseBytes(vectors.readString(".step.driveIn"));
        uint32[] memory ids = _u32s(vectors.readUintArray(".step.readoutIds"));
        uint256 T = vectors.readUint(".step.nSteps");
        uint256 t1 = vectors.readUint(".step.split.t1");

        (bytes memory mid, uint32[] memory c1, bytes32 chk1) = engine.step(_stepInput(gen, drive, ids, t1));
        assertEq(keccak256(mid), keccak256(vm.parseBytes(vectors.readString(".step.split.mid"))), "mid mismatch");
        assertEq(chk1, vectors.readBytes32(".step.split.chk1"), "chk1 mismatch");

        (bytes memory out, uint32[] memory c2, bytes32 chk2) = engine.step(_stepInput(mid, drive, ids, T - t1));
        assertEq(chk2, vectors.readBytes32(".step.split.chk2"), "chk2 mismatch");
        bytes memory full = vm.parseBytes(vectors.readString(".step.stateOut"));
        assertEq(keccak256(_stripCounts(out)), keccak256(_stripCounts(full)), "composed state mismatch");
        uint256[] memory expected = vectors.readUintArray(".step.readoutCounts");
        for (uint256 i = 0; i < expected.length; ++i) {
            assertEq(uint256(c1[i]) + uint256(c2[i]), expected[i], "counts do not add up");
        }
    }

    function test_DecideMatchesReference() public view {
        bytes memory frame = vm.parseBytes(vectors.readString(".decide.frame"));
        FlyTypes.Stimulus memory stim = FlyTypes.Stimulus({
            punishSteps: uint16(vectors.readUint(".decide.stimulus.punishSteps")),
            rewardSteps: uint16(vectors.readUint(".decide.stimulus.rewardSteps"))
        });
        uint256[] memory r0 = vectors.readUintArray(".decide.rates0");
        uint32[4] memory rates0 = [uint32(r0[0]), uint32(r0[1]), uint32(r0[2]), uint32(r0[3])];

        (FlyTypes.Readout memory r, bytes32 spikeRoot) = engine.decide(graphRoot, warmRoot, cfg, frame, stim, rates0);

        uint256[] memory rates = vectors.readUintArray(".decide.readout.rateMilliHz");
        uint256[] memory last30 = vectors.readUintArray(".decide.readout.spikesLast30ms");
        uint256[] memory wc = vectors.readUintArray(".decide.readout.windowCounts");
        for (uint256 j = 0; j < 4; ++j) {
            assertEq(uint256(r.rateMilliHz[j]), rates[j], "rate mismatch");
            assertEq(uint256(r.spikesLast30ms[j]), last30[j], "last30 mismatch");
        }
        for (uint256 j = 0; j < 14; ++j) {
            assertEq(uint256(r.windowCounts[j]), wc[j], "window count mismatch");
        }
        assertEq(uint256(r.totalSpikes), vectors.readUint(".decide.readout.totalSpikes"), "total spikes mismatch");
        assertEq(spikeRoot, vectors.readBytes32(".decide.spikeRoot"), "spikeRoot mismatch");
    }

    function test_RasterizeMatchesReference() public view {
        bytes memory frame = engine.rasterize(graphRoot, cfg, _observation());
        assertEq(keccak256(frame), keccak256(vm.parseBytes(vectors.readString(".decide.frame"))), "frame mismatch");
    }

    function test_TamperedStateReverts() public {
        bytes memory mid = vm.parseBytes(vectors.readString(".step.split.mid"));
        // set neuron 0's `last` (bytes 24..30 of its word) to the clock (bytes 5..11 of the header)
        for (uint256 i = 0; i < 6; ++i) {
            mid[128 + 24 + i] = mid[5 + i];
        }
        bytes memory drive = vm.parseBytes(vectors.readString(".step.driveIn"));
        uint32[] memory ids = _u32s(vectors.readUintArray(".step.readoutIds"));
        FlyEngine.StepInput memory a = _stepInput(mid, drive, ids, 10);
        vm.expectRevert(FlyEngine.MalformedState.selector);
        engine.step(a);
    }

    function test_StateHashMismatchReverts() public {
        bytes memory gen = vm.parseBytes(vectors.readString(".step.stateIn"));
        FlyEngine.StepInput memory a = _stepInput(gen, "", new uint32[](0), 1);
        a.expectStateIn = bytes32(uint256(1));
        vm.expectRevert(FlyEngine.StateHashMismatch.selector);
        engine.step(a);
    }

    /// @notice Overlay mode (chunks etched at derived phantom addresses) is byte-identical to directory mode
    function test_OverlayModeMatchesDirectoryMode() public {
        bytes32 manifest = keccak256(abi.encodePacked(keccak256(ptrBlob), keccak256(edgesBlob), keccak256(metaBlob)));
        bytes[3] memory blobs = [ptrBlob, edgesBlob, metaBlob];
        uint256 idx = 0;
        for (uint256 b = 0; b < 3; ++b) {
            for (uint256 at = 0; at < blobs[b].length; at += CHUNK) {
                uint256 len = blobs[b].length - at;
                if (len > CHUNK) len = CHUNK;
                vm.etch(
                    engine.overlayChunkAddress(manifest, idx++), abi.encodePacked(hex"00", _slice(blobs[b], at, len))
                );
            }
        }
        FlyEngine.StepInput memory a = _stepInput(
            vm.parseBytes(vectors.readString(".step.stateIn")),
            vm.parseBytes(vectors.readString(".step.driveIn")),
            _u32s(vectors.readUintArray(".step.readoutIds")),
            vectors.readUint(".step.nSteps")
        );
        a.graphRoot = address(0);
        a.manifest = manifest;
        (bytes memory out,, bytes32 chk) = engine.step(a);
        assertEq(
            keccak256(out), keccak256(vm.parseBytes(vectors.readString(".step.stateOut"))), "overlay stateOut mismatch"
        );
        assertEq(chk, vectors.readBytes32(".step.chk"), "overlay chk mismatch");
    }

    function test_CheckArtifacts() public {
        engine.checkArtifacts(graphRoot, warmRoot, cfg);
        // wrong warm root (graph root has 3 chunks, warm expects 1) → malformed directory
        vm.expectRevert(FlyEngine.MalformedDirectory.selector);
        engine.checkArtifacts(graphRoot, graphRoot, cfg);
        // edge count off by one → blob length mismatch
        bytes32[3] memory bad = cfg;
        bad[0] = bytes32(uint256(bad[0]) + (uint256(1) << 192));
        vm.expectRevert(FlyEngine.ArtifactLengthMismatch.selector);
        engine.checkArtifacts(graphRoot, warmRoot, bad);
    }

    /// @notice Gas probe on the synthetic graph: 100 steps from the warm state (HANDOFF §7.3 test 8)
    function test_GasProbeStep100() public {
        bytes memory warm = vm.parseBytes(vectors.readString(".warm.stateOut"));
        bytes memory drive = vm.parseBytes(vectors.readString(".step.driveIn"));
        uint32[] memory ids = _u32s(vectors.readUintArray(".step.readoutIds"));
        FlyEngine.StepInput memory a = _stepInput(warm, drive, ids, 100);
        uint256 g0 = gasleft();
        (, uint32[] memory counts,) = engine.step(a);
        uint256 used = g0 - gasleft();
        uint256 spikes = 0;
        for (uint256 i = 0; i < counts.length; ++i) {
            spikes += counts[i];
        }
        emit log_named_uint("gas: step(100) on n=64", used);
        emit log_named_uint("readout spikes in those 100 steps", spikes);
    }
}
