// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";

import {FlyAMM} from "./FlyAMM.sol";
import {FlyEngine} from "./FlyEngine.sol";
import {FlyTypes} from "./FlyTypes.sol";

/// @title FlyPolicy
/// @notice The Gas Killer consumer of the fly-connectome AMM: one tracked function, `decide`, runs a
///         300 ms episode of the complete fly brain (a multi-Ggas STATICCALL into the stateless
///         `FlyEngine`) on the pool's last closed window and settles ONE packed word — fee, skew,
///         flags, window, epoch and a 160-bit commitment to the full `FlyState` (HANDOFF §4.5, §4.7).
/// @dev Invariants (GasKillerChat pattern):
///        - `decide` mutates only FLY_SLOT (the StateTracker counter is gate-exempt);
///        - the brain is a STATICCALL into a stateless engine; graph and warm snapshot are EXTCODECOPY
///          reads of immutable data contracts — never in the payload;
///        - no block-environment reads (the epoch is `stateTransitionCount()`; the pool's `observe()`
///          returns closed-window storage only);
///        - the pool never inherits the SDK and clamps everything it reads: a colluding quorum can
///          pin the fee inside the band, never drain reserves. Do not merge the two contracts.
contract FlyPolicy is GasKillerSDK {
    /// @notice Domain separator of the packed word chain
    bytes32 public constant FLY_DOMAIN = keccak256("gaskiller.fly.amm.policy.v1");

    /// @notice The single mutable app slot
    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.FlyPolicy.flyWord")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant FLY_SLOT = 0xcbecd64d5226c3b53f872ce956484768a63c3b8a34d2c1088c069f9663d00d00;

    /// @notice keccak256("") — the memory root while ETA == 0 (no plasticity in v1)
    bytes32 public constant MEMORY_ROOT_ZERO = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    uint8 public constant FLAG_REBALANCE = 1;
    uint8 public constant FLAG_PUNISH_NEXT = 2;
    uint8 public constant FLAG_REWARD_NEXT = 4;

    FlyEngine public immutable engine;
    address public immutable graphRoot;
    address public immutable warmRoot;
    FlyAMM public immutable pool;
    bytes32 private immutable _cfg0;
    bytes32 private immutable _cfg1;
    bytes32 private immutable _cfg2;

    // fee-band parameters, decoded from cfg[2] at construction (design targets: 5/100/30/25 bps)
    uint256 public immutable minFeeBps;
    uint256 public immutable maxFeeBps;
    uint256 public immutable maxSkewBps;
    uint256 public immutable rebalThresholdBps;
    uint256 public immutable pulseSteps;

    /// @notice Emitted by every settled decision; the full state lives here, its packed word in FLY_SLOT
    event FlyDecided(
        uint256 indexed transitionIndex,
        bytes32 indexed flyWord,
        bytes32 indexed spikeRoot,
        FlyTypes.FlyState next,
        bytes frame,
        FlyTypes.Readout readout
    );

    error StateMismatch();
    error WindowNotClosed();

    constructor(
        address _avsAddress,
        address _blsSigChecker,
        FlyEngine _engine,
        address _graphRoot,
        address _warmRoot,
        bytes32[3] memory _packedConfig,
        FlyAMM _pool
    ) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        engine = _engine;
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
        pulseSteps = (uint256(_packedConfig[1]) >> 224) & 0xffff;
        _validateArtifacts();
    }

    /// @notice Artifact validation hook (≈22 M gas on the real graph: fine in a constructor)
    function _validateArtifacts() internal view virtual {
        engine.checkArtifacts(graphRoot, warmRoot, [_cfg0, _cfg1, _cfg2]);
    }

    // ================================================================== the tracked function

    /// @notice Run one episode on the last closed window and settle the next packed word.
    /// @dev The ONLY tracked function. Operators simulate it under the unbounded profile and sign
    ///      the single-STORE (+ log) diff; the brain never executes in the applying transaction.
    /// @param prev The previous FlyState (from the last FlyDecided log); its packed word must be in FLY_SLOT
    function decide(FlyTypes.FlyState calldata prev) external trackState {
        bytes32 word = flyWord();
        if (!_matches(word, prev)) revert StateMismatch();
        (FlyTypes.FlyState memory next, bytes memory frame, FlyTypes.Readout memory r, bytes32 spikeRoot) =
            _compute(prev);
        next.prevWord = word;
        bytes32 newWord = pack(next);
        assembly ("memory-safe") {
            sstore(FLY_SLOT, newWord)
        }
        emit FlyDecided(stateTransitionCount(), newWord, spikeRoot, next, frame, r);
    }

    /// @notice The decision without touching state (eth_call / operators / tests)
    function dryRun(FlyTypes.FlyState calldata prev)
        external
        view
        returns (
            FlyTypes.FlyState memory next,
            bytes32 word,
            bytes memory frame,
            FlyTypes.Readout memory r,
            bytes32 spikeRoot
        )
    {
        (next, frame, r, spikeRoot) = _compute(prev);
        next.prevWord = flyWord();
        word = pack(next);
    }

    function _compute(FlyTypes.FlyState calldata prev)
        internal
        view
        returns (FlyTypes.FlyState memory next, bytes memory frame, FlyTypes.Readout memory r, bytes32 spikeRoot)
    {
        FlyTypes.Observation memory o = pool.observe(); // STATICCALL, storage-only
        if (o.windowId <= prev.windowId) revert WindowNotClosed(); // one decision per closed window
        bytes32[3] memory cfg = [_cfg0, _cfg1, _cfg2];
        frame = engine.rasterize(graphRoot, cfg, o);
        FlyTypes.Stimulus memory s = FlyTypes.Stimulus({
            punishSteps: (prev.flags & FLAG_PUNISH_NEXT) != 0 ? uint16(pulseSteps) : 0,
            rewardSteps: (prev.flags & FLAG_REWARD_NEXT) != 0 ? uint16(pulseSteps) : 0
        });
        (r, spikeRoot) = engine.decide(graphRoot, warmRoot, cfg, frame, s, prev.rateMilliHz); // the Ggas call
        // §4.3: DNp20 R−L → skew, DNpe017 sum → fee, DNpe017 spikes in the last 30 ms + deviation → rebalance
        int256 turn = _clamp(
            int256(120) * (int256(uint256(r.rateMilliHz[0])) - int256(uint256(r.rateMilliHz[1]))) / 1000, -6000, 6000
        );
        uint256 fwd = _clampU(400 * (uint256(r.rateMilliHz[2]) + r.rateMilliHz[3]) / 1000, 0, 20000);
        next.epoch = prev.epoch + 1;
        next.windowId = o.windowId;
        next.skewBps = int16(turn * int256(maxSkewBps) / 6000);
        next.feeBps = uint16(minFeeBps + fwd * (maxFeeBps - minFeeBps) / 20000);
        bool rebal = (uint256(r.spikesLast30ms[2]) + r.spikesLast30ms[3]) > 0
            && _absDevBps(o.spotQ64, o.twapQ64) > rebalThresholdBps;
        next.flags = (rebal ? FLAG_REBALANCE : 0) | (o.lpLossQuote > 0 ? FLAG_PUNISH_NEXT : 0)
            | (o.feeIncomeQuote > 0 ? FLAG_REWARD_NEXT : 0);
        next.rateMilliHz = r.rateMilliHz;
        next.memoryRoot = MEMORY_ROOT_ZERO;
    }

    /// @notice The state the very first decision extends (FLY_SLOT == 0)
    function genesisState() public pure returns (FlyTypes.FlyState memory s) {
        s.memoryRoot = MEMORY_ROOT_ZERO;
    }

    /// @dev `prev` is the state committed in `word`; a zero word commits to `genesisState()`
    function _matches(bytes32 word, FlyTypes.FlyState calldata prev) internal pure returns (bool) {
        bytes32 h = keccak256(abi.encode(prev));
        if (word == bytes32(0)) return h == keccak256(abi.encode(genesisState()));
        return uint160(uint256(word)) == uint160(uint256(h));
    }

    // ================================================================== the packed word

    /// @notice Parameters the pool reads with one SLOAD
    function params()
        external
        view
        returns (uint16 feeBps, int16 skewBps, bool rebalance, uint32 windowId, uint32 epoch)
    {
        uint256 w = uint256(flyWord());
        feeBps = uint16(w >> 240);
        skewBps = int16(uint16(w >> 224));
        rebalance = ((w >> 216) & FLAG_REBALANCE) != 0;
        windowId = uint32(w >> 184);
        epoch = uint32((w >> 160) & 0xffffff);
    }

    /// @notice The packed word in FLY_SLOT (the contract's only mutable app state)
    function flyWord() public view returns (bytes32 word) {
        assembly ("memory-safe") {
            word := sload(FLY_SLOT)
        }
    }

    /// @notice feeBps[255:240] | skewBps[239:224] | flags[223:216] | windowId[215:184] | epoch[183:160] | keccak(state)[159:0]
    function pack(FlyTypes.FlyState memory s) public pure returns (bytes32) {
        uint256 w = uint256(uint160(uint256(keccak256(abi.encode(s)))));
        w |= uint256(s.epoch & 0xffffff) << 160;
        w |= uint256(s.windowId) << 184;
        w |= uint256(s.flags) << 216;
        w |= uint256(uint16(s.skewBps)) << 224;
        w |= uint256(s.feeBps) << 240;
        return bytes32(w);
    }

    /// @notice The packed model config words
    function packedConfig() external view returns (bytes32[3] memory) {
        return [_cfg0, _cfg1, _cfg2];
    }

    // ================================================================== helpers

    function _absDevBps(uint256 spot, uint256 twap) internal pure returns (uint256) {
        if (twap == 0) return 0;
        return ((spot > twap ? spot - twap : twap - spot) * 10000) / twap;
    }

    function _clamp(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }

    function _clampU(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }
}
