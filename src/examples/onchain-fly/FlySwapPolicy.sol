// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";

import {FlyEngine} from "./FlyEngine.sol";
import {FlySwapPool} from "./FlySwapPool.sol";
import {FlySwapRasterizer} from "./FlySwapRasterizer.sol";
import {FlyTypes} from "./FlyTypes.sol";

/// @title FlySwapPolicy
/// @notice v2 Gas Killer consumer (HANDOFF_PER_SWAP §4.2): `settle(prev)` prices the next pending intents
///         of `FlySwapPool` with ONE fly episode per intent and writes one fill word per intent plus the
///         chained `FlyStateV2` word. The pool then executes each intent in order via `applyNext`.
/// @dev Invariants:
///        - `settle` is the only tracked function; it writes only FLY_SLOT, DECIDED_SLOT and `fills[id]`
///          (plus the gate-exempt StateTracker counter). No pool storage, no CALL, no block env.
///        - the brain runs through STATICCALLs into the stateless engine/rasterizer; graph and warm
///          snapshot are EXTCODECOPY reads of immutable data contracts.
///        - a direct on-chain `settle` is unaffordable (one episode is ~14 Ggas vs the 16.78 M tx cap), so
///          no caller gate is needed (D-4). The pool clamps everything it reads (LP safety boundary).
contract FlySwapPolicy is GasKillerSDK {
    bytes32 public constant FLY_DOMAIN = keccak256("gaskiller.fly.swap.policy.v2");

    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.FlySwapPolicy.flyWord")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant FLY_SLOT = 0x95ea1e5fdee79051d094f5119683b73a6e730d081099bb1589df6f5280d2ba00;
    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.FlySwapPolicy.decidedThrough")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant DECIDED_SLOT = 0x9b731ba361cf21552bffc2ccab8fec4efb8add0e30508c02bc7187aecc795700;
    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.FlySwapPolicy.fills")) - 1)) & ~bytes32(uint256(0xff)); fills[id] at keccak256(abi.encode(id, FILLS_BASE))
    bytes32 public constant FILLS_BASE = 0x52817363cd56a26990c2296faa5d3c5779637154d64b831769c2a544d450bc00;
    bytes32 public constant MEMORY_ROOT_ZERO = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    uint8 public constant FLAG_REBALANCE = 1;
    uint8 public constant FLAG_PUNISH_NEXT = 2;
    uint8 public constant FLAG_REWARD_NEXT = 4;

    FlyEngine public immutable engine;
    FlySwapRasterizer public immutable rasterizer;
    address public immutable graphRoot;
    address public immutable warmRoot;
    FlySwapPool public immutable pool;
    bytes32 private immutable _cfg0;
    bytes32 private immutable _cfg1;
    bytes32 private immutable _cfg2;

    uint256 public immutable minFeeBps;
    uint256 public immutable maxFeeBps;
    uint256 public immutable maxSkewBps;
    uint256 public immutable rebalThresholdBps;
    uint256 public immutable pulseSteps;
    uint256 public immutable maxBatch; // cfg2[103:96] (D-1); 0 → 1

    /// @notice One fill decided (the frame is recomputable from `obs`; it is not logged)
    event FlyIntentDecided(
        uint64 indexed id,
        bytes32 indexed fillWord,
        bytes32 indexed spikeRoot,
        FlyTypes.SwapObservation obs,
        FlyTypes.Readout readout
    );
    /// @notice The round's chained state
    event FlySettled(uint256 indexed transitionIndex, bytes32 indexed flyWord, FlyTypes.FlyStateV2 next);

    error StateMismatch();
    error NothingToDecide();

    constructor(
        address _avsAddress,
        address _blsSigChecker,
        FlyEngine _engine,
        FlySwapRasterizer _rasterizer,
        address _graphRoot,
        address _warmRoot,
        bytes32[3] memory _packedConfig,
        FlySwapPool _pool
    ) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        engine = _engine;
        rasterizer = _rasterizer;
        graphRoot = _graphRoot;
        warmRoot = _warmRoot;
        pool = _pool;
        _cfg0 = _packedConfig[0];
        _cfg1 = _packedConfig[1];
        _cfg2 = _packedConfig[2];
        uint256 c2 = uint256(_packedConfig[2]);
        minFeeBps = (c2 >> 240) & 0xffff;
        maxFeeBps = (c2 >> 224) & 0xffff;
        maxSkewBps = (c2 >> 208) & 0xffff;
        rebalThresholdBps = (c2 >> 176) & 0xffff;
        uint256 mb = (c2 >> 96) & 0xff;
        maxBatch = mb == 0 ? 1 : mb;
        pulseSteps = (uint256(_packedConfig[1]) >> 224) & 0xffff;
        _validateArtifacts();
    }

    /// @notice Artifact validation hook (~20 M gas on the real graph: only via eth_call under EIP-7825)
    function _validateArtifacts() internal view virtual {
        engine.checkArtifacts(graphRoot, warmRoot, [_cfg0, _cfg1, _cfg2]);
    }

    // ================================================================== the tracked function

    /// @dev Everything one round decides (memory only; `settle` stores + emits, `dryRun` returns)
    struct Round {
        FlyTypes.FlyStateV2 next;
        uint64 from;
        bytes32[] fillWords;
        bytes32[] spikeRoots;
        FlyTypes.SwapObservation[] obs;
        FlyTypes.Readout[] readouts;
    }

    /// @notice Price the next pending intents (one episode each) and settle the fill words + chained state
    function settle(FlyTypes.FlyStateV2 calldata prev) external trackState {
        bytes32 word = flyWord();
        if (!_matches(word, prev)) revert StateMismatch();
        Round memory rd = _compute(prev);
        rd.next.prevWord = word;
        for (uint256 k = 0; k < rd.fillWords.length; ++k) {
            uint64 id = rd.from + uint64(k);
            bytes32 slot = fillSlot(id);
            bytes32 w = rd.fillWords[k];
            assembly ("memory-safe") {
                sstore(slot, w)
            }
            emit FlyIntentDecided(id, w, rd.spikeRoots[k], rd.obs[k], rd.readouts[k]);
        }
        uint256 through = rd.next.decidedThrough;
        bytes32 newWord = pack(rd.next);
        assembly ("memory-safe") {
            sstore(DECIDED_SLOT, through)
            sstore(FLY_SLOT, newWord)
        }
        emit FlySettled(stateTransitionCount(), newWord, rd.next);
    }

    /// @notice The round without stores (keeper sanity + operators)
    function dryRun(FlyTypes.FlyStateV2 calldata prev) external view returns (Round memory rd, bytes32 word) {
        rd = _compute(prev);
        rd.next.prevWord = flyWord();
        word = pack(rd.next);
    }

    function _compute(FlyTypes.FlyStateV2 calldata prev) internal view returns (Round memory rd) {
        (, uint64 tail) = pool.pendingRange();
        uint256 dt = decidedThrough();
        uint64 from = uint64(dt) + 1;
        uint64 to = tail < uint64(dt + maxBatch) ? tail : uint64(dt + maxBatch);
        if (from > to) revert NothingToDecide();
        uint256 n = to - from + 1;
        rd.from = from;
        rd.fillWords = new bytes32[](n);
        rd.spikeRoots = new bytes32[](n);
        rd.obs = new FlyTypes.SwapObservation[](n);
        rd.readouts = new FlyTypes.Readout[](n);
        uint32 epoch = prev.epoch + 1;
        uint32[4] memory rates = prev.rateMilliHz;
        uint8 lastFlags;
        for (uint256 k = 0; k < n; ++k) {
            FlyTypes.SwapObservation memory o = _observe(from + uint64(k), epoch);
            FlyTypes.Stimulus memory s;
            if (k == 0) {
                s.punishSteps = (prev.flags & FLAG_PUNISH_NEXT) != 0 ? uint16(pulseSteps) : 0;
                s.rewardSteps = (prev.flags & FLAG_REWARD_NEXT) != 0 ? uint16(pulseSteps) : 0;
            }
            (bytes32 fw, bytes32 spikeRoot, FlyTypes.Readout memory r) = _decideOne(o, s, rates, epoch);
            rates = r.rateMilliHz;
            rd.fillWords[k] = fw;
            rd.spikeRoots[k] = spikeRoot;
            rd.obs[k] = o;
            rd.readouts[k] = r;
            lastFlags = (o.lpLossQuote > 0 ? FLAG_PUNISH_NEXT : 0) | (o.feeIncomeQuote > 0 ? FLAG_REWARD_NEXT : 0);
        }
        rd.next.epoch = epoch;
        rd.next.decidedThrough = to;
        rd.next.flags = lastFlags;
        rd.next.rateMilliHz = rates;
        rd.next.memoryRoot = MEMORY_ROOT_ZERO;
    }

    /// @dev One episode for one intent: rasterize → decide → readout mapping (exactly v1 `_compute`)
    function _decideOne(
        FlyTypes.SwapObservation memory o,
        FlyTypes.Stimulus memory s,
        uint32[4] memory rates0,
        uint32 epoch
    ) internal view returns (bytes32 fillWord, bytes32 spikeRoot, FlyTypes.Readout memory r) {
        (r, spikeRoot) = _episode(o, s, rates0);
        fillWord = _mapReadout(r, o, epoch, spikeRoot);
    }

    function _episode(FlyTypes.SwapObservation memory o, FlyTypes.Stimulus memory s, uint32[4] memory rates0)
        internal
        view
        returns (FlyTypes.Readout memory r, bytes32 spikeRoot)
    {
        bytes32[3] memory cfg = [_cfg0, _cfg1, _cfg2];
        bytes memory frame = rasterizer.rasterizeSwap(graphRoot, cfg, o);
        (r, spikeRoot) = engine.decide(graphRoot, warmRoot, cfg, frame, s, rates0);
    }

    function _mapReadout(FlyTypes.Readout memory r, FlyTypes.SwapObservation memory o, uint32 epoch, bytes32 spikeRoot)
        internal
        view
        returns (bytes32)
    {
        int256 turn = _clamp(
            int256(120) * (int256(uint256(r.rateMilliHz[0])) - int256(uint256(r.rateMilliHz[1]))) / 1000, -6000, 6000
        );
        uint256 fwd = _clampU(400 * (uint256(r.rateMilliHz[2]) + r.rateMilliHz[3]) / 1000, 0, 20000);
        bool rebal = (uint256(r.spikesLast30ms[2]) + r.spikesLast30ms[3]) > 0
            && _absDevBps(o.spotQ64, o.emaSpotQ64) > rebalThresholdBps;
        return packFill(
            uint16(minFeeBps + fwd * (maxFeeBps - minFeeBps) / 20000),
            int16(turn * int256(maxSkewBps) / 6000),
            rebal ? FLAG_REBALANCE : 0,
            epoch,
            spikeRoot
        );
    }

    /// @dev Pool's raw observation → rotated histogram for `epoch` (bins k = epochs epoch−16+k, D-2)
    function _observe(uint64 id, uint32 epoch) internal view returns (FlyTypes.SwapObservation memory o) {
        o = pool.observeIntent(id);
        uint32 histEpoch = o.epoch;
        uint64[16] memory raw;
        uint64[16] memory rawS;
        for (uint256 k = 0; k < 16; ++k) {
            raw[k] = o.buyQuote[k]; // explicit copies: memory array assignment would alias the ring being rewritten
            rawS[k] = o.sellQuote[k];
        }
        for (uint256 k = 0; k < 16; ++k) {
            int256 e = int256(uint256(epoch)) - 16 + int256(k);
            bool valid = e >= 1 && e <= int256(uint256(histEpoch));
            o.buyQuote[k] = valid ? raw[uint256(e) % 16] : 0;
            o.sellQuote[k] = valid ? rawS[uint256(e) % 16] : 0;
        }
        o.epoch = epoch;
    }

    // ================================================================== words + views

    /// @notice The fly's fill for intent `id` (the pool reads this with one SLOAD)
    function fillOf(uint64 id)
        external
        view
        returns (uint16 feeBps, int16 skewBps, bool rebalance, uint32 epoch, bool decided)
    {
        decided = id != 0 && id <= decidedThrough();
        if (!decided) return (0, 0, false, 0, false);
        uint256 w = uint256(_sload(fillSlot(id)));
        feeBps = uint16(w >> 240);
        skewBps = int16(uint16(w >> 224));
        rebalance = ((w >> 216) & FLAG_REBALANCE) != 0;
        epoch = uint32((w >> 192) & 0xffffff);
    }

    function fillWordOf(uint64 id) external view returns (bytes32) {
        return _sload(fillSlot(id));
    }

    function decidedThrough() public view returns (uint256) {
        return uint256(_sload(DECIDED_SLOT));
    }

    function flyWord() public view returns (bytes32) {
        return _sload(FLY_SLOT);
    }

    function fillSlot(uint64 id) public pure returns (bytes32) {
        return keccak256(abi.encode(uint256(id), FILLS_BASE));
    }

    /// @notice feeBps[255:240] | skewBps[239:224] | flags[223:216] | epoch[215:192] | spikeRoot[159:0]
    function packFill(uint16 fee, int16 skew, uint8 flags, uint32 epoch, bytes32 spikeRoot)
        public
        pure
        returns (bytes32)
    {
        uint256 w = uint256(uint160(uint256(spikeRoot)));
        w |= uint256(epoch & 0xffffff) << 192;
        w |= uint256(flags) << 216;
        w |= uint256(uint16(skew)) << 224;
        w |= uint256(fee) << 240;
        return bytes32(w);
    }

    /// @notice epoch[255:232] | decidedThrough[231:168] | flags[167:160] | keccak(state)[159:0]
    function pack(FlyTypes.FlyStateV2 memory s) public pure returns (bytes32) {
        uint256 w = uint256(uint160(uint256(keccak256(abi.encode(s)))));
        w |= uint256(s.flags) << 160;
        w |= uint256(s.decidedThrough) << 168;
        w |= uint256(s.epoch & 0xffffff) << 232;
        return bytes32(w);
    }

    /// @notice The state the very first round extends (FLY_SLOT == 0)
    function genesisState() public pure returns (FlyTypes.FlyStateV2 memory s) {
        s.memoryRoot = MEMORY_ROOT_ZERO;
    }

    function packedConfig() external view returns (bytes32[3] memory) {
        return [_cfg0, _cfg1, _cfg2];
    }

    function _matches(bytes32 word, FlyTypes.FlyStateV2 calldata prev) internal pure returns (bool) {
        bytes32 h = keccak256(abi.encode(prev));
        if (word == bytes32(0)) return h == keccak256(abi.encode(genesisState()));
        return uint160(uint256(word)) == uint160(uint256(h));
    }

    function _sload(bytes32 slot) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := sload(slot)
        }
    }

    function _absDevBps(uint256 spot, uint256 ref) internal pure returns (uint256) {
        if (ref == 0) return 0;
        return ((spot > ref ? spot - ref : ref - spot) * 10000) / ref;
    }

    function _clamp(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }

    function _clampU(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }
}

/// @notice FlySwapPolicy without the constructor-time artifact check (EIP-7825: the ~20 M check cannot fit
///         a deploy tx on Sepolia; run `tools/fly_anvil.py check` via eth_call instead)
contract FlySwapPolicyUnchecked is FlySwapPolicy {
    constructor(
        address _avsAddress,
        address _blsSigChecker,
        FlyEngine _engine,
        FlySwapRasterizer _rasterizer,
        address _graphRoot,
        address _warmRoot,
        bytes32[3] memory _packedConfig,
        FlySwapPool _pool
    ) FlySwapPolicy(_avsAddress, _blsSigChecker, _engine, _rasterizer, _graphRoot, _warmRoot, _packedConfig, _pool) {}

    function _validateArtifacts() internal view override {}
}
