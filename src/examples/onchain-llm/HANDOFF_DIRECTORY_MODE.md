# HANDOFF — Qwen3-0.6B is on-chain. Integrating directory mode into Gas Killer.

**Status:** weights deployed and verified on Sepolia 2026-09-11. Nothing outside the solidity-sdk worktree knows about them yet. Every artifact in `service` and `gas-analyzer` is still written for overlay mode.

---

## 1. What changed

The full Qwen3-0.6B int8 weight set is now **real Sepolia contract code**, deployed as CREATE data contracts behind a two-level directory (root → 20 pages → 24,364 chunks).

| | Overlay mode (what's live today) | Directory mode (new) |
|---|---|---|
| Where weights live | 597 MB blob on a GitHub release | 24,385 Sepolia contracts |
| How an operator gets them | initContainer curl → emptyDir/PVC → streaming-keccak verify → mmap mount → `anvil_setCode` into a fork | syncs a node |
| Addressing | phantom addrs `keccak("gaskiller.llm.overlay.v1" ‖ manifest ‖ i)[12..]` | real deployed addresses, resolved on-chain |
| Commitment | `manifestHash 0x23216cb9…` + an `env_commitment` that **has no consumer in the SP1 guest** | the state root. `anchorHash` + sp1-cc's `header.state_root == sketch.state.state_root()` assert already cover it |
| Missing-chunk failure | `extcodesize==0` → empty diff → **quorum settles an empty round silently** | `DataContractLib.payloadLength` reverts `DeployFailed()` → loud revert, round refused |

**Why it matters:** the model becomes part of consensus state. The "how do we prove every operator mounted the same 597 MB" problem class is deleted outright, and with it the single largest unshipped safety item in the overlay design (`env_commitment` / `ENV_COMMITMENT_DOMAIN_V2` was computed but never bound into `chainConfigHash`; `grep -i overlay` on sp1-cc @`1f04b99` returns zero hits, and `UNBOUNDED_OVERLAYS.md:42-43` gates overlay mode out of slashable quorums until a guest change that does not exist).

**What it does NOT change:** gas. 28.6 Ggas/generated token, 19.8 Ggas/prompt token, ~545 Ggas for a 16-in/8-out answer. `GK_SIM_PROFILE=unbounded` (2^40 ≈ 1.1 Tgas) is still mandatory. Directory resolution adds ~21 EXTCODECOPYs per engine call (root + 20 pages) — negligible; it does **not** do the per-chunk `EXTCODESIZE` loop that makes `checkArtifacts` cost 104.3M.

---

## 2. Deployment facts (ground truth)

| Item | Value |
|---|---|
| Directory root | `0x9d1dDc25c098DA26417D0A061b647f3a3511D7b0` (401 bytes = 1 STOP + 20 page addrs) |
| Contracts | 24,364 chunks (24,299 weight + 65 tokenizer) + 20 pages + 1 root = **24,385** |
| Deploy cost | 130.78 B gas / 171.97 ETH |
| Deployer | `0x6636A1CCBdf54485067304C1a590DE016DeaD9F0` |
| Sepolia block range | 11,668,746 → **11,681,346** (root last) |
| Verification | all 24,385 codehashes == `keccak(0x00 ‖ payload)` — `.context/qwen3/deploy-ledger/deploy.log`: `[verify] all 24385 contracts match expected codehashes` |
| Overlay manifest (superseded for 0.6B) | `0x23216cb9ed9ef2b4bc20c84d27b68fa62ab194fc0845dfa707836f48ec4a7ae9` |

**Hard constraint: every simulation anchor block must be ≥ 11,681,346.** Assert this at ingress.

### packedConfig (identical in both modes; `Qwen3_0_6B.packedConfig()`)

```
cfg0 = 0x04000c001c100800800002518004000101000000000000000000000000000000
cfg1 = 0x0000000010c6f7a10000000016a09e6600000000239791f10000000000000000
cfg2 = 0x00182bc20002505d0002505b0000000000000000000000000000000000000000
```

### Infra addresses (tenop; newest broadcast `run-1784249412945`)

| Role | Address |
|---|---|
| AVS service manager | `0xac91Ef6C23Bc683E5f8dd6c210033BE3f95Dc62e` |
| registryCoordinator | `0x574369B88ae0E4db774b822Fe921090b0ab8c06b` |
| BLSSignatureChecker (current) | `0xE9bFFC8af24E019741158B3A569d1Bd3dE8e374E` |
| `Qwen3SegEngine` (current) | `0x6785256C51301464415f367afa39411271dEF8b1` |
| `GasKillerChatSharded` (current, single-slot) | `0x16a066E8bEcf278Df3D1B4377Ebe9f675D22bF05` |
| stake / blsapk / operatorStateRetriever | `0xfeeaf35…a87d` / `0xf82ed73…5980` / `0x5e708c8…d957` |

Superseded, do not use: seg engines `0x18C8b1677a…13Aa4` (run-1784130313570) and `0xEE2723cB…2652` (run-1784246101178); consumers `0xd3F7f985…E80b`, `0x833c59D2…fB11`; checker `0xCc0ab324…087c`. (One research lens recommended `0x18C8…` — that is the *oldest* run and is wrong. Verified against `broadcast/DeployOnchainLLMShardedOverlay.s.sol/11155111/`.)

**Do not reuse `Qwen3Engine` at `0xd1fAbab961625d790342859f77886F77243Fb372`** — deployed 2026-07-13 04:28 UTC; commit `b7dbcc7` (same day, 19:16 UTC) changed 4 `private`→`internal` visibilities in `Qwen3.sol`, which is inlined into the engine runtime. Deploy fresh (~3.6M gas).

---

## 3. What this DELETES

All of the following is **0.6B only**. The 35B (34 GB) cannot go on-chain — extrapolating 130.78 Ggas / 171.97 ETH per 597 MB gives ~7.4 Tgas and ~9,800 ETH — so if the 35B stays live, none of this can be removed from the codebase, only *disabled per model*. See §9, Decision 1.

### service
| Delete | Where |
|---|---|
| `qwen-overlay-ensurer` (whole Deployment + inline `ensure.py`, ~130 lines that keccak-verify and `anvil_setCode` 24,364 chunks) | `deploy/testnet-default/sim-fork-stack.yaml` |
| `qwen-sim-fork` + `gk-sim-proxy` + ConfigMap `gk-sim-proxy-src` + `extras-ingress.yaml` | same file (see §6 — the fork topology must die, not just the ensurer) |
| CronJob `qwen-fork-refresh` (`*/8 * * * *` `anvil_reset`) and the `REFRESH_AT=60` tuning from PR #336 | `bridge/k8s.yaml:143` |
| `overlay.*` values block, the `fetch-overlay-artifacts` initContainer on router + every node, the `overlay-artifacts` emptyDir | `values.yaml:107-138`, `router-deployment.yaml:212-242`, `node-deployment.yaml:167+` |
| `GK_OVERLAY_WEIGHTS/TOKENIZER/MANIFEST[_N]`, `GK_OVERLAY_MMAP`; `overlay_env_from_env()`, `overlay_files_from_env()`, `indexed_overlay_slots*()` | `common/src/validator.rs:~227-416`, `common/src/local_exec_shim.rs` |
| `deploy/testnet-default/verify-artifacts.yaml` (`gk-keccak-verify`) | nothing left to verify |
| 0.6B slice of the `gas-killer-shared-data` PVC pre-staging (`/app/.nodes/qwen06/`) and revival-runbook steps 3–4 | `README.md:61-64`, `HANDOFF.md` §0 |
| `role: ops-highmem` nodeSelector co-location **for 0.6B** — it exists only because the RWO PVC holds the mmapped weights | removes HANDOFF footguns §10.4 (7-min restarts) and §10.5 (cgroup-v2 mmap accounting forcing 50Gi limits) |

### gas-analyzer
- `crates/core/src/overlay.rs` (296 lines), `docs/UNBOUNDED_OVERLAYS.md`, `apply_overlay_env` + the three `*_with_env` RPC helpers, `call_to_encoded_state_updates_with_evmsketch_env` — dead for 0.6B. PR #168's stated justification ("~130B gas to deploy — or, with overlays, one 32-byte hash") is satisfied; you paid the 130.78 Ggas.
- `env_commitment` / `ENV_COMMITMENT_DOMAIN_V2` — no consumer, never will have one for this model.
- `SimProfile::UnboundedV1Xl` (2^43) is **not needed**: 545 Ggas is 49.6% of 2^40; 2^40 admits ~38 tokens at 28.6 Ggas/tok.

### Second-order wins
- The `~1.2 GB hex stateOverrides JSON per tracer call, two in flight` memory line — the dominant memory item in the 0.6B profile — vanishes.
- The ~9-min eager manifest keccak per daemon boot, and the "first ask after any fleet restart costs ~15–20 min extra" cold-start tax, both disappear.
- The refork-race class of bugs disappears (with the fork).

---

## 4. Exact call arguments

### Monolithic, directory mode
Nothing about weights is in calldata; the consumer's immutables carry it. Operator calls `ask(uint32[],uint256)` (`0xdf5b7e31`) / `dryRun(uint32[],uint256)` (`0x0f47ef18`); consumer internally issues:

```
Qwen3Engine.chat(                                    // 0x09a41261, external view -> STATICCALL
  0x9d1dDc25c098DA26417D0A061b647f3a3511D7b0,        // rootDirectory
  0x0000000000000000000000000000000000000000000000000000000000000000,  // manifestHash (ignored)
  [cfg0, cfg1, cfg2], promptIds, maxNewTokens)
```

### Sharded, directory mode — **two JSON fields, zero contract changes**
`Qwen3SegEngine.forwardRange` (`0x568f9e26`) / `argmaxRange` (`0xcfa1c545`) already take `rootDirectory` as a call-time argument, and `_resolveWeights` (`Qwen3SegEngine.sol:102-134`) already branches on `rootDirectory != 0`. The router's `InferRequest` already carries `weights_root: Address` + `manifest: B256` (`router/src/shard.rs:99-100`) threaded into `ForwardArgs`/`ArgmaxArgs` (`router/src/model.rs:252,277,305,316`).

| field | overlay (today) | directory (new) |
|---|---|---|
| `weights_root` | `0x0000000000000000000000000000000000000000` | `0x9d1dDc25c098DA26417D0A061b647f3a3511D7b0` |
| `manifest` | `0x23216cb9…7ae9` | `0x00…00` |

Ready request: `/Users/wk/conductor/workspaces/solidity-sdk/monterrey-v3/.context/tenop/shard06_req.directory.json`.

`GasKillerChatSharded` needs **no redeploy** — its constructor is `(address _avsAddress, address _blsSigChecker)`, it holds zero model state.

### Post-deploy verification (this is what replaces the constructor check)
```bash
# byte-identity: eth_getProof.codeHash vs keccak(0x00 || payload) for all 24,385
python3 src/examples/onchain-llm/tools/verify_onchain_directory.py \
  --artifacts .context/qwen3/artifacts --ledger .context/qwen3/deploy-ledger --rpc "$SEPOLIA_RPC"

# shape assertion, against a node with --rpc.gascap >= 200000000 (measured 104.3M)
cast call "$ENGINE" "checkArtifacts(address,bytes32,bytes32[3])" \
  0x9d1dDc25c098DA26417D0A061b647f3a3511D7b0 \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  "[0x04000c001c100800800002518004000101000000000000000000000000000000,0x0000000010c6f7a10000000016a09e6600000000239791f10000000000000000,0x00182bc20002505d0002505b0000000000000000000000000000000000000000]" \
  --rpc-url "$BIG_GASCAP_RPC"
```

---

## 5. The 104.3M-gas constructor blocker — recommendation

**Problem.** `GasKillerChat`'s constructor calls `engine.checkArtifacts` whenever `weightsRoot != 0`. Over the real 24,385-contract directory that is a **measured 104.3M gas** — above Sepolia's 60M block gas limit and above geth's default 50M `rpc.gascap`. Not expensive: **un-mineable**. A two-phase `initialize()` does not help (same tx-level ceiling). A factory does not help. Deploying elsewhere does not help — the directory is on Sepolia.

**Recommendation: make the check a `virtual` hook and override it to a no-op in a directory-mode subclass. Ship this. The code is already written, builds clean, 11/11 tests green.**

Why this is not a security regression, from the code:
1. `weightsRoot`, `weightsManifest`, `_cfg0..2` are all `immutable`; there is **no setter anywhere**. Skipping the check cannot enable a later swap.
2. `checkArtifacts` (`Qwen3Engine.sol:73-89`) is a **shape** assertion — `Qwen3.layout` self-consistency, `root.length % 20 == 0`, per-page length, `seen == nW + nT`, summed chunk payload lengths vs `c.weightLen`/`c.tokLen`, `table[0] == 1`. **It never hashes a weight byte.** In directory mode `manifestHash` is zero and ignored, so there is no on-chain content commitment at all — a same-length garbage directory passes.
3. Everything it catches is a liveness failure that resurfaces immediately: `chat()` calls `_resolve()` on **every** call, so a malformed directory reverts `ask`/`dryRun`. It can never return a wrong answer. The consumer custodies no value; its only mutable state is a keccak chain.
4. The repo already treats it as optional: both live Sepolia deployments used `root = address(0)` (no check at all), and `script/e2e_operator_replay.sh:46-47` runs `checkArtifacts` as a separate post-mount operator step, "never at deploy time".
5. What actually proves the bytes are the model is `verify_onchain_directory.py` — strictly stronger, already run, already passed.

### The diff (applied in the worktree, uncommitted)

`src/examples/onchain-llm/GasKillerChat.sol`:
```diff
         if (_weightsRoot != address(0)) {
-            _engine.checkArtifacts(_weightsRoot, _weightsManifest, _packedConfig);
+            _validateArtifacts(_engine, _weightsRoot, _weightsManifest, _packedConfig);
         } else if (_weightsManifest == bytes32(0)) {
             revert MissingWeights();
         }
     }
+
+    function _validateArtifacts(
+        Qwen3Engine _engine,
+        address _weightsRoot,
+        bytes32 _weightsManifest,
+        bytes32[3] memory _packedConfig
+    ) internal view virtual {
+        _engine.checkArtifacts(_weightsRoot, _weightsManifest, _packedConfig);
+    }
```

`src/examples/onchain-llm/GasKillerChatUnchecked.sol` (new; functional body in full):
```solidity
contract GasKillerChatUnchecked is GasKillerChat {
    constructor(
        address _avsAddress, address _blsSigChecker, Qwen3Engine _engine,
        address _weightsRoot, bytes32 _weightsManifest, bytes32[3] memory _packedConfig
    ) GasKillerChat(_avsAddress, _blsSigChecker, _engine, _weightsRoot, _weightsManifest, _packedConfig) {}

    function _validateArtifacts(Qwen3Engine, address, bytes32, bytes32[3] memory) internal pure override {}
}
```
Solidity dispatches virtual calls from a base constructor to the most-derived override, and the override touches no state. No ABI change, no storage change; existing `GasKillerChat` behaviour is byte-identical.

Tests added to `test/examples/OnchainChat.t.sol`: `test_UncheckedDirectoryModeMatchesChecked` (byte-identical answer + ids vs the checked consumer over the same directory), `test_UncheckedConstructorSkipsArtifactCheck`.

**Optional follow-up (nice-to-have, does not unblock anything):** additive `checkArtifactsRange(root, manifest, cfg, lo, hi)` on `Qwen3Engine` so the semantic check fits under a 50M `rpc.gascap` in ~3 `eth_call`s.

### Deploy
```bash
export SEPOLIA_RPC=https://sepolia.drpc.org
export PK=<deployer key>
export AVS_ADDRESS=0xac91Ef6C23Bc683E5f8dd6c210033BE3f95Dc62e
export SIG_CHECKER_ADDRESS=0xE9bFFC8af24E019741158B3A569d1Bd3dE8e374E
export SEG_ENGINE=0x6785256C51301464415f367afa39411271dEF8b1   # reuse

forge script script/DeployOnchainLLMDirectory.s.sol:DeployOnchainLLMDirectoryScript \
  --rpc-url "$SEPOLIA_RPC" --private-key "$PK" --broadcast -vvv
```
The script hardcodes the root, pulls config from `Qwen3_0_6B.packedConfig()`, asserts `weightsRoot.code.length > 0`, optionally reuses `ENGINE`/`SEG_ENGINE`, and prints `DEPLOYED_TARGET/ENGINE/SEG_ENGINE/WEIGHTS_ROOT/MANIFEST/PACKED_CFG_*`.

---

## 6. Operator requirements

### 6.1 The 597 MB does **not** cross the wire — but it does thrash your node

The prestate tracer runs with `diff_mode: true, disable_code: true` (`gas-analyzer crates/rpc/src/lib.rs:173`), so the ~24k touched-but-unchanged data contracts appear in neither tracer response. Response volume is kilobytes. `callTracer` never sees EXTCODECOPY at all.

`GasKillerChat.ask` stays on the prestate fast path because `Qwen3Engine.chat` is `external view` → **STATICCALL**, which `classify_prestate_eligibility` explicitly permits (`crates/core/src/prestate.rs:118`). **Treat "engine entry points stay `view`, consumer writes stay local" as a hard invariant and add a regression test** — the struct-log fallback runs with `enable_memory: true` over ~10¹¹ steps, which is not a slow path, it is an unbounded-memory death.

The 597 MB is **node-internal read volume**: ~24 forward passes per 16-in/8-out answer ≈ **14 GB of EXTCODECOPY per answer**, all of which must be served from RAM.

### 6.2 Node requirements

| Requirement | Number / flag | Why |
|---|---|---|
| Own node, per operator | — | a shared/public/QuickNode endpoint cannot serve this |
| `--rpc.gascap=0` (geth) / raised (reth) / `--disable-block-gas-limit` (anvil) | default is **50,000,000** | `UNBOUNDED_MODE.md` calls this "a consensus requirement, not a performance setting". Clamped node returns **`Ok` with an empty or partial payload** that passes the 2^24 budget gate and is indistinguishable from correct |
| Trace timeout | geth default **5 s**; analyzer **never sets it** | see §7, hard code blocker |
| `--rpc.evmtimeout` raised | geth `eth_call` default 5 s | `common/src/shard.rs:1353` has a plain-`eth_call` fallback for segments |
| HTTP write timeout | `rpc.DefaultHTTPTimeouts.WriteTimeout` = 30 s, often not a CLI flag | use IPC/WS if your build can't raise it — **verify on your geth version** |
| geth ≥ ~1.14 | `prestateTracer.disableCode` support | older nodes ignore it and buffer 597 MB in the tracer's `pre` map |
| Archive vs full | **disputed — see §9 Decision 3** | |
| RAM | host page cache must hold ~600 MB hot; ~0.6–1.5 GB resident for the code set wherever state lives | geth's in-process code cache is a fixed LRU well below 597 MB (believed 64 MB `codeCacheSize` — verify) |
| Single client fleet | geth **or** reth **or** anvil, not mixed | gas-analyzer #178: callTracer log ordering differs (`index` vs `position`) → forks the digest |

### 6.3 The anvil-fork topology must go

`deploy/testnet-default/sim-fork-stack.yaml` runs `anvil --fork-url <publicnode> --compute-units-per-second 300 …`, reforked by the ensurer at `REFRESH_AT=60` blocks drift and by a `*/8 * * * *` cron.

- `anvil_reset` **drops the fork cache**. In overlay mode that was survivable (the ensurer `setCode`'d the chunks back in). In directory mode all 597 MB must be re-fetched from upstream after every refork.
- At 300 CUPS and ~19–26 CU per `eth_getCode`, that's ~12–16 fetches/s → **25–35 min to warm 24,364 chunks, on an 8-minute refork cycle. It never converges.** (Cross-check from the same file: the ensurer measured `anvil_setCode` at ~4 chunks/s ⇒ ~100 min, pre-keep-alive.)
- The refork cadence is not tunable upward: the ~110-block ceiling is "bounded by the UPSTREAM's non-archive window, NOT by anything in gas-killer" and "raising this above ~100 will silently break" reads at the fork base.

**Pick one:** (a) a local Sepolia node as `GK_SIM_RPC` directly; or (b) anvil forking a *local* node with a relaxed refork cadence. **Keeping the publicnode fork is not viable.** If you keep the proxy at all, add the new directory-mode consumer to the hardcoded two-address `FORK_TARGETS` allowlist or its traces go to the keyed upstream and fail.

The existing hosted-RPC matrix is already known-unusable: drpc's `eth_getProof` is broken (settlement dies on it), Alchemy is over monthly quota, publicnode 403s state older than ~110 blocks and deep `eth_getLogs`, and `values.yaml:48-50` notes hosted providers commonly gate `prestateTracer` to paid tiers.

### 6.4 Resources (directory-mode 0.6B, vs `llm-overrides.yaml`'s overlay profile)

| | overlay profile | directory-mode recommendation |
|---|---|---|
| node memory | req 4 Gi / lim 12 Gi (live: 12 Gi / 50 Gi) | req 3 Gi / **lim 6–8 Gi** |
| node CPU | `values.yaml` main: 100m / 500m | **4000m** — wall clock is linear in CPU; a 500m limit turns a 9-min leg into 18+ min of CFS throttling |
| router memory | req 4 Gi / lim 12 Gi | req 2 Gi / lim 4–6 Gi |
| `terminationGracePeriodSeconds` | 360 | must exceed `ROUND_TIMEOUT` — 360 s is **shorter than a monolithic leg**, so any pod roll mid-analysis is a SIGKILL |
| liveness probe | `initialDelay 30, timeout 5, period 30, failureThreshold 6` + `spawn_blocking` | **keep** — long synchronous revm traces starved tokio and got pods SIGKILLed (HANDOFF §10.9) |
| PVC / nodeSelector | RWO `gas-killer-shared-data`, `role: ops-highmem` | not needed for 0.6B |

---

## 7. Code changes required before this works

### gas-analyzer — 3 changes, all hard
| # | Change | Detail |
|---|---|---|
| A | **Set `timeout` on all three tracer option builders** — `crates/rpc/src/lib.rs` ~:115, ~:169, ~:217 | All build `GethDebugTracingOptions{ ..Default::default() }` and never touch `.timeout`. The field is `skip_serializing_if = Option::is_none`, so the key is omitted and geth applies its 5 s default to a call that needs tens of minutes. This has never bitten anyone because the live fleet runs anvil, which has no such default. Also: no client-level timeout is set on `RootProvider::new_http` (`lib.rs:207`), so the analyzer **hangs** rather than erroring. Have `apply_sim_profile` set the timeout whenever the profile lifts gas limits, and add the row to `docs/UNBOUNDED_MODE.md:138-150`'s node table. |
| B | **`gk-fast-view` needs an RPC-backed base `DatabaseRef`** — `crates/gk-fast-view/` | Base DB is `CacheDB<EmptyDB>` (`src/lib.rs:62`); the job format hard-assumes `rootDirectory == address(0)` (`src/job.rs:10-20`). Directory mode would need 24,385 `account <addr> <code>` lines ≈ **1.2 GB of stdin**, preceded by 24,385 serial `eth_getCode`, per segment. `GK_FAST_VIEW_EXTRA_ACCOUNTS` is not a workaround at this scale. The README names the fix: an `rpc` cargo feature + revm-41 `AlloyDB`, `rpc_url` + `block` in the job — **plus a bulk prefetch**. Cost of not doing it: the 4.2× fast executor is unavailable; 8 tokens goes from ~4 min to ~17.2 min. |
| C | **`LocalStateCache` persistent code cache** — `crates/evmsketch/src/local_exec.rs:207-248` | `LruCache<(rpc_url, block), SharedBackend>`, capacity **4**, built with `BlockchainDb::new(meta, None)` — **no disk cache**. Every distinct anchor block re-fetches ~597 MB, nothing survives a pod restart. Fix: `Some(path)`, and key the code cache by **codeHash** (immutable; you have all 24,385 verified) so the fetch is one-time per operator, not per call. There is no bulk *read-set* prefetch anywhere — `prefetch_slots_into_cache` is driven by `hints_from_state_updates`, i.e. by what the payload *writes*. |

### service — 2 hard, plus config
- `common/src/shard.rs:1332` — `local_view_call` calls `eth_block_number` **freshly per segment**. With 12 s Sepolia blocks and ~48 segments per answer, segments land on different blocks → new `SharedBackend` → full 597 MB re-fetch at every block boundary. **Pin the anchor block for the whole `/shard/infer` run.** Invisible in overlay mode (weights came from the manifest-keyed mount); fatal in directory mode. **HARD.**
- `common/src/shard.rs:855-900` — `fast_view_call` job construction, see gas-analyzer (B). **HARD.**
- New pinned consensus parameter: `GK_WEIGHTS_ROOT` (or per-consumer) threaded to `ShardRequest.weights_root`. Router and all nodes must agree — **coordinated flip, not rolling**, exactly like `simProfile`.
- New `llm-overrides.yaml` profile: "Qwen3-0.6B, directory mode" — `overlay.enabled: false`, `simProfile: unbounded`, `simExecutor: local`, no `GK_OVERLAY_*`, resources per §6.4.
- Ingress assertion: `block_height ≥ 11,681,346`, and `root.code.length > 0` at that block.

### solidity-sdk — commit what's in the worktree
`GasKillerChat.sol` (modified), `GasKillerChatUnchecked.sol`, `script/DeployOnchainLLMDirectory.s.sol`, `tools/verify_onchain_directory.py`, `tools/deploy_sepolia.py` (the last two are the **provenance record for a 171.97 ETH deploy** and are currently untracked). Also fix `TESTNET.md`: line 10 says directory mode costs "same + ~66M constructor validation" (real: 104.3M, un-mineable), and lines 45–79's "known upstream dependencies" list is stale (gas-analyzer #166 is merged, `GK_SIM_PROFILE` is wired).

### Branch reality — read before planning
| repo | state |
|---|---|
| gas-analyzer `origin/main` = `f527099` | has `SimProfile{Chain, Unbounded}`, priced `validate_unbounded_cost`. **No overlays, no XL, no local execution.** |
| gas-analyzer #168 (overlays) | OPEN, DRAFT, **CONFLICTING** — still on the pre-review `UnboundedV1`/`UnboundedV1Xl` naming and the old hard 1-store `validate_unbounded_shape` |
| gas-analyzer #172 (`ron/local-execution`, base = #168) | OPEN, DRAFT, +14,837/-1 |
| service `origin/main` = `88a5763` | tracks analyzer default branch. No overlay, no shard, no `GK_SIM_RPC`, no `simExecutor` |
| service `ron/sharded-inference` (#321) and `deployed/node-fast-v6` | pin `gas-analyzer branch = "ron/local-execution"`, **two generations behind main** (missing the #299+#322 consensus-aggregation rewrite and the #300→#324 task-lifecycle stack) |

**Recommended:** land #172's local-execution core against main's 2-variant `SimProfile` **without** dragging `overlay.rs` or the XL tier along. That's a much smaller, much more mergeable PR and it is exactly what directory mode needs. Every deletion in §3 shrinks the service two-generation port — the ~130 lines of overlay env parsing in `validator.rs` are precisely the hand-merge surface. Also: version skew today — service `Cargo.lock` pins analyzer `ac38dbd` but the shipped `node-fast:v6` fast-view sidecar was built from `541c9e7`.

---

## 8. Latency, and which serving path is real

Throughput, measured: anvil `debug_traceCall` **0.35–0.40 Ggas/s**; in-process revm (`GK_SIM_EXECUTOR=local`) **~1.0 Ggas/s**; revmc `gk-fast-view` **4.2×** the interpreter on segment view calls.

Monolithic `ask(16 prompt ids, N)`, one execution leg: `T_rpc(N) = 868 + 78.4·N` s, `T_local(N) = 317 + 28.6·N` s.

| N | anvil traceCall | in-process revm |
|---|---|---|
| 1 | 15.8 m | 5.8 m |
| 8 | **24.9 m** (matches the live 24m56s measurement) | 9.1 m |
| 24 (bridge cap) | 45.8 m | 16.7 m |

Against `ROUND_TIMEOUT`: library default 30 s → **0 tokens**. Helm main `300` → **0 tokens** (the prefill alone is 317–868 s). `llm-overrides` 600 → 0 on rpc, ≤9 local. 1800 → ≤11 rpc, ≤51 local.

Also note `payloadBlockBuffer: "50"` ≈ 600 s of payload validity — a monolithic analysis longer than that produces a payload that expires before it can be settled. And the node path costs the RPC **2× full execution** (prestate + call tracer in `try_join!`) ≈ 1.09 Tgas of node work per task per operator; gas-analyzer #185 (combined tracer) halves it.

> **Architectural recommendation: do not serve monolithic `ask` through an aggregation round.** Use the sharded split — heavy inference as `forwardRange`/`argmaxRange` view calls *outside* the round (bridge timeout 14,400 s, `segmentTimeout` 7,200 s), and `GasKillerChatSharded.fulfil(uint32[],uint256,uint32[],bytes32)` (`0x9c98c06e`) as the tracked function: pure, single-slot, touches no weights, settles in **16–31 s** at ~350–384k gas. This is unaffected by where the weights live. Deploy the monolithic directory-mode consumer as a reference/verification artifact, not as the serving path.

Live caps for 0.6B: `max_new ≤ 24`, prompt ≤ 992 ids, prompt+answer ≤ 1024.

---

## 9. Where the research disagreed — decisions needed

**Decision 1 — Is the 35B staying live? (product, blocks everything in §3)**
If yes, the overlay subsystem (multi-overlay `GK_OVERLAY_*_N`, mmap, `simExecutor: local`, 34 GB PVC, cgroup-v2 footgun, 50 Gi pod limits) **cannot be deleted** and the fleet runs both modes concurrently — roughly doubling the config surface and turning "delete" into "make per-model optional". If the 35B is retiring, §3 is real deletion. The likely answer is "keep both, directory is default for 0.6B, overlays are the MoE-only escape hatch" — but that has to be said out loud, because it determines whether gas-analyzer #168 gets rebased or **closed**.

**Decision 2 — Can `OverlayMount` mount blobs at an explicit address list?**
This is the highest-leverage open question. Today `OverlayMount::from_files` derives chunk addresses *per-manifest* from phantom keccaks, so directory mode cannot use the mmap path at all and chunk code comes from the lazy state backend. If `OverlayMount` gains an "explicit address list" source (the 24,364 real addresses are in `.context/qwen3/deploy-ledger/ledger.jsonl`), you get **directory-mode trust plus mmap speed** — estimated ~1 day of work, and it also largely subsumes gas-analyzer change (C). If not, benchmark one `forwardRange` against a real node before committing to the flip. **Owner: gas-analyzer / `ron/local-execution`.**

**Decision 3 — Archive node or full node? (researchers split)**
- *Full is enough:* contract code in geth/reth is content-addressed by codeHash and is **not pruned with state trie nodes**, and the anchor is head (`provider.get_block_number()`), inside the recent-state window. Archive only needed to re-anchor a historical round (slasher replay).
- *Archive is mandatory:* a geth PBSS full node keeps ~128 state layers ≈ **25.6 min on Sepolia**, and a monolithic analysis anchored at a pinned block runs 9–46 min — the anchor ages out mid-analysis. `BLOCK_STALE_MEASURE=50000` and multi-hour rounds make this worse.
- **Resolution:** the two are consistent. Sharded settlement (§8), where segments are short view calls, only needs a full node. A monolithic leg needs archive. If you follow the §8 recommendation, provision full; if you serve `ask` monolithically, provision archive. A Sepolia archive node is ~1–2 TB — cheaper and far more reliable than 597 MB × N operators × per-block re-fetch over hosted RPC, and it eliminates the publicnode/drpc/Alchemy three-way workaround. **Decide explicitly.**

**Decision 4 — `simExecutor: rpc` or `local`?**
Under `local`, the gas override is applied in-process by `build_cfg_and_block` and never crosses the wire, so **service#356 precondition 3 (per-operator `debug_traceCall` cap lift) is satisfied by construction** and no anvil is needed. Under `rpc` you need `--rpc.gascap=0` fleet-wide with a silent-corruption failure mode. Recommendation: `local`. Note this makes #172 a hard dependency.

**Decision 5 — single-client fleet vs everyone-runs-their-own-node.**
gas-analyzer #178 (callTracer log ordering: `index` vs `position`) means a mixed geth/reth/anvil fleet forks the digest. But directory mode requires each operator to run their own node. Either mandate one client (which?) or keep an anvil indirection specifically to normalize tracer output — which conflicts with §6.3. **Unresolved.**

**Decision 6 — does service#356's "DO NOT set this to unbounded on a production fleet yet" (`values.yaml:73-81`) still hold, and is a testnet demo "production"?**
Precondition 1 (SP1 guest binds lifted limits) is **satisfied** by sp1-cc#12 @`1f04b99` + gas-analyzer #194 — that text is stale. Precondition 2 (re-measure `UNBOUNDED_APPLY_GAS_PER_PAYLOAD_BYTE = 14` against a real `verifyAndUpdate`, gas-analyzer #181) is still open. Precondition 3 is Decision 4. Someone has to make this call explicitly.

**Decision 7 — chainConfigHash for directory mode.** Consensus across lenses, stated for the record: **nothing new is needed.** The correct value is today's `ChainConfigWithEnvOverrides{chainId, activeForkName, blockGasLimitOverride = 2^40, txGasLimitOverride = 2^40}`. The weights are covered by `anchorHash` + the `header.state_root == sketch.state.state_root()` assert. One caveat flagged by the ops lens: a *fraud-proof guest* would now have to witness 24,385 code blobs (597 MB of keccak + MPT proofs) instead of streaming-keccaking a manifest — roughly a wash, and nobody has built either.

### Unresolved empirical questions (cheap to answer, do them first)
1. Does geth's 5 s `defaultTraceTimeout` apply to native Go tracers (`prestateTracer`/`callTracer`) or only JS? Alloy's doc comment says JS; reading `eth/tracers/api.go traceTx` suggests the deadline wraps all tracers. Fix is the same either way; severity differs. **Test: a >30 s `debug_traceCall` with the prestate tracer against a real geth with `--rpc.gascap=0`.**
2. **MEASURED 2026-09-11** (`script/e2e_directory_dryrun.sh`: live directory mirrored onto anvil at its real addresses via `tools/mirror_directory_anvil.py`): `dryRun` 16-in/8-out = **662,920,878,814 gas**, **516 s** as a plain anvil 1.5.1 `eth_call` (≈1.28 Ggas/s), 1,622 s inside `forge script` (OperatorReplay); answer bit-identical to `vectors.json` `genShort`; settled on Sepolia via `script/OperatorSettle.s.sol` on mock-quorum consumer `0xc4Fe9b915cA0Fe1A24d660Bb4B32351B03E2170A` (tx `0xcaae3902…2fda66`, block 11,684,592, 124,874 gas). Original question — measured wall-clock for one real directory-mode `dryRun`. The only figure in the repo (0.35 Ggas/s) is from a compute-heavy busy loop with **no state access**. Extend `bench_local_vs_rpc_throughput` (`crates/evmsketch/src/lib.rs:3030-3120`) against the deployed directory.
3. How many `eth_getCode` round-trips does `foundry_fork_db::SharedBackend` 0.21.0 issue for 24,364 addresses, and with what concurrency? Determines whether change (C) is nice-to-have or the whole ballgame. Read `foundry-fork-db-0.21.0/src/backend.rs`.
4. geth's `codeCacheSize` on the target version (believed 64 MB) — if so, a 597 MB working set thrashes every forward pass.
5. Does `eth_getCode` for 24,385 addresses at a pinned block work on drpc, at what rate limit and cost?
6. **MEASURED 2026-09-11:** the 16-in/8-out `chat` costs 663 Ggas in directory mode vs the ~545 Ggas overlay figure below (+22%) — re-derive per-token numbers from directory-mode traces before quoting. Original question — per-token gas in directory mode. 28.6 Ggas/tok was measured in **overlay** mode. Directory adds ~20 cold page accounts + ~490 KB EXTCODECOPY (~0.6M gas est.) while removing ~24,364 keccaks (~1.2M gas est.) — probably marginally cheaper, but **re-measure before quoting**.

---

## 10. Go-live checklist (dependency-ordered)

### Phase 0 — land the code that already exists
1. **[HARD]** Commit + review the 5 worktree files: `GasKillerChat.sol` (`virtual _validateArtifacts`), `GasKillerChatUnchecked.sol`, `DeployOnchainLLMDirectory.s.sol`, `tools/verify_onchain_directory.py`, `tools/deploy_sepolia.py`.
2. **[HARD]** Re-run `verify_onchain_directory.py` from a clean checkout so byte-identity is reproducible in CI, not a chat claim.
3. [nice] `checkArtifacts(root, 0, packedConfig)` as an `eth_call` against a `--rpc.gascap >= 200000000` node.
4. [nice] Fix `TESTNET.md` lines 10 and 45–79.

### Phase 1 — decide, then provision
5. **[HARD]** Answer Decisions 1, 3, 4, 5 (§9). Everything downstream branches on these.
6. **[HARD]** Stand up the state topology: local Sepolia node with `--rpc.gascap=0`, raised `--rpc.evmtimeout`, no 30 s HTTP write timeout (IPC/WS if needed), geth ≥ ~1.14, RAM for a 600 MB hot code set. Either direct as `GK_SIM_RPC`, or anvil forking *it*. **Not publicnode.**
7. **[HARD]** Single-client fleet until gas-analyzer #178 lands.

### Phase 2 — analyzer / service
8. **[HARD]** gas-analyzer (A): set `timeout` in all three tracer builders.
9. **[HARD]** gas-analyzer (C) + service `shard.rs:1332`: disk-backed / codeHash-keyed code cache, and pin the anchor block for a whole `/shard/infer` run.
10. **[HARD]** gas-analyzer (B) + service `shard.rs:855-900`: `gk-fast-view` RPC-backed base DB + bulk prefetch. *Skippable only if you accept 17.2 min vs ~4 min for 8 tokens.*
11. **[HARD]** Rebase decision: land `local_exec.rs` against main's 2-variant `SimProfile` without `overlay.rs`/XL; reconcile the `Unbounded` vs `UnboundedV1` naming and the `_helpers.tpl` allow-list.
12. [nice] gas-analyzer #185 combined prestate+call tracer — halves node work.
13. [nice] Ingress assertions: `block_height ≥ 11,681,346`, `root.code.length > 0`.
14. [nice] Remove the inert `ethereum:` block from `llm-overrides.yaml` (there is no `ethereum` key in `values.yaml`; those resource numbers were never rendered).

### Phase 3 — deploy contracts
15. **[HARD]** Deploy fresh `Qwen3Engine` + `GasKillerChatUnchecked` via `DeployOnchainLLMDirectory.s.sol`.
16. **[nice]** Reuse `Qwen3SegEngine` at `0x6785256C51301464415f367afa39411271dEF8b1` — `_resolveWeights` already branches on `rootDirectory != 0`. Verify its deployed codehash against a fresh compile (strip the CBOR metadata trailer) before relying on it.
17. **[HARD]** `GasKillerChatSharded` at `0x16a066E8bEcf278Df3D1B4377Ebe9f675D22bF05` needs **no redeploy** — flip the two request fields instead. Re-point every `GK_SHARD_CONSUMER` / `shard.consumer` / `avsReferenceTarget`; note the router gate and node gate intentionally use *different* consumers, preserve that asymmetry.

### Phase 4 — fleet config (coordinated flip, not rolling — these change the digest)
18. **[HARD]** `GK_SIM_PROFILE=unbounded` on router and every node simultaneously.
19. **[HARD]** `STATE_ENCODING=prestate-net`, same coordination.
20. **[HARD]** `weights_root` → `0x9d1dDc25…D7b0`, `manifest` → `0x00…00`.
21. **[HARD]** `ROUND_TIMEOUT` 300 → 1800 if you serve monolithic `ask` at all; ≥600 with margin even for sharded settlement. Raise `terminationGracePeriodSeconds` above it. Keep `REBROADCAST_INTERVAL` ≪ `ROUND_TIMEOUT`.
22. **[HARD]** Node resources: CPU 500m → 4000m, memory limits → 6–8 Gi.
23. [nice] `overlay.enabled: false` for 0.6B; keep the sextet for 35B if it stays.
24. [nice] Delete the sim-fork stack + `qwen-fork-refresh` cron once the upstream is local (retires the `role=sim` pool, ~$144–248/mo).

### Phase 5 — before calling it production
25. **[HARD]** Boot-time provisioning probe: a `debug_traceCall` with `gas = 2^40` against a known busy-loop, asserting it does not OOG. A clamped node returns `Ok` with a partial payload that passes the budget gate. **Documentation is not a control.**
26. **[HARD]** Resolve service#356 (Decision 6) explicitly, in writing.
27. [nice] Alert on the `extraction=prestate_net|struct_log` span field — a fleet split across representations is invisible at `RUST_LOG=info`.
28. [nice] Fund the router operator key `0x5DD2e7db…` (~0.5 ETH Sepolia; settlements are 350–384k gas).

---

## 11. Blocker ledger — what on-chain weights fix, leave alone, or worsen

| Blocker | Directory mode |
|---|---|
| 545 Ggas ≫ block gas limit | **Unchanged.** `unbounded` profile still mandatory |
| Every operator's trace RPC needs its cap lifted | **Unchanged** under `simExecutor: rpc`; **satisfied by construction** under `local` |
| 597 MB out-of-band distribution (release, initContainer, manifest verify, mmap, `GK_OVERLAY_*` sextet) | **RESOLVED** |
| `anvil_setCode` staging + ensurer + refork race | Ensurer **resolved**; fork **worse** — chunks now come from throttled lazy `eth_getCode` and every `anvil_reset` costs 25–35 min. The fork topology must go |
| "Settled-but-empty round" from missing chunks | **RESOLVED / fail-loud** — `DataContractLib.payloadLength` reverts `DeployFailed()` on `extcodesize == 0`; PR #411 refuses the empty analysis |
| struct-log encoding O(steps) | **Unchanged.** `prestate-net` mandatory; a late top-level revert still drops to `enable_memory: true` over ~10¹¹ gas and takes the node down |
| `ROUND_TIMEOUT` 30/300 s | **Unchanged.** Only the sharded split fixes this |
| Long traces starve tokio → liveness SIGKILL | **Unchanged.** Keep `spawn_blocking` + relaxed probes |
| SP1 overlay env-commitment binding | **DELETED** as a dependency for 0.6B. `SimProfile → EnvOverrides` (sp1-cc#12) still required, and satisfied at the pinned rev |
| Cross-client callTracer log ordering (#178) | **Unchanged.** Single-client fleet only |
| `maxOperatorCount: 4`; speedup bounded by registered operators, not VMs | **Unchanged** |
| Constructor `checkArtifacts` 104.3M gas | **NEW.** Mitigated by §5 (uncommitted) |
| `gk-fast-view` assumes `rootDirectory == 0` + `CacheDB<EmptyDB>` | **NEW / much worse.** 4.2× fast path unavailable until fixed |
| `LocalStateCache` LRU(4), no disk cache; `eth_block_number` per segment | **NEW.** 597 MB re-fetch per block change |
| 35B (34 GB) | **Not addressable** — ~7.4 Tgas / ~9,800 ETH. Overlays stay for the MoE tier |
| Anchor block ≥ 11,681,346 | **NEW**, trivially satisfied, must be asserted |

---

## 12. Provenance & ownership

- **Deploy record:** `.context/qwen3/deploy-ledger/ledger.jsonl` (24,385 confirmed entries), `deploy.log`, `.context/qwen3/artifacts/vectors.json` (packedConfig source of truth).
- **Worktree:** `/Users/wk/conductor/workspaces/solidity-sdk/monterrey-v3`, branch `RonTuretzky/onchain-solidity-llm`, PR #56.
- **Access blocker:** per `service docs/HANDOFF.md` §2, GCP project IAM, the frontend repo, the Cloudflare Worker and the `gaskiller.xyz` DNS zone are all under Ron Turetzky's personal accounts with no shared credential store; `gcloud auth login` is interactive-only. Any operator team needs those grants before Phase 1. The `demo-expiry` CronJob (`30 20 25 7 *`, deletes the sim stack + node pools) was armed as of the last snapshot.
- **Cluster ground truth is unverified.** Every number in `HANDOFF.md` §6 is a pre-teardown snapshot (2026-07-21), and `default-live-overrides.yaml` is itself drifted (commits `router.image.tag: router-pr-321`; live was `…/gk-fast/router-live:v1`). Before acting: `kubectl get deploy,cronjob,pvc -n default`, `helm get values gas-killer -n default -o yaml`, `helm history gas-killer` against GKE `gas-killer` / us-east4 / project `gas-killer-testnet`.
