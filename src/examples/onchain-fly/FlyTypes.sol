// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

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
