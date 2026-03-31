# Gas Killer Solidity SDK

[![Solidity](https://img.shields.io/badge/solidity-%5E0.8.0-blue)](https://docs.soliditylang.org)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-green)](LICENSE)
[![Experimental](https://img.shields.io/badge/status-experimental-red)](https://github.com/gas-killer/solidity-sdk)

> **Disclaimer:** This code is experimental and has not been audited. It is provided as-is, without warranty of any kind. The authors and contributors accept no liability for any loss of funds or damages arising from the use of this software in production. **Use at your own risk.**

Solidity SDK for integrating Gas Killer functionality into EigenLayer AVS contracts. Inherit from `GasKillerSDK` to let off-chain operators propose and verify state updates via BLS signature aggregation instead of running expensive computations on-chain.

## Overview

The SDK intercepts state-changing function calls so that the actual computation can happen off-chain. Operators sign a payload describing the resulting state updates, the router aggregates the BLS signatures when a quorum threshold is reached, and the result is submitted on-chain via `verifyAndUpdate`.

## Repository Structure

- **`src/`** — Core SDK contracts
  - `GasKillerSDK.sol` — Abstract base contract; inherit this in your AVS consumer
  - `StateTracker.sol` — Tracks state transitions via an ERC-7201 storage slot
  - `StateChangeHandlerLib.sol` — Executes batched `STORE`, `CALL`, and `LOG` operations
  - `interface/IGasKillerSDK.sol` — Public interface
  - `interface/IStateUpdateTypes.sol` — Alloy-compatible struct definitions
- **`src/examples/array-summation/`** — Demo app: `ArraySummation` and `ArraySummationFactory`
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
