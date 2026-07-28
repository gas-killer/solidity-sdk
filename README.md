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

`TransitionGuard` (used by the base `GasKillerSDK.verifyAndUpdate` and the Schnorr scheme's
`verifyAndUpdate`/`verifyAndUpdateBatch`, see `src/TransitionGuard.sol`) is a
reentrancy/in-transition guard built on EIP-1153
transient storage, and has no fallback path for a pre-Cancun EVM — deploying it to a chain
without EIP-1153 breaks settlement itself, not just the guard. `foundry.toml` pins
`evm_version = "cancun"` accordingly. Ethereum mainnet has supported EIP-1153 since Dencun;
before deploying to any other chain (in particular an L2 settlement target), confirm it has
activated the equivalent of Cancun/EIP-1153.

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
