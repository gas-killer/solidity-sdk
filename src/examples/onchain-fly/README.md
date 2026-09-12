# Fruit-fly-connectome AMM on Gas Killer

A plain x·y = k pool whose fee and directional skew are chosen every ~5-minute window by one 300 ms
episode of the **complete MaleCNS v1.0 fly brain** (166,700 neurons, 25,582,938 edges) simulated
on-chain, settled through Gas Killer as **one storage word**. Design: [HANDOFF.md](HANDOFF.md);
build log and measurements: [PROGRESS.md](PROGRESS.md).

| Contract | Role |
|---|---|
| `FlyEngine.sol` | Stateless, integer-only LIF kernel (Yul) over the chunked connectome; `step` / `decide` / `warmup` / `rasterize` / `checkArtifacts` / `genesisState`. Bit-for-bit twin of `tools/fly_int.py`. |
| `FlyPolicy.sol` | The Gas Killer consumer. `decide(FlyState)` is the ONLY tracked function: STATICCALLs the engine and writes one packed word to `FLY_SLOT`. |
| `FlyAMM.sol` | The pool. Never inherits the SDK; reads `FlyPolicy.params()` under hard clamps (fee ∈ [5,100] bps, skew ∈ ±30, staleness → 30 bps default). |
| `FlyTypes.sol` | `Observation`, `Stimulus`, `Readout`, `FlyState`. |
| `FlyTestToken.sol` | Mintable ERC20 for rehearsals. |
| `FlySwapPool.sol` (v2) | Per-swap intents: escrow + FIFO queue, `applyNext` executes each intent at its own fly-decided fee (HANDOFF_PER_SWAP.md). |
| `FlySwapPolicy.sol` (v2) | Gas Killer consumer: `settle(prev)` runs one episode per pending intent, writes one fill word per intent + the chained state. |
| `FlySwapRasterizer.sol` (v2) | Renders one intent (direction, size, slippage) + the per-epoch histogram onto the retina. |

## How a round works

1. Traders swap; the first swap in a new 25-block window closes the previous one (16-window histogram
   ring, TWAP, fee income, LP loss, closing spot). `FlyAMM.observe()` returns only that closed data.
2. A keeper (`tools/fly_keeper.py submit`) posts `decide(prev)` to the router (`POST /tasks`); `prev` is
   the `FlyState` of the last `FlyDecided` log (or `genesisState()`).
3. Operators simulate `decide` under the unbounded profile: rasterize the observation onto the 3,335
   R1-R6 photoreceptors, load the on-chain warm snapshot, run 3,000 steps of the brain, decode DNp20 /
   DNpe017 rates into fee / skew / rebalance, and sign the diff `[STORE(FLY_SLOT, word), LOG4(FlyDecided)]`.
4. `verifyAndUpdate` applies it; the pool's `effectiveFee` reads the word with one SLOAD.
5. Anyone replays the chain from logs: `tools/fly_keeper.py verify`.

## Measured (full graph, anvil, `tools/fly_anvil.py`)

| Call | Gas | Wall (anvil/revm) | Matches reference |
|---|---|---|---|
| `decide` 300 ms busy pool | 44.88 Ggas (149.6 Ggas / simulated second) | 44 s | readout + spikeRoot bit-exact |
| `decide` 300 ms empty pool | — | 40 s | bit-exact |
| `FlyPolicy.decide` as a transaction (rasterize + episode + settle) | 41.85 Ggas | 40.7 s | fee 55 bps, skew +10 → pool 65 / 45 bps |
| `checkArtifacts` (4,415 chunks) | 15.7 M | 0.01 s | passes (policy constructor) |
| `warmup(20000)` | 255.1 Ggas (127.6 Ggas / simulated second) | 250 s | stateOut == `artifacts/warm.bin` byte-for-byte |

The Solidity optimizer and via-IR do not change the kernel's cost (the hot loop is hand-written Yul);
a cheaper kernel is a v2 item (§3.8 tonic-cell sleeping, d=1 fast path, cached bases).

## Artifacts and tools

- `tools/fly_convert.py graph.npz outdir` → `ptr.bin` (28 chunks), `edges.bin` (4,165), `meta.bin` (3).
- `tools/fly_int.py` — THE reference (Python + `fly_int_core.c`); `warmup` subcommand writes `warm.bin` (219 chunks).
- `tools/fly_synth.py` + `tools/fly_validate.py synth` → `test/fixtures/onchain-fly/` vectors; `fly_validate.py full` → float-kernel parity gates.
- `../onchain-llm/tools/deploy_sepolia.py --blobs ptr.bin,edges.bin,meta.bin` / `--blobs warm.bin`,
  `verify_onchain_directory.py --engine-kind fly --warm-root …`, `deploy_anvil.py --blobs … --family 5|6`
  (the Qwen deploy tools, now multi-blob; the Qwen default `weights.bin,tokenizer.bin` plan is byte-identical).
- `tools/fly_anvil.py deploy|check|warmup|decide` — full-graph rehearsal against the reference, with gas via `debug_traceCall`.
- `tools/fly_keeper.py state|calldata|submit|verify|should-run` — the round keeper.
- `script/DeployOnchainFly.s.sol` — engine + tokens + pool + policy on top of uploaded directories
  (`FLY_GRAPH_ROOT`, `FLY_WARM_ROOT`, `FLY_CFG0..2` from `artifacts/fly_config.json`).

## Live on Sepolia (Gas Killer testnet, 2026-09-12)

| | |
|---|---|
| Graph / warm directory roots | `0xe7c83910719ea03d80f7dd71caee4489a0a05641` / `0x046b0eedf28701d257944c0c48d64ac2fc9666ac` |
| FlyEngine / FlyAMM / FlyPolicy | `0xB61fd991A4A6afAEf54404bA54DC6123d2B9E4fC` / `0x0147847039d35Aa489c6654C21F49b9b58c9ed50` / `0x3c749083688dEDb379c37071fC4bf3809B67Db6E` (100 ms episode) |
| First settled round | tx `0xa31b872ba627878210d7cbf4b0ce3281b5bc9e11b16818b19353e18ba144f450`, fee 36 bps / skew +1, operators' spikeRoot == reference |

See PROGRESS.md "Testnet run" for the fleet timings and the deployment gotchas (EIP-7825 tx cap → `FlyPolicyUnchecked`,
rendered-payload settlement tier, staleness clamp).

## v2: every swap priced by its own fly episode (live on Sepolia)

Pool `0xD9adC740c61c2362AA9649cDe79D1A20B537fa69`, policy `0x474c62c9931e5a501986f6E27AC4Cc084dFf9908`, rasterizer
`0x9caE2512890d5B46b5882CA25EFF78d7c24E2428`. `submit` escrows an intent; the keeper (`tools/fly_keeper2.py round`) sends
`settle(prev)` through the router, broadcasts the rendered `verifyAndUpdate`, then `applyUpTo` fills in queue order. Two
live rounds: #1 buy paid 33 bps (fly fee 31 +2), #2 sell paid 32 bps (fly fee 41 −9). Details in PROGRESS.md "v2".
The animation (`tools/fly_viz_build2.py`) replays each intent's episode from its on-chain log.

## Tests

```
forge test --match-path 'test/examples/Fly*.t.sol'
```

`FlyEngine.t.sol`: genesis, warm-up, step, exact segment composition, decide, rasterize, overlay parity,
tamper rejection, artifact checks, gas probe — all against `vectors.json`. `FlyAMM.t.sol`: windows and
storage-only `observe`, clamps, single-slot regression (`vm.record`), `verifyAndUpdate` applying the
`[STORE, LOG4]` diff, the commitment chain.

## Operator requirements

Unbounded profile (`GK_SIM_PROFILE=unbounded`, gas cap 2^40), an RPC with its execution cap lifted,
prestate tracer with `disable_code` so the 4,415 touched chunks never enter the payload, and
`ROUND_TIMEOUT` well above one episode (Helm sets 300 s; an episode is ~45 s in revm). Calldata is one
`FlyState` (≈ 350 B); the diff is one STORE plus one ~7 KB log.

## Honest limits

Deterministic and predictable (anyone with the reference knows the next fee minutes ahead); the fly does
not learn (ETA = 0); the DN readouts are an engineered BCI; the band and staleness clamps are caps, not
manipulation resistance. See HANDOFF §9.
