// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {DataContractLib} from "../onchain-llm/DataContractLib.sol";
import {FlyTypes} from "./FlyTypes.sol";

/// @title FlyEngine
/// @notice Stateless, integer-only port of doomfly's LIF simulator over the complete MaleCNS v1.0
///         connectome (166,700 neurons / 25.6 M edges stored as DataContractLib chunks behind a
///         two-level directory). Reached by STATICCALL from `FlyPolicy`; nothing here ever enters a
///         Gas Killer state-update payload.
/// @dev Bit-for-bit twin of tools/fly_int.py (THE reference): Q24 int64 membrane state, Q64 decay
///      tables, round-half-up at every product, kernel.cpp's iteration order (active-list sweep with
///      in-place compaction → ring-FIFO delivery in CSR order → reset), the stateIn/stateOut wire
///      format of HANDOFF §3.4, and the commitment hashes of §3.5. Every arithmetic and ordering
///      decision that the handoff left open is pinned in fly_int.py's docstring (D-A … D-I).
///
///      Memory is laid out by hand (bases computed from N at call entry, free pointer bumped past
///      them) so the 5.4 MB working state IS the returned `stateOut` and never gets abi-copied.
contract FlyEngine {
    // ------------------------------------------------------------------ constants
    string public constant DOMAIN = "gaskiller.fly.engine.v1";
    string public constant OVERLAY_DOMAIN = "gaskiller.fly.overlay.v1";
    string public constant WARM_DOMAIN = "gaskiller.fly.amm.warm.v1";

    uint256 internal constant CHUNK = 24_575; // DataContractLib.MAX_PAYLOAD
    uint256 internal constant TBL_WORDS = 1025; // decay tables: d = 0..1024
    uint256 internal constant TB_OFF = 32_800; // 1025 * 32
    uint256 internal constant TC_OFF = 65_600;
    uint256 internal constant SCR_BYTES = 24_608; // one chunk of edges + slack

    // two's-complement 256-bit literals (inline assembly needs plain literals)
    uint256 internal constant R_Q24_W = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffcc000000; // -52 << 24
    uint256 internal constant THR_Q24_W = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffd3000000; // -45 << 24
    uint256 internal constant R_Q24_FIELD = 0xffffffffcc000000; // low 64 bits of R_Q24
    uint256 internal constant BOUND_Q16 = 0x70000; // 7 << 16
    uint256 internal constant BOUND_Q24 = 0x7000000; // 7 << 24
    uint256 internal constant A1 = 0xfeb923493e945789; // floor(e^(-1/200) * 2^64)
    uint256 internal constant B1 = 0xfaee4cdd6f62db92; // floor(e^(-1/50)  * 2^64)
    uint256 internal constant ONE64 = 0x10000000000000000;
    uint256 internal constant HALF64 = 0x8000000000000000;
    uint256 internal constant HALF56 = 0x80000000000000;
    uint256 internal constant M64 = 0xffffffffffffffff;
    uint256 internal constant MID_AND_LAST = 0xffffffffffffffffffffffffffff0000; // bits 127..16
    uint256 internal constant LOW28 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint256 internal constant W_NUM = 23_068_672; // 11 * 2^21

    uint256 internal constant GAIN = 30;
    uint256 internal constant HALF_SAT_Q16 = 1311;
    uint256 internal constant LAMINA_Q16 = 12 << 16;
    uint256 internal constant SUGAR_Q16 = 30 << 16;
    uint256 internal constant PPL101_Q16 = 4 << 16;
    uint256 internal constant CANVAS_W = 640;
    uint256 internal constant CANVAS_H = 480;
    uint256 internal constant STRIP_ROWS = 40;

    // ------------------------------------------------------------------ errors
    error MalformedDirectory();
    error MalformedMeta();
    error ArtifactLengthMismatch();
    error MalformedState();
    error StateHashMismatch();
    error BadDriveIn();
    error BadReadoutId();
    error BadFrame();
    error BadConfig();

    // ------------------------------------------------------------------ structs
    /// @dev Packed config decoded from the three words (see fly_int.pack_cfg)
    struct Config {
        uint256 n;
        uint256 nEdges;
        uint256 ptrChunks;
        uint256 edgeChunks;
        uint256 metaChunks;
        uint256 warmChunks;
        uint256 delay;
        uint256 rfc;
        uint256 epc;
        uint256 episodeSteps;
        uint256 pulseSteps;
        uint256 binSteps;
        uint256 alpha;
        uint256 decay;
        uint256 devRef;
        uint256 volBarRows;
    }

    /// @dev Kernel context: memory bases + scheduler registers. Field order is load-bearing for the
    ///      Yul (offset = 32 * index).
    struct Ctx {
        uint256 n; // 0x000
        uint256 sw; // 0x020 neuron words
        uint256 active; // 0x040 uint32[] packed, capacity 2n+16
        uint256 ring; // 0x060 uint32[] packed FIFO, capacity n+8
        uint256 ptr; // 0x080 uint32[n+1] packed
        uint256 ta; // 0x0a0 tables: tA at ta, tB at ta+TB_OFF, tC at ta+TC_OFF
        uint256 dir; // 0x0c0 chunk addresses, one word each: [ptr][edges][meta][warm]
        uint256 scr; // 0x0e0 edge scratch
        uint256 edgeDir; // 0x100 = dir + 32*ptrChunks
        uint256 delay; // 0x120
        uint256 rfc; // 0x140
        uint256 slots; // 0x160
        uint256 clock; // 0x180
        uint256 nActive; // 0x1a0
        uint256 head; // 0x1c0
        uint256 tail; // 0x1e0
        uint256 inflight; // 0x200
        uint256 hdr; // 0x220 wire header (32 B) + slotCount (96 B); sw = hdr + 128
        uint256 drv; // 0x240 dense int32 drives, packed
        uint256 epc; // 0x260
        uint256 metaDir; // 0x280 = dir + 32*(ptrChunks+edgeChunks)
        uint256 warmDir; // 0x2a0 = metaDir + 32*metaChunks
    }

    /// @dev Parsed meta.bin index tables (offsets into `meta`)
    struct Meta {
        bytes data;
        uint256 nReadouts;
        uint256 offR;
        uint256 nRetina;
        uint256 offRet; // first retina record
        uint256 nLamina;
        uint256 offLam; // first lamina id
        uint256 nSugar;
        uint256 offSug;
        uint256 ppl0;
        uint256 ppl1;
    }

    // ================================================================== config

    /// @notice Decode the three packed config words
    function unpack(bytes32[3] memory cfg) public pure returns (Config memory c) {
        uint256 c0 = uint256(cfg[0]);
        uint256 c1 = uint256(cfg[1]);
        uint256 c2 = uint256(cfg[2]);
        c.n = (c0 >> 224) & 0xffffffff;
        c.nEdges = (c0 >> 192) & 0xffffffff;
        c.ptrChunks = (c0 >> 176) & 0xffff;
        c.edgeChunks = (c0 >> 160) & 0xffff;
        c.metaChunks = (c0 >> 144) & 0xffff;
        c.warmChunks = (c0 >> 128) & 0xffff;
        c.delay = (c0 >> 120) & 0xff;
        c.rfc = (c0 >> 112) & 0xff;
        c.epc = (c0 >> 96) & 0xffff;
        c.episodeSteps = (c1 >> 240) & 0xffff;
        c.pulseSteps = (c1 >> 224) & 0xffff;
        c.binSteps = (c1 >> 216) & 0xff;
        c.alpha = (c1 >> 200) & 0xffff;
        c.decay = (c1 >> 184) & 0xffff;
        c.devRef = (c2 >> 160) & 0xffff;
        c.volBarRows = (c2 >> 136) & 0xffff;
        if (c.n == 0 || c.n >= (1 << 18) || c.epc == 0 || c.delay == 0 || c.rfc <= c.delay || c.rfc > 255) {
            revert BadConfig();
        }
        if (c.ptrChunks != (c.n + 1 + c.epc - 1) / c.epc || c.edgeChunks != (c.nEdges + c.epc - 1) / c.epc) {
            revert BadConfig();
        }
        if (c.metaChunks == 0 || 4 * c.epc + 3 > CHUNK) revert BadConfig();
    }

    /// @notice Derive the overlay address of chunk `i` (graph directory only)
    function overlayChunkAddress(bytes32 manifest, uint256 i) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(OVERLAY_DOMAIN, manifest, uint64(i))))));
    }

    // ================================================================== entry points

    /// @notice Inputs of `step` (one calldata struct keeps the legacy codegen inside the stack limit)
    struct StepInput {
        address graphRoot;
        bytes32 manifest; // overlay manifest when graphRoot == 0
        bytes32[3] cfg;
        bytes stateIn; // wire state (§3.4)
        bytes driveIn; // COMPLETE sorted set of nonzero drives, 8 B each: uint32 id ‖ int32 Q16 mV
        uint32[] readoutIds;
        uint256 nSteps;
        bytes32 expectStateIn; // keccak256(stateIn) or zero to skip the check
    }

    /// @notice General kernel: advance the brain `nSteps` × 0.1 ms from an explicit lazy state.
    /// @dev Does NOT materialize (D-A): step([0,t1)) ∘ step([t1,T)) == step([0,T)) exactly.
    ///      chk = keccak256(abi.encode(keccak256(DOMAIN), keccak256(stateIn), keccak256(driveIn),
    ///            keccak256(abi.encodePacked(readoutIds)), nSteps, keccak256(stateOut), keccak256(abi.encodePacked(readoutCounts))))
    function step(StepInput calldata a)
        external
        view
        returns (bytes memory stateOut, uint32[] memory readoutCounts, bytes32 chk)
    {
        if (a.expectStateIn != bytes32(0) && keccak256(a.stateIn) != a.expectStateIn) revert StateHashMismatch();
        Config memory c = unpack(a.cfg);
        Ctx memory ctx = _layout(c, 0);
        _stepLoad(ctx, c, a);
        _kernel(ctx, 0, 0);
        _kernel(ctx, 1, a.nSteps);
        _stepReturn(ctx, a);
    }

    function _stepLoad(Ctx memory ctx, Config memory c, StepInput calldata a) internal view {
        _resolve(a.graphRoot, a.manifest, c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        _loadPtr(ctx, c);
        _kernel(ctx, 3, 0);
        bytes calldata stateIn = a.stateIn;
        if (stateIn.length < 128) revert MalformedState();
        uint256 hdr = ctx.hdr;
        assembly ("memory-safe") {
            calldatacopy(hdr, stateIn.offset, stateIn.length)
        }
        _adoptWire(ctx, stateIn.length);
        _zeroCounts(ctx);
        _parseDriveIn(ctx, a.driveIn);
    }

    /// @dev Hand-built ABI return of (bytes stateOut, uint32[] readoutCounts, bytes32 chk): the wire is returned in place
    function _stepReturn(Ctx memory ctx, StepInput calldata a) internal pure {
        uint256 len = _finalizeWire(ctx);
        uint256 hdr = ctx.hdr;
        uint256 cntBase = hdr + ((len + 31) & ~uint256(31)) + 32;
        uint256 nRo = a.readoutIds.length;
        _writeCounts(ctx, a.readoutIds, cntBase);
        bytes32 chk = _chk(a, hdr, len, cntBase, nRo);
        assembly ("memory-safe") {
            mstore(add(hdr, len), 0) // zero the ABI padding after the state bytes (strict decoders check it)
            let base := sub(hdr, 128)
            mstore(base, 0x60)
            mstore(add(base, 32), sub(sub(cntBase, 32), base))
            mstore(add(base, 64), chk)
            mstore(add(base, 96), len)
            mstore(sub(cntBase, 32), nRo)
            return(base, sub(add(cntBase, shl(5, nRo)), base))
        }
    }

    function _writeCounts(Ctx memory ctx, uint32[] calldata readoutIds, uint256 cntBase) internal pure {
        uint256 n = ctx.n;
        uint256 sw = ctx.sw;
        for (uint256 k = 0; k < readoutIds.length; ++k) {
            uint256 id = readoutIds[k];
            if (id >= n) revert BadReadoutId();
            assembly ("memory-safe") {
                mstore(add(cntBase, shl(5, k)), and(shr(64, mload(add(sw, shl(5, id)))), 0xffffffff))
            }
        }
    }

    function _chk(StepInput calldata a, uint256 hdr, uint256 len, uint256 cntBase, uint256 nRo)
        internal
        pure
        returns (bytes32)
    {
        bytes32 stateHash;
        bytes32 countsHash;
        assembly ("memory-safe") {
            stateHash := keccak256(hdr, len)
            countsHash := keccak256(cntBase, shl(5, nRo))
        }
        return keccak256(
            abi.encode(
                keccak256(bytes(DOMAIN)),
                keccak256(a.stateIn),
                keccak256(a.driveIn),
                keccak256(abi.encodePacked(a.readoutIds)),
                a.nSteps,
                stateHash,
                countsHash
            )
        );
    }

    /// @dev Decoder registers carried across bins
    struct Decoder {
        uint256[4] rates;
        uint256[4] prev;
        uint256[3][4] hist; // last three bins per BCI readout (ring by bin index)
        uint256 nBins;
    }

    /// @notice AMM entry: one episode from the warm snapshot with a static frame (HANDOFF §3.5)
    function decide(
        address graphRoot,
        address warmRoot,
        bytes32[3] calldata cfg,
        bytes calldata frame,
        FlyTypes.Stimulus calldata stim,
        uint32[4] calldata rates0
    ) external view returns (FlyTypes.Readout memory r, bytes32 spikeRoot) {
        Config memory c = unpack(cfg);
        if (c.binSteps == 0 || c.episodeSteps % c.binSteps != 0 || c.warmChunks == 0) revert BadConfig();
        Ctx memory ctx = _layout(c, c.warmChunks);
        Meta memory m = _prepare(ctx, c, graphRoot, warmRoot);
        if (frame.length != 2 * m.nRetina || m.nReadouts > 14) revert BadFrame();
        Decoder memory dec;
        for (uint256 j = 0; j < 4; ++j) {
            dec.rates[j] = rates0[j];
        }
        _episode(ctx, c, m, frame, stim, dec);
        _kernel(ctx, 2, 0); // materialize
        _readout(ctx, m, dec, r);
        bytes32 stateHash = _stateHash(ctx);
        spikeRoot = keccak256(abi.encode(keccak256(bytes(DOMAIN)), keccak256(frame), stim, rates0, stateHash, r));
    }

    /// @dev Resolve both directories, load ptr/tables/meta/warm state, zero counts
    function _prepare(Ctx memory ctx, Config memory c, address graphRoot, address warmRoot)
        internal
        view
        returns (Meta memory m)
    {
        _resolve(graphRoot, bytes32(0), c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        _resolve(warmRoot, bytes32(0), c.warmChunks, ctx.warmDir);
        _loadPtr(ctx, c);
        _kernel(ctx, 3, 0);
        m = _loadMeta(ctx, c);
        _loadWarm(ctx, c);
        _zeroCounts(ctx);
    }

    /// @dev The per-bin loop: drives → pre-pass → binSteps → decoder EMA (no materialize between bins, D-B)
    function _episode(
        Ctx memory ctx,
        Config memory c,
        Meta memory m,
        bytes calldata frame,
        FlyTypes.Stimulus calldata stim,
        Decoder memory dec
    ) internal view {
        uint256[] memory lf = new uint256[](m.nRetina);
        uint256 nBins = c.episodeSteps / c.binSteps;
        dec.nBins = nBins;
        for (uint256 b = 0; b < nBins; ++b) {
            uint256 t0 = b * c.binSteps;
            _buildDrives(ctx, c, m, frame, lf, t0 < stim.rewardSteps, t0 < stim.punishSteps);
            _kernel(ctx, 0, 0);
            _kernel(ctx, 1, c.binSteps);
            _decodeBin(ctx, c, m, dec, b);
        }
    }

    function _decodeBin(Ctx memory ctx, Config memory c, Meta memory m, Decoder memory dec, uint256 b) internal pure {
        for (uint256 j = 0; j < 4; ++j) {
            uint256 cnt = _countOf(ctx, _readoutIdx(m, j));
            uint256 c4 = cnt - dec.prev[j];
            dec.prev[j] = cnt;
            dec.hist[j][b % 3] = c4;
            uint256 raw = (c4 * 10_000_000) / c.binSteps;
            dec.rates[j] = (dec.rates[j] * c.decay + raw * (65536 - c.decay)) >> 16;
        }
    }

    function _readout(Ctx memory ctx, Meta memory m, Decoder memory dec, FlyTypes.Readout memory r) internal pure {
        for (uint256 j = 0; j < 4; ++j) {
            r.rateMilliHz[j] = uint32(dec.rates[j]);
            uint256 last3 = 0;
            uint256 lim = dec.nBins < 3 ? dec.nBins : 3;
            for (uint256 k = 0; k < lim; ++k) {
                last3 += dec.hist[j][k];
            }
            r.spikesLast30ms[j] = uint32(last3);
        }
        for (uint256 j = 0; j < m.nReadouts; ++j) {
            r.windowCounts[j] = uint32(_countOf(ctx, _readoutIdx(m, j)));
        }
        r.totalSpikes = uint64(_totalSpikes(ctx));
    }

    function _stateHash(Ctx memory ctx) internal pure returns (bytes32 h) {
        uint256 len = _finalizeWire(ctx);
        uint256 hdr = ctx.hdr;
        assembly ("memory-safe") {
            h := keccak256(hdr, len)
        }
    }

    /// @notice Render the pool observation onto the retina (HANDOFF §4.2): 2 B Q16 luminance per receptor
    function rasterize(address graphRoot, bytes32[3] calldata cfg, FlyTypes.Observation calldata o)
        external
        view
        returns (bytes memory frame)
    {
        Config memory c = unpack(cfg);
        Ctx memory ctx = _layoutDir(c, 0);
        _resolve(graphRoot, bytes32(0), c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        Meta memory m = _loadMeta(ctx, c);
        frame = new bytes(2 * m.nRetina);
        for (uint256 k = 0; k < m.nRetina; ++k) {
            (, uint256 u, uint256 v) = _retina(m, k);
            uint256 lum = _sample(o, c, u, v);
            frame[2 * k] = bytes1(uint8(lum >> 8));
            frame[2 * k + 1] = bytes1(uint8(lum));
        }
    }

    /// @notice `steps` black steps from genesis (lamina tonic only), materialized: the warm snapshot
    function warmup(address graphRoot, bytes32[3] calldata cfg, uint256 steps)
        external
        view
        returns (bytes memory stateOut, bytes32 warmCommitment)
    {
        Config memory c = unpack(cfg);
        Ctx memory ctx = _layout(c, 0);
        _resolve(graphRoot, bytes32(0), c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        _loadPtr(ctx, c);
        _kernel(ctx, 3, 0);
        Meta memory m = _loadMeta(ctx, c);
        _genesisInto(ctx);
        uint256[] memory lf = new uint256[](m.nRetina);
        _buildDrives(ctx, c, m, msg.data[0:0], lf, false, false);
        _kernel(ctx, 0, 0);
        _kernel(ctx, 1, steps);
        _kernel(ctx, 2, 0);
        uint256 len = _finalizeWire(ctx);
        uint256 hdr = ctx.hdr;
        bytes32 h;
        assembly ("memory-safe") {
            h := keccak256(hdr, len)
        }
        warmCommitment = keccak256(abi.encodePacked(WARM_DOMAIN, h));
        assembly ("memory-safe") {
            mstore(add(hdr, len), 0) // zero the ABI padding after the state bytes
            let base := sub(hdr, 96)
            mstore(base, 0x40)
            mstore(add(base, 32), warmCommitment)
            mstore(add(base, 64), len)
            return(base, add(96, and(add(len, 31), not(31))))
        }
    }

    /// @notice The genesis wire state: clock 1, every neuron at rest, nothing scheduled
    function genesisState(bytes32[3] calldata cfg) external pure returns (bytes memory) {
        Config memory c = unpack(cfg);
        uint256 n = c.n;
        bytes memory out = new bytes(128 + 32 * n);
        assembly ("memory-safe") {
            let hdr := add(out, 32)
            mstore(hdr, 0)
            mstore8(hdr, 1)
            mstore(add(hdr, 1), shl(224, n))
            mstore(add(hdr, 5), shl(208, 1)) // clock = 1 (u48)
            let sw := add(hdr, 128)
            let w := shl(192, R_Q24_FIELD)
            for { let p := sw } lt(p, add(sw, shl(5, n))) { p := add(p, 32) } { mstore(p, w) }
        }
        return out;
    }

    /// @notice Validate directory shape, blob lengths, meta header and warm-snapshot length (~4,415 cold chunk reads on the real graph)
    function checkArtifacts(address graphRoot, address warmRoot, bytes32[3] calldata cfg) external view {
        Config memory c = unpack(cfg);
        Ctx memory ctx = _layoutDir(c, c.warmChunks);
        _resolve(graphRoot, bytes32(0), c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        if (_sumLengths(ctx.dir, c.ptrChunks) != 4 * (c.n + 1) + 3 * c.ptrChunks) revert ArtifactLengthMismatch();
        if (_sumLengths(ctx.edgeDir, c.edgeChunks) != 4 * c.nEdges + 3 * c.edgeChunks) revert ArtifactLengthMismatch();
        Meta memory m = _loadMeta(ctx, c);
        if (m.nReadouts > 14 || m.nRetina == 0) revert MalformedMeta();
        if (c.warmChunks != 0) {
            _resolve(warmRoot, bytes32(0), c.warmChunks, ctx.warmDir);
            uint256 total = _sumLengths(ctx.warmDir, c.warmChunks);
            // header of the first warm chunk: version, n, clock, nActive, inflight
            address first;
            uint256 warmDir = ctx.warmDir;
            assembly ("memory-safe") {
                first := mload(warmDir)
            }
            bytes memory head = new bytes(32);
            assembly ("memory-safe") {
                extcodecopy(first, add(head, 32), 1, 32)
            }
            uint256 nActive = _be32(head, 11);
            uint256 inflight = _be32(head, 15);
            if (uint8(head[0]) != 1 || _be32(head, 1) != c.n || total != 128 + 32 * c.n + 4 * (nActive + inflight)) {
                revert ArtifactLengthMismatch();
            }
        }
    }

    // ================================================================== memory layout

    function _layout(Config memory c, uint256 warmChunks) internal pure returns (Ctx memory ctx) {
        uint256 n = c.n;
        uint256 base;
        assembly ("memory-safe") {
            base := and(add(mload(0x40), 31), not(31))
        }
        ctx.n = n;
        ctx.hdr = base + 128; // 4 words of ABI head reserve before the wire
        ctx.sw = ctx.hdr + 128;
        ctx.active = ctx.sw + 32 * n;
        ctx.ring = ctx.active + _pad(8 * n + 64);
        ctx.ptr = ctx.ring + _pad(4 * n + 32);
        ctx.ta = ctx.ptr + _pad(4 * (n + 1) + 32);
        ctx.dir = ctx.ta + 3 * TBL_WORDS * 32;
        uint256 nChunks = c.ptrChunks + c.edgeChunks + c.metaChunks + warmChunks;
        ctx.scr = ctx.dir + 32 * nChunks;
        ctx.drv = ctx.scr + SCR_BYTES;
        uint256 end = ctx.drv + _pad(4 * n + 32);
        ctx.edgeDir = ctx.dir + 32 * c.ptrChunks;
        ctx.metaDir = ctx.edgeDir + 32 * c.edgeChunks;
        ctx.warmDir = ctx.metaDir + 32 * c.metaChunks;
        ctx.delay = c.delay;
        ctx.rfc = c.rfc;
        ctx.slots = c.delay + 1;
        ctx.epc = c.epc;
        ctx.clock = 1;
        assembly ("memory-safe") {
            mstore(0x40, end)
        }
    }

    /// @dev Directory-only layout for the cheap entry points (checkArtifacts, rasterize): no state memory
    function _layoutDir(Config memory c, uint256 warmChunks) internal pure returns (Ctx memory ctx) {
        uint256 base;
        assembly ("memory-safe") {
            base := and(add(mload(0x40), 31), not(31))
        }
        ctx.n = c.n;
        ctx.dir = base;
        uint256 nChunks = c.ptrChunks + c.edgeChunks + c.metaChunks + warmChunks;
        ctx.edgeDir = ctx.dir + 32 * c.ptrChunks;
        ctx.metaDir = ctx.edgeDir + 32 * c.edgeChunks;
        ctx.warmDir = ctx.metaDir + 32 * c.metaChunks;
        uint256 end = ctx.dir + 32 * nChunks;
        assembly ("memory-safe") {
            mstore(0x40, end)
        }
    }

    function _pad(uint256 x) internal pure returns (uint256) {
        return (x + 31) & ~uint256(31);
    }

    // ================================================================== directory + blobs

    /// @dev Walk root → pages → chunks, writing one address word per chunk at `dirBase`
    function _resolve(address root, bytes32 manifest, uint256 expected, uint256 dirBase) internal view {
        if (root == address(0)) {
            if (manifest == bytes32(0)) revert MalformedDirectory();
            for (uint256 i = 0; i < expected; ++i) {
                address a = overlayChunkAddress(manifest, i);
                assembly ("memory-safe") {
                    mstore(add(dirBase, shl(5, i)), a)
                }
            }
            return;
        }
        bytes memory rootBytes = DataContractLib.read(root);
        if (rootBytes.length == 0 || rootBytes.length % 20 != 0) revert MalformedDirectory();
        uint256 seen = 0;
        uint256 nPages = rootBytes.length / 20;
        for (uint256 p = 0; p < nPages; ++p) {
            bytes memory page = DataContractLib.read(_addrAt(rootBytes, p * 20));
            if (page.length % 20 != 0) revert MalformedDirectory();
            uint256 cnt = page.length / 20;
            for (uint256 i = 0; i < cnt; ++i) {
                if (seen >= expected) revert MalformedDirectory();
                address a = _addrAt(page, i * 20);
                assembly ("memory-safe") {
                    mstore(add(dirBase, shl(5, seen)), a)
                }
                ++seen;
            }
        }
        if (seen != expected) revert MalformedDirectory();
    }

    function _addrAt(bytes memory b, uint256 off) internal pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(b, 32), off)))
        }
    }

    function _sumLengths(uint256 dirBase, uint256 count) internal view returns (uint256 total) {
        for (uint256 i = 0; i < count; ++i) {
            address a;
            assembly ("memory-safe") {
                a := mload(add(dirBase, shl(5, i)))
            }
            total += DataContractLib.payloadLength(a);
        }
    }

    /// @dev Concatenate the payloads of `count` chunks starting at `dirBase`
    function _readAll(uint256 dirBase, uint256 count) internal view returns (bytes memory out) {
        uint256 total = _sumLengths(dirBase, count);
        out = new bytes(total);
        uint256 at = 0;
        for (uint256 i = 0; i < count; ++i) {
            address a;
            assembly ("memory-safe") {
                a := mload(add(dirBase, shl(5, i)))
            }
            at += DataContractLib.readInto(a, out, at);
        }
    }

    /// @dev Copy the ptr blob (6,143 entries + 3 pad bytes per chunk) into the packed PTR region
    function _loadPtr(Ctx memory ctx, Config memory c) internal view {
        uint256 entries = c.n + 1;
        uint256 epc = c.epc;
        uint256 dir = ctx.dir;
        uint256 dst = ctx.ptr;
        for (uint256 ci = 0; ci < c.ptrChunks; ++ci) {
            uint256 take = entries - ci * epc;
            if (take > epc) take = epc;
            assembly ("memory-safe") {
                let a := mload(add(dir, shl(5, ci)))
                if lt(extcodesize(a), add(1, shl(2, take))) {
                    mstore(0, 0x1a2f92f6) // ArtifactLengthMismatch()
                    revert(28, 4)
                }
                extcodecopy(a, add(dst, mul(ci, shl(2, epc))), 1, shl(2, take))
            }
        }
    }

    function _loadMeta(Ctx memory ctx, Config memory c) internal view returns (Meta memory m) {
        m.data = _readAll(ctx.metaDir, c.metaChunks);
        bytes memory d = m.data;
        if (d.length < 101 || uint8(d[0]) != 1) revert MalformedMeta();
        if (_be32(d, 1) != c.n || _be32(d, 5) != c.nEdges || _be16(d, 9) != c.epc) revert MalformedMeta();
        if (_be16(d, 11) != c.delay || _be16(d, 13) != c.rfc) revert MalformedMeta();
        m.nReadouts = _be16(d, 15);
        m.offR = _be32(d, 17);
        uint256 offRet = _be32(d, 21);
        uint256 offLam = _be32(d, 25);
        uint256 offSug = _be32(d, 29);
        uint256 offPPL = _be32(d, 33);
        m.nRetina = _be32(d, offRet);
        m.offRet = offRet + 4;
        m.nLamina = _be32(d, offLam);
        m.offLam = offLam + 4;
        m.nSugar = _be32(d, offSug);
        m.offSug = offSug + 4;
        m.ppl0 = _be32(d, offPPL);
        m.ppl1 = _be32(d, offPPL + 4);
        if (
            m.offR + 6 * m.nReadouts > d.length || m.offRet + 8 * m.nRetina > d.length
                || m.offLam + 4 * m.nLamina > d.length || m.offSug + 4 * m.nSugar > d.length || offPPL + 8 > d.length
                || m.ppl0 >= c.n || m.ppl1 >= c.n
        ) revert MalformedMeta();
    }

    function _loadWarm(Ctx memory ctx, Config memory c) internal view {
        uint256 total = _sumLengths(ctx.warmDir, c.warmChunks);
        if (total < 128) revert MalformedState();
        uint256 warmDir = ctx.warmDir;
        uint256 dst = ctx.hdr;
        for (uint256 i = 0; i < c.warmChunks; ++i) {
            address a;
            assembly ("memory-safe") {
                a := mload(add(warmDir, shl(5, i)))
            }
            uint256 len = DataContractLib.payloadLength(a);
            assembly ("memory-safe") {
                extcodecopy(a, dst, 1, len)
            }
            dst += len;
        }
        _adoptWire(ctx, total);
    }

    // ================================================================== wire format

    /// @dev The wire bytes are in place at ctx.hdr. Validate (D-D), move the ring into RING, set registers.
    function _adoptWire(Ctx memory ctx, uint256 len) internal pure {
        uint256 hdr = ctx.hdr;
        uint256 n = ctx.n;
        uint256 slots = ctx.slots;
        uint256 rfc = ctx.rfc;
        uint256 clock;
        uint256 nActive;
        uint256 inflight;
        bool bad;
        assembly ("memory-safe") {
            let h := mload(hdr)
            // version u8 | n u32 | clock u48 | nActive u32 | inflight u32 | ringHead u32 | 9 zero bytes
            bad := iszero(eq(shr(248, h), 1))
            bad := or(bad, iszero(eq(and(shr(216, h), 0xffffffff), n)))
            clock := and(shr(168, h), 0xffffffffffff)
            nActive := and(shr(136, h), 0xffffffff)
            inflight := and(shr(104, h), 0xffffffff)
            bad := or(bad, and(h, 0xffffffffffffffffffffffffff)) // ringHead + padding must be zero
            bad := or(bad, iszero(clock))
            bad := or(bad, or(gt(nActive, n), gt(inflight, n)))
            // slot counts: sum == inflight, padding zero
            let sum := 0
            for { let s := 0 } lt(s, slots) { s := add(s, 1) } { sum := add(
                sum,
                shr(224, mload(add(add(hdr, 32), shl(2, s))))
            ) }
            bad := or(bad, iszero(eq(sum, inflight)))
            for { let p := add(add(hdr, 32), shl(2, slots)) } lt(p, add(hdr, 128)) { p := add(p, 32) } {
                let rem := sub(add(hdr, 128), p)
                let v := mload(p)
                if lt(rem, 32) { v := shr(mul(8, sub(32, rem)), v) }
                bad := or(bad, iszero(iszero(v)))
            }
        }
        if (bad || len != 128 + 32 * n + 4 * (nActive + inflight)) revert MalformedState();
        uint256 sw = ctx.sw;
        uint256 act = ctx.active;
        uint256 ring = ctx.ring;
        assembly ("memory-safe") {
            // 1. every listed active id: in range, flag set → clear it (catches duplicates)
            for { let k := 0 } lt(k, nActive) { k := add(k, 1) } {
                let i := shr(224, mload(add(act, shl(2, k))))
                bad := or(bad, iszero(lt(i, n)))
                let wp := add(sw, shl(5, i))
                let w := mload(wp)
                bad := or(bad, iszero(and(w, 1)))
                mstore(wp, and(w, not(1)))
            }
            // 2. full scan: last <= clock-1, refr <= rfc, no stray flag
            let prev := sub(clock, 1)
            for { let wp := sw } lt(wp, add(sw, shl(5, n))) { wp := add(wp, 32) } {
                let w := mload(wp)
                bad := or(bad, gt(and(shr(16, w), 0xffffffffffff), prev))
                bad := or(bad, gt(and(shr(8, w), 0xff), rfc))
                bad := or(bad, and(w, 1))
            }
            // 3. re-set the flags of the listed ids
            for { let k := 0 } lt(k, nActive) { k := add(k, 1) } {
                let i := shr(224, mload(add(act, shl(2, k))))
                if lt(i, n) {
                    let wp := add(sw, shl(5, i))
                    mstore(wp, or(mload(wp), 1))
                }
            }
            // 4. ring ids: move from act + 4*nActive to RING (forward copy, regions disjoint)
            let src := add(act, shl(2, nActive))
            for { let off := 0 } lt(off, shl(2, inflight)) { off := add(off, 32) } {
                mstore(add(ring, off), mload(add(src, off)))
            }
            for { let k := 0 } lt(k, inflight) { k := add(k, 1) } {
                bad := or(bad, iszero(lt(shr(224, mload(add(ring, shl(2, k)))), n)))
            }
        }
        if (bad) revert MalformedState();
        ctx.clock = clock;
        ctx.nActive = nActive;
        ctx.head = 0;
        ctx.tail = inflight % n;
        ctx.inflight = inflight;
    }

    /// @dev Write header registers, linearize the ring after the active list; return the wire length
    function _finalizeWire(Ctx memory ctx) internal pure returns (uint256 len) {
        uint256 hdr = ctx.hdr;
        uint256 n = ctx.n;
        uint256 nActive = ctx.nActive;
        uint256 inflight = ctx.inflight;
        uint256 head = ctx.head;
        uint256 clock = ctx.clock;
        uint256 act = ctx.active;
        uint256 ring = ctx.ring;
        assembly ("memory-safe") {
            let h := or(shl(248, 1), shl(216, n))
            h := or(h, or(shl(168, clock), or(shl(136, nActive), shl(104, inflight))))
            mstore(hdr, h)
            let dst := add(act, shl(2, nActive))
            let first := sub(n, head)
            if gt(first, inflight) { first := inflight }
            let src := add(ring, shl(2, head))
            for { let off := 0 } lt(off, shl(2, first)) { off := add(off, 32) } { mstore(
                add(dst, off),
                mload(add(src, off))
            ) }
            let rest := sub(inflight, first)
            dst := add(dst, shl(2, first))
            for { let off := 0 } lt(off, shl(2, rest)) { off := add(off, 32) } { mstore(
                add(dst, off),
                mload(add(ring, off))
            ) }
        }
        len = 128 + 32 * n + 4 * (nActive + inflight);
    }

    function _genesisInto(Ctx memory ctx) internal pure {
        uint256 hdr = ctx.hdr;
        uint256 n = ctx.n;
        assembly ("memory-safe") {
            mstore(hdr, or(shl(248, 1), or(shl(216, n), shl(168, 1))))
            mstore(add(hdr, 32), 0)
            mstore(add(hdr, 64), 0)
            mstore(add(hdr, 96), 0)
            let sw := add(hdr, 128)
            let w := shl(192, R_Q24_FIELD)
            for { let p := sw } lt(p, add(sw, shl(5, n))) { p := add(p, 32) } { mstore(p, w) }
        }
        ctx.clock = 1;
        ctx.nActive = 0;
        ctx.head = 0;
        ctx.tail = 0;
        ctx.inflight = 0;
    }

    function _zeroCounts(Ctx memory ctx) internal pure {
        uint256 sw = ctx.sw;
        uint256 n = ctx.n;
        assembly ("memory-safe") {
            let mask := not(shl(64, 0xffffffff))
            for { let p := sw } lt(p, add(sw, shl(5, n))) { p := add(p, 32) } { mstore(p, and(mload(p), mask)) }
        }
    }

    // ================================================================== drives

    function _parseDriveIn(Ctx memory ctx, bytes calldata driveIn) internal pure {
        if (driveIn.length % 8 != 0) revert BadDriveIn();
        uint256 n = ctx.n;
        uint256 drv = ctx.drv;
        _zeroDrives(ctx);
        bool bad;
        assembly ("memory-safe") {
            let prev := not(0)
            for { let off := 0 } lt(off, driveIn.length) { off := add(off, 8) } {
                let rec := calldataload(add(driveIn.offset, off))
                let id := shr(224, rec)
                let val := and(shr(192, rec), 0xffffffff)
                bad := or(bad, or(iszero(lt(id, n)), iszero(val)))
                bad := or(bad, and(iszero(eq(prev, not(0))), iszero(gt(id, prev))))
                prev := id
                let p := add(drv, shl(2, id))
                mstore(p, or(shl(224, val), and(mload(p), LOW28)))
            }
        }
        if (bad) revert BadDriveIn();
    }

    function _zeroDrives(Ctx memory ctx) internal pure {
        uint256 drv = ctx.drv;
        uint256 n = ctx.n;
        assembly ("memory-safe") {
            for { let p := drv } lt(p, add(drv, add(shl(2, n), 32))) { p := add(p, 32) } { mstore(p, 0) }
        }
    }

    /// @dev Rebuild the dense drive array for one bin exactly as fly_int.decide does:
    ///      zero → lamina 12 mV → retina (30·Lf<<16)/(1311+Lf) → sugar 30 mV (reward) → PPL101 += 4 mV (punish).
    ///      `lf` is updated in place (Lf += (alpha·(L−Lf)) >> 16, arithmetic shift). Empty frame = black.
    function _buildDrives(
        Ctx memory ctx,
        Config memory c,
        Meta memory m,
        bytes calldata frame,
        uint256[] memory lf,
        bool reward,
        bool punish
    ) internal pure {
        _zeroDrives(ctx);
        uint256 drv = ctx.drv;
        bytes memory d = m.data;
        for (uint256 k = 0; k < m.nLamina; ++k) {
            uint256 idx = _be32(d, m.offLam + 4 * k);
            _setDrive(drv, idx, LAMINA_Q16);
        }
        for (uint256 k = 0; k < m.nRetina; ++k) {
            (uint256 idx,,) = _retina(m, k);
            if (frame.length != 0) {
                int256 L = int256(uint256(uint8(frame[2 * k])) << 8 | uint256(uint8(frame[2 * k + 1])));
                int256 cur = int256(lf[k]);
                cur += (int256(c.alpha) * (L - cur)) >> 16;
                lf[k] = uint256(cur);
            }
            uint256 L2 = lf[k];
            _setDrive(drv, idx, ((GAIN * L2) << 16) / (HALF_SAT_Q16 + L2));
        }
        if (reward) {
            for (uint256 k = 0; k < m.nSugar; ++k) {
                _setDrive(drv, _be32(d, m.offSug + 4 * k), SUGAR_Q16);
            }
        }
        if (punish) {
            _addDrive(drv, m.ppl0, PPL101_Q16);
            _addDrive(drv, m.ppl1, PPL101_Q16);
        }
    }

    function _setDrive(uint256 drv, uint256 idx, uint256 val) internal pure {
        assembly ("memory-safe") {
            let p := add(drv, shl(2, idx))
            mstore(p, or(shl(224, and(val, 0xffffffff)), and(mload(p), LOW28)))
        }
    }

    function _addDrive(uint256 drv, uint256 idx, uint256 val) internal pure {
        assembly ("memory-safe") {
            let p := add(drv, shl(2, idx))
            let cur := signextend(3, shr(224, mload(p)))
            mstore(p, or(shl(224, and(add(cur, val), 0xffffffff)), and(mload(p), LOW28)))
        }
    }

    // ================================================================== meta accessors

    function _retina(Meta memory m, uint256 k) internal pure returns (uint256 idx, uint256 u, uint256 v) {
        bytes memory d = m.data;
        uint256 off = m.offRet + 8 * k;
        idx = _be32(d, off);
        u = _be16(d, off + 4);
        v = _be16(d, off + 6);
    }

    function _readoutIdx(Meta memory m, uint256 j) internal pure returns (uint256) {
        if (j >= m.nReadouts) revert BadReadoutId();
        return _be32(m.data, m.offR + 6 * j);
    }

    function _be32(bytes memory d, uint256 off) internal pure returns (uint256 x) {
        assembly ("memory-safe") {
            x := shr(224, mload(add(add(d, 32), off)))
        }
    }

    function _be16(bytes memory d, uint256 off) internal pure returns (uint256 x) {
        assembly ("memory-safe") {
            x := shr(240, mload(add(add(d, 32), off)))
        }
    }

    function _countOf(Ctx memory ctx, uint256 idx) internal pure returns (uint256 cnt) {
        if (idx >= ctx.n) revert BadReadoutId();
        uint256 sw = ctx.sw;
        assembly ("memory-safe") {
            cnt := and(shr(64, mload(add(sw, shl(5, idx)))), 0xffffffff)
        }
    }

    function _totalSpikes(Ctx memory ctx) internal pure returns (uint256 total) {
        uint256 sw = ctx.sw;
        uint256 n = ctx.n;
        assembly ("memory-safe") {
            for { let p := sw } lt(p, add(sw, shl(5, n))) { p := add(p, 32) } {
                total := add(total, and(shr(64, mload(p)), 0xffffffff))
            }
        }
    }

    // ================================================================== rasterizer (§4.2)

    /// @dev Procedural 640×480 canvas value at (y, x): deviation strip over rows [0,40), histogram bars below
    function _canvas(FlyTypes.Observation calldata o, Config memory c, uint256 y, uint256 x)
        internal
        pure
        returns (uint256)
    {
        uint256 spot = o.spotQ64;
        uint256 twap = o.twapQ64;
        if (y < STRIP_ROWS) {
            if (spot == twap || twap == 0) return 0;
            uint256 absDev = ((spot > twap ? spot - twap : twap - spot) * 10000) / twap;
            uint256 lit = absDev * 65535 / c.devRef;
            if (lit > 65535) lit = 65535;
            return ((x < 320) == (spot > twap)) ? lit : 0;
        }
        uint256 vol = x < 320 ? o.buyQuote[x / 20] : o.sellQuote[(x - 320) / 20];
        uint256 volRef = o.volRef;
        uint256 h = volRef == 0 ? 0 : (c.volBarRows * (vol < volRef ? vol : volRef)) / volRef;
        return y >= CANVAS_H - h ? 65535 : 0;
    }

    /// @dev Bilinear sample at receptor (uQ16, vQ16), exactly game.py retinal_samples in integers
    function _sample(FlyTypes.Observation calldata o, Config memory c, uint256 u, uint256 v)
        internal
        pure
        returns (uint256)
    {
        uint256 xq = u * (CANVAS_W - 1);
        uint256 yq = v * (CANVAS_H - 1);
        uint256 x0 = xq >> 16;
        uint256 y0 = yq >> 16;
        uint256 x1 = x0 + 1 < CANVAS_W - 1 ? x0 + 1 : CANVAS_W - 1;
        uint256 y1 = y0 + 1 < CANVAS_H - 1 ? y0 + 1 : CANVAS_H - 1;
        uint256 dx = xq & 0xffff;
        uint256 dy = yq & 0xffff;
        uint256 acc = (65536 - dx) * (65536 - dy) * _canvas(o, c, y0, x0);
        acc += dx * (65536 - dy) * _canvas(o, c, y0, x1);
        acc += (65536 - dx) * dy * _canvas(o, c, y1, x0);
        acc += dx * dy * _canvas(o, c, y1, x1);
        return acc >> 32;
    }

    // ================================================================== the kernel (Yul)

    /// @dev op 0 = pre-pass (install ctx.drv), 1 = run(arg steps), 2 = materialize, 3 = build tables.
    ///      One assembly block so the Yul helpers are defined once. Helpers re-load bases from the
    ///      context word instead of caching them: the legacy codegen has 16 reachable stack slots.
    function _kernel(Ctx memory ctxm, uint256 op, uint256 arg) internal view {
        assembly ("memory-safe") {
            function u32get(p) -> x {
                x := shr(224, mload(p))
            }
            function u32set(p, x) {
                mstore(p, or(shl(224, x), and(mload(p), LOW28)))
            }
            // x^q in Q64, right-to-left square-and-multiply from 2^64, rhu64 at every product (D-E)
            function powq(x, q) -> r {
                r := ONE64
                for {} q {} {
                    if and(q, 1) { r := shr(64, add(mul(r, x), HALF64)) }
                    x := shr(64, add(mul(x, x), HALF64))
                    q := shr(1, q)
                }
            }
            function farDecay(d, ta) -> a, b, c {
                if lt(d, 8873) {
                    let q := shr(10, d)
                    let r := and(d, 1023)
                    a := powq(mload(add(ta, 32768)), q)
                    if r { a := shr(64, add(mul(a, mload(add(ta, shl(5, r)))), HALF64)) }
                    if lt(d, 2219) {
                        b := powq(mload(add(ta, add(TB_OFF, 32768))), q)
                        if r { b := shr(64, add(mul(b, mload(add(add(ta, TB_OFF), shl(5, r)))), HALF64)) }
                    }
                    c := div(sub(a, b), 3)
                }
            }
            // evolve(i, tnow, I): lazy exact integration of one neuron word at wp; stores and returns the word
            function evolve(wp, tnow, I, ta) -> w {
                w := mload(wp)
                let d := sub(tnow, and(shr(16, w), 0xffffffffffff))
                if d {
                    let refr := and(shr(8, w), 0xff)
                    if refr {
                        let skip := sub(refr, 1)
                        if lt(d, skip) { skip := d }
                        switch lt(d, refr)
                        case 1 { refr := sub(refr, d) }
                        default { refr := 0 }
                        d := sub(d, skip)
                    }
                    let v := sar(192, w)
                    let g := signextend(7, shr(128, w))
                    if d {
                        let a, b, c
                        switch gt(d, 1024)
                        case 0 {
                            a := mload(add(ta, shl(5, d)))
                            b := mload(add(add(ta, TB_OFF), shl(5, d)))
                            c := mload(add(add(ta, TC_OFF), shl(5, d)))
                        }
                        default { a, b, c := farDecay(d, ta) }
                        v := sar(64, add(mul(sub(v, R_Q24_W), a), HALF64))
                        v := add(v, sar(56, add(mul(I, sub(ONE64, a)), HALF56)))
                        v := add(v, sar(64, add(mul(g, c), HALF64)))
                        v := add(v, R_Q24_W)
                        g := sar(64, add(mul(g, b), HALF64))
                    }
                    w := and(w, 0xffffffffffffffff00000000000000ff) // keep drive | count | flags
                    w := or(w, shl(192, and(v, M64)))
                    w := or(w, shl(128, and(g, M64)))
                    w := or(w, or(shl(16, tnow), shl(8, refr)))
                    mstore(wp, w)
                }
            }
            function ringPush(ctx, i) {
                let tail := mload(add(ctx, 0x1e0))
                u32set(add(mload(add(ctx, 0x60)), shl(2, tail)), i)
                tail := add(tail, 1)
                if eq(tail, mload(ctx)) { tail := 0 }
                mstore(add(ctx, 0x1e0), tail)
            }
            function ringPop(ctx) -> i {
                let head := mload(add(ctx, 0x1c0))
                i := u32get(add(mload(add(ctx, 0x60)), shl(2, head)))
                head := add(head, 1)
                if eq(head, mload(ctx)) { head := 0 }
                mstore(add(ctx, 0x1c0), head)
            }
            function awaken(ctx, i) {
                let na := mload(add(ctx, 0x1a0))
                u32set(add(mload(add(ctx, 0x40)), shl(2, na)), i)
                mstore(add(ctx, 0x1a0), add(na, 1))
            }
            // (2) threshold sweep over the active-list snapshot with in-place compaction
            function sweep(ctx, tnow) -> pushed {
                let act := mload(add(ctx, 0x40))
                let end := add(act, shl(2, mload(add(ctx, 0x1a0))))
                let kept := act
                for { let kp := act } lt(kp, end) { kp := add(kp, 4) } {
                    let i := shr(224, mload(kp))
                    let wp := add(mload(add(ctx, 0x20)), shl(5, i))
                    let w := evolve(wp, tnow, signextend(3, shr(96, mload(wp))), mload(add(ctx, 0xa0)))
                    let I := signextend(3, shr(96, w))
                    if and(iszero(and(w, 0xff00)), sgt(sar(192, w), THR_Q24_W)) {
                        ringPush(ctx, i)
                        pushed := add(pushed, 1)
                        w := add(w, shl(64, 1))
                        mstore(wp, w)
                    }
                    let canFire := sgt(sar(192, w), THR_Q24_W)
                    canFire := or(canFire, sgt(I, BOUND_Q16))
                    canFire := or(canFire, sgt(add(shl(8, I), signextend(7, shr(128, w))), BOUND_Q24))
                    switch canFire
                    case 1 {
                        u32set(kept, i)
                        kept := add(kept, 4)
                    }
                    default { mstore(wp, and(w, not(1))) }
                }
                mstore(add(ctx, 0x1a0), shr(2, sub(kept, act)))
            }
            // (3) deliver the edges in scratch [sp, end) to their targets
            function deliverRange(ctx, sp, end, neg, tnow) {
                for {} lt(sp, end) { sp := add(sp, 4) } {
                    let edge := shr(224, mload(sp))
                    let wp := add(mload(add(ctx, 0x20)), shl(5, shr(14, edge)))
                    let w := evolve(wp, tnow, signextend(3, shr(96, mload(wp))), mload(add(ctx, 0xa0)))
                    if iszero(and(w, 0xff00)) {
                        let wq := div(mul(and(edge, 0x3fff), W_NUM), 5)
                        if neg { wq := sub(0, wq) }
                        wq := and(add(signextend(7, shr(128, w)), wq), M64)
                        w := or(and(w, not(shl(128, M64))), shl(128, wq))
                        if iszero(and(w, 1)) {
                            w := or(w, 1)
                            awaken(ctx, shr(14, edge))
                        }
                        mstore(wp, w)
                    }
                }
            }
            // stream one presynaptic neuron's CSR row through the scratch chunk buffer
            function deliver(ctx, i, tnow) {
                let ptr := mload(add(ctx, 0x80))
                let p0 := u32get(add(ptr, shl(2, i)))
                let e1 := and(u32get(add(ptr, shl(2, add(i, 1)))), 0x7fffffff)
                let neg := shr(31, p0)
                let e := and(p0, 0x7fffffff)
                let epc := mload(add(ctx, 0x260))
                for {} lt(e, e1) {} {
                    let ci := div(e, epc)
                    let within := sub(e, mul(ci, epc))
                    let take := sub(epc, within)
                    if gt(take, sub(e1, e)) { take := sub(e1, e) }
                    let scr := mload(add(ctx, 0xe0))
                    extcodecopy(
                        mload(add(mload(add(ctx, 0x100)), shl(5, ci))),
                        scr,
                        add(1, shl(2, within)),
                        shl(2, take)
                    )
                    deliverRange(ctx, scr, add(scr, shl(2, take)), neg, tnow)
                    e := add(e, take)
                }
            }
            // (5) reset this step's spikes: ring[p, tail)
            function resetRange(ctx, p) {
                let n := mload(ctx)
                let sw := mload(add(ctx, 0x20))
                let ring := mload(add(ctx, 0x60))
                let tail := mload(add(ctx, 0x1e0))
                let rfc := mload(add(ctx, 0x140))
                for {} iszero(eq(p, tail)) {
                    p := add(p, 1)
                    if eq(p, n) { p := 0 }
                } {
                    let wp := add(sw, shl(5, u32get(add(ring, shl(2, p)))))
                    let w := and(mload(wp), or(MID_AND_LAST, 0xff))
                    mstore(wp, or(w, or(shl(192, R_Q24_FIELD), shl(8, rfc))))
                }
            }
            function run(ctx, steps) {
                let slots := mload(add(ctx, 0x160))
                let sc := add(mload(add(ctx, 0x220)), 32)
                for { let t := 0 } lt(t, steps) { t := add(t, 1) } {
                    let tnow := mload(add(ctx, 0x180))
                    let tailBefore := mload(add(ctx, 0x1e0))
                    let pushed := sweep(ctx, tnow)
                    let slot := mod(tnow, slots)
                    let nDeliver := u32get(add(sc, shl(2, slot)))
                    for { let q := 0 } lt(q, nDeliver) { q := add(q, 1) } { deliver(ctx, ringPop(ctx), tnow) }
                    u32set(add(sc, shl(2, slot)), 0)
                    resetRange(ctx, tailBefore)
                    u32set(add(sc, shl(2, mod(add(tnow, mload(add(ctx, 0x120))), slots))), pushed)
                    mstore(add(ctx, 0x200), sub(add(mload(add(ctx, 0x200)), pushed), nDeliver))
                    mstore(add(ctx, 0x180), add(tnow, 1))
                }
            }
            // (P) pre-pass: settle history under the old drive, install the new one, awaken
            function setDrives(ctx) {
                let n := mload(ctx)
                let drv := mload(add(ctx, 0x240))
                let prev := sub(mload(add(ctx, 0x180)), 1)
                for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                    let nd := signextend(3, shr(224, mload(add(drv, shl(2, i)))))
                    let wp := add(mload(add(ctx, 0x20)), shl(5, i))
                    let od := signextend(3, shr(96, mload(wp)))
                    if iszero(eq(nd, od)) {
                        let w := evolve(wp, prev, od, mload(add(ctx, 0xa0)))
                        w := or(and(w, not(shl(96, 0xffffffff))), shl(96, and(nd, 0xffffffff)))
                        if iszero(and(w, 1)) {
                            w := or(w, 1)
                            awaken(ctx, i)
                        }
                        mstore(wp, w)
                    }
                }
            }
            // (M) materialize every neuron at clock-1
            function materialize(ctx) {
                let sw := mload(add(ctx, 0x20))
                let ta := mload(add(ctx, 0xa0))
                let prev := sub(mload(add(ctx, 0x180)), 1)
                for { let wp := sw } lt(wp, add(sw, shl(5, mload(ctx)))) { wp := add(wp, 32) } {
                    pop(evolve(wp, prev, signextend(3, shr(96, mload(wp))), ta))
                }
            }
            function buildTables(ta) {
                mstore(ta, ONE64)
                mstore(add(ta, TB_OFF), ONE64)
                mstore(add(ta, TC_OFF), 0)
                let a := ONE64
                let b := ONE64
                for { let d := 1 } lt(d, 1025) { d := add(d, 1) } {
                    a := shr(64, add(mul(a, A1), HALF64))
                    b := shr(64, add(mul(b, B1), HALF64))
                    mstore(add(ta, shl(5, d)), a)
                    mstore(add(add(ta, TB_OFF), shl(5, d)), b)
                    mstore(add(add(ta, TC_OFF), shl(5, d)), div(sub(a, b), 3))
                }
            }
            switch op
            case 0 { setDrives(ctxm) }
            case 1 { run(ctxm, arg) }
            case 2 { materialize(ctxm) }
            default { buildTables(mload(add(ctxm, 0xa0))) }
        }
    }
}
