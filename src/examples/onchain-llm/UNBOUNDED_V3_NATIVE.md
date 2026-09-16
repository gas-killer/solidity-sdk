# UNBOUNDED_V3: native guest execution (gkvm)

Specification and cross-repo plan for extending Gas Killer's pinned simulation
environment with a **native guest precompile**: tracked functions delegate heavy
compute to a program compiled for RISC-V (`riscv64im`, SP1's guest ISA), executed
natively by the operator's simulator instead of as EVM bytecode. The consumer side
(Solidity library, example consumer, Python toolchain) lands in this directory; the
analyzer/service/guest side is specified here for companion PRs stacked on
gas-analyzer #172.

UnboundedV1 (gas-analyzer #166) established the governing principle, and V2
(UNBOUNDED_V2_OVERLAYS.md) restated it: *the simulation environment may deviate from
the real chain env, provided every deviation is a **versioned protocol constant**
that operators, the analyzer, and the SP1 slashing guest agree on bit-for-bit.*
The three deviations are **orthogonal axes**, not successive versions (see
`sim_profile.rs`'s V1/V2 note): V1 pins gas limits, V2 pins `address → code`
bindings, **V3 pins a guest VM** — one precompile address, one instruction-set
semantics, one cycle-metering rule. A consumer may use any combination: the native
chat consumer below is V1 + V3 with no V2 overlays at all.

## Motivation

`GasKillerChat.ask()` today runs a full transformer forward pass as EVM bytecode
(`Qwen3.sol`, 732 lines of Solidity kernels). Measured on the deployed example
(README.md, RESEARCH.md):

| | today (EVM bytecode) | V3 (native guest) |
|---|---|---|
| Qwen3-0.6B, 16-id prompt + 8 tokens | **545.1B gas**, ~9 min at ~1B gas/s | est. **5–12B gas**, seconds–minutes (**TBD, M4**) |
| Qwen3-0.6B, prefill + 1 token | 344.8B gas | TBD (M4) |
| per generated token | ~28.6B gas | est. 0.6–1.5B gas (**TBD, M4**) |
| per prompt position | ~21.5B gas | TBD (M4) |
| stories260K, 200-token story | 10,467,959,687 gas | TBD (M5) |
| Qwen3.5-35B-A3B MoE | **3.6T gas**, XL tier, 4h round timeout, 64–128Gi | est. minutes, V1 tier (**TBD**) |
| weights residency during a run | streamed through a 3.2MB scratch (loading at once = ~2.7T gas of memory expansion) | paged on demand, no EVM memory at all |
| engine code surface | ~1,000 LOC Solidity (`Qwen3.sol` + `Qwen3Engine.sol` + `DataContractLib.sol`) | ~0 (a generated binding + the C/Python program itself) |
| `verifyAndUpdate` application cost | ~100k gas (unchanged) | ~100k gas (unchanged) |

Estimates are scalar-rv64im instruction counts (~2.5–6G cycles/token for the 0.6B
model at 4 cycles/gas, § Metering) and are **flagged TBD until milestone M4
measures them** — sp1-jit throughput in particular has no published benchmark. The
EVM numbers are measured and exact.

The deeper motivation is the one RESEARCH.md §4 already names: *"the
memory-expansion wall is the true scale limit, not gas."* The EVM prices memory
quadratically and word-addresses everything through 256-bit stack items; a native
guest reads weight pages into flat RAM. V3 removes the wall entirely and, with it,
the entire streaming-kernel discipline (`loadRange`, scratch sizing, word-batched
matmuls) that makes `Qwen3.sol` hard to write and harder to extend. The Qwen3.5-MoE
engine — 2,100 more lines of Solidity on this branch — is the scale argument: every
new architecture currently costs a hand-written integer kernel library. Under V3 it
costs `make CC=riscv64-unknown-elf-gcc`.

## The constraint set

Every V3 design choice answers one of the constraints the V1/V2 line already
operates under:

| constraint | V3 design response |
|---|---|
| tracked functions never execute on-chain; diffs do | precompile exists **only** in the simulation env; on the real chain its address is empty and `GkVm.exec` deterministically reverts (§ Precompile) |
| every operator must produce a bit-identical diff | one pinned guest ISA + one pinned executor cycle model + closed hostcall set; no clock/rng/fs/net in the guest (§ Guest ABI) |
| fraud proofs must be able to re-execute the round | guest = an SP1-target ELF; the dispute guest re-runs the same ELF; artifact reads are Merkle-verified per page so a proof can authenticate them (§ Dispute path) |
| payload gas estimation stays on the real chain env (#166/#168 rule) | the estimator EVM never registers the precompile; applied diffs are priced exactly as today |
| `call_data + storage_updates` ≤ 128KB transport cap | guest input and output are capped at 131,072 bytes each — guest output feeds consumer post-processing (root + logs), which is itself transport-capped |
| misconfiguration must fail loudly, never fork the quorum ("silently degrading would fork the quorum", `SimExecutor` doctrine) | missing program/artifact is an **executor error → operator abstains**; only spec'd deterministic guest outcomes produce signable results (§ Precompile, error split) |
| metering must be one implementation, not N agreeing ones | operator interpreter, operator JIT, and dispute guest all run SP1's executor lineage; JIT is legal only because M1 proves count-equality (§ Metering) |

## The precompile

### Address

One fixed address for all programs, derived in the house pattern:

```solidity
// address(uint160(uint256(keccak256("gaskiller.gkvm.addr.v1"))))
address constant GKVM_ADDRESS = 0x35597421749DeEad8ba95049eDEe0B94E66F3c59;
```

Program identity travels as a hash argument (below), so there is no per-program
address, no registry, and nothing to enumerate in the env commitment. A
pre-existing account at the derived address is a ~2⁻¹⁶⁰ event — the same acceptance
argument the overlay chunk addresses already make.

### Wire format

The precompile speaks raw bytes (precompile convention — no function selector):

```
input  = programHash (32) || artifactRoot (32, zero = no artifact) || abi.encode(args...)
output = 0x01 || abi.encode(rets...)            on success
```

`programHash = keccak256(guestElfBytes)`. `artifactRoot` is the paged Merkle root of
the artifact bundle (§ Guest ABI) — the V3 analogue of `weightsManifest`, committed
as a consumer immutable exactly as today.

The mandatory `GKVM_OK_TAG = 0x01` prefix is what makes real-chain behavior sound:
on any real chain the address is empty, so a STATICCALL to it **succeeds with empty
returndata**. `GkVm.sol` treats `success && returndata.length == 0` as
`revert GkVmUnavailable()`. Consequence worth stating plainly: **directly executing
a V3 tracked function on-chain deterministically reverts** — strictly better than
V2, where a phantom-chunk `EXTCODECOPY` silently reads zeros.

```solidity
library GkVm {
    error GkVmUnavailable();

    function exec(address gkvm, bytes32 programHash, bytes32 artifactRoot, bytes memory payload)
        internal
        view
        returns (bytes memory out)
    {
        (bool ok, bytes memory ret) =
            gkvm.staticcall(abi.encodePacked(programHash, artifactRoot, payload));
        if (!ok) _bubble(ret);                      // typed guest errors pass through
        if (ret.length == 0 || ret[0] != 0x01) revert GkVmUnavailable();
        return _stripTag(ret);
    }
}
```

Consumers hold `address internal immutable GKVM = GKVM_ADDRESS`, overridable in the
constructor — that immutable is the Foundry Phase A seam (§ Foundry integration),
not an escape hatch: production deployments pass the constant.

### Error semantics — the determinism split

Two disjoint failure classes, and the split is the load-bearing design decision:

**Deterministic guest outcomes** — every honest operator computes the same one:

| outcome | surfaced as |
|---|---|
| guest called `gk_abort(code, msg)` | `revert GkGuestTrap(uint32 code, bytes data)` |
| cycle budget exhausted | `revert GkGuestOutOfCycles(uint64 used, uint64 limit)`, consumes the call's full gas |
| input/output cap breached | `revert GkVmInputOverflow()` / `GkVmOutputOverflow()` |
| invoked outside STATICCALL | `revert GkVmStaticOnly()` |
| illegal instruction / bad ELF semantics | `revert GkGuestTrap` with a spec'd code |

These bubble up as tracked-function reverts and take the **existing #165
revert-fallback path unchanged**: the round settles as a revert transition, nothing
unsound is signed. (revm 31's `PrecompileProvider::run` returns a full
`InterpreterResult`, so Revert-with-returndata is expressible; the `is_static` flag
is available on `CallInputs` — both are implementation-time verification items.)

**Operator-local environment failures** — `programHash` not installed,
`artifactRoot` not mounted, mmap or Merkle verification failure at load: **not an
EVM outcome at all**. The provider returns a fatal executor error,
`analyze_transaction` fails, the operator does not sign. Missing config is a
liveness event, never a divergent signable result — the same doctrine
`GK_SIM_EXECUTOR` parsing already enforces by panicking on typos.

### The STATICCALL rule

`GkVm.exec` is `view` and the precompile reverts `GkVmStaticOnly` when invoked
non-statically. This is enforced belt-and-suspenders because it carries two
guarantees, one verified against the #172 code:

1. **The classify fast path survives.** `ClassifyInspector` treats a target-depth
   `CallScheme::StaticCall` as "read-only — safely ignored"
   (`local_exec.rs:477`), while a target-depth regular `CALL` — including one to a
   precompile — notes fast-path disqualification and forces the two-pass replay
   fallback. `engine.chat` is already a target-depth STATICCALL today; `GkVm.exec`
   keeps the exact same shape.
2. **The interaction can never enter a payload.** STATICCALLs are excluded from
   replay capture, so no `Call` state update referencing `GKVM_ADDRESS` can ever be
   extracted and re-executed on the real chain against an empty account.

### Estimator invisibility

As with V1's gas limits and V2's overlays: **payload gas estimation stays on the
real chain env.** The estimator EVM (`crates/gas-estimator`, which injects the
`StateChangeHandlerGasEstimator` at the consumer address) never registers the
precompile. The applied diff — one `Store`, some `Log`s — is priced exactly as it
will execute inside `verifyAndUpdate` in a real block. V3 is also **local-executor
only**: a `debug_traceCall` request has no vocabulary for a native precompile, so
V3 consumers require `GK_SIM_EXECUTOR=local` — precedent already set by the 35B
tier, which requires `local` for unrelated reasons (the ~70GB `stateOverrides`
body).

### Program distribution and memoization

Programs and artifacts ride the existing overlay artifact channel:

```
GK_GUEST_PROGRAM[_N]=/path/guest.elf       GK_GUEST_PROGRAM_HASH[_N]=0x…   # keccak(elf), verified at startup
GK_GUEST_ARTIFACT[_N]=/path/weights.bin    GK_GUEST_ARTIFACT_ROOT[_N]=0x…  # Merkle root, verified at startup
```

All-or-nothing per slot, panic on mismatch, types re-exported through the service's
`local_exec_shim` so the accepted set can never drift — verbatim the
`GK_OVERLAY_*` conventions. Helm grows `global.guestPrograms` /
`global.guestArtifacts` lists feeding the same GitHub-release initContainer that
ships overlay blobs today.

`gkExec` is pure in `(programHash, artifactRoot, keccak(payload))`; the provider
memoizes results (`GKVM_RESULT_MEMO_ENTRIES = 16`, LRU — the `OverlayMountSet`
cache pattern) so the classify pass, a forced replay pass, and view-call serving
never run an inference twice. This is also what alloy-evm models as
`supports_caching()` — relevant to the evm2 port (§ Per-repo plan).

## Guest ABI

### Entrypoint and toolchain target

A guest is an ELF for target `riscv64im` (SP1 v6's guest ISA: rv64, integer +
multiply, no A/C/F extensions; build C with `-march=rv64im -mabi=lp64`). Rust
guests use `sp1_zkvm::entrypoint!`; C and interpreter guests (MicroPython, qwen.c)
link `gk-guest-crt`, a small crt0 + syscall shim speaking the same ABI. **One ELF
runs under all four hosts** — forge-test shim, gk-anvil, operator, SP1 dispute —
which is the whole determinism story.

### Hostcalls (`GKVM_HOSTCALLS_V1` — closed, versioned)

| hostcall | semantics | cap |
|---|---|---|
| `gk_input_read(dst) -> len` | the gkExec payload, SP1-stdin style | `GKVM_INPUT_BYTES_CAP = 131,072` |
| `gk_output_write(src, len)` | the result payload; in a dispute this is literally the SP1 public-values commit stream — output binding comes for free | `GKVM_OUTPUT_BYTES_CAP = 131,072` |
| `gk_artifact_len(kind) -> u64` | byte length of file `kind` in the mounted bundle (0 = weights, 1 = tokenizer, …) | — |
| `gk_artifact_read(kind, page_idx, dst)` | one 4,096-byte page + its Merkle branch; **the guest-side SDK verifies the branch against `artifactRoot` before returning bytes — always, in every host** | `GKVM_ARTIFACT_PAGE_SIZE = 4,096` |
| `gk_abort(code, msg, len)` | deterministic trap → `GkGuestTrap` | — |

Nothing else. No clock, no randomness, no filesystem, no network, no host floats.
Guest memory is zero-initialized (SP1 semantics) and capped at
`GKVM_MEM_BYTES_CAP = 2^31` bytes. Softfloat is permitted (deterministic) but the
shipped engines are integer-only, matching the RESEARCH.md numerics doctrine.

**Verification-always-on is load-bearing:** if operators skipped per-page Merkle
verification outside disputes, operator cycle counts and dispute cycle counts would
diverge — a slashing bug by construction. Uniform verification keeps the counted
work identical everywhere; the SDK amortizes it with a verified-page LRU inside the
guest.

### Artifact manifest v3

V2's manifest is a flat streaming keccak over whole blobs — perfect for
mount-time verification, **unusable in a dispute**, where the guest must
authenticate *one page* without hashing 597MB. V3 artifacts therefore commit to a
paged Merkle tree:

```
ARTIFACT_MANIFEST_DOMAIN_V3 = "gaskiller.artifact.v3"
leaf_i = keccak256(0x00 || page_i)                      # page = 4,096 bytes, zero-padded tail
node   = keccak256(0x01 || left || right)               # domain-separated binary tree
artifactRoot = keccak256(DOMAIN_V3 || fileCount || root_0 || … || root_{n-1})
```

For the Qwen3-0.6B weights (24,299 overlay chunks ⇒ ≤ 597,147,925 bytes): ≈145.8k
pages, tree depth 18, so one authenticated page read carries 18 × 32 = 576 bytes of
branch. Existing V2 blobs re-manifest byte-identically (same bytes, new 32-byte
root); `tools/gk manifest` emits the root and the branch store. Startup
verification remains one streaming pass, the same cost class as today's flat hash.

What this deletes from the V2 consumer: the 24,299 phantom data contracts, the
`overlayChunkAddress` derivation, `DataContractLib`, the 3.2MB scratch and its
`loadRange` chunk-boundary walking, and the ~2.7T-gas load-at-once wall. Weights
are never EVM state in any form; they are pages the guest asks for.

## Metering

All constants live in `gas-analyzer-core` (`crates/core/src/gkvm.rs`); the SP1
guest imports them and never restates them — the #166 doctrine.

```rust
pub const UNBOUNDED_V3_CYCLES_PER_GAS: u64 = 4;
pub const GKVM_GAS_BASE: u64            = 65_536;   // charged before execution
pub const GKVM_GAS_PER_INPUT_BYTE: u64  = 16;       // DoS floor on large payloads
pub const UNBOUNDED_V3_GKVM_SPEC_VERSION: u32 = 1;  // {ISA, cycle model, hostcalls v1, caps}
```

Execution: the provider charges the base + input cost, converts the call's
remaining gas to a cycle budget `cycle_limit = gas_remaining × 4`, runs the ELF
under SP1's executor with that limit, and converts back:
`gas_used = ceil(cycles / 4)` from the executor's instruction count. Exhaustion is
`GkGuestOutOfCycles`, consuming all provided gas — a tracked-function revert into
the #165 fallback, and **deterministic**, because the limit derives from pinned
constants and pinned per-call gas, never from operator hardware.

**Why 4 cycles per gas.** The local executor measures ~1B gas/s, so 1 gas ≈ 1ns of
honest-operator wall clock ≈ 3–4 cycles at 3–4GHz. `CYCLES_PER_GAS = 4` preserves
"gas ≈ nanoseconds", which is the semantics the 2^40/2^43 round budgets were sized
around, and keeps V3 numbers comparable with the 545.1B baseline. The constant is
provisional until M1 measures the executor's real throughput; it is versioned
precisely so it can change without ambiguity.

**Why meter at all, when tracked functions never land on-chain:**

1. It maps guest work into the **already-committed** SimProfile budgets — the V1
   tier's 2^40 tx gas ⇒ 4,398,046,511,104 guest cycles, the XL tier ⇒
   35,184,372,088,832 — so DoS and wall-clock bounds ride constants that are
   already in the env commitment; V3 adds no new budget knob.
2. Analyzer gas reports stay comparable across V1/V2/V3 consumers.
3. It prices round-timeout economics (the 4h MoE tier exists because gas predicts
   wall clock).

It does **not** price real-chain execution — diff application stays ~100k gas.

**Executor tiers.** `GK_GUEST_EXEC=interp` (default, consensus) runs
`sp1-core-executor`'s interpreter; `GK_GUEST_EXEC=jit` opts into `sp1-jit`.
The JIT is legal *only* because results and instruction counts are bit-identical to
the interpreter — a validation obligation (M1 differential gate), not an
assumption. Parsed fail-loudly, `SimExecutor`-style. If M1 finds any divergence,
jit demotes to a non-consensus preview tool and the doc's perf targets move to the
interpreter column.

**Version pinning.** `sp1-core-executor = "=6.x.y"` joins `revm = "=31.0.2"` in
the exact-pin set, with the same Cargo.toml comment: cycle-count semantics are
consensus-affecting; an SP1 upgrade is a coordinated, versioned change
(`GKVM_SPEC_VERSION` bump + env-commitment change), never a routine dep bump.

## Writing programs: the Python toolchain

The developer contract, end to end:

```python
# contracts/guest/answer.py
def main(prompt_ids: list[int], max_new: int) -> bytes:
    ids = respond(prompt_ids, max_new)          # arbitrary Python
    return encode(ids)
```

```bash
$ gk build guest/answer.py
  frozen    answer.py + gk_runtime.py  →  micropython-gkvm image
  linked    guest.elf (riscv64im, 1.9MB)
  program   0x8c41…e2a9  (keccak256 of the ELF)
  emitted   src/gen/GkAnswer.sol
```

`gk build` (a `tools/gk` Python package, sibling of `convert.py` /
`reference.py` / `deploy_anvil.py`):

1. **Freezes** the user script plus `gk_runtime.py` (ABI decode/encode + the
   verified-page artifact LRU) into the MicroPython gkvm port — the QEMU
   `VIRT_RV64` board port with UART/timer replaced by `GKVM_HOSTCALLS_V1`, built
   `-march=rv64im -mabi=lp64`, `MICROPY_FLOAT_IMPL_NONE` (floats rejected at build
   time; matches the integer-only engine doctrine).
2. **Links** against `gk-guest-crt` → `guest.elf`; `programHash = keccak256(elf)`.
3. **Generates the Solidity binding** from the type hints:

```solidity
// src/gen/GkAnswer.sol — generated by `gk build`, do not edit
library GkAnswer {
    bytes32 constant PROGRAM_HASH = 0x8c41…e2a9;

    function call(address gkvm, bytes32 artifactRoot, uint256[] memory promptIds, uint256 maxNew)
        internal view returns (bytes memory)
    {
        return GkVm.exec(gkvm, PROGRAM_HASH, artifactRoot, abi.encode(promptIds, maxNew));
    }
}
```

| Python type hint | Solidity type |
|---|---|
| `int` | `uint256` (MicroPython mpz big-ints; ABI words) |
| `bool` | `bool` |
| `bytes` | `bytes` |
| `str` | `string` (UTF-8) |
| `list[T]` | `T[]` |
| `float` | **rejected at build time** |

4. **Vectors**: `gk vectors guest/answer.py --input …` mirrors `reference.py` →
   `test/fixtures/answer_vectors.json`, consumed by forge tests via
   `vm.readFileBinary`/`parseJson` under the existing `fs_permissions` grant.

**One binary, four hosts:**

| host | invocation | role |
|---|---|---|
| forge test | `vm.ffi(["gk-run", "--program", …, "--input", 0x…])` via `GkVmFfiShim` | unit tests, CI |
| gk-anvil | `PrecompileFactory` registering the same `gkvm` crate | local node, demos, `cast call` |
| operator | in-process `PrecompileProvider` in the LocalExecutor | production simulation |
| SP1 dispute | same ELF as proof witness | slashing (design below) |

`gk-run` is the sidecar binary (`crates/gkvm/bin/gk-run`): artifact + program +
hex input on argv, one hex line on stdout — the `gk-fast-view` stdin/stdout
discipline, and exactly what `vm.ffi` consumes (trimmed stdout, hex-decoded).

**The Qwen story.** The flagship guest is not Python: it is `qwen.c` (llama2.c
lineage, int8, the same integer semantics `Qwen3.sol` implements) compiled to
rv64im, reading weights through `gk_artifact_read`. Scalar estimate: ~0.6G MACs per
token × 4–10 instructions/MAC + paging/verification overhead ≈ 2.5–6G cycles/token
⇒ 0.6–1.5B gas/token at 4 cycles/gas ⇒ **~19–48× below the ~28.6B/token EVM
baseline — all cells TBD until M4 measures them.** Wall clock: native inference is
memory-bandwidth-bound (sub-second/token); interpreter-tier RISC-V is the open
question sp1-jit vs ckb-vm-class ~39× datum brackets. Python remains the DX proof:
the same pipeline, zero glue, for business-logic-scale programs (M5 ships a
stories260K-class Python demo in CI).

## Operator lifecycle

1. Consumer deploys with `programHash` + `artifactRoot` immutables (the V3
   analogues of `weightsManifest`); publishes ELF + artifacts out-of-band (GitHub
   release, IPFS — availability, not trust).
2. Operator configures `GK_GUEST_PROGRAM/_HASH` + `GK_GUEST_ARTIFACT/_ROOT`
   (+ `GK_SIM_EXECUTOR=local`, `GK_SIM_PROFILE=unbounded-v1[-xl]`,
   `GK_GUEST_EXEC=interp`); startup verifies hashes/roots or panics.
3. Tracked tx observed; task references the pinned block.
4. Classify pass runs (fast path intact — gkExec is a STATICCALL).
5. Precompile executes the guest under the cycle budget; result memoized.
6. Diff extraction: one `Store` + logs; **shape gate unchanged**
   (`validate_unbounded_shape`, ≤1 Store beyond the exempt tracker slot, no
   CREATE).
7. Payload gas estimated on the real chain env (precompile invisible).
8. Quorum signs `sha256(abi.encode(transitionIndex, target, selector,
   storageUpdates))` — format unchanged.
9. `verifyAndUpdate` applies the diff on-chain, ~100k gas.

An operator missing the program or artifacts stops at step 5 with an executor
error: it abstains and the round degrades to liveness, exactly like an unmounted V2
overlay.

## Foundry integration

### Phase A — forge tests, zero new infrastructure

Consumers take `GKVM` in the constructor (defaulting to `GKVM_ADDRESS`). Tests
deploy **`GkVmFfiShim`** at any address and pass it in:

```solidity
contract GkVmFfiShim {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    fallback(bytes calldata data) external returns (bytes memory) {
        (bytes32 program, bytes32 root, bytes memory payload) = _decodeWire(data);
        bytes memory out = vm.ffi(_gkRunArgs(program, root, payload));
        return abi.encodePacked(bytes1(0x01), out);
    }
}
```

Chosen over environment sniffing (e.g. probing for forge's VM marker) because
constructor injection is explicit and fail-loud, and **production bytecode carries
zero ffi paths**. Requires `ffi = true` — test profile only, called out as such in
foundry.toml. Bit-exactness is free: the shim runs the *same* `gk-run` binary the
operator path wraps. One verify-at-impl item: `vm.ffi` from inside a STATICCALL
context (`dryRun` is `view`) — if forge rejects it, the shim's test entrypoints go
through non-static wrappers.

### Phase B — gk-anvil

A thin excluded crate (own Cargo.lock — the `gk-fast-view` precedent) wrapping
anvil-as-a-library: `NodeConfig::with_precompile_factory` registering the same
provider, exposed as a `gk-anvil` binary. Purpose is developer UX — `cast call` a
V3 consumer against a local node, demo deployments — **not** the operator path.

`e2e_operator_replay.sh` under V3:

- the chain anvil stays **vanilla** — gkvm must be absent on the applying chain,
  and the e2e asserts exactly that (direct `ask()` reverts `GkVmUnavailable`);
- `deploy_anvil.py --overlay`'s 24,299 `anvil_setCode` calls are **gone** — weights
  arrive as `GK_GUEST_ARTIFACT` mounts (a large e2e wall-clock win, measured in M3);
- the `checkArtifacts` cast-call preflight becomes a `gk-run` preflight;
- `OperatorReplay.s.sol` and `GK_VERIFY_MODE=transition-count` polling are
  unchanged.

### Phase C — upstream

An RFC to foundry's `foundry-evm-networks` crate (the sanctioned custom-network
precompile mechanism: a `NetworkConfigs` flag auto-generates the `foundry.toml`
key and the CLI flag on both forge and anvil; `--celo`, Tempo, and BSC shipped this
way). The ask is a first-class `gas_killer` network flag — not a resurrection of
the removed `--odyssey` (foundry #11675). Phases A/B are complete without C; C
removes the shim and the wrapper binary from the developer's world.

## Determinism and versioning

The consensus pin set:

| pin | value | why |
|---|---|---|
| `revm` | `= 31.0.2` | gas accounting / journal semantics (existing, #172) |
| `sp1-core-executor` | `= 6.x.y` | guest cycle model, ISA semantics |
| `GKVM_SPEC_VERSION` | `1` | {rv64im, cycle model, hostcalls v1, caps} as one bundle |
| `UNBOUNDED_V3_CYCLES_PER_GAS` | `4` | cycle↔gas conversion |

The env commitment gains a third arm (extending the `None → V1 / Some → V2`
dispatch in `overlay.rs`):

```
pre = ENV_COMMITMENT_DOMAIN_V3                  # b"gaskiller.env.unbounded.v3"
   || block_gas_limit  (u64 BE)
   || tx_gas_limit     (u64 BE)
   || overlay_segment                           # exactly the V2 segment; may be empty
   || gkvm_spec_version (u32 BE)
   || cycles_per_gas    (u64 BE)
env_commitment = keccak256(pre)
```

The **installed-program list is deliberately not bound**: programs are
self-authenticating per call (`programHash` in the wire format), and absence is a
liveness event. Binding the VM spec + metering constants is what makes a fraud
proof under a different cycle model unverifiable, mirroring how V2 makes a proof
under different weights unverifiable.

SP1 guest side: `chain_config_hash_with_overrides` (the
`ron/unbounded-env-overrides` fork of sp1-contract-call) widens once more to carry
the single 32-byte env commitment — the companion change UNBOUNDED_V2_OVERLAYS.md
already specifies for the overlay axis, now covering all three axes at once.

## What V3 does not change

- The shape gate (`validate_unbounded_shape`): ≤1 Store, tracker slot exempt, no
  CREATE, Calls/Logs pass.
- The signed digest format
  `sha256(abi.encode(transitionIndex, target, selector, storageUpdates))` (but see
  Risks — V3 sharpens an existing gap here).
- `verifyAndUpdate`, the BLS/Schnorr quorum machinery, and every on-chain contract.
- The #165 revert-fallback semantics.
- Payload gas estimation on the real chain env.
- The V1 gas tiers and their constants.
- V2 overlays for existing consumers — the axes compose; nothing migrates
  involuntarily.
- Transport caps (128KB) and task flow.

## Dispute path (design, not built)

Stated with V2's candor: **native mode must not serve slashable quorums until the
guest binding ships.** The design space, mapped:

- **Witness**: the guest ELF (or its hash + preimage availability), the gkExec
  input, and the *touched artifact pages + Merkle branches* — for the 0.6B model a
  full-answer replay touches essentially all ≈146k pages (~600MB + 84MB of
  branches), but a **single-segment dispute** (bisected to one decode step or one
  layer range, as the sharded-inference checkpoint chain already structures the
  computation) touches a bounded page set.
- **Inner execution**: two candidates, spike-gated. (a) An rv64im interpreter
  compiled *into* the SP1 guest — semantics-pinned, ~30–100× cycle blowup: at
  2.5–6G cycles/token that is 0.1–0.6T outer cycles per disputed token, which is
  why disputes bisect to segments first. (b) SP1's `untrusted_program`
  mprotect/W^X pattern executing the guest natively in-proof — potentially ~1×,
  but the pattern is documented for host-side execution and its in-proof viability
  is **unverified**; treated as a spike (M-series), not a promise.
- **Output binding**: free — guest output is the public-values commit stream.

This is THE open fraud-economics question of V3 and the doc's biggest honest
unknown. It does not block the PoC track, exactly as V2 overlays shipped ahead of
their guest binding under the same stance.

## Status and upstream dependencies

- **This directory** (consumer side): specified here; `GkVm.sol`, `GkVmFfiShim`,
  `tools/gk`, and the native chat example land on this branch's successor PR.
- **gas-analyzer**: #166 (UnboundedV1) and #168 (V2 overlays) open; **#172
  (LocalExecutor) is the substrate V3 stacks on** — the precompile is
  local-executor-only.
- **service**: #313/#319 (unbounded + LLM e2e) provide the harness a V3 consumer
  variant plugs into; #321 (sharded) provides the segment structure disputes want.
- **sp1-contract-call fork**: `ron/unbounded-env-overrides` carries the
  env-binding mechanism V3 extends; the V2 overlay binding is itself still
  unshipped — V3 joins that queue, it does not jump it.
- **alloy-rs/evm2**: 0.1.0, no releases, no crates.io, explicit no-stability
  notice; adoption lane below.
- **foundry** #11675 (odyssey removal) + `foundry-evm-networks` (Phase C target).
- **MicroPython** v1.28 QEMU `VIRT_RV64` port (the Python-guest substrate).

## Per-repo work plan

### gas-analyzer (stacked on #172)

1. `crates/core/src/gkvm.rs`: every `UNBOUNDED_V3_*` / `GKVM_*` constant,
   `gkvm_address()`, the manifest-v3 hasher, and the `env_commitment` V3 arm.
2. New workspace crate `crates/gkvm`: `GuestProgramSet` (mirrors
   `OverlayMountSet`: env-triplet load, hash verify, mmap, LRU),
   `ArtifactMountV3` (Merkle build/verify/page-serve), the SP1 executor wrapper
   (hostcalls, cycle budget, memo), and `bin/gk-run`.
3. `crates/evmsketch/src/gkvm_precompile.rs`: a `PrecompileProvider` wrapping
   `EthPrecompiles`, intercepting `GKVM_ADDRESS`; wired at `run_pass`
   (`local_exec.rs:806` region) and threaded as a new field through the single
   private funnel `call_to_encoded_state_updates_local_with_mounts` (+
   `call_view_local_multi`) — not a fifth parallel entry point.
4. Differential tests: ffi ≡ precompile golden fixtures; classify-stays-fast
   assertion; memo-hit; and the negative that documents the gate — an `rpc`
   executor hitting a V3 consumer yields the deterministic `GkVmUnavailable`
   revert transition.

### solidity-sdk (this repo, stacked on PR #56)

`src/gkvm/{GkVm.sol, GkVmErrors.sol}`; `test/GkVmFfiShim.sol`; `tools/gk`;
`src/examples/onchain-llm-native/{GasKillerChatNative.sol, guest/answer.py,
gen/GkAnswer.sol}`. `GasKillerChatNative.ask()` keeps the exact L103–112 shape of
`GasKillerChat.ask()` — staticcall, fold root, one `sstore(CHAT_ROOT_SLOT)`, one
event — with `engine.chat(...)` replaced by the generated binding.
`Qwen3.sol`/`Qwen3Engine.sol`/`DataContractLib.sol` are simply not deployed for
native consumers; they remain for V2 ones.

### service

`common/src/local_exec_shim.rs` re-exports the gkvm config types;
`common/src/validator.rs` threads `GuestProgramSet` into the existing
`analyze_transaction` dispatch (inside the existing `spawn_blocking`; guest
execution single-threaded per task — the commonware `worker_threads = 2`
starvation incident applies with force to multi-minute guest runs). A consumer
registry `requiresGuestVm` bit gates analysis on `executor == local ∧ program
installed` — the operational mitigation for the mixed-config fork risk below. Helm:
`global.guestPrograms` / `global.guestArtifacts` + initContainer; e2e:
`GK_E2E_CONSUMER=chat-native` variant (deploy script printing
`CHAT_NATIVE_TARGET=`, step-7a un-landability assert now expects
`GkVmUnavailable`, step-10c decodes `ChatAnswered` from the applied receipt).

### sp1-contract-call fork

Env-commitment V3 in `chain_config_hash_with_overrides`; the inner-VM +
paged-witness spike.

### evm2 lane (parallel, non-blocking)

evm2 is the **destination**, revm-31 the **vehicle**. Adoption follows the
`gk-fast-view` playbook exactly: an excluded crate pinned to a git rev (the solar
model), targeting the view/segment fast path first, gated by golden-fixture
differential CI against the revm-31 interpreter. The port is mechanical where it
matters — evm2 precompiles receive `&mut Evm` (strictly more capable than revm
31's provider), its inspectors are ported revm-inspectors (same prestate/DiffMode
builders the extraction pipeline speaks), and its LLVM JIT is the same lineage as
the revmc spike #172 already carries. Promotion to consensus executor has two
criteria, both external: differential CI green at scale, and an upstream
release on crates.io ending the no-stability era.

### PR DAG

```
this doc ──► M1 crates/gkvm (standalone)  ──► gas-analyzer precompile PR (on #172) ──► sdk PR ──► SP1 fork PR ──► Phase C RFC
                 ∥ micropython port spike                                            ──► service PR
                 ∥ evm2 lane (independent)
```

## Milestones

- **M1 — deterministic runner.** `gk-run` executes hello.c and hello.py ELFs with
  byte-identical output AND identical instruction counts across x86_64 + aarch64 ×
  {interp, jit} × 10 runs. Measures executor throughput both tiers → fills this
  doc's TBD cells and revalidates `CYCLES_PER_GAS = 4`.
- **M2 — forge loop.** `GkVmFfiShim` + vectors fixtures green; ffi output
  bit-identical to direct `gk-run`; golden-fixture diff in CI.
- **M3 — precompile parity.** The same task through the ffi shim and through
  `call_to_encoded_state_updates_local_with_mounts` yields identical encoded
  `StateUpdate` payloads and env commitments; classify pass records no fallback;
  memo hit on the second pass. Also: e2e wall-clock delta from dropping the 24,299
  `setCode` calls, measured.
- **M4 — the flagship number.** qwen.c guest + Qwen3-0.6B Merkle artifacts:
  cycles/token, gas at 4 cyc/gas, wall clock interp vs jit vs the 545.1B / ~9min
  baseline. Gate: **≥10× wall-clock, ≥20× gas reduction, jit ≡ interp counts at
  10^10-cycle scale.**
- **M5 — the DX promise.** `answer.py → gk build → forge test → local executor`
  with zero hand-written glue; a stories260K-class Python demo in CI (the 10.47B
  donor precedent, natively).
- **M6 — real operators.** `run_e2e_test.sh GK_E2E_CONSUMER=chat-native`,
  2-operator quorum, transition-count verification; negative test: an operator
  without the program **abstains** — the round stalls or degrades, but no
  divergent transition is ever signed.

## Risks and open questions

Ranked; mitigations inline.

1. **sp1-jit determinism across hosts is unproven.** M1 is the gate; on any
   divergence jit demotes to perf-preview and interp carries consensus (must then
   fit the 4h XL timeout — measured in M1).
2. **The SP1 pin is a much larger consensus surface than revm's.** Accepted cost
   of the "one codebase" invariant; upgrades are `GKVM_SPEC_VERSION` bumps
   coordinated like revm's.
3. **Mixed-config quorum fork (pre-existing gap, sharpened by V3).** The signed
   digest binds `(transitionIndex, target, selector, storageUpdates)` but **not
   the env commitment** — a mis-configured `rpc`-executor operator hitting a V3
   consumer deterministically produces the `GkVmUnavailable` *revert-fallback*
   transition and would sign it, competing with the honest quorum's result.
   Near-term: the service-side `requiresGuestVm` gate (refuse to analyze, never
   sign). Durable fix, recommended as its own message-format rev: **fold
   `env_commitment` into the signed digest**, making cross-env signatures
   unaggregatable. This gap exists today for V1/V2 (a `chain`-profile operator
   OOGs into the same fallback); V3 merely makes it deserve a name.
4. **MicroPython rv64im port effort.** The QEMU VIRT_RV64 port exists but
   UART/timer→hostcall adaptation, frozen-heap sizing, and mpz throughput are real
   work. Fallback that preserves every milestone except M5's language: C guests
   first, Python lands when the port does.
5. **Toolchain ABI mismatch.** succinct's linker script / entry conventions vs
   plain `riscv64-unknown-elf-gcc` output — `gk-guest-crt`'s job; verify early in
   M1.
6. **Guest-in-guest dispute blowup** (0.1–0.6T outer cycles/token via
   interpreter): bisect-to-segment first, `untrusted_program` spike second;
   inherited not-slashable stance bounds the exposure meanwhile.
7. **35B-MoE witness volume.** Hot-page witness for a segment dispute at 35GB of
   artifacts; page-size trade (4,096 vs chunk-aligned 24,575) is open.
8. **revm-31 provider details.** `is_static` visibility and revert-with-returndata
   through `PrecompileProvider::run` — verify at implementation start (M3 entry
   criterion).
9. **`vm.ffi` under STATICCALL** in forge (`dryRun` is `view`) — Phase A
   verify-at-impl.
10. **Operator hardware variance** affects wall clock only, never results —
    interp-tier worst case must fit the round timeout; M1/M4 quantify.

Open questions carried explicitly: page size 4,096 vs 24,575; multi-artifact
manifests day-1 vs single; whether `CYCLES_PER_GAS = 4` survives M1; in-proof
`untrusted_program` viability; the digest-binding message-format rev.
