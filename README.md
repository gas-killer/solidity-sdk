# Gas Killer Solidity SDK

[![Solidity](https://img.shields.io/badge/solidity-%5E0.8.0-blue)](https://docs.soliditylang.org)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-green)](LICENSE)
[![Experimental](https://img.shields.io/badge/status-experimental-red)](https://github.com/gas-killer/solidity-sdk)

> **Disclaimer:** This code is experimental and has not been audited. It is provided as-is, without warranty of any kind. The authors and contributors accept no liability for any loss of funds or damages arising from the use of this software in production. **Use at your own risk.**

Solidity SDK for integrating Gas Killer functionality into EigenLayer AVS contracts. Inherit from `GasKillerSDK` to let off-chain operators propose and verify state updates via BLS signature aggregation instead of running expensive computations on-chain.

> 📖 **Integrating this into your own contract?** Start with the
> [Solidity Reference](https://gaskiller.xyz/docs/solidity/integrate) in the Gas Killer docs — it covers
> installation, the live addresses to configure, `trackState` semantics and storage-layout rules, and a
> revert-selector lookup table. This README is the SDK's own reference: verification schemes, chain
> requirements, operator-set mechanics, and the code-level contract.

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

`TransitionGuard` (used by the base `GasKillerSDK.verifyAndUpdate` and the Schnorr scheme's
`verifyAndUpdate`/`verifyAndUpdateBatch`, see `src/TransitionGuard.sol`) is a
reentrancy/in-transition guard built on EIP-1153
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

## Funding value-bearing state updates

A `CALL`, `CREATE` or `CREATE2` state update can move ETH, and it is paid out of the settling
contract's own balance. Every settlement entrypoint is therefore `payable` — `GasKillerSDK.verifyAndUpdate`
under the BLS scheme, and `SchnorrGasKillerSDK.verifyAndUpdate`/`verifyAndUpdateBatch` under the
Schnorr one — so a pass-through caller (deposit-then-forward, intent settler, swap router) can fund
the transition from `msg.value` instead of having to pre-fund the contract.

`msg.value` cannot redirect value: how much each update moves, and to whom, is fixed inside the
quorum-signed `storageUpdates`. All `msg.value` does is top the balance up, which leaves exactly two
ways to get it wrong:

- **Under-funding** reverts the whole transition — `RevertingContext` with empty revert data for a
  `CALL` (the EVM fails the call before the target runs), `DeploymentFailed` for a `CREATE`/`CREATE2`.
- **Over-funding is not refunded.** Whatever the updates do not consume stays in the contract.
  Recovery is the inheriting contract's job: a withdrawal function, or a refund executed as a signed
  `CALL` update in a later transition.

There is deliberately no balance-delta invariant on the entrypoint. The signed updates already fix
how much value every operation moves, so a check could only re-assert what the signature already
guarantees.

For `verifyAndUpdateBatch`, `msg.value` tops the balance up **once for the whole batch** and is
pooled across every applied sub-transition rather than partitioned per submission. Assemblers must
send the sum of what the applied submissions spend; the batch is atomic, so a shortfall on any one
of them unwinds all of them. A submission skipped as already-settled — the front-run tolerance
described above — spends nothing, so its share simply lands in the retained-surplus case.

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

The [Solidity Reference](https://gaskiller.xyz/docs/solidity/integrate) is the full integration guide —
a complete minimal target, the addresses to wire and how to verify them, what keeps a tracked function
extractable, and the whole API surface. This section is the short version.

### Installation

```bash
forge install gas-killer/solidity-sdk
```

Add the remapping:

```
gas-killer-sdk/=lib/solidity-sdk/src/
```

### Integrating the SDK

Inherit `GasKillerSDK`, configure it in the constructor, and mark each state-changing function
`trackState`:

```solidity
import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";

contract MyContract is GasKillerSDK {
    uint256 public storedValue;

    constructor(address _avsAddress, address _blsSigChecker) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
    }

    function updateValue(uint256 newValue) external trackState {
        storedValue = newValue;
    }
}
```

Operators then settle a transition through `verifyAndUpdate`, which requires that:

- the reference block is below the current block and within `blockStaleMeasure` blocks of it,
- `transitionIndex + 1` matches the current `stateTransitionCount`,
- the recomputed message hash matches the one signed,
- at least `QUORUM_THRESHOLD` (66%) of **each** quorum's stake signed.

**The AVS and `BLSSignatureChecker` addresses to configure live in
[Configuration](https://gaskiller.xyz/docs/solidity/configuration).** They are properties of a
particular AVS deployment rather than constants of the protocol, so they are maintained there and
deliberately not repeated in this repo.

### State Update Types

The `storageUpdates` payload is an ABI-encoded `(StateUpdateType[], bytes[])` pair. Each entry is one
of the following, applied in order:

| Type | Effect | Encoded args |
|------|--------|--------------|
| `STORE` | Write to a storage slot | `(bytes32 slot, bytes32 value)` |
| `CALL` | External call with optional ETH | `(address target, uint256 value, bytes calldata)` |
| `LOG0`–`LOG4` | Emit a log with 0–4 topics | `(bytes data[, bytes32 topic1, ...])` |
| `CREATE` | Deploy via `CREATE` | `(uint256 value, bytes initcode)` |
| `CREATE2` | Deploy via `CREATE2` | `(bytes32 salt, uint256 value, bytes initcode)` |

See [Funding value-bearing state updates](#funding-value-bearing-state-updates) for how `CALL`,
`CREATE` and `CREATE2` are paid for.

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
forge script script/DeployArraySummation.s.sol --rpc-url <rpc_url> --private-key <private_key> --broadcast
```

Required environment variables: `AVS_ADDRESS`, `SIG_CHECKER_ADDRESS`, `ARRAY_SIZE`, `MAX_VALUE`, `ARRAY_SEED`

`SIG_CHECKER_ADDRESS` is optional: left unset, the script deploys a `BLSSignatureChecker`
against `REGISTRY_COORDINATOR_ADDRESS` so the target is correct by construction.

### Deploy SchnorrArraySummation (demo)

The aggregate-Schnorr counterpart, verified against a `SchnorrStakeRegistry` rather than a
`BLSSignatureChecker`. A target verifies exactly one scheme's proof, so this one settles only
against a fleet running `SIGNATURE_SCHEME=schnorr`.

```bash
forge script script/DeploySchnorrArraySummation.s.sol --rpc-url <rpc_url> --private-key <private_key> --broadcast
```

Required environment variables: `AVS_ADDRESS`, `SCHNORR_STAKE_REGISTRY_ADDRESS`, `ARRAY_SIZE`, `MAX_VALUE`, `ARRAY_SEED`

The registry is required rather than deployed here. It is an operator set, populated by each
operator registering a secp256k1 key with a proof of possession, which the service repo's
`setup_schnorr_operators` binary does. Deploying one here would produce a target verifying
against an empty set.
