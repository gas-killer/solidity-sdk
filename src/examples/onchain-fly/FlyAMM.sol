// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FlyTypes} from "./FlyTypes.sol";

/// @notice What the pool reads from the fly policy (one SLOAD on the policy side)
interface IFlyPolicyParams {
    function params()
        external
        view
        returns (uint16 feeBps, int16 skewBps, bool rebalance, uint32 windowId, uint32 epoch);
}

/// @title FlyAMM
/// @notice A plain x·y = k pool whose fee and directional skew are read from `FlyPolicy` under hard
///         clamps (HANDOFF §4.1, §4.6, §4.7). NOT a Gas Killer consumer: it never inherits the SDK,
///         so a colluding operator quorum can at worst pin the fee inside [MIN_FEE, MAX_FEE] — never
///         touch reserves.
/// @dev Windows are WINDOW_BLOCKS long. The first pool interaction in a new window CLOSES the previous
///      one: its buy/sell quote volume lands in a 16-window histogram ring, and its TWAP, fee income,
///      LP loss and closing spot are snapshotted. `observe()` returns ONLY closed-window data from
///      storage, so the fly's input is identical at every reference block inside a window and reads no
///      block environment. Volumes in the observation are in units of OBS_UNIT quote wei so they fit
///      the uint64 fields of the handoff's `Observation`.
contract FlyAMM {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ the security boundary
    uint16 public constant MIN_FEE_BPS = 5;
    uint16 public constant MAX_FEE_BPS = 100;
    uint16 public constant MAX_SKEW_BPS = 30;
    uint16 public constant REBAL_SKEW_BPS = 30;
    uint16 public constant DEFAULT_FEE_BPS = 30;
    uint32 public constant MAX_LAG_WINDOWS = 2;
    uint32 public constant WINDOW_BLOCKS = 25;
    uint256 public constant OBS_UNIT = 1e12; // quote wei per observation volume unit
    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------ tokens / policy
    IERC20 public immutable base;
    IERC20 public immutable quote;
    address public immutable deployer;
    IFlyPolicyParams public policy; // set once after the policy is deployed (it needs this pool's address)

    // ------------------------------------------------------------------ reserves + LP shares
    uint128 public reserveBase;
    uint128 public reserveQuote;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // ------------------------------------------------------------------ open window accumulators
    uint32 public curWindowId; // 0 = never opened
    uint64 internal curBuy; // OBS_UNIT quote units
    uint64 internal curSell;
    uint64 internal curFee;
    uint128 internal openBase;
    uint128 internal openQuote;
    uint256 internal openCum;
    uint64 internal openBlock;
    uint256 internal priceCumQ64; // Σ spotQ64 × blocks
    uint64 internal lastCumBlock;

    // ------------------------------------------------------------------ closed window
    struct Closed {
        uint32 windowId;
        uint64 volRef;
        uint128 spotQ64;
        uint128 twapQ64;
        uint64 feeIncomeQuote;
        uint64 lpLossQuote;
    }

    Closed public closed;
    uint64[16] internal buyHist; // indexed by windowId % 16
    uint64[16] internal sellHist;

    // ------------------------------------------------------------------ events / errors
    event Swap(
        address indexed sender, address indexed to, bool buyBase, uint256 amountIn, uint256 amountOut, uint16 feeBps
    );
    event LiquidityAdded(address indexed to, uint256 baseIn, uint256 quoteIn, uint256 lp);
    event LiquidityRemoved(address indexed to, uint256 baseOut, uint256 quoteOut, uint256 lp);
    event WindowClosed(
        uint32 indexed windowId,
        uint64 buy,
        uint64 sell,
        uint64 feeIncome,
        uint64 lpLoss,
        uint128 twapQ64,
        uint64 volRef
    );

    error PolicyAlreadySet();
    error NotDeployer();
    error InsufficientOutput();
    error InsufficientLiquidity();
    error ZeroAmount();

    constructor(IERC20 _base, IERC20 _quote) {
        base = _base;
        quote = _quote;
        deployer = msg.sender;
    }

    /// @notice One-shot wiring of the fly policy (which needs this pool's address at its construction)
    function setPolicy(IFlyPolicyParams _policy) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(policy) != address(0)) revert PolicyAlreadySet();
        policy = _policy;
    }

    // ================================================================== trading

    /// @notice Swap `amountIn` of quote for base (`buyBase`) or base for quote
    function swap(bool buyBase, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out) {
        if (amountIn == 0) revert ZeroAmount();
        _touch();
        uint16 fee = effectiveFee(buyBase);
        uint256 rB = reserveBase;
        uint256 rQ = reserveQuote;
        if (rB == 0 || rQ == 0) revert InsufficientLiquidity();
        uint256 inAfter = amountIn * (BPS - fee) / BPS;
        if (buyBase) {
            quote.safeTransferFrom(msg.sender, address(this), amountIn);
            out = rB * inAfter / (rQ + inAfter);
            if (out < minOut || out >= rB) revert InsufficientOutput();
            reserveQuote = uint128(rQ + amountIn);
            reserveBase = uint128(rB - out);
            base.safeTransfer(to, out);
            curBuy = _sat64(uint256(curBuy) + amountIn / OBS_UNIT);
            curFee = _sat64(uint256(curFee) + (amountIn - inAfter) / OBS_UNIT);
        } else {
            base.safeTransferFrom(msg.sender, address(this), amountIn);
            out = rQ * inAfter / (rB + inAfter);
            if (out < minOut || out >= rQ) revert InsufficientOutput();
            uint256 spotBefore = (rQ << 64) / rB;
            reserveBase = uint128(rB + amountIn);
            reserveQuote = uint128(rQ - out);
            quote.safeTransfer(to, out);
            curSell = _sat64(uint256(curSell) + out / OBS_UNIT);
            curFee = _sat64(uint256(curFee) + (((amountIn - inAfter) * spotBefore) >> 64) / OBS_UNIT);
        }
        emit Swap(msg.sender, to, buyBase, amountIn, out, fee);
    }

    function addLiquidity(uint256 baseIn, uint256 quoteIn, address to) external returns (uint256 lp) {
        if (baseIn == 0 || quoteIn == 0) revert ZeroAmount();
        _touch();
        base.safeTransferFrom(msg.sender, address(this), baseIn);
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        uint256 supply = totalSupply;
        if (supply == 0) {
            lp = _sqrt(baseIn * quoteIn);
        } else {
            uint256 a = baseIn * supply / reserveBase;
            uint256 b = quoteIn * supply / reserveQuote;
            lp = a < b ? a : b;
        }
        if (lp == 0) revert InsufficientLiquidity();
        reserveBase += uint128(baseIn);
        reserveQuote += uint128(quoteIn);
        totalSupply = supply + lp;
        balanceOf[to] += lp;
        emit LiquidityAdded(to, baseIn, quoteIn, lp);
    }

    function removeLiquidity(uint256 lp, address to) external returns (uint256 baseOut, uint256 quoteOut) {
        if (lp == 0) revert ZeroAmount();
        _touch();
        uint256 supply = totalSupply;
        baseOut = lp * reserveBase / supply;
        quoteOut = lp * reserveQuote / supply;
        balanceOf[msg.sender] -= lp;
        totalSupply = supply - lp;
        reserveBase -= uint128(baseOut);
        reserveQuote -= uint128(quoteOut);
        base.safeTransfer(to, baseOut);
        quote.safeTransfer(to, quoteOut);
        emit LiquidityRemoved(to, baseOut, quoteOut, lp);
    }

    // ================================================================== the fly's view

    /// @notice The last CLOSED window, storage reads only (no block environment): the fly's input
    function observe() external view returns (FlyTypes.Observation memory o) {
        Closed memory c = closed;
        o.windowId = c.windowId;
        for (uint256 k = 0; k < 16; ++k) {
            if (uint256(c.windowId) + k < 15) continue; // window would be negative
            uint256 w = uint256(c.windowId) + k - 15;
            if (w == 0) continue;
            o.buyQuote[k] = buyHist[w % 16];
            o.sellQuote[k] = sellHist[w % 16];
        }
        o.volRef = c.volRef;
        o.spotQ64 = c.spotQ64;
        o.twapQ64 = c.twapQ64;
        o.feeIncomeQuote = c.feeIncomeQuote;
        o.lpLossQuote = c.lpLossQuote;
    }

    /// @notice The fee a trade pays now: clamps FlyPolicy.params(), staleness, rebalance override (§4.7)
    function effectiveFee(bool buyBase) public view returns (uint16) {
        if (address(policy) == address(0)) return DEFAULT_FEE_BPS;
        (uint16 fee, int16 skew, bool rebal, uint32 wid,) = policy.params();
        uint32 now_ = _windowId();
        if (wid > now_ || now_ - wid > MAX_LAG_WINDOWS || fee < MIN_FEE_BPS || fee > MAX_FEE_BPS) {
            return DEFAULT_FEE_BPS;
        }
        int256 s = skew;
        if (s > int256(uint256(MAX_SKEW_BPS))) s = int256(uint256(MAX_SKEW_BPS));
        if (s < -int256(uint256(MAX_SKEW_BPS))) s = -int256(uint256(MAX_SKEW_BPS));
        if (rebal && closed.windowId != 0 && reserveBase != 0) {
            // surcharge the direction that moves spot AWAY from the last closed TWAP
            uint256 spot = (uint256(reserveQuote) << 64) / reserveBase;
            s = spot > closed.twapQ64 ? int256(uint256(REBAL_SKEW_BPS)) : -int256(uint256(REBAL_SKEW_BPS));
        }
        int256 f = int256(uint256(fee)) + (buyBase ? s : -s);
        if (f < int256(uint256(MIN_FEE_BPS))) f = int256(uint256(MIN_FEE_BPS));
        if (f > int256(uint256(MAX_FEE_BPS))) f = int256(uint256(MAX_FEE_BPS));
        return uint16(uint256(f));
    }

    /// @notice Current spot price, quote per base, Q64
    function spotQ64() public view returns (uint128) {
        if (reserveBase == 0) return 0;
        return uint128((uint256(reserveQuote) << 64) / reserveBase);
    }

    function currentWindowId() external view returns (uint32) {
        return _windowId();
    }

    // ================================================================== windows

    function _windowId() internal view returns (uint32) {
        return uint32(block.number / WINDOW_BLOCKS);
    }

    /// @dev Accrue the TWAP accumulator and roll the window if the block moved into a new one
    function _touch() internal {
        uint32 w = _windowId();
        uint256 spot = spotQ64();
        if (lastCumBlock != 0 && block.number > lastCumBlock) {
            priceCumQ64 += spot * (block.number - lastCumBlock);
        }
        lastCumBlock = uint64(block.number);
        if (curWindowId == 0) {
            curWindowId = w;
            _openWindow();
            return;
        }
        if (w != curWindowId) {
            _closeWindow(spot);
            curWindowId = w;
            _openWindow();
        }
    }

    function _openWindow() internal {
        openBase = reserveBase;
        openQuote = reserveQuote;
        openCum = priceCumQ64;
        openBlock = uint64(block.number);
        curBuy = 0;
        curSell = 0;
        curFee = 0;
    }

    function _closeWindow(uint256 spot) internal {
        uint32 wid = curWindowId;
        uint256 blocks = block.number - openBlock;
        uint256 twap = blocks == 0 ? spot : (priceCumQ64 - openCum) / blocks;
        // volRef: EMA of window volume, α = 1/8 (first window seeds it)
        uint256 vol = uint256(curBuy) + curSell;
        uint256 volRef = closed.windowId == 0 ? vol : uint256(closed.volRef) + vol / 8 - uint256(closed.volRef) / 8;
        // LP loss at the window TWAP: max(0, x0·P + y0 − x1·P − y1), in OBS_UNIT quote units
        uint256 v0 = ((uint256(openBase) * twap) >> 64) + openQuote;
        uint256 v1 = ((uint256(reserveBase) * twap) >> 64) + reserveQuote;
        uint256 lpLoss = v0 > v1 ? (v0 - v1) / OBS_UNIT : 0;
        // zero histogram slots of windows that never closed (no activity) since the previous close
        uint256 prevWid = closed.windowId;
        if (prevWid != 0 && wid > prevWid + 1) {
            uint256 gap = wid - prevWid - 1;
            if (gap > 16) gap = 16;
            for (uint256 g = 1; g <= gap; ++g) {
                buyHist[(prevWid + g) % 16] = 0;
                sellHist[(prevWid + g) % 16] = 0;
            }
        }
        buyHist[wid % 16] = curBuy;
        sellHist[wid % 16] = curSell;
        closed = Closed({
            windowId: wid,
            volRef: _sat64(volRef),
            spotQ64: uint128(spot),
            twapQ64: uint128(twap),
            feeIncomeQuote: curFee,
            lpLossQuote: _sat64(lpLoss)
        });
        emit WindowClosed(wid, curBuy, curSell, curFee, _sat64(lpLoss), uint128(twap), _sat64(volRef));
    }

    // ================================================================== helpers

    function _sat64(uint256 x) internal pure returns (uint64) {
        return x > type(uint64).max ? type(uint64).max : uint64(x);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
