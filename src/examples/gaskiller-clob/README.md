# GasKillerCLOB

A proof-of-concept spot central-limit-order-book (CLOB) DEX demonstrating the Gas Killer
**"unbounded Solidity, O(1) on-chain state"** pattern.

## The problem

A conventional on-chain CLOB must run matching inside a transaction, so the number of fills
per block is bounded by the block gas limit. At ~2,100 gas per SLOAD, a 30M-gas block can
match fewer than ~14,000 order-pair comparisons — far short of a competitive exchange.
Lighter.xyz solves this by moving the exchange to a ZK-rollup. GasKillerCLOB solves it with
EigenLayer restaking.

## The Gas Killer approach

The **entire mutable exchange state** — user balances in the base/quote tokens plus the open
order book — is committed into a **single storage slot**:

```
STATE_SLOT ← bits[255:64] = uint192(keccak256(canonical_state)[:24])
              bits[63:0]   = uint64(block.timestamp at last transition)
```

Every transition writes exactly **2 slots**: one for the new commitment, one for the
`StateTracker` counter inherited from `GasKillerSDK`. Gas cost is O(1) regardless of fill count.

Gas Killer AVS operators run `settleEpoch` **off-chain** under
`SimProfile::UnboundedV1` (gas limit 2^40 ≈ 1.1 Tgas). With a thousand resting orders, the
price-time-priority sorting alone exceeds any real block gas limit. Operators BLS-sign the
resulting single-slot commitment; on-chain application via `verifyAndUpdate` is one SSTORE.

See [`docs/UNBOUNDED_MODE.md`](../../../../docs/UNBOUNDED_MODE.md) for the node/guest
consistency requirements.

## How Lighter.xyz compares

| Property | Lighter.xyz | GasKillerCLOB |
|---|---|---|
| Prove matching | Plonky2 ZK circuit | EigenLayer BLS quorum + fraud proof |
| L1/L2 | Ethereum L2 app-chain | Ethereum mainnet |
| Settlement finality | ZK proof (hours) | BLS quorum threshold (minutes) + slashing window |
| Trust model | Validity proof (trustless) | ≥ 66% restaked stake honest |
| Throughput | Bounded by ZK prover | Bounded by off-chain compute (near-unlimited) |
| Single-slot state | No — full Merkle tree | Yes — 32-byte commitment |

## Contract API

```solidity
// Deposit tokens into the exchange
clob.deposit(witness, isBase, amount);

// Withdraw tokens from the exchange
clob.withdraw(witness, isBase, amount);

// Place a resting limit order (locks collateral)
clob.placeOrder(witness, isBid, price, size);
// price: quote-per-base in 1e18 fixed-point (e.g. 3000e18 = 3000 USDC per WETH)

// Cancel a resting order (restores collateral)
clob.cancelOrder(witness, orderId);

// Run price-time-priority matching across the full book
// — this is the expensive off-chain function Gas Killer operators execute
clob.settleEpoch(witness);

// Emergency: withdraw after 7 days without an operator transition
clob.emergencyWithdraw(witness, isBase, amount);
```

Every function takes a `CLOBState witness` — the off-chain expanded state the commitment
hashes to. The contract verifies it on-chain before mutating. Off-chain, operators compute
the post-state, derive the new commitment, and submit it via the inherited `verifyAndUpdate`.

## Running the tests

```bash
# Standard tests (including the small-book O(1) write proof)
forge test --match-contract GasKillerCLOBTest

# Above-block-limit gas proof (requires unlimited gas)
forge test --match-test testSettleEpochAboveBlockGasLimit --gas-limit 0
```

The `testSettleEpochAboveBlockGasLimit` test creates 1000 crossing orders and asserts that
the direct `settleEpoch` call exceeds 30M gas — proving that this workload *cannot* run in a
real block without Gas Killer.
