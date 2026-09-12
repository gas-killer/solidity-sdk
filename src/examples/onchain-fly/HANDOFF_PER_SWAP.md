# HANDOFF — per-swap fly pricing (v2 of the fly-connectome AMM)

Date: 2026-09-12. Supersedes §4.6–§4.7 of `HANDOFF.md` (the window/policy-loop design) for the v2
consumer. Everything else in `HANDOFF.md` (engine, wire format, fixed point, artifacts) still applies.
Live v1 state and addresses: `PROGRESS.md` (this directory) and
`atlanta-v1/.context/fly/{sepolia.json,PROGRESS.md}` in the service workspace.

## 0. The ask, and the one-paragraph design

**Ask.** Every swap must be settled through a Gas Killer round in which the fly decides that swap's
rate. Latency is explicitly not a concern (rounds are ~7 min end to end on the testnet fleet).

**Design.** Swaps become *intents*: a trader escrows `amountIn` in the pool and joins a FIFO queue.
The tracked function `FlySwapPolicy.settle(prev)` reads the next undecided intents from the pool
(STATICCALL, storage only), runs **one fly episode per intent** with that intent rendered on the
retina, and writes **one fill word per intent** (`fee`, `skew`, `flags`, `epoch`, spike-root
commitment) into the policy's own storage, plus the chained `FlyState` word. The quorum-signed diff is
therefore `N + 2` STOREs and `N + 1` logs. After `verifyAndUpdate` lands, anyone (the keeper) calls
`FlySwapPool.applyNext()` which executes intent `applied + 1` **in queue order** against the pool's
*current* reserves at the fly-decided fee, pays out (or refunds if `minOut`/expiry fails), and
records the fill. The pool still never inherits the SDK, still clamps everything it reads, and the
quorum still cannot touch reserves — it can only choose each intent's fee inside `[MIN_FEE, MAX_FEE]`.

Per-swap = `MAX_BATCH = 1`. Batching (`MAX_BATCH > 1`, still one episode per intent) is a throughput
knob bounded by the fleet's 300 s round timeout, see §6.

## 1. What is different from live v1, and why v1 could not simply be extended

| v1 (live, `FlyPolicy` + `FlyAMM`) | v2 (this doc) |
|---|---|
| Swaps execute immediately; the pool *pulls* `policy.params()` (one word for everyone) | Swaps are queued intents; nothing executes until the fly has decided *that* intent |
| One decision per closed 25-block window, decays after `MAX_LAG_WINDOWS` | One decision per intent, applied exactly once, never stale (bound to the intent id, not to time) |
| `decide` = 1 episode, 1 STORE (+ counter) + 1 LOG | `settle` = N episodes, N+2 STOREs + N+1 LOGs |
| Observation = closed-window histogram + spot/TWAP | Observation = the intent itself + last-16-epoch fill histogram + spot/EMA price |
| Fly output → global `feeBps/skewBps` | Fly output → per-intent `feeBps/skewBps`; pool derives the rate from its curve less that fee |
| Engine `rasterize(Observation)` | Engine v2 adds `rasterizeSwap(SwapObservation)`; `decide` is untouched and stays vector-pinned |

**A stale rule in `HANDOFF.md` §1 to unlearn.** "≤1 STORE" is no longer the unbounded profile's gate.
The analyzer at the pinned commit (`gas-analyzer` `3cbd54f`, `crates/core/src/sim_profile.rs`) *prices*
the payload instead of counting writes: any number of STOREs is accepted as long as the estimated
apply cost of the diff (worst-case 22,100 gas per store, LOG costs, calldata, apply overhead, BLS
floor) is `≤ 2^24` (`UNBOUNDED_PAYLOAD_GAS_BUDGET`, EIP-7825's per-tx cap). `CREATE` is still rejected.
Test `unbounded_profile_accepts_a_multi_slot_payload_that_fits` pins this.

## 2. Hard constraints (verified 2026-09-12, do not re-derive)

1. **No regular `CALL` and no non-consumer storage change inside the tracked function.**
   `classify_prestate_eligibility` (`crates/core/src/prestate.rs:62-91`) falls back to the struct-log
   encoder if any account other than the consumer changed storage or if a `CALL` appears at target
   depth. The struct-log trace is `O(execution steps)` and cannot complete a multi-Ggas call. So the
   tracked function **cannot move tokens**. `STATICCALL` is fine (v1's `pool.observe()` and
   `engine.decide()` went through live). Consequence: escrow on submit, pay out on apply, both untracked.
2. **The diff is applied blind, up to `blockStaleMeasure = 300` blocks after `referenceBlockNumber`,
   with no hook** (`GasKillerSDK.verifyAndUpdate` is `external`, not `virtual`). Every slot the
   payload writes must be one that *no untracked function writes* between reference and apply,
   otherwise the apply clobbers it. §4.3 proves slot disjointness for the layout below.
3. **Payload budget** `≤ 16,777,216` gas applied (§1). **Transport cap**
   `call_data + storage_updates ≤ 128 KB` (`common/src/task_data.rs:41`).
4. **One task in flight fleet-wide**; tasks serialize on `transition_index`
   (`router/src/sequencer.rs:48-66`). Concurrent `settle` submissions are safe (auto transition index)
   but never parallel.
5. **Round timeout 300 s** (`helm/gas-killer/values.yaml` `roundTimeout: "300"`). Fleet trace time on
   the sim node (reth v2.5.2, `--rpc.gascap=max`, 7 CPU): 100 ms episode = 84 s prestate trace,
   300 ms = 255 s. Router + 3 operators trace concurrently.
6. **No block-environment reads** in the tracked path (v1 rule, keep it): expiry is in *epochs*, not
   blocks (§4.2).
7. **EIP-7825 on Sepolia**: 16,777,216 gas per transaction. Constructor-time `checkArtifacts` (~20 M)
   is undeployable; use the `Unchecked` pattern with the check via `eth_call` (`tools/fly_anvil.py check`).
8. **Rendered-payload API-key tier**: the router does not broadcast; `GET /tasks/{id}` returns
   `payload.{to,data,estimated_gas,valid_until_block}` and the keeper sends it. Observed submit→ready
   latency: ~7 min for one 100 ms episode.
9. **Determinism**: `settle` output must depend only on storage at the reference block and calldata.
   Intents are immutable after submit (no cancel, §4.2), so any reference block ≥ the submit block
   yields the same diff for that intent.

## 3. Flow

```
trader ──submit(buyBase, amountIn, minOut, expiryEpoch)──▶ FlySwapPool   (escrow in, id = ++tail)
keeper ──POST /tasks {target: FlySwapPolicy, call_data: settle(prev), block_height: latest}──▶ router
        router + operators: settle() = for each id in (decidedThrough, min(tail, decidedThrough+MAX_BATCH)]:
            obs = pool.observeIntent(id)            STATICCALL, storage only
            frame = engine.rasterizeSwap(obs)       STATICCALL
            (r, spikeRoot) = engine.decide(frame…)  STATICCALL, ~14 Ggas at 100 ms
            fills[id] = pack(fee, skew, flags, epoch, spikeRoot)      STORE
            emit FlyIntentDecided(id, …)                               LOG
        decidedThrough = last id; FLY_SLOT = pack(next FlyState)      STORE, STORE
keeper ──verifyAndUpdate(rendered payload)──▶ FlySwapPolicy            (quorum-signed diff applied)
keeper ──applyNext() × N──▶ FlySwapPool   (in id order: read fills[id], clamp, x·y=k at current reserves,
                                            minOut/expiry check → transfer out | refund; reserves updated;
                                            epoch histogram updated)
```

`applyNext` is permissionless and idempotent per id; the trader can call it too. LP `addLiquidity` /
`removeLiquidity` stay immediate and untracked (they only touch pool storage, which the payload never
writes).

## 4. Contracts

### 4.1 `FlySwapPool` (does NOT inherit the SDK — keep it that way)

Storage (all pool-owned; the payload never writes here):

```
IERC20 base, quote; address deployer; IFlySwapPolicyFills policy (set once)
uint128 reserveBase, reserveQuote; uint256 totalSupply; mapping(address=>uint256) balanceOf
uint64  tail;      // last submitted id (ids start at 1)
uint64  applied;   // last applied id
struct Intent { address owner; bool buyBase; uint8 status; uint32 expiryEpoch; uint128 amountIn; uint128 minOut; }
mapping(uint64 => Intent) intents;          // written by submit (new id) and applyNext (status only)
struct Fill { uint128 amountOut; uint16 feeBps; uint32 epoch; }
mapping(uint64 => Fill) fills;              // written by applyNext only
uint64[16] buyHist, sellHist;               // per-epoch fee-paid quote volume (OBS_UNIT), index epoch % 16
uint32  histEpoch;                          // epoch the histogram head corresponds to
uint64  volRef;                             // EMA α = 1/8 of per-epoch volume
uint128 emaSpotQ64;                         // EMA of post-fill spot, α = 1/8 (replaces TWAP: no block env)
```

Functions:

- `submit(bool buyBase, uint256 amountIn, uint256 minOut, uint32 expiryEpoch) returns (uint64 id)`:
  `safeTransferFrom` escrow, `intents[++tail] = …`, `status = PENDING`, emit `IntentSubmitted`.
  Revert if `amountIn == 0`. `expiryEpoch == 0` means never.
- `applyNext() returns (uint64 id)`: `id = applied + 1`; revert `NothingToApply` if `id > tail`;
  `(fee, skew, rebal, epoch, ok) = policy.fillOf(id)`; revert `NotDecided` if `!ok`.
  Clamp exactly as v1 `effectiveFee` (band, skew cap, rebalance override against `emaSpotQ64`).
  If `intent.expiryEpoch != 0 && epoch > intent.expiryEpoch` → refund. Else compute
  `out` by x·y=k on **current** reserves with `inAfter = amountIn·(1e4−fee)/1e4`; if `out < minOut`
  or `out >= reserve` → refund. Refund: transfer `amountIn` back, `status = REFUNDED`. Fill: update
  reserves, transfer `out`, `status = FILLED`, `fills[id] = …`, histogram/volRef/emaSpot update,
  emit `Swap(id, …)`. `applied = id`.
- `applyUpTo(uint64 n)`: loop `applyNext` while possible (keeper convenience, stops at first `NotDecided`).
- `addLiquidity` / `removeLiquidity`: as v1.
- `observeIntent(uint64 id) view returns (FlyTypes.SwapObservation)`: storage only (§5.1). Reverts
  `NoSuchIntent` if `id > tail`.
- `pendingRange() view returns (uint64 applied, uint64 tail)`.

Status enum: `PENDING=0, FILLED=1, REFUNDED=2`.

**No cancel.** A cancel that lands between the reference block and the apply would let the same intent
be both refunded (by cancel) and decided (by the diff) → the later `applyNext` would fill a refunded
intent. Expiry-by-epoch gives traders an exit that the round itself honours: `settle` still decides
an expired intent (the fly runs, the fill word is written), and `applyNext` refunds it. Simpler than
special-casing in the tracked path, and keeps `settle` free of pool writes.

### 4.2 `FlySwapPolicy is GasKillerSDK` (the consumer)

Storage the payload writes (and nothing else ever writes):

```
FLY_SLOT           bytes32  packed FlyState v2 word (chain)                       — written by settle only
DECIDED_SLOT       uint64   decidedThrough                                        — settle only
mapping(uint64 => bytes32) fills   at keccak(id, FILLS_BASE)                       — settle only, each id once
STATE_TRACKER      (SDK counter, gate-exempt; verifyAndUpdate's modifier rewrites the same value)
```

Immutables: `engine`, `graphRoot`, `warmRoot`, `pool`, `cfg[3]`, band params from `cfg[2]`, `maxBatch`
(from a new cfg field or constructor arg, see D-1).

- `settle(FlyTypes.FlyState calldata prev) external trackState`:
  1. `word = sload(FLY_SLOT)`; `_matches(word, prev)` else revert `StateMismatch` (as v1).
  2. `(applied, tail) = pool.pendingRange()`; `from = decidedThrough + 1`;
     `to = min(tail, decidedThrough + maxBatch)`; revert `NothingToDecide` if `from > to`.
     (`applied` is unused by the decision; it is read only so the keeper's `should-run` and the
     contract agree on "pending".)
  3. `rates = prev.rateMilliHz`; for `id` in `[from, to]`:
     `obs = pool.observeIntent(id)`; `frame = engine.rasterizeSwap(graphRoot, cfg, obs)`;
     `stim` from `prev.flags` for the first intent only, then zero (D-3);
     `(r, spikeRoot) = engine.decide(graphRoot, warmRoot, cfg, frame, stim, rates)`;
     map `r → (fee, skew, rebal)` exactly as v1 `_compute`; `rates = r.rateMilliHz`;
     `sstore(fillSlot(id), packFill(fee, skew, flags, epoch, spikeRoot))`;
     `emit FlyIntentDecided(id, fillWord, spikeRoot, obs, r)`.
  4. `next = FlyState{prevWord: word, epoch: prev.epoch+1, decidedThrough: to, rateMilliHz: rates,
     flags: punish/reward from obs of the last intent (D-3), memoryRoot: ZERO}`;
     `sstore(DECIDED_SLOT, to)`; `sstore(FLY_SLOT, pack(next))`; `emit FlySettled(…)`.
- `dryRun(prev) view` mirrors `settle` without stores (keeper sanity + operators).
- `fillOf(uint64 id) view returns (uint16 fee, int16 skew, bool rebal, uint32 epoch, bool decided)`:
  `decided = id <= decidedThrough` (word may legitimately be nonzero only then).
- `decidedThrough() view`, `flyWord() view`, `pack`/`packFill`/`genesisState` pure.
- `_validateArtifacts` hook + `FlySwapPolicyUnchecked` subclass (EIP-7825).

Fill word: `feeBps[255:240] | skewBps[239:224] | flags[223:216] | epoch[215:192] | reserved[191:160] | spikeRoot160[159:0]`.
FlyState v2 word: `epoch[255:232] | decidedThrough[231:168] | flags[167:160] | keccak(state)160[159:0]`
(fee/skew leave the chain word: the pool reads `fills`, not `params`).

```
struct FlyState {            // v2
    bytes32 prevWord; uint32 epoch; uint64 decidedThrough; uint8 flags;
    uint32[4] rateMilliHz; bytes32 memoryRoot;
}
```

### 4.3 Slot-disjointness proof (constraint 2)

Between the reference block `R` of a `settle` and its apply block `A ≤ R + 300`, the only writers are:

| Writer | Slots written | Overlap with the in-flight diff? |
|---|---|---|
| `pool.submit` | `intents[tail+1..]`, `tail` | Pool storage: the diff never writes pool slots. New ids `> tail_R` are not in the batch. |
| `pool.applyNext` | `intents[id].status`, `fills[id]` (pool), reserves, hist, `applied` | Pool storage only. |
| `pool.add/removeLiquidity` | reserves, LP balances | Pool storage only. |
| `policy.verifyAndUpdate` of an *earlier* round | `fills[≤ decidedThrough_R]`, `DECIDED_SLOT`, `FLY_SLOT` | Cannot happen: transitions serialize; the earlier round is already applied at `R` (its `transitionIndex` is the reference state). A later round cannot apply before this one (`transitionIndex + 1 == count`). |
| `policy.settle` called directly on chain | would write policy slots | Unaffordable: one episode is ~14 Ggas against Sepolia's 16.78 M per-tx cap, so a direct call always reverts before any SSTORE. Same property v1's `decide` relies on; do not add a caller gate (operators simulate `from` the keeper address, D-4). |

Reserves at `R` vs at `A` may differ (LP ops, earlier applies): irrelevant to validity, since the fly
chose only a fee and the pool computes `out` at apply time. This is the same "fly sees slightly stale
reserves" property v1 already had.

### 4.4 `FlyEngine` v2

Add, keep everything else byte-identical (the 11 `FlyEngine.t.sol` vectors must still pass):

- `rasterizeSwap(address graphRoot, bytes32[3] cfg, FlyTypes.SwapObservation obs) view returns (bytes frame)`:
  same receptor sampling (`_retina`, `_sample`) over a new `_canvasSwap` (§5.2).
- Nothing else. `decide` already takes an opaque `frame`, so the per-intent episode is the existing
  entry. Redeploy is code-only (data directories reused); it must fit the 16.78 M deploy cap — the v1
  engine did.

Mirror `rasterizeSwap` in `tools/fly_int.py` (`rasterize_swap`) and regenerate
`synth/vectors.json` with a `decideSwap` key so `test_RasterizeSwapMatchesReference` exists.

## 5. Fly I/O for one intent

### 5.1 `FlyTypes.SwapObservation` (storage reads only)

```
struct SwapObservation {
    uint64  id;
    bool    buyBase;
    uint64  sizeBps;        // amountIn relative to the input-side reserve, bps, saturating at 10_000
    uint64  maxSlipBps;     // implied by minOut vs curve quote at current reserves (0 if minOut == 0)
    uint64  queueDepth;     // tail − applied at the reference block
    uint32  epoch;          // policy epoch the observation was taken for (prev.epoch + 1), passed in by settle
    uint64[16] buyQuote;    // per-epoch fee-paid quote volume, oldest..newest (OBS_UNIT)
    uint64[16] sellQuote;
    uint64  volRef;
    uint128 spotQ64;
    uint128 emaSpotQ64;
    uint64  feeIncomeQuote; // last applied epoch's fee income  → REWARD pulse next episode
    uint64  lpLossQuote;    // last applied epoch's LP loss vs emaSpot → PUNISH pulse next episode
}
```

`observeIntent` computes `sizeBps` and `maxSlipBps` from storage arithmetic only. `epoch` is not
storage: `settle` passes `prev.epoch + 1` into the observation *before* rasterizing so the histogram
alignment (`hist[(epoch−15+k) % 16]`) is deterministic; `observeIntent` returns the raw ring and
`histEpoch`, and the policy rotates it (D-2).

### 5.2 Canvas (640×480, linear luminance, v1 conventions)

| Rows | Content |
|---|---|
| 0–39 (strip) | v1 deviation strip, now `spot` vs `emaSpot` (left half lit if spot > ema, right half otherwise, intensity `absDev/devRef`) |
| 40–79 (new intent strip) | direction: left half lit for `buyBase`, right half for sell; intensity = `sizeBps/sizeRef` saturating (new cfg field `sizeRef`, D-1) |
| 80–119 (new slippage strip) | full width, intensity `maxSlipBps/slipRef` (0 if `minOut == 0`); cfg `slipRef` |
| 120–479 | v1 histogram bars (`volBarRows` scaled, `buyQuote` left, `sellQuote` right) |

Integer formulas as D-H in `PROGRESS.md` (floor division, `x==ref` lights nothing, `volRef==0` → no bars).

### 5.3 Readout → rate

Unchanged from v1 `_compute`: DNp20 R−L → `skew ∈ [−maxSkew, +maxSkew]`, DNpe017 sum → `fee ∈ [minFee, maxFee]`,
DNpe017 spikes in last 30 ms and `|spot − ema| > rebalThreshold` → `rebalance`. The trader's rate is
`out = curveOut(amountIn·(1e4 − clamp(fee ± skew))/1e4)` at apply time. **The fly picks the fee, never
the price**: that is the LP-safety boundary (`HANDOFF.md` §4.1 (ii)) and is what lets the pool stay
outside the SDK. Widening the band is a governance change, not a design change.

### 5.4 Episode chaining

Within a round, intent `i+1`'s episode is seeded with intent `i`'s terminal `rateMilliHz`; the last
one persists into `FlyState`. Reward/punish pulses (from the previous *epoch's* fee income / LP loss)
apply to the first episode of the round only (D-3). `spikeRoot` per intent commits to
`(frame, stim, rates0, stateHash, readout)` exactly as v1, so each fill is independently replayable
from its `FlyIntentDecided` log.

## 6. Budget and wall clock

Per intent at 100 ms (`episodeSteps = 1000`): ~14 Ggas simulated, 84 s prestate trace on the sim node.

| MAX_BATCH | trace time (fleet) | STOREs | applied-gas upper bound (est.) | transport |
|---|---|---|---|---|
| 1 | ~84 s + rasterize | 3 (+ counter) | ~0.6 M incl. BLS floor | ~1 KB |
| 3 | ~250 s | 5 | ~0.7 M | ~2 KB |
| 6 @ 50 ms episodes | ~250 s | 8 | ~0.8 M | ~3 KB |

Logs carry `SwapObservation` + `Readout` (~400 B), **not the 6,670-byte frame** (v1 logged the frame;
it is recomputable from the observation, and at N per round it is dead weight in the payload).

The binding constraint is trace time vs `ROUND_TIMEOUT = 300 s`, not the payload. `MAX_BATCH = 1`
at 100 ms is the safe default; `MAX_BATCH = 3` is the ceiling on today's fleet. Raising `roundTimeout`
in `helm/gas-killer/values.yaml` (and the matching deployment `terminationGracePeriodSeconds`, see the
comments at lines 335/380) is the fleet knob if larger batches are wanted. Throughput at
`MAX_BATCH = 1` is one swap per ~7 min, which the ask accepts.

## 7. Keeper (`tools/fly_keeper.py` v2)

- `should-run`: `pool.pendingRange()`; run iff `tail > policy.decidedThrough()` and no task in flight
  (persist the last task id + status locally; the router's one-in-flight rule makes a duplicate submit
  wait, not fail).
- `submit`: `call_data = settle(prev)` with `prev` rebuilt from the last `FlySettled` log (genesis if
  none); `block_height = latest`; `from_address = keeper`; poll `GET /tasks/{id}` to `ready`;
  send `payload.data` to `payload.to`; then `pool.applyUpTo(N)`; then `verify` (replay chain from logs,
  check `FLY_SLOT` and each `fills[id]`).
- `watch`: subscribe to `IntentSubmitted`; loop the above.
- Abort conditions: `valid_until_block` passed before broadcast (re-submit; the diff is still valid
  for the same reference state only if no other transition landed — it hasn't, since only this keeper
  submits); task `failed`/`expired` → log the router error, retry next tick.

Reference-block race to keep in mind: an intent submitted after `block_height` is simply not in this
batch; nothing breaks. Do not pin `block_height` to a block before the newest intent you want included.

## 8. Tests

Keep all 11 `FlyEngine.t.sol` tests green (bit-exact vectors). Add in `test/examples/FlySwapAMM.t.sol`
(mock engine as v1's `FlyAMM.t.sol` does, plus one full-graph anvil rehearsal script):

1. `test_SubmitEscrowsAndQueues`, `test_ApplyRequiresDecision` (`NotDecided`).
2. `test_SettleWritesOnlyPolicySlots`: record all SSTOREs; assert set == `{FLY_SLOT, DECIDED_SLOT, fills[from..to], STATE_TRACKER}`.
3. `test_SettleDiffAppliesViaVerifyAndUpdate`: extract the diff (as v1 `test_VerifyAndUpdateAppliesDecisionDiff`), apply, then `applyNext` fills at the fly fee.
4. `test_ApplyInOrderOnly`, `test_ApplyIdempotent`, `test_RefundOnMinOut`, `test_RefundOnExpiry`.
5. `test_PoolClampsOutOfRangeFill` (fill word with fee 0 / 10,000 / skew 200 → clamped as v1).
6. `test_LiquidityOpsBetweenReferenceAndApplyDoNotBreakSettlement`: settle at state S, `addLiquidity`, apply diff, `applyNext` → fills against new reserves, no revert.
7. `test_BatchChainsRates`: two intents, second episode seeded with first's rates; `FlyState.rateMilliHz` == last.
8. `test_RasterizeSwapMatchesReference` (new vector), `test_PackFillRoundTrip`, `test_FlyStateV2PackRoundTrip`.
9. Payload gate: run `validate_unbounded_cost` equivalent numbers by hand once for `MAX_BATCH = 3` and record in `PROGRESS.md`.

## 9. Sepolia deploy and migration

Reuse graph root `0xe7c83910719ea03d80f7dd71caee4489a0a05641` and warm root
`0x046b0eedf28701d257944c0c48d64ac2fc9666ac` (both codehash-verified; 27.3 ETH sunk, nothing to re-upload).

1. Deploy `FlyEngine` v2 (code only). Run `fly_anvil.py check` via `eth_call` on the fleet node.
2. Deploy `FlySwapPool(base, quote)` with the existing `FlyTestToken`s (mintable), then
   `FlySwapPolicyUnchecked(avs 0x4Fa4…00B5, checker 0x7568…4ba5, engine, graphRoot, warmRoot, cfg, pool)`,
   then `pool.setPolicy`. Verify `setPolicy` bound a *codeful* address before seeding (v1 lesson:
   `forge script` silently dropped a CREATE and orphaned a pool).
3. Seed liquidity, submit one intent, run the keeper, confirm `applyNext` paid out at the decided fee.
4. Extend `script/DeployOnchainFly.s.sol` with `FLY_VARIANT=swap`. Budget: deployer holds ~1.66 ETH;
   engine + pool + policy + seeding ≈ 0.1 ETH at ~1 gwei.
5. v1 pool/policy stay deployed and untouched.

## 10. Rejected alternatives (so nobody re-litigates them)

- **Merged consumer writing reserves in the diff.** The quorum would then sign reserve values; a
  colluding quorum drains LPs, and `verifyAndUpdate` cannot check the diff. Also every LP op would
  have to become an intent to keep slots disjoint. The in-order `applyNext` design gets per-swap fly
  pricing with the v1 trust boundary intact.
- **Token transfers inside `settle` (CALL replay).** Forces the struct-log fallback (constraint 1);
  cannot trace a Ggas call.
- **Batch clearing price / one episode per batch.** Not "the fly decides this swap"; also
  order-dependent fairness questions. Kept only as the `MAX_BATCH > 1` *chaining* form, still one
  episode per intent.
- **Fly decides the price directly (outside the fee band).** Breaks `HANDOFF.md` §4.1 (ii); the band
  is the only thing bounding LP downside per epoch.
- **Cancellation of pending intents.** Double-settlement race with the blind apply (§4.1).
- **Block-number expiry.** Needs `block.number` in the tracked path.

## 11. Decisions for the implementer (D-list)

- **D-1** Where `maxBatch`, `sizeRef`, `slipRef` live: cfg word 2 has free bits below `volBarRows[151:136]`
  (`[135:0]`); recommend `sizeRef[135:120]`, `slipRef[119:104]`, `maxBatch[103:96]`. Changing cfg
  changes `spikeRoot` domain inputs only through `cfg` → no engine impact; `pack_cfg` in `fly_int.py` must match.
- **D-2** Histogram rotation in the policy vs the pool: recommended in the policy (pool returns raw ring + `histEpoch`), so `observeIntent` stays a pure storage dump.
- **D-3** Pulses on first episode only vs every episode in a batch: first only (the observed epoch's outcome is one event).
- **D-4** `settle` callable by anyone on chain: leave it (unaffordable under 16.78 M); do not add an `onlyRouter` gate, operators simulate from the keeper's `from_address`.
- **D-5** `OBS_UNIT = 1e12` and uint64 volumes: keep.
- **D-6** Whether `applyNext` should also be triggerable inside the same tx as `verifyAndUpdate` via a tiny `FlySettleAndApply` helper (external contract: `policy.verifyAndUpdate(...)` then `pool.applyUpTo(n)`): nice for "settled alongside" UX; optional.
- **D-7** Episode length for v2 launch: 100 ms (`episodeSteps = 1000`), `MAX_BATCH = 1`.

## 12. Pinned pointers

- Service repo (`atlanta-v1`): `common/src/task_data.rs:41` (128 KB), `router/src/sequencer.rs:48-66`
  (one in flight), `router/src/ingress.rs:674-696` (task body: `target_address, call_data,
  transition_index|auto, from_address, value, block_height`), `helm/gas-killer/values.yaml:394` (`roundTimeout`).
- Analyzer (`gas-analyzer` `3cbd54f`): `crates/core/src/sim_profile.rs` (`UNBOUNDED_PAYLOAD_GAS_BUDGET = 1<<24`,
  `UNBOUNDED_COLD_SSTORE_COST = 22_100`, `validate_unbounded_cost`), `crates/core/src/prestate.rs:62-91`
  (eligibility), `crates/evmsketch/src/lib.rs:858-888` (`StateEncoding`).
- SDK: `src/GasKillerSDK.sol` (`verifyAndUpdate`, `blockStaleMeasure` default 300),
  `src/StateChangeHandlerLib.sol` (STORE/CALL/LOG/CREATE apply loop), this directory's v1 contracts.
- Live v1: addresses in `PROGRESS.md` §"Testnet run"; keeper + round scripts in
  `atlanta-v1/.context/fly/` (`run_round3.sh`, `run_sepolia_deploy.sh`, `gk-api-key.txt`, `deployer.key`).
- Python reference env: `atlanta-v1/.context/doomfly/.venv-neural/bin/python`.
