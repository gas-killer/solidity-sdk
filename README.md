# Gas Killer Solidity SDK

[![Solidity](https://img.shields.io/badge/solidity-%5E0.8.0-blue)](https://docs.soliditylang.org)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-green)](LICENSE)
[![Experimental](https://img.shields.io/badge/status-experimental-red)](https://github.com/gas-killer/solidity-sdk)

> **Disclaimer:** This code is experimental and has not been audited. It is provided as-is, without warranty of any kind. The authors and contributors accept no liability for any loss of funds or damages arising from the use of this software in production. **Use at your own risk.**

Solidity SDK for integrating Gas Killer functionality into EigenLayer AVS contracts. Inherit from `GasKillerSDK` to let off-chain operators propose and verify state updates via BLS signature aggregation instead of running expensive computations on-chain.

## Overview

Contracts that inherit GasKillerSDK expose a public `verifyAndUpdate` function, which enables expensive state-changing computations to be performed off-chain. Operators sign a payload describing the resulting state updates, the router aggregates the BLS signatures once a quorum threshold is reached, and the result is submitted on-chain through `verifyAndUpdate`.

## Repository Structure

- **`src/`** — Core SDK contracts
  - `GasKillerSDK.sol` — Abstract base contract; inherit this in your AVS consumer
  - `StateTracker.sol` — Tracks state transitions via an ERC-7201 storage slot
  - `StateChangeHandlerLib.sol` — Executes batched `STORE`, `CALL`, and `LOG` operations
  - `interface/IGasKillerSDK.sol` — Public interface
  - `interface/IGasKillerForwardee.sol` — Multi-call forwarding interface
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
| `CREATE` | Deploy a contract (nonce-derived address) | `(uint256 value, bytes initcode)` |
| `CREATE2` | Deploy a contract (salt-derived address) | `(bytes32 salt, uint256 value, bytes initcode)` |

> **Unsupported opcodes:** `SELFDESTRUCT` and `TSTORE` are not supported as update types.

### Multi-call mode

When a transaction spans several GasKiller-enabled contracts (A calls B calls C), one
quorum-signed bundle can apply every contract's storage diff — one BLS verification for
the whole call graph. The callee's sub-payload is embedded as an ordinary `CALL` update
targeting the callee's `applyForwardedUpdates` entrypoint:

```solidity
// inside A's signed storageUpdates, at the position of the original A→B call:
CALL(address(B), value, abi.encodeCall(
    IGasKillerForwardee.applyForwardedUpdates,
    (storageUpdates_B, expectedTransitionIndex_B)
))
```

Because A's signed message hash commits to every byte of its `storageUpdates`, the
quorum signature transitively covers B's sub-payload and expected transition index.
`applyForwardedUpdates` enforces:

- **Caller trust** — `msg.sender` must be on the callee's trusted-forwarder allowlist
  (`_setTrustedForwarder`, wired in the constructor or toggled post-deploy by a
  quorum-signed `STORE`). Only allowlist immutable, unmodified-SDK contracts: an
  allowlisted forwarder can write any non-reserved slot of the callee.
- **Sequencing** — `expectedTransitionIndex + 1 == stateTransitionCount()`, the same
  check `verifyAndUpdate` uses, so each forward is valid at exactly one counter value
  and the callee's counter advances once per apply.
- **Reserved slots** — forwarded `STORE`s may not touch the state-tracker slot or the
  SDK configuration slots.

Failures anywhere in the bundle (untrusted forwarder, stale index, reverting nested
call) bubble up as `RevertingContext` and revert the entire bundle atomically.
Sub-payloads may themselves contain forwarding `CALL`s, so bundles recurse across the
call graph. Contracts advertise the capability via ERC-165 support for
`IGasKillerForwardee`.

See `design/multicall-mode.md` for the full design, trust model, and the corresponding
gas-analyzer changes.

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
