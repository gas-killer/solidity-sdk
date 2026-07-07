# GasKillerVertex

A proof-of-concept **cross-margin perpetual-futures DEX** demonstrating the Gas Killer
**"unbounded off-chain compute, O(1) on-chain state"** pattern — the derivatives sibling of
[`GasKillerCLOB`](../gaskiller-clob/README.md).

It is a **clean-room reimplementation of the architecture** of a Vertex-style exchange (a
sequencer that posts oracle prices and batches off-chain-ordered actions; a cross-margin
clearinghouse; a perp engine with funding; health-based liquidations). It is **not** a port of
Vertex's source — Vertex Protocol is GPL-2.0 and its storage/settlement layout is the opposite of
this pattern. Here, only the *design* is borrowed; the code is original.

## The problem

An on-chain perp DEX must run matching, mark-to-market, funding accrual, and liquidations inside
transactions — so throughput is bounded by the block gas limit. Vertex answers this with an
off-chain sequencer + on-chain risk engine; dYdX with an app-chain; Lighter with a ZK-rollup.
GasKillerVertex answers it with **EigenLayer restaking**: the whole exchange runs off-chain and a
single 32-byte commitment lands on-chain.

## The single-slot commitment

The **entire mutable exchange** — every account's quote collateral and open perp positions, every
resting order, every market's oracle price and cumulative funding index, and the insurance-fund
balance — is committed into **one storage slot**:

```
STATE_SLOT ← bits[255:64] = uint192(keccak256(canonical_state)[:24])
              bits[63:0]   = uint64(block.timestamp at last transition)
```

Every transition writes exactly **2 slots** (commitment + the inherited `StateTracker` counter),
regardless of how many accounts, positions, orders, funding accruals, or liquidations it processed.

Gas Killer AVS operators run `settleEpoch` **off-chain** under `SimProfile::UnboundedV1`
(gas limit 2^40 ≈ 1.1 Tgas). With many markets and thousands of resting orders, the per-market
price-time sort plus the cross-account funding/liquidation sweep exceeds any real block gas limit.
Operators BLS-sign the resulting single-slot commitment; on-chain application via `verifyAndUpdate`
is one SSTORE.

## Cross-margin accounting (WAD = 1e18)

A perp position never moves the quote token at fill time — only margin is at risk. An account's
*equity* is its collateral plus unrealized PnL minus funding owed:

```
equity(a) = a.collateral
          + Σ_i  size_i · (oracle_i − avgEntry_i) / 1e18          (unrealized PnL, signed)
          − Σ_i  size_i · (cumFunding_i − entryFunding_i) / 1e18   (funding owed, signed)

initialMargin(a)     = Σ_i |size_i| · oracle_i · imf_i / 1e36
maintenanceMargin(a) = Σ_i |size_i| · oracle_i · mmf_i / 1e36
```

- **Withdrawals** and **order placement** require `equity ≥ initialMargin` (placement checks the
  account as if the order fully filled at its limit price, on a side-effect-free scratch copy).
- An account with `equity < maintenanceMargin` is **liquidatable** by anyone: its position is closed
  at the oracle price, a `LIQUIDATION_PENALTY` (2.5%) of notional is routed to the insurance fund,
  bad debt is absorbed by the insurance fund, and the liquidator inherits the position at oracle.

## Funding

`syncMarket(witness, marketId, newOracle, fundingDelta)` is the sequencer's price/funding post: it
sets the mark price and increments the market's cumulative funding index. Positive `fundingDelta`
means longs pay shorts. Funding owed is always `size · (cumFunding − entryFunding)` and is included
live in equity; it is *realized* into collateral whenever a position is next touched (matched,
liquidated).

## Contract API

```solidity
vertex.deposit(witness, amount);                                   // add USDC collateral
vertex.withdraw(witness, amount);                                  // remove collateral (must stay IM-healthy)
vertex.listMarket(witness, marketId, imf, mmf, initialOracle);    // operator: list a perp market
vertex.syncMarket(witness, marketId, newOracle, fundingDelta);    // sequencer: post oracle + funding
vertex.placeOrder(witness, marketId, isBid, price, size);         // rest an order (IM-checked)
vertex.cancelOrder(witness, orderId);
vertex.settleEpoch(witness);                                      // off-chain: match all markets → open positions
vertex.liquidate(witness, victim, marketId);                      // close an underwater position
vertex.emergencyWithdraw(witness, amount);                        // exit after 7-day operator inactivity (no open positions)
```

Every function takes an `ExchangeState witness` — the off-chain expanded state the commitment hashes
to. The contract verifies it before mutating. Off-chain, operators compute the post-state, derive
the new commitment, and submit it via the inherited `verifyAndUpdate`.

## How this compares

| Property | Vertex | Lighter | GasKillerVertex |
|---|---|---|---|
| Matching | Off-chain sequencer | ZK-rollup sequencer | Off-chain AVS operators |
| Correctness | On-chain risk re-check | ZK validity proof | EigenLayer BLS quorum (≥66% stake) |
| On-chain state | Per-account/position storage | Merkle state root | **Single 32-byte commitment** |
| Product | Hybrid orderbook + AMM perps | CLOB perps | CLOB perps |
| Margin | Cross | Cross + isolated | Cross |
| License | GPL-2.0 | Closed / BUSL | AGPL-3.0 (this repo) |

## Running the tests

```bash
forge test --match-contract GasKillerVertexTest

# The above-block-limit gas proof (settleEpoch over 1200 orders exceeds 30M gas)
forge test --match-test testSettleEpochAboveBlockGasLimit -vv
```

> **Note:** this repo builds with `via_ir = true` (see `foundry.toml`) — the cross-margin/perp math
> has enough locals to hit "stack too deep" on the legacy pipeline. The IR pipeline produces
> equivalent, better-optimized bytecode for the other examples.

## Status

This is a **pedagogical example**, not production code. It demonstrates the single-slot / off-chain
compute pattern applied to perps. It omits much of a real exchange (richer order types & TIF,
multi-asset margin, ADL, sub-accounts, an in-contract fraud-proof/slashing path, and any API/SDK
surface), and it uses raw ERC20 transfers without `SafeERC20`/reentrancy guards. See the repo root
for the broader Gas Killer design and `docs/UNBOUNDED_MODE.md` for the node/guest consistency spec.
