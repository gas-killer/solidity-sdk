# GasKillerVertex — operator console (frontend)

A full dApp for [`GasKillerVertex`](../src/examples/gaskiller-vertex/GasKillerVertex.sol), built with
[`@breadcoop/ui`](https://github.com/BreadchainCoop/bread-ui-kit) (React + Tailwind v4 + wagmi/viem).

## The architecture that makes this unusual

`GasKillerVertex` commits its **entire** state (accounts, cross-margin positions, orders, per-market
oracle/funding, insurance fund) into **one storage slot** — the chain only stores a 32-byte hash.
Every mutator takes the full expanded state as a `witness`, verifies it against that hash, mutates in
memory, and re-commits.

So the frontend **is the off-chain operator**: it maintains the full `ExchangeState` locally
(`src/engine/engine.ts` — a faithful TypeScript port of the contract), passes it as the witness on
every call, and after each transaction verifies sync by comparing the contract's
`computeStateHash(witness)` against the on-chain `stateHash()`. That equality is shown live in the
header and the "Single-slot commitment" panel.

`src/engine/engine.ts` is validated against the live contract by `scripts/verify.mts`, which drives
every transition through both the engine and the chain and asserts the hashes match at each step.

## Run it (local anvil)

```bash
# 1. from the repo root — start a local chain
anvil

# 2. deploy the demo stack (USDC + BLS checker + GasKillerVertex), mint USDC, write deployments.json
forge script script/DeployVertex.s.sol:DeployVertex \
  --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 3. run the frontend
cd frontend
npm install
npm run dev            # → http://localhost:5173
```

Open http://localhost:5173 and click **Seed demo scenario** (lists an ETH market, funds Alice & Bob,
crosses a 2-ETH order pair, settles into perp positions), or drive everything by hand.

### Conformance check (engine ↔ contract)

```bash
cd frontend && npx tsx scripts/verify.mts
# ✓ [1..16] every transition stays in sync — the TS engine faithfully mirrors the contract ✅
```

## What's wired (all contract functionality, end to end)

| Panel | Contract functions |
|---|---|
| Collateral | `deposit`, `withdraw` (+ ERC20 `approve`) |
| Markets | `listMarket`, `syncMarket` (sequencer posts oracle + funding) |
| Trade | `placeOrder`, `cancelOrder`, live order book |
| Operator & settlement | `settleEpoch` (standalone) **and** the Gas Killer path: `verifyAndUpdate` (settle off-chain → one BLS-attested `STORE`) |
| Liquidations | `liquidate` (auto-lists accounts below maintenance margin) |
| Emergency exit | `warp +7d` + `emergencyWithdraw` |
| Account / All accounts / Single-slot commitment | `accountMargin`, `stateHash`, `computeStateHash`, `stateTransitionCount`, `lastTransitionAt`, `STATE_SLOT` |

## Connection model

The console sends transactions as one of the default anvil accounts (Deployer / Alice / Bob / Carol /
Liquidator), selectable in the header — no wallet extension needed, so the whole flow is one click.
Chain interaction is done directly with viem (`src/chain.ts`, `src/contract.ts`); the wagmi + bread
providers are present for the UI-kit components. **Local demo only — those keys are public.**

## Notes

- Local-only: addresses come from `src/deployments.json` (deterministic anvil addresses).
- Operator state is persisted to `localStorage`; if you redeploy/restart anvil and it drifts, the
  header shows **out of sync** with a **reset local state** button (valid when the chain is at the
  empty commitment).
