// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FlyTypes} from "./FlyTypes.sol";

/// @notice What the pool reads from the v2 policy: the fly's fill word for one intent
interface IFlySwapPolicyFills {
    function fillOf(uint64 id)
        external
        view
        returns (uint16 feeBps, int16 skewBps, bool rebalance, uint32 epoch, bool decided);
}

/// @title FlySwapPool
/// @notice v2 of the fly AMM (HANDOFF_PER_SWAP §4.1): swaps are escrowed *intents* in a FIFO queue; every
///         intent is priced by its own fly episode (settled through a Gas Killer round into `FlySwapPolicy`)
///         and then executed, in queue order, by the permissionless `applyNext` at the fly-decided fee.
/// @dev NOT a Gas Killer consumer (never inherits the SDK). The quorum-signed diff writes only policy
///      storage; this pool's storage is written only by `submit`, `applyNext` and the LP functions, so
///      nothing the payload writes can be clobbered by pool activity between reference and apply.
///      The fly chooses a fee inside [MIN_FEE, MAX_FEE]; the pool computes the price from its curve.
///      No cancel (double-settlement race, §4.1); traders exit through `expiryEpoch` (refund on apply).
contract FlySwapPool {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ the security boundary
    uint16 public constant MIN_FEE_BPS = 5;
    uint16 public constant MAX_FEE_BPS = 100;
    uint16 public constant MAX_SKEW_BPS = 30;
    uint16 public constant REBAL_SKEW_BPS = 30;
    uint256 public constant OBS_UNIT = 1e12; // quote wei per observation volume unit
    uint256 internal constant BPS = 10_000;

    uint8 public constant PENDING = 0;
    uint8 public constant FILLED = 1;
    uint8 public constant REFUNDED = 2;

    struct Intent {
        address owner;
        bool buyBase;
        uint8 status;
        uint32 expiryEpoch; // 0 = never
        uint128 amountIn;
        uint128 minOut;
    }

    struct Fill {
        uint128 amountOut;
        uint16 feeBps;
        uint32 epoch;
    }

    // ------------------------------------------------------------------ tokens / policy
    IERC20 public immutable base;
    IERC20 public immutable quote;
    address public immutable deployer;
    IFlySwapPolicyFills public policy; // set once after the policy is deployed (it needs this pool's address)

    // ------------------------------------------------------------------ reserves + LP shares
    uint128 public reserveBase;
    uint128 public reserveQuote;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // ------------------------------------------------------------------ the queue
    uint64 public tail; // last submitted id (ids start at 1)
    uint64 public applied; // last applied id
    mapping(uint64 => Intent) public intents;
    mapping(uint64 => Fill) public fills;

    // ------------------------------------------------------------------ per-epoch statistics the fly sees
    uint64[16] internal buyHist; // fee-paid quote volume per policy epoch, index epoch % 16
    uint64[16] internal sellHist;
    uint32 public histEpoch; // newest epoch with fills applied (0 = none)
    uint64 public volRef; // EMA (α = 1/8) of per-epoch volume
    uint128 public emaSpotQ64; // EMA (α = 1/8) of post-fill spot; seeded at first liquidity
    uint64 internal curFeeIncome; // accumulators for `histEpoch`
    uint64 internal curLpLoss;
    uint64 public lastEpochFeeIncome; // completed-epoch values the fly is rewarded / punished with
    uint64 public lastEpochLpLoss;

    // ------------------------------------------------------------------ events / errors
    event IntentSubmitted(
        uint64 indexed id, address indexed owner, bool buyBase, uint256 amountIn, uint256 minOut, uint32 expiryEpoch
    );
    event Swap(
        uint64 indexed id,
        address indexed owner,
        bool buyBase,
        uint256 amountIn,
        uint256 amountOut,
        uint16 feeBps,
        uint32 epoch
    );
    event IntentRefunded(uint64 indexed id, address indexed owner, uint256 amountIn, string reason);
    event LiquidityAdded(address indexed to, uint256 baseIn, uint256 quoteIn, uint256 lp);
    event LiquidityRemoved(address indexed to, uint256 baseOut, uint256 quoteOut, uint256 lp);
    event EpochRolled(
        uint32 indexed epoch,
        uint64 buy,
        uint64 sell,
        uint64 feeIncome,
        uint64 lpLoss,
        uint64 volRef,
        uint128 emaSpotQ64
    );

    error PolicyAlreadySet();
    error NotDeployer();
    error NothingToApply();
    error NotDecided();
    error NoSuchIntent();
    error InsufficientLiquidity();
    error ZeroAmount();

    constructor(IERC20 _base, IERC20 _quote) {
        base = _base;
        quote = _quote;
        deployer = msg.sender;
    }

    /// @notice One-shot wiring of the fly policy (which needs this pool's address at its construction)
    function setPolicy(IFlySwapPolicyFills _policy) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(policy) != address(0)) revert PolicyAlreadySet();
        policy = _policy;
    }

    // ================================================================== intents

    /// @notice Escrow `amountIn` and join the queue. The fly prices this intent in a later round.
    function submit(bool buyBase, uint256 amountIn, uint256 minOut, uint32 expiryEpoch) external returns (uint64 id) {
        if (amountIn == 0) revert ZeroAmount();
        (buyBase ? quote : base).safeTransferFrom(msg.sender, address(this), amountIn);
        id = ++tail;
        intents[id] = Intent({
            owner: msg.sender,
            buyBase: buyBase,
            status: PENDING,
            expiryEpoch: expiryEpoch,
            amountIn: uint128(amountIn),
            minOut: uint128(minOut)
        });
        emit IntentSubmitted(id, msg.sender, buyBase, amountIn, minOut, expiryEpoch);
    }

    /// @notice Execute the next intent in queue order at its fly-decided fee (or refund it). Permissionless.
    function applyNext() public returns (uint64 id) {
        id = applied + 1;
        if (id > tail) revert NothingToApply();
        (uint16 fee, int16 skew, bool rebal, uint32 epoch, bool decided) = policy.fillOf(id);
        if (!decided) revert NotDecided();
        Intent storage it = intents[id];
        uint16 eff = _clampFee(fee, skew, rebal, it.buyBase, reserveBase, reserveQuote);
        applied = id;
        _rollEpoch(epoch);
        if (it.expiryEpoch != 0 && epoch > it.expiryEpoch) return _refund(id, it, "expired");
        _execute(id, eff, epoch);
    }

    /// @dev x·y=k at the current reserves with the clamped fee; refunds on minOut / empty pool
    function _execute(uint64 id, uint16 eff, uint32 epoch) internal {
        Intent storage it = intents[id];
        uint256 amountIn = it.amountIn;
        uint256 rB = reserveBase;
        uint256 rQ = reserveQuote;
        if (rB == 0 || rQ == 0) {
            _refund(id, it, "no liquidity");
            return;
        }
        uint256 inAfter = amountIn * (BPS - eff) / BPS;
        uint256 out;
        uint256 feeQuote;
        if (it.buyBase) {
            out = rB * inAfter / (rQ + inAfter);
            if (out < it.minOut || out >= rB) {
                _refund(id, it, "minOut");
                return;
            }
            reserveQuote = uint128(rQ + amountIn);
            reserveBase = uint128(rB - out);
            feeQuote = amountIn - inAfter;
            base.safeTransfer(it.owner, out);
            buyHist[epoch % 16] = _sat64(uint256(buyHist[epoch % 16]) + amountIn / OBS_UNIT);
        } else {
            out = rQ * inAfter / (rB + inAfter);
            if (out < it.minOut || out >= rQ) {
                _refund(id, it, "minOut");
                return;
            }
            feeQuote = ((amountIn - inAfter) * ((rQ << 64) / rB)) >> 64;
            reserveBase = uint128(rB + amountIn);
            reserveQuote = uint128(rQ - out);
            quote.safeTransfer(it.owner, out);
            sellHist[epoch % 16] = _sat64(uint256(sellHist[epoch % 16]) + out / OBS_UNIT);
        }
        it.status = FILLED;
        fills[id] = Fill({amountOut: uint128(out), feeBps: eff, epoch: epoch});
        _afterFill(rB, rQ, feeQuote);
        emit Swap(id, it.owner, it.buyBase, amountIn, out, eff, epoch);
    }

    /// @notice Keeper convenience: apply up to `n` intents, stopping at the first undecided one
    function applyUpTo(uint64 n) external returns (uint64 count) {
        while (count < n) {
            uint64 id = applied + 1;
            if (id > tail) break;
            (,,,, bool decided) = policy.fillOf(id);
            if (!decided) break;
            applyNext();
            ++count;
        }
    }

    function _refund(uint64 id, Intent storage it, string memory reason) internal returns (uint64) {
        it.status = REFUNDED;
        (it.buyBase ? quote : base).safeTransfer(it.owner, it.amountIn);
        emit IntentRefunded(id, it.owner, it.amountIn, reason);
        return id;
    }

    /// @dev Exactly v1 `effectiveFee`: band clamp, skew cap, rebalance override against the EMA spot
    function _clampFee(uint16 fee, int16 skew, bool rebal, bool buyBase, uint256 rB, uint256 rQ)
        internal
        view
        returns (uint16)
    {
        int256 f = int256(uint256(fee));
        if (f < int256(uint256(MIN_FEE_BPS))) f = int256(uint256(MIN_FEE_BPS));
        if (f > int256(uint256(MAX_FEE_BPS))) f = int256(uint256(MAX_FEE_BPS));
        int256 s = skew;
        if (s > int256(uint256(MAX_SKEW_BPS))) s = int256(uint256(MAX_SKEW_BPS));
        if (s < -int256(uint256(MAX_SKEW_BPS))) s = -int256(uint256(MAX_SKEW_BPS));
        if (rebal && rB != 0 && emaSpotQ64 != 0) {
            uint256 spot = (rQ << 64) / rB;
            s = spot > emaSpotQ64 ? int256(uint256(REBAL_SKEW_BPS)) : -int256(uint256(REBAL_SKEW_BPS));
        }
        f += buyBase ? s : -s;
        if (f < int256(uint256(MIN_FEE_BPS))) f = int256(uint256(MIN_FEE_BPS));
        if (f > int256(uint256(MAX_FEE_BPS))) f = int256(uint256(MAX_FEE_BPS));
        return uint16(uint256(f));
    }

    /// @dev First fill of a newer epoch: freeze the previous epoch's outcome (reward/punish inputs), zero skipped slots
    function _rollEpoch(uint32 epoch) internal {
        uint32 prev = histEpoch;
        if (epoch <= prev) return;
        if (prev != 0) {
            uint256 vol = uint256(buyHist[prev % 16]) + sellHist[prev % 16];
            volRef = _sat64(volRef == 0 ? vol : uint256(volRef) + vol / 8 - uint256(volRef) / 8);
            lastEpochFeeIncome = curFeeIncome;
            lastEpochLpLoss = curLpLoss;
            emit EpochRolled(prev, buyHist[prev % 16], sellHist[prev % 16], curFeeIncome, curLpLoss, volRef, emaSpotQ64);
        }
        uint256 gap = epoch - prev;
        if (gap > 16) gap = 16;
        for (uint256 g = 1; g <= gap; ++g) {
            buyHist[(prev + g) % 16] = 0;
            sellHist[(prev + g) % 16] = 0;
        }
        curFeeIncome = 0;
        curLpLoss = 0;
        histEpoch = epoch;
    }

    /// @dev LP loss vs the EMA spot before the fill, fee income, then the EMA update
    function _afterFill(uint256 rB0, uint256 rQ0, uint256 feeQuote) internal {
        uint256 P = emaSpotQ64;
        uint256 v0 = ((rB0 * P) >> 64) + rQ0;
        uint256 v1 = ((uint256(reserveBase) * P) >> 64) + reserveQuote;
        if (v0 > v1) curLpLoss = _sat64(uint256(curLpLoss) + (v0 - v1) / OBS_UNIT);
        curFeeIncome = _sat64(uint256(curFeeIncome) + feeQuote / OBS_UNIT);
        uint256 spot = (uint256(reserveQuote) << 64) / reserveBase;
        emaSpotQ64 = uint128(P == 0 ? spot : P + spot / 8 - P / 8);
    }

    // ================================================================== liquidity (immediate, untracked)

    function addLiquidity(uint256 baseIn, uint256 quoteIn, address to) external returns (uint256 lp) {
        if (baseIn == 0 || quoteIn == 0) revert ZeroAmount();
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
        if (emaSpotQ64 == 0) emaSpotQ64 = uint128((uint256(reserveQuote) << 64) / reserveBase);
        emit LiquidityAdded(to, baseIn, quoteIn, lp);
    }

    function removeLiquidity(uint256 lp, address to) external returns (uint256 baseOut, uint256 quoteOut) {
        if (lp == 0) revert ZeroAmount();
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

    // ================================================================== the fly's view (storage only)

    /// @notice Raw observation of intent `id`: the histogram ring is UNrotated (index = epoch % 16) and
    ///         `epoch` carries `histEpoch`; `FlySwapPolicy` rotates it for the observed epoch (D-2).
    function observeIntent(uint64 id) external view returns (FlyTypes.SwapObservation memory o) {
        if (id == 0 || id > tail) revert NoSuchIntent();
        Intent storage it = intents[id];
        uint256 rB = reserveBase;
        uint256 rQ = reserveQuote;
        uint256 rIn = it.buyBase ? rQ : rB;
        uint256 rOut = it.buyBase ? rB : rQ;
        o.id = id;
        o.buyBase = it.buyBase;
        o.sizeBps = uint64(rIn == 0 ? BPS : _min(BPS, uint256(it.amountIn) * BPS / rIn));
        if (it.minOut != 0 && rIn != 0 && rOut != 0) {
            uint256 q = rOut * uint256(it.amountIn) / (rIn + uint256(it.amountIn));
            o.maxSlipBps = uint64(q > it.minOut ? (q - it.minOut) * BPS / q : 0);
        }
        o.queueDepth = tail - applied;
        o.epoch = histEpoch;
        o.buyQuote = buyHist;
        o.sellQuote = sellHist;
        o.volRef = volRef;
        o.spotQ64 = uint128(rB == 0 ? 0 : (rQ << 64) / rB);
        o.emaSpotQ64 = emaSpotQ64;
        o.feeIncomeQuote = lastEpochFeeIncome;
        o.lpLossQuote = lastEpochLpLoss;
    }

    function pendingRange() external view returns (uint64, uint64) {
        return (applied, tail);
    }

    function spotQ64() external view returns (uint128) {
        return reserveBase == 0 ? 0 : uint128((uint256(reserveQuote) << 64) / reserveBase);
    }

    // ================================================================== helpers

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

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
