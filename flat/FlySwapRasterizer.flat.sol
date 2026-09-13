// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

// src/examples/onchain-llm/DataContractLib.sol

/// @title DataContractLib
/// @notice Minimal from-scratch "data contract" helpers: store immutable byte blobs as
///         contract runtime code (up to 24,575 payload bytes each under EIP-170) and read
///         them back with EXTCODECOPY.
/// @dev The deployed runtime is `0x00 || payload`. The leading STOP byte guarantees the
///      blob can never be executed as meaningful code. Reads skip that first byte.
///      Under Gas Killer's unbounded simulation mode, EXTCODECOPY reads never enter the
///      extracted state-update payload, so weights stored this way are free to consume
///      off-chain while remaining part of verifiable chain state.
library DataContractLib {
    /// @notice Maximum payload per data contract: EIP-170 (24,576) minus the STOP prefix
    uint256 internal constant MAX_PAYLOAD = 24_575;

    /// @notice Thrown when a payload exceeds MAX_PAYLOAD
    error PayloadTooLarge();

    /// @notice Thrown when CREATE fails (e.g. out of gas or nonce issues)
    error DeployFailed();

    /// @notice Deploy `payload` as the runtime code of a fresh data contract
    /// @param payload The bytes to persist (at most MAX_PAYLOAD)
    /// @return pointer The address of the deployed data contract
    function write(bytes memory payload) internal returns (address pointer) {
        if (payload.length > MAX_PAYLOAD) revert PayloadTooLarge();
        // Init code: PUSH2 len | DUP1 | PUSH1 0x0C | PUSH1 0x00 | CODECOPY | PUSH1 0x00 | RETURN
        // (12 bytes) followed by the runtime `0x00 || payload` at offset 0x0C.
        bytes memory initCode =
            abi.encodePacked(hex"61", uint16(payload.length + 1), hex"80600C6000396000F3", hex"00", payload);
        assembly ("memory-safe") {
            pointer := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (pointer == address(0)) revert DeployFailed();
    }

    /// @notice Payload length of a data contract (code size minus the STOP prefix)
    /// @param pointer The data contract address
    /// @return length The payload byte length
    function payloadLength(address pointer) internal view returns (uint256 length) {
        assembly ("memory-safe") {
            length := extcodesize(pointer)
        }
        if (length == 0) revert DeployFailed();
        unchecked {
            length -= 1;
        }
    }

    /// @notice Read the full payload of a data contract
    /// @param pointer The data contract address
    /// @return data The payload bytes
    function read(address pointer) internal view returns (bytes memory data) {
        uint256 length = payloadLength(pointer);
        data = new bytes(length);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, length)
        }
    }

    /// @notice Copy a data contract's payload into `dest` starting at byte `destOffset`
    /// @dev Reverts if the payload would overflow `dest`
    /// @param pointer The data contract address
    /// @param dest The destination buffer
    /// @param destOffset The byte offset within `dest` to copy to
    /// @return copied The number of payload bytes copied
    function readInto(address pointer, bytes memory dest, uint256 destOffset) internal view returns (uint256 copied) {
        copied = payloadLength(pointer);
        if (destOffset + copied > dest.length) revert PayloadTooLarge();
        assembly ("memory-safe") {
            extcodecopy(pointer, add(add(dest, 0x20), destOffset), 1, copied)
        }
    }
}

// src/examples/onchain-fly/FlyTypes.sol

/// @title FlyTypes
/// @notice Shared value types of the fly-connectome AMM (HANDOFF §3.5, §4.2, §4.5, §4.7; HANDOFF_PER_SWAP §4–§5)
library FlyTypes {
    // ------------------------------------------------------------------ v1 (window policy loop)

    /// @notice What the v1 pool exposes to the fly: the last CLOSED window, storage reads only
    struct Observation {
        uint32 windowId;
        uint64[16] buyQuote;
        uint64[16] sellQuote;
        uint64 volRef;
        uint128 spotQ64;
        uint128 twapQ64;
        uint64 feeIncomeQuote;
        uint64 lpLossQuote;
    }

    /// @notice Reinforcement pulses applied from step 0 of an episode
    struct Stimulus {
        uint16 punishSteps;
        uint16 rewardSteps;
    }

    /// @notice Decoder outputs of one episode
    struct Readout {
        uint32[4] rateMilliHz;
        uint32[4] spikesLast30ms;
        uint32[14] windowCounts;
        uint64 totalSpikes;
    }

    /// @notice The v1 per-round consumer state (lives in the log; its packed word lives in FLY_SLOT)
    struct FlyState {
        bytes32 prevWord;
        uint32 epoch;
        uint32 windowId;
        uint16 feeBps;
        int16 skewBps;
        uint8 flags;
        uint32[4] rateMilliHz;
        bytes32 memoryRoot;
    }

    // ------------------------------------------------------------------ v2 (per-swap intents)

    /// @notice One queued intent as the fly sees it (HANDOFF_PER_SWAP §5.1). Storage reads only; the
    ///         histogram is already rotated so index 15 is epoch−1 and the strips use `epoch`.
    struct SwapObservation {
        uint64 id;
        bool buyBase;
        uint64 sizeBps; // amountIn relative to the input-side reserve, bps, saturating at 10_000
        uint64 maxSlipBps; // implied by minOut vs the curve quote at current reserves (0 if minOut == 0)
        uint64 queueDepth; // tail − applied at the reference block
        uint32 epoch; // policy epoch the observation is taken for (prev.epoch + 1)
        uint64[16] buyQuote; // per-epoch fee-paid quote volume, oldest..newest (OBS_UNIT)
        uint64[16] sellQuote;
        uint64 volRef;
        uint128 spotQ64;
        uint128 emaSpotQ64;
        uint64 feeIncomeQuote; // last applied epoch's fee income → REWARD pulse
        uint64 lpLossQuote; // last applied epoch's LP loss vs emaSpot → PUNISH pulse
    }

    /// @notice The v2 chained consumer state (fee/skew live per intent in `fills`, not here)
    struct FlyStateV2 {
        bytes32 prevWord;
        uint32 epoch;
        uint64 decidedThrough;
        uint8 flags;
        uint32[4] rateMilliHz;
        bytes32 memoryRoot;
    }
}

// src/examples/onchain-fly/FlySwapRasterizer.sol

/// @title FlySwapRasterizer
/// @notice v2 retina rendering (HANDOFF_PER_SWAP §5.2): one queued swap intent plus the pool's
///         per-epoch histogram onto the 3,335 R1-R6 photoreceptors of the on-chain graph.
/// @dev Kept out of `FlyEngine` on purpose: the deployed engine is vector-pinned and sits 2.1 KB
///      under EIP-170, so the swap canvas lives in this stateless companion (STATICCALLed by
///      `FlySwapPolicy` exactly like the engine). Same receptor sampling as `FlyEngine.rasterize`
///      (bilinear over a 640×480 linear-luminance canvas, retina uv from meta.bin); the canvas is:
///        rows   0– 39  deviation strip: spot vs emaSpot (left half lit if spot > ema, else right)
///        rows  40– 79  intent strip: left half lit for buyBase, right for sell; intensity sizeBps/sizeRef
///        rows  80–119  slippage strip: full width, intensity maxSlipBps/slipRef
///        rows 120–479  per-epoch histogram bars (buy left, sell right), height min(volBarRows,360)·min(vol,volRef)/volRef
///      Integer rules as HANDOFF D-H: floor divisions, x == ref lights nothing, volRef == 0 → no bars,
///      refs of 0 → strip dark. Mirrored bit-for-bit by tools/fly_int.py `rasterize_swap`.
contract FlySwapRasterizer {
    uint256 internal constant CANVAS_W = 640;
    uint256 internal constant CANVAS_H = 480;
    uint256 internal constant STRIP = 40;
    uint256 internal constant BAR_TOP = 120;

    error MalformedDirectory();
    error MalformedMeta();

    /// @dev cfg fields this contract needs (same word layout as FlyEngine.unpack + the v2 fields, D-1)
    struct Cfg {
        uint256 ptrChunks;
        uint256 edgeChunks;
        uint256 metaChunks;
        uint256 devRef;
        uint256 volBarRows;
        uint256 sizeRef;
        uint256 slipRef;
    }

    function unpackCfg(bytes32[3] memory cfg) public pure returns (Cfg memory c) {
        uint256 c0 = uint256(cfg[0]);
        uint256 c2 = uint256(cfg[2]);
        c.ptrChunks = (c0 >> 176) & 0xffff;
        c.edgeChunks = (c0 >> 160) & 0xffff;
        c.metaChunks = (c0 >> 144) & 0xffff;
        c.devRef = (c2 >> 160) & 0xffff;
        c.volBarRows = (c2 >> 136) & 0xffff;
        c.sizeRef = (c2 >> 120) & 0xffff;
        c.slipRef = (c2 >> 104) & 0xffff;
    }

    /// @notice Render one intent observation to the retina: 2 bytes (Q16 luminance) per receptor
    function rasterizeSwap(address graphRoot, bytes32[3] calldata cfg, FlyTypes.SwapObservation calldata o)
        external
        view
        returns (bytes memory frame)
    {
        Cfg memory c = unpackCfg(cfg);
        bytes memory meta = _readMeta(graphRoot, c);
        uint256 offRet = _be32(meta, 21);
        uint256 nRet = _be32(meta, offRet);
        if (offRet + 4 + 8 * nRet > meta.length) revert MalformedMeta();
        frame = new bytes(2 * nRet);
        for (uint256 k = 0; k < nRet; ++k) {
            uint256 off = offRet + 4 + 8 * k;
            uint256 lum = _sample(o, c, _be16(meta, off + 4), _be16(meta, off + 6));
            frame[2 * k] = bytes1(uint8(lum >> 8));
            frame[2 * k + 1] = bytes1(uint8(lum));
        }
    }

    /// @notice Canvas value at (y, x) for an intent observation (public for tests / replay tools)
    function canvasSwap(FlyTypes.SwapObservation calldata o, bytes32[3] calldata cfg, uint256 y, uint256 x)
        external
        pure
        returns (uint256)
    {
        return _canvas(o, unpackCfg(cfg), y, x);
    }

    function _canvas(FlyTypes.SwapObservation calldata o, Cfg memory c, uint256 y, uint256 x)
        internal
        pure
        returns (uint256)
    {
        if (y < STRIP) {
            uint256 spot = o.spotQ64;
            uint256 ema = o.emaSpotQ64;
            if (spot == ema || ema == 0 || c.devRef == 0) return 0;
            uint256 absDev = ((spot > ema ? spot - ema : ema - spot) * 10000) / ema;
            uint256 lit = absDev * 65535 / c.devRef;
            if (lit > 65535) lit = 65535;
            return ((x < 320) == (spot > ema)) ? lit : 0;
        }
        if (y < 2 * STRIP) {
            if (c.sizeRef == 0 || o.sizeBps == 0) return 0;
            uint256 lit = uint256(o.sizeBps) * 65535 / c.sizeRef;
            if (lit > 65535) lit = 65535;
            return ((x < 320) == o.buyBase) ? lit : 0;
        }
        if (y < 3 * STRIP) {
            if (c.slipRef == 0 || o.maxSlipBps == 0) return 0;
            uint256 lit = uint256(o.maxSlipBps) * 65535 / c.slipRef;
            return lit > 65535 ? 65535 : lit;
        }
        uint256 vol = x < 320 ? o.buyQuote[x / 20] : o.sellQuote[(x - 320) / 20];
        uint256 volRef = o.volRef;
        uint256 rows = c.volBarRows < CANVAS_H - BAR_TOP ? c.volBarRows : CANVAS_H - BAR_TOP;
        uint256 h = volRef == 0 ? 0 : (rows * (vol < volRef ? vol : volRef)) / volRef;
        return y >= CANVAS_H - h ? 65535 : 0;
    }

    /// @dev Bilinear sample at receptor (uQ16, vQ16), identical to FlyEngine._sample
    function _sample(FlyTypes.SwapObservation calldata o, Cfg memory c, uint256 u, uint256 v)
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

    // ------------------------------------------------------------------ directory: meta chunks only

    /// @dev Walk root → pages, take the `metaChunks` addresses after the ptr and edge chunks, concatenate
    function _readMeta(address root, Cfg memory c) internal view returns (bytes memory out) {
        bytes memory rootBytes = DataContractLib.read(root);
        if (rootBytes.length == 0 || rootBytes.length % 20 != 0) revert MalformedDirectory();
        uint256 first = c.ptrChunks + c.edgeChunks;
        uint256 total = first + c.metaChunks;
        address[] memory metaAddrs = new address[](c.metaChunks);
        uint256 seen = 0;
        uint256 nPages = rootBytes.length / 20;
        for (uint256 p = 0; p < nPages && seen < total; ++p) {
            bytes memory page = DataContractLib.read(_addrAt(rootBytes, p * 20));
            if (page.length % 20 != 0) revert MalformedDirectory();
            uint256 cnt = page.length / 20;
            if (seen + cnt <= first) {
                seen += cnt;
                continue;
            }
            for (uint256 i = 0; i < cnt && seen < total; ++i) {
                if (seen >= first) metaAddrs[seen - first] = _addrAt(page, i * 20);
                ++seen;
            }
        }
        if (seen < total) revert MalformedDirectory();
        uint256 len = 0;
        for (uint256 i = 0; i < c.metaChunks; ++i) {
            len += DataContractLib.payloadLength(metaAddrs[i]);
        }
        out = new bytes(len);
        uint256 at = 0;
        for (uint256 i = 0; i < c.metaChunks; ++i) {
            at += DataContractLib.readInto(metaAddrs[i], out, at);
        }
        if (out.length < 101 || uint8(out[0]) != 1) revert MalformedMeta();
    }

    function _addrAt(bytes memory b, uint256 off) internal pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(b, 32), off)))
        }
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
}
