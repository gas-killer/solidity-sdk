// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

/// @title FlyTypes
/// @notice Shared value types of the fly-connectome AMM (HANDOFF §3.5, §4.2, §4.5, §4.7)
library FlyTypes {
    /// @notice What the pool exposes to the fly: the last CLOSED window, storage reads only
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

    /// @notice The per-round consumer state (lives in the log; its packed word lives in FLY_SLOT)
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
}
