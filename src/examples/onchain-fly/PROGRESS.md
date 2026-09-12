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
| 9 Sepolia upload + deploys | **done 2026-09-12** | graph root `0xe7c83910719ea03d80f7dd71caee4489a0a05641` (4,196 chunks, 26.0 ETH at ~1.16 gwei, ~11 h with fee gating), warm root `0x046b0eedf28701d257944c0c48d64ac2fc9666ac` (219 chunks, 1.3 ETH); FlyEngine `0xB61fd991A4A6afAEf54404bA54DC6123d2B9E4fC`, FlyAMM `0x0147847039d35Aa489c6654C21F49b9b58c9ed50`, FlyPolicyUnchecked `0x3c749083688dEDb379c37071fC4bf3809B67Db6E` (100 ms episode) |
| 10 live rounds | **done** | task `868b8f54…` through `testnet.gaskiller.xyz`: router traced in 89 s, all 3 operators certified height 46 with the task digest 2 min later, settled in `0xa31b872ba627878210d7cbf4b0ce3281b5bc9e11b16818b19353e18ba144f450` (418,737 gas); operators' spikeRoot == reference |

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

## Testnet run (2026-09-12) — what changed vs the plan

- **Fleet trace time decides the episode length.** On the fleet's `sim-node` (reth v2.5.2, `--rpc.gascap=max`, 7 CPU):
  100 ms episode = 25 s `eth_call` / 84 s prestate diff trace; 300 ms = 73 s / 255 s. With router + 3 operators tracing
  concurrently and `ROUND_TIMEOUT=300`, the policy went live at `episodeSteps=1000` (100 ms). Both were bit-exact vs the
  reference on real Sepolia state.
- **EIP-7825 (16,777,216 gas per tx) is live on Sepolia.** The `FlyPolicy` constructor + `checkArtifacts` (~20 M) cannot be
  deployed; `FlyPolicyUnchecked` (script `FLY_SKIP_CHECK=true`) is the only option, with the check run by `eth_call`
  (`fly_anvil.py check`). `forge script` silently dropped that CREATE and the pool's one-shot `setPolicy` bound a codeless
  address — pool + policy had to be redeployed (old pool `0x5c79…e0ca` is orphaned).
- **Settlement is a rendered payload for this API-key tier.** The router validates the quorum certificate and stores a
  ready-to-sign `verifyAndUpdate` (`GET /tasks/{id}` → `payload.{to,data,estimated_gas,valid_until_block}`); the
  submitter broadcasts it. `fly_keeper.py` + `run_round3.sh` (in the service workspace's `.context/fly`) automate
  trade → submit → poll `ready` → send.
- **Staleness clamp in practice.** Round 1 took ~30 min from window close (script fixes), beyond `MAX_LAG_WINDOWS=2`, so
  `effectiveFee` correctly fell back to 30 bps although the slot held fee 36 / skew +1. Round 2 (task `634c73e6…`,
  fully automated: window closed 11:37:01 → submitted 11:38:12 → `ready` 11:45:04 → settled in
  `0x68650b3e1b32e969da606f1a3eb43b1bd85b5ec45bb6a8e78e8735277fa3ee09` at 11:45:12, lag 2 windows) landed inside the
  clamp: epoch 2, fee 16 / skew +8 → `effectiveFee` 24 bps buy / 8 bps sell, and the next swap
  (`0x94806702ec9113a65ffb50f9bf559839c61d5ef23794678be687bd28c503e068`) paid 24 bps. Round latency on this fleet is
  ~7 min from submission to `ready`, so a keeper should submit within seconds of a window close.
- Tooling gotchas: Cloudflare and the public Sepolia RPCs 403 Python's default user agent (tools now send `curl/8.4.0`);
  reth refuses `eth_getLogs` below block 1,000,000 and ranges over 100,000 blocks (keeper uses a 90k lookback);
  `cast call/send` want `--gas-limit` and positional raw calldata.
