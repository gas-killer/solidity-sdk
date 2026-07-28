# Gas Killer Solidity SDK

[![Solidity](https://img.shields.io/badge/solidity-%5E0.8.0-blue)](https://docs.soliditylang.org)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-green)](LICENSE)
[![Experimental](https://img.shields.io/badge/status-experimental-red)](https://github.com/gas-killer/solidity-sdk)

> **Disclaimer:** This code is experimental and has not been audited. It is provided as-is, without warranty of any kind. The authors and contributors accept no liability for any loss of funds or damages arising from the use of this software in production. **Use at your own risk.**

Solidity SDK for integrating Gas Killer functionality into EigenLayer AVS contracts. Inherit from `GasKillerSDK` to let off-chain operators propose and verify state updates via BLS signature aggregation instead of running expensive computations on-chain.

## Overview

Contracts that inherit GasKillerSDK expose a public `verifyAndUpdate` function, which enables expensive state-changing computations to be performed off-chain. Operators sign a payload describing the resulting state updates, the router aggregates the BLS signatures once a quorum threshold is reached, and the result is submitted on-chain through `verifyAndUpdate`.

## Verification schemes

The SDK offers two interchangeable ways to authorise a state transition. Both sign the same task
digest and share the same `StateTracker` / `StateChangeHandlerLib` state-update machinery — they
differ only in how an operator quorum's approval is verified on-chain:

- **BLS** (`GasKillerSDK`) — verifies an aggregated BLS signature against an EigenLayer
  `IBLSSignatureChecker`, passing per-operator non-signer stakes.
- **Aggregate Schnorr** (`SchnorrGasKillerSDK`) — verifies a **single** aggregate secp256k1
  Schnorr signature against a `SchnorrStakeRegistry` in constant gas (one `ecrecover`, non-signer
  subtraction). Rogue-key-safe via a registration proof of possession.

## Chain requirements

`TransitionGuard` (used by the Schnorr scheme's `verifyAndUpdate`/`verifyAndUpdateBatch`,
see `src/TransitionGuard.sol`) is a reentrancy/in-transition guard built on EIP-1153
transient storage, and has no fallback path for a pre-Cancun EVM — deploying it to a chain
without EIP-1153 breaks settlement itself, not just the guard. `foundry.toml` pins
`evm_version = "cancun"` accordingly. Ethereum mainnet has supported EIP-1153 since Dencun;
before deploying to any other chain (in particular an L2 settlement target), confirm it has
activated the equivalent of Cancun/EIP-1153.

## Operator-set changes (Schnorr)

`SchnorrStakeRegistry` stores a single *current* aggregate key and total weight rather than a
per-block history. Any change to the operator set — registration **or** deregistration —
therefore invalidates a signature that an off-chain round has already assembled against the
previous set. The round must be re-assembled and resubmitted.

The cost is a retry, not a soundness risk: the failure mode is a rejected signature, never
acceptance of one that no current-set quorum endorsed. Depending on when the reference block is
chosen, the rejection surfaces one of two ways:

| Reference block pinned | Result |
|---|---|
| Before the mutation | `StaleSnapshot` revert — `refBlock` is below the registry's `effectiveBlock` watermark |
| After the mutation (freshest block, `block.number - 1`) | `isValidSignature` returns `false`, surfacing as `InvalidQuorumSignature` — the cached aggregate no longer matches what the operators signed |

The window of exposure runs from the operator set the signers observed through to the block the
settlement is included in — the signing round's duration plus however long the assembled payload
waits before inclusion. `verifyAndUpdate` bounds the second part: a reference block must be within
`blockStaleMeasure` blocks of the current block (300 by default), so a payload expires rather than
lingering indefinitely.

A mutation also changes *what counts as* a quorum, since the threshold is measured against the
current total weight. Removing an operator can turn a signature that held less than the threshold
share of the old set into a valid quorum of the smaller one — correctly, because the remaining
signers do carry that share. Signatures stay bound to one signer set by the aggregate match, not
by the reference block.

### Scheduling changes with a notice window

`SchnorrStakeRegistry` takes a `noticeWindow` (in blocks) at construction, which turns the
quiescence requirement above from an assumption into something a router can check:

| Call | Effect |
|---|---|
| `announceRegister` / `announceDeregister` | Queue a change, applicable after `noticeWindow` blocks. Nothing is mutated yet |
| `commitNextChange` | Apply the oldest announced change, once its window has elapsed |
| `cancelNextChange` | Drop the oldest announced change without applying it |
| `cancelChange(operator)` | Drop one identity's announced change, wherever it sits in the queue |
| `nextPossibleMutationBlock()` | The earliest block the set can change, or `type(uint256).max` when nothing is queued |

A round is safe from set-mutation invalidation while the block its settlement lands in is below
`nextPossibleMutationBlock()`. Size `noticeWindow` to exceed the signing round's duration plus the
consumer's `blockStaleMeasure`, or a round can still be assembled under one set and settled under
another.

Registration is validated in full at announcement — curve membership, weight bounds, proof of
possession — so an unusable entry cannot sit in the queue holding the horizon. An announced
operator is *not* in the aggregate until its change commits, so it must not sign before then; an
operator announced for removal stays in the aggregate and in the threshold denominator until
commit, so it is expected to keep signing throughout its window.

`registerOperator` and `deregisterOperator` bypass the window, for bootstrapping a registry that
does not yet back any consumer and for emergencies such as a compromised key. They emit
`ForcedMutation` so consumers relying on the horizon can detect the bypass, and the fail-closed
watermark remains the backstop for it.

They refuse to act on an identity that has a change queued, so that the scheduled and forced paths
can never both apply to it. Clearing the way is `cancelChange(operator)` followed by the forced
call, in the same block if needed — cancelling by identity reaches into the middle of the queue, so
other operators keep both their positions and their remaining notice windows.

Consequences for integrators:

- Prefer the announced path once the registry is live, and enforce the horizon check before
  submitting.
- Treat `ForcedMutation`, and any `OperatorRegistered` / `OperatorDeregistered` without a
  preceding announcement, as a "re-snapshot required" signal.
- An exited operator's record is kept as a tombstone rather than deleted: its key, weight and
  `exitBlock` stay readable so the identity remains attributable after it leaves, while
  `registered` going false is what removes it from the active set.
- `blockStaleMeasure` is set per consumer contract and is owner-adjustable, while one registry
  may back several consumers. The registry cannot enforce any relationship between its own
  mutation timing and each consumer's staleness bound, so keeping the two consistent is
  deployment discipline rather than a contract guarantee.

## Repository Structure

- **`src/`** — Core SDK contracts
  - `GasKillerSDK.sol` — Abstract base for the BLS scheme; inherit this in your AVS consumer
  - `StateTracker.sol` — Tracks state transitions via an ERC-7201 storage slot (scheme-agnostic)
  - `StateChangeHandlerLib.sol` — Executes batched `STORE`, `CALL`, and `LOG` operations (scheme-agnostic)
  - `interface/IGasKillerSDK.sol` — Public interface for the BLS scheme
  - `interface/IStateUpdateTypes.sol` — Alloy-compatible struct definitions
- **`src/schnorr/`** — Aggregate-Schnorr scheme
  - `SchnorrGasKillerSDK.sol` — Abstract base; inherit this for the Schnorr scheme
  - `SchnorrStakeRegistry.sol` — Aggregate-key registry with proof-of-possession registration and non-signer subtraction
  - `interface/` — `ISchnorrGasKillerSDK` and `ISchnorrStakeRegistry`
  - `libraries/` — `Secp256k1` (affine point math) and `SchnorrVerify` (constant-gas `ecrecover`-trick verify)
- **`src/examples/array-summation/`** — Demo apps: `ArraySummation`(`Factory`) (BLS) and `SchnorrArraySummation`(`Factory`) (Schnorr)
- **`script/`** — Deployment scripts
- **`test/`** — Unit and integration tests

## Usage

### Installation

```bash
forge install gas-killer/solidity-sdk
```

Add the remapping:

```
gas-killer-sdk/=lib/solidity-sdk/src/
```

### Integrating the SDK

1. Inherit from `GasKillerSDK` and configure it in your constructor:

```solidity
import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";

contract MyContract is GasKillerSDK {
    constructor(address _avsAddress, address _blsSigChecker) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
    }
}
```

2. Mark state-changing functions with the `trackState` modifier:

```solidity
function updateValue(uint256 newValue) external trackState {
    storedValue = newValue;
}
```

3. Off-chain, compute the state update payload and submit it via `verifyAndUpdate`:

```solidity
contract.verifyAndUpdate(
    msgHash,
    quorumNumbers,
    referenceBlockNumber,
    storageUpdates,   // ABI-encoded (StateUpdateType[], bytes[])
    transitionIndex,
    targetFunction,
    nonSignerStakesAndSignature
);
```

`verifyAndUpdate` checks that:
- The reference block is within `blockStaleMeasure` blocks of the current block
- `transitionIndex + 1` matches the current `stateTransitionCount`
- The message hash matches the expected hash for the given transition, function, and updates
- At least `QUORUM_THRESHOLD` (66%) of quorum stake has signed

### State Update Types

The `storageUpdates` payload is an ABI-encoded `(StateUpdateType[], bytes[])` pair. Each entry can be one of:

| Type | Effect | Encoded args |
|------|--------|--------------|
| `STORE` | Write to a storage slot | `(bytes32 slot, bytes32 value)` |
| `CALL` | External call with optional ETH | `(address target, uint256 value, bytes calldata)` |
| `LOG0`–`LOG4` | Emit a log with 0–4 topics | `(bytes data[, bytes32 topic1, ...])` |

> **Unsupported opcodes:** `CREATE` and `CREATE2` are not yet implemented as update types.

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Deploy ArraySummation (demo)

```bash
forge script script/ArraySummation.s.sol --rpc-url <rpc_url> --private-key <private_key> --broadcast
```

Required environment variables: `AVS_ADDRESS`, `SIG_CHECKER_ADDRESS`, `ARRAY_SIZE`, `MAX_VALUE`, `ARRAY_SEED`
