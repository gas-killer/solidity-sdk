# Fly AMM — build log against HANDOFF.md (2026-09-11)

Data, reference and artifacts were built first (Phases 0–3, 5, 6) under the service-v1 workspace
`atlanta-v1/.context/fly/` (git-excluded; see the memory note / that directory's PROGRESS.md for the
float-vs-fixed parity tables). This file records the Solidity side and the full-graph rehearsal.

## Phase status

| Phase | Status | Evidence |
|---|---|---|
| 0 graph.npz rebuilt | done | sha256 `346b8af8…` exact; audit passed |
| 1 converter | done | ptr.bin 28 / edges.bin 4,165 / meta.bin 3 chunks; **max contact count 2,591, no row splits** |
| 2 synth + fixed-point reference + vectors | done | `tools/fly_int.py` (+ C twin) == pure Python bit-for-bit; `test/fixtures/onchain-fly/vectors.json` |
| 3 multi-blob deploy tooling | done | `src/examples/onchain-llm/tools/{deploy_sepolia,verify_onchain_directory,deploy_anvil}.py` (`--blobs`, `--engine-kind fly`, `--family`) |
| 4 FlyEngine.sol + forge tests | **done** | `test/examples/FlyEngine.t.sol`: 11 tests bit-exact vs vectors (genesis, warmup, step, composition, decide, rasterize, overlay, tamper, checkArtifacts, gas probe) |
| 5 fly_int vs kernel.cpp, full graph | done | all §7.2 gates pass on the busy frame from genesis (raster identical 100 steps, Δv ≤ 1.3e-4 mV, spikes 149,216 vs 149,208) |
| 6 warm.bin | done | reference `artifacts/warm.bin` (5,376,396 B, keccak `eb2a77cf…`, warmCommitment `ed717ffa…`); reproduced by FlyEngine on anvil (see below) |
| 7 FlyPolicy / FlyAMM + tests | **done** | `test/examples/FlyAMM.t.sol`: 9 tests — windows + storage-only observe, clamps, single-slot `vm.record`, `verifyAndUpdate` applies `[STORE, LOG4]`, commitment chain |
| 8 anvil full-graph rehearsal | **done** | `tools/fly_anvil.py`: decide busy/empty bit-exact vs reference; gas measured (below) |
| 9 Sepolia upload + deploys | open (needs ≈31 ETH + key) | commands below |
| 10 live rounds | open | `tools/fly_keeper.py submit` once the policy is on the testnet |

## Full-graph numbers (anvil 1.5.1, revm, `--disable-block-gas-limit`)

| Call | Gas | Wall | Reference match |
|---|---|---|---|
| `decide` busy pool, 300 ms | **44,882,535,127 (44.9 Ggas → 149.6 Ggas / simulated second)** | 44.4 s | readout + spikeRoot identical (`2a933955…`) |
| `decide` empty pool, 300 ms | — (no trace) | 39.9 s | identical (`3ffc491f…`) |
| `decide` **as a transaction through FlyPolicy** (pool window 8, busy) | 41,851,627,177 (41.9 Ggas incl. rasterize + settlement) | 40.7 s | fee 55 / skew +10 / flags 4 → pool 65 bps buy, 45 bps sell |
| `checkArtifacts` (4,196 + 219 chunks) | 15.7 M (directory-only layout; 173.6 M before the fix) | 0.01 s | passes; runs inside the policy constructor |
| `rasterize` | 216 M with the state layout → directory-only layout now (≈1-2 M) | | frame identical |
| `warmup(20000)` (2 s from genesis, materialized) | 255,103,984,183 (255 Ggas → 127.6 Ggas / simulated second) | 250 s | **stateOut == `warm.bin` byte-for-byte**, warmCommitment `ed717ffa…` |
| engine deploy | 4.83 M | | runtime 22,152 B |

End-to-end on anvil (`run_anvil_e2e.sh`): forge script deploys engine + test tokens + seeded pool +
policy (constructor check included) → swaps through four windows → `fly_keeper.py state` returns the
genesis state and `should-run` says yes → `decide(prev)` sent as a 2^40-gas transaction → `params()`
= (55, 10, false, 8, 1) → `effectiveFee` 65 / 45 → `fly_keeper.py verify` replays the chain from the
`FlyDecided` log and matches FLY_SLOT → `fly_keeper.py submit --dry-run` renders the router request.

The handoff's per-second estimates (12–52 Ggas) were low: the compiled kernel costs ≈150 Ggas per
simulated second, i.e. ≈880 gas per evolve. Neither the Solidity optimizer nor via-IR changes it (the hot
loop is hand-written Yul; the legacy codegen's 16-slot stack forced base reloads from the context word).
A 300 ms episode is 44 s in revm — inside the Helm 300 s `ROUND_TIMEOUT`, outside the 30 s default.

## Decisions taken while writing the Solidity

- `step()` takes one `StepInput` calldata struct (eight loose parameters overflow the legacy stack).
- `decide()`/`warmup()` return the wire state in place (hand-built ABI return); `stateOut` is never abi-copied.
- `checkArtifacts` and `rasterize` use a directory-only memory layout (no 9 MB state reserve).
- The policy's genesis word is 0 and commits to `FlyPolicy.genesisState()` (memoryRoot = keccak("")).
- `FlyDecided` has three indexed params → operators' diff is `[STORE(FLY_SLOT), LOG4]`.
- `FlyAMM` volumes in `Observation` are in units of `OBS_UNIT = 1e12` quote wei (uint64 fields); the
  closing spot is snapshotted so `observe()` is constant inside a window; histogram is a 16-slot ring with
  gap zeroing; `setPolicy` is a one-shot deployer call (policy needs the pool address at construction).
- `DeployOnchainFly.s.sol` has `FLY_SKIP_CHECK` (→ `FlyPolicyUnchecked`) for chains whose block cannot
  hold the constructor's artifact check; run `fly_anvil.py check` / `verify_onchain_directory.py --engine-kind fly` instead.

## Sepolia runbook (Phase 9–10)

```
# 1. graph directory (≈4,196 chunks, ≈6 h, ≈30 ETH) and warm directory (219 chunks)
python3 src/examples/onchain-llm/tools/deploy_sepolia.py --artifacts <artifacts> --blobs ptr.bin,edges.bin,meta.bin --key-file <key> --ledger <ledger-graph>
python3 src/examples/onchain-llm/tools/deploy_sepolia.py --artifacts <artifacts> --blobs warm.bin --key-file <key> --ledger <ledger-warm>
# 2. verify bytes
python3 src/examples/onchain-llm/tools/verify_onchain_directory.py --artifacts <artifacts> --blobs ptr.bin,edges.bin,meta.bin --ledger <ledger-graph>
python3 src/examples/onchain-llm/tools/verify_onchain_directory.py --artifacts <artifacts> --blobs warm.bin --ledger <ledger-warm>
# 3. contracts (cfg words from artifacts/fly_config.json)
AVS_ADDRESS=… SIG_CHECKER_ADDRESS=… FLY_GRAPH_ROOT=<graph root> FLY_WARM_ROOT=<warm root> FLY_CFG0=… FLY_CFG1=… FLY_CFG2=… FLY_SKIP_CHECK=true \
  forge script script/DeployOnchainFly.s.sol --rpc-url $SEPOLIA --broadcast
python3 src/examples/onchain-llm/tools/verify_onchain_directory.py … --engine <FlyEngine> --engine-kind fly --warm-root <warm root> --config-from <artifacts>/fly_config.json
# 4. rounds (operators on GK_SIM_PROFILE=unbounded, ROUND_TIMEOUT 300)
python3 src/examples/onchain-fly/tools/fly_keeper.py submit --rpc $SEPOLIA --policy <FlyPolicy> --router <router> --api-key <key>
python3 src/examples/onchain-fly/tools/fly_keeper.py verify --rpc $SEPOLIA --policy <FlyPolicy>
```
