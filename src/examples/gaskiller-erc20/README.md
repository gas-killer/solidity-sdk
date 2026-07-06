# GasKillerERC20 — a single-slot commitment ERC20

An example Gas Killer SDK consumer that demonstrates how to design a "native" Gas Killer contract so
that **storage writes are always O(1)**: the *entire* mutable token state — `totalSupply`, every account
balance, and every allowance — is rolled up into a **single storage slot** holding a 32-byte commitment.

## The idea

A conventional ERC20 keeps balances and allowances in `mapping`s. Each mutation writes one slot per
account it touches:

| Operation | Conventional ERC20 SSTOREs |
|-----------|----------------------------|
| `transfer` | 2 (debit + credit) |
| `mint` | 2 (balance + totalSupply) |
| airdrop to N | N (+1) |

The number of storage writes scales with the number of accounts touched. Under Gas Killer — where a state
transition is applied on-chain as a batch of raw `STORE` ops from a BLS-signed payload — that means the
on-chain cost of a transition scales with the accounts it moves.

`GasKillerERC20` instead stores only a commitment to the full state in one slot:

```
STATE_ROOT_SLOT  ->  keccak256(abi.encode(STATE_DOMAIN, totalSupply, canonicalAccounts))
```

The authoritative expanded state lives off-chain (with the AVS operators / an indexer). Every transition —
no matter how many accounts it moves — recomputes the commitment and writes it back with **exactly one
`SSTORE`**:

```
writes per transition = 1 (commitment)  +  1 (StateTracker counter, from `trackState`)
```

A 1-recipient transfer and a 10,000-recipient airdrop cost the *same* number of storage writes: one.

## Two ways to advance state

1. **Standalone / reference path** (`transfer`, `transferFrom`, `approve`, `mint`, `burn`).
   The caller passes the current expanded state as a `TokenState` **witness**. The contract verifies the
   witness hashes to the stored commitment, applies the operation in memory, and writes the new
   commitment. This makes the contract fully self-contained and unit-testable without any operators — it
   is the on-chain analogue of the SDK's `ArraySummation.sum()`. It is the "expensive" path (O(n) calldata
   and hashing) that Gas Killer is designed to replace.

2. **Gas Killer path** (inherited `verifyAndUpdate`).
   AVS operators compute the new commitment off-chain (with the same `computeStateRoot` rules) and submit a
   single `STORE(STATE_ROOT_SLOT, newRoot)` op in a BLS-signed payload. On-chain this is one `STORE` plus
   the `trackState` counter — O(1) in everything. Both paths reach identical commitments.

## Canonical commitment

Correctness rests on one logical state mapping to exactly one commitment. `computeStateRoot`
canonicalises before hashing:

- accounts sorted strictly ascending by owner (**duplicate owners rejected**);
- each account's allowances sorted strictly ascending by spender (**duplicate spenders rejected**);
- zero balances and zero allowances **omitted**, so `{alice: 0}` and `{}` hash identically;
- a domain separator (`STATE_DOMAIN`) is mixed in;
- on load, a **conservation check** enforces `sum(balances) == totalSupply` (fail-closed against a
  malformed/inflationary commitment).

Because of this, any representation of a state (shuffled, padded with zero entries) verifies to the same
root — see `testWitnessOrderIndependent`.

## Reads

Balances are not individually stored, so `balanceOf` / `allowance` / `totalSupply` take a `TokenState`
witness and are verified against the commitment before answering. Off-chain, operators or any indexer that
tracks the committed state serve these reads. `stateRoot()` exposes the raw commitment.

## Operator responsibilities (Gas Killer path)

- Compute `newRoot` from the **current** committed state with `computeStateRoot`. The `verifyAndUpdate`
  `transitionIndex` check strictly orders updates, so a root computed against a stale state reverts
  rather than corrupting the token (see `testStaleTransitionIndexRevertsAndReplayProtected`).
- Emit faithful ERC20 events. Applying a `STORE` does not run transfer logic, so operators should append
  `LOG3`/`LOG2` ops for each logical `Transfer`/`Approval` in the same signed payload (they are covered by
  the signature). Storage writes stay O(1); only logs scale with the batch. See
  `testVerifyAndUpdateEmitsFaithfulEvent`.

## Tradeoffs (honest downsides vs a normal ERC20)

- **Reads need a witness.** `balanceOf(address)` cannot be answered from one slot; on-chain consumers
  supply a `TokenState` witness, and wallets/explorers rely on an off-chain indexer.
- **Data availability.** The contract holds only a hash; the full state must remain available off-chain to
  build witnesses. Funds are never lost (the root commits them) but liveness depends on state being
  republishable.
- **Standalone calls are heavy and race-prone.** Each carries the full state as calldata (O(n)) and
  reverts if another transition landed first (optimistic concurrency, fail-closed). The operator batch is
  the intended high-throughput route.
- **Inverted gas profile.** Excellent for large batches (one SSTORE), worse than a plain ERC20 for a
  single isolated standalone transfer.

## Tests

`test/examples/GasKillerERC20.t.sol` covers ERC20 semantics, the canonicalisation/commitment properties,
the conservation invariant, replay/ordering protection, the end-to-end `verifyAndUpdate` path, and — the
headline — proves via `vm.record` that a transfer writes **exactly two slots** (commitment + tracker)
whether there are 2 or 50+ holders.

```bash
forge test --match-path 'test/examples/GasKillerERC20.t.sol' -vv
```
