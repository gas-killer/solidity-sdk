// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {DataContractLib} from "../onchain-llm/DataContractLib.sol";
import {FlyTypes} from "./FlyTypes.sol";

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
