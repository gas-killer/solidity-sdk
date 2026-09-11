# HANDOFF: Fruit-Fly-Connectome AMM on Gas Killer (FlyEngine + FlyPolicy + FlyAMM)

> Provenance: written 2026-09-11 by a research → write → refute workflow (4 research lenses over doomfly and this SDK; 12 load-bearing claims re-verified against source or arithmetic, 4 corrected and applied). Every `file:line` citation into `src/`, `test/`, `script/`, `.context/tenop` and `.context/doomfly`, and every constant in §3.2 / §2.3 / §6, was then re-checked by hand at the worktree state of the same day. `.context/` is git-excluded (`.git/info/exclude`), so the `DOOM` paths need the doomfly clone at HEAD `71ecf53` on the machine that builds this. Nothing under `src/examples/onchain-fly/` exists yet except this file.

**What you are building and why it is feasible (10 lines)**

1. Three artifacts: (a) the complete MaleCNS v1.0 fly connectome (166,700 neurons, 25,582,938 edges) uploaded to Sepolia as DataContractLib data contracts behind a two-level directory, exactly as the Qwen3-0.6B weights were; (b) `FlyEngine`, a stateless, integer-only Solidity/Yul port of doomfly's LIF simulator reached by STATICCALL; (c) a two-contract consumer — `FlyPolicy is GasKillerSDK` (one mutable slot) and `FlyAMM` (a plain x·y=k pool that reads fee/skew/rebalance from `FlyPolicy` under hard clamps).
2. Each Gas Killer round runs one 300 ms "episode" of the fly brain from a committed warm snapshot, with the pool's closed-window flow histogram and price deviation rendered onto the fly's retina; descending-neuron readouts (DNp20 L/R, DNpe017 L/R) become `feeBps`, `skewBps`, `rebalance`.
3. Headline upload: ≈103 MB on-chain graph (4,193 chunks) ≈ 22.5 Ggas ≈ 29-30 Sepolia ETH ≈ 6 h at the measured 700 chunks/h; +219 chunks (≈1.17 Ggas, ≈1.5 ETH) for the warm snapshot.
4. Headline runtime: ≈12-29 Ggas per simulated brain-second (≈ one Qwen token at 28.6 Ggas); researcher opcode-count estimates range 22-52 Ggas/s (see §3.7 and §10 D6) — measure before quoting.
5. A 300 ms episode is therefore ≈4-16 Ggas: 16 s at in-process revm (1.0 Ggas/s), ~45 s under anvil `debug_traceCall` (0.35-0.40 Ggas/s), ≈1.5% of the 2^40 unbounded budget.
6. Everything the fly writes is one packed 32-byte word (fee, skew, flags, windowId, epoch, 160-bit state root) — the same single-slot shape that already settles live for the LLM consumers.
7. The pool never inherits GasKillerSDK, so a colluding 66% quorum can at worst pin the fee at `MAX_FEE` — never drain reserves.
8. The Qwen deployment already proved every piece of infrastructure: 24,364 CREATE chunks, resumable ledger deployer, codehash verifier, directory `_resolve` walk, single-slot settlement, 28.6 Ggas tracked calls.
9. Determinism is guaranteed operator-vs-operator (identical integer code), NOT vs doomfly's float32 kernel; a Python fixed-point twin (`tools/fly_int.py`) is the reference.
10. Honest status: the fly does not learn (doomfly's v6 plasticity failed its own gates), the fee policy is predictable minutes ahead, and the readouts are an engineered BCI — this is a deterministic biologically-derived controller, not a market oracle.

All repo paths below are relative to `/Users/wk/conductor/workspaces/solidity-sdk/monterrey-v3/`; `DOOM` = `.context/doomfly` (HEAD 71ecf53); `LLM` = `src/examples/onchain-llm`.

---

## 1. Context

### 1.1 Gas Killer (8 lines)
- EigenLayer-style AVS. Operators simulate a *tracked* contract call off-chain under the **unbounded profile** (gas limit 2^40 ≈ 1.1 Tgas per round, standard post-Berlin gas schedule — only the limit is pinned).
- A ≥66%-stake quorum (`src/GasKillerSDK.sol:38`, `QUORUM_THRESHOLD = 66`) BLS-signs the resulting state diff; `verifyAndUpdate(msgHash, quorumNumbers, referenceBlockNumber, storageUpdates, transitionIndex, targetFunction, sig)` (`:51-86`) settles it on-chain.
- Checks: `referenceBlockNumber < block.number` and `referenceBlockNumber + blockStaleMeasure(300) >= block.number` (`:41,63-64`); `transitionIndex + 1 == stateTransitionCount()` (`:67`); `msgHash == sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates))` (`:68-69`).
- The diff is applied by `StateChangeHandlerLib._runStateUpdates` (`src/StateChangeHandlerLib.sol:47-51`): STORE = blind `sstore(slot,value)` to ANY slot, no allowlist; CALL re-executes at real gas; CREATE supported by the lib.
- The **shape gate is off-chain** (analyzer/service unbounded profile, `LLM/RESEARCH.md:84-88`): ≤1 STORE (the `StateTracker` counter bump `src/StateTracker.sol:13-25` is exempt), no CREATE, LOGs pass, no block-environment reads, nothing that reverts on well-formed input. Violations kill rounds live ("payload shape violation ... found 2 Store ops", commit `8b4f4cc`).
- Tracked functions must be view/STATICCALL into a stateless engine; the consumer keeps tiny mutable state (a keccak commitment chain).
- Operator budget: `ROUND_TIMEOUT` 30 s default / 300 s Helm; transport cap `call_data + storage_updates <= 128 KB` (`LLM/TESTNET.md:69-71`). Measured settlement: 81,560 gas mock BLS, ~0.5 M real quorum (`LLM/README.md:50`).
- Measured operator throughput: anvil `debug_traceCall` 0.35-0.40 Ggas/s; in-process revm ~1.0 Ggas/s; one Qwen token = 28.6 Ggas.

### 1.2 The Qwen deployment — the worked template
| Item | Value |
|---|---|
| Artifact | Qwen3-0.6B weights, 597 MB, 24,364 CREATE data contracts (runtime `0x00 || payload`, 24,575-byte payloads) |
| Directory | 20 pages of 1,228 addresses; root **`0x9d1ddc25c098da26417d0a061b647f3a3511d7b0`** |
| Measured cost | 218.3 gas/payload byte all-in; 5,364,000 gas/full chunk; ~700 chunks/h at ~1.3 gwei; 130.78 Ggas / 171.97 ETH total (= 1.315 ETH/Ggas) |
| Deployer | `LLM/tools/deploy_sepolia.py` — resumable JSONL ledger (keys `c<i>`, `p<p>`, `root`), `verify_all` recomputes `keccak(0x00||payload)` against `eth_getProof.codeHash` (`:488-510`) |
| Verifier | `LLM/tools/verify_onchain_directory.py` — rebuilds the plan, re-derives pages/root from the ledger, optional `checkArtifacts(address,bytes32,bytes32[3])` call at 200 M gas (`:94-104`) |
| Pattern contracts | `LLM/DataContractLib.sol` (write/read/readInto/payloadLength), `Qwen3.sol` (`loadRange` `:214-231`, packed KV cache `:89,379-406`, int8 MAC `:252-293`), `Qwen3Engine.sol` (`_resolve` root→pages→chunks `:100-139`, `checkArtifacts` `:77-86`), `Qwen3SegEngine.sol` (sharded `forwardRange` with `expectXIn` witnesses `:50-58`), `GasKillerChat.sol` (monolithic consumer), `GasKillerChatSharded.sol` (settlement-only consumer, `settlePrefix`/`fulfilResumed` resume anchors) |
| Serving lesson | never serve a 28.6 Ggas call through a round if you can settle a commitment instead (`LLM/HANDOFF_DIRECTORY_MODE.md:296`); `checkArtifacts` over the real directory costs 104.3 M gas, so `GasKillerChatUnchecked.sol:12-16,63` skips it in the constructor |

### 1.3 doomfly (8 lines)
- `DOOM/doom/kernel.cpp` (56 lines, clang++ -O3, no fast-math, float32) runs the complete retained MaleCNS v1.0 graph: 166,700 neurons, 25,582,938 directed edges, 124,177,617 contacts.
- LIF: dt = 0.1 ms, τm = 20 ms, τg = 5 ms, rest −52 mV, threshold −45 mV (strict >), refractory 2.2 ms (22 steps), synaptic delay 1.8 ms (18 steps), weight = contacts × 0.275 mV × presynaptic transmitter sign. Brian2 oracle `DOOM/tests/test_doom_reference.py:21-25`.
- Inputs: 3,335 mapped R1-R6 photoreceptors driven by `30·L/(0.02+L)` mV from a 10 ms low-pass of frame luminance; 7,114 lamina cells at 12 mV tonic; 23 LB3c "sugar" cells at 30 mV on reward.
- Outputs (BCI decoder, `DOOM/doom/engine.py:120-125`): DNp20 R−L → turn, DNpe017 sum → forward/attack, 100 ms rate EMA.
- Live telemetry: ~537,000 spikes per simulated second, ~9,500-neuron active set, population rate ~3.3 Hz. Neural state persists across game episodes.
- Scientific status (honest): the readouts were "selected after observing responses ... an engineered brain-computer interface" (`DOOM/docs/doom-neuroscience-review.md` §5); DNa02/DNp09/MDN/MN9 were silent in the intact visual test; controls fire under black input because of lamina tonic drive (review `:296-299`).
- v6 plasticity (KC→MBON11, PPL101 dopamine) **failed its own validation gates** (`DOOM/docs/doom-learning-iteration-log.md:133-143`, `doom-live-training.md:53-56`; `survival.py` hard-codes `'survival_learning_demonstrated': False`). Treat doomfly as a deterministic controller, not a learner.
- `graph.npz` is **NOT in the clone** (only `outputs/doom/malecns_v1/manifest.json`); it must be rebuilt (§2.1).

---

## 2. Data pipeline

### 2.1 Source files (`DOOM/data-provenance/malecns_v1/source.lock.json`)
| File | URL | Bytes | sha256 |
|---|---|---|---|
| annotations.feather | https://storage.googleapis.com/flyem-male-cns/v1.0/connectome-data/flat-connectome/body-annotations-male-cns-v1.0-minconf-0.5.feather | 14,483,314 | `2177e246113e4cfbf1e7772ec37c6da1955ff22e8063d0b1f833101f99a9a3b2` |
| neurotransmitters.feather | https://storage.googleapis.com/flyem-male-cns/v1.0/connectome-data/flat-connectome/body-neurotransmitters-male-cns-v1.0.feather | 43,282,834 | `95c9289220663abeb3409f3ad9e5a7f8a53f8093f5139d15502cd08da8879621` |
| edges.feather | https://storage.googleapis.com/flyem-male-cns/v1.0/connectome-data/flat-connectome/connectome-weights-male-cns-v1.0-minconf-0.5.feather | 1,051,241,946 | `e35da783d1c686b2b58b3b87cd6a403ae43bfcfba8bff28e08ef752c1a56afc1` |

Build: download the three files into `DOOM/connectome_data/malecns_v1/`, verify sha256, run `python -m doom.connectome malecns_v1` (normalize) then `python -m doom.prepare` → `graph.npz` (exact sequence in §8 Phase 0), verify **sha256 `346b8af85a11af13b8324e18669812c1924569e7d1adcb4e6f45cc461a2c344b`** (`DOOM/outputs/doom/audit/data-integrity.json`). If the hash differs, stop: every index below (readouts, lamina, retina, LB3c, PPL101) depends on graph order.

### 2.2 Import policy (doomfly's, carried forward verbatim)
- Retain **all** edges: 25,582,938 including 101 self-edges and 10,299,701 single-contact edges. No thresholding.
- CSR by presynaptic index, stable argsort (`DOOM/doom/prepare.py:20-23`): `ptr` int64[n+1], `post` int32[E], `weight = fl32(fl32(count)·sign·fl32(0.275))` computed in float32 arithmetic via `count[order].astype(np.float32) * signs[pre[order]] * .275` (`prepare.py:23`; the trailing `.astype(np.float32)` is a no-op), with the constant itself rounded to float32: `fl32(0.275) = 0x3E8CCCCD = 9227469/2^25 ≈ 0.27500000596`. This is NOT the same as `fl32(fl32(count·sign)·0.275)` with an exact 0.275: e.g. count=3, sign=+1 gives 3·fl32(0.275) = 27682407/2^25, an exact tie that rounds-to-even to `0x3F533334` (0.82500004768), whereas fl32(3·0.275 exact) = `0x3F533333` (0.82499998808).
- Sign is a property of the **presynaptic neuron** (`prepare.py:22` `signs[pre[order]]`), from `DOOM/doom/transmitters.py:15-20`: `tokens = set(str(value).lower().split(','))`; `+1` if `acetylcholine` ∈ tokens; `−1` if tokens intersect `{gaba, glutamate, histamine}`; if exactly one set fired use it, otherwise (both/neither/missing/modulator-only) `ambiguous_sign`, which `prepare.py` leaves at its default `+1` — 3,718 "uncertain" cells (manifest).
- Graph index order = `graph.npz` order (sorted body ID). Never reorder; hash-check `ids`.
- Fixed indices (graph index / bodyId) from the manifest and `DOOM/outputs/doom/bci-readouts.json`:

| Readout | idx | bodyId | | Readout | idx | bodyId |
|---|---|---|---|---|---|---|
| DNp20 R | 48 | 10059 | | DNa02 R | 332 | 10360 |
| DNp20 L | 146 | 10162 | | DNa02 L | 131957 | 523769 |
| DNpe017 L | 489 | 10527 | | DNp09 L / R | 725 / 1087 | 10783 / 11177 |
| DNpe017 R | 142493 | 555871 | | MDN R,L,R,L | 706, 1196, 1240, 2194 | 10763, 11288, 11332, 12348 |
| PPL101 R / L | 1235 / 1774 | 11327 / 11900 | | MN9 L / R | 306 / 6367 | 10331 / 16949 |
| MBON11 L / R | 655 / 1306 | 10704 / 11402 | | | | |

Populations: retina 3,335 mapped R1-R6 (1,107 L / 2,228 R; 42 unmapped, 15 below 0.8 confidence); lamina 7,114 (L1/L2/L3/L5); sugar 23 LB3c; KC 4,064; modulatory 541 (v6 only; unused in v1).

### 2.3 On-chain artifact format (decision: **4-byte packed edges, per-neuron sign in ptr, 6,143 entries/chunk, 3 blobs + separate warm directory**)

Two directories (each: root page → pages of 1,228 × 20-byte addresses → chunks; byte-identical to `Qwen3Engine.sol:13-17` / `deploy_sepolia.py:234-247`), each blob restarting chunking at its own byte 0:

**graphRoot** = `[ptr.bin][edges.bin][meta.bin]`

| Blob | Content | Entries/size | Chunks |
|---|---|---|---|
| `ptr.bin` | uint32 BE entries, `[sign:1 (bit 31; 1 = inhibitory presynaptic) \| ptr:31]`, N+1 = 166,701 entries; entry N carries E with sign 0 | 666,804 B payload + pad | 28 |
| `edges.bin` | uint32 BE entries, `[post:18 (bits 31..14) \| count:14 (bits 13..0)]`, sorted by pre (CSR) | 25,582,938 entries | 4,165 |
| `meta.bin` | index tables (below) | ≈60 KB | ≤ 3 |

Chunk packing rule (load-bearing): each 24,575-byte chunk holds exactly **6,143 entries (24,572 B) + 3 zero pad bytes**, so no entry straddles a chunk. Entry k of a blob lives in chunk `k / 6143` at payload byte `4·(k mod 6143)`, i.e. EXTCODECOPY offset `1 + 4·(k mod 6143)` (STOP-byte skip). `deploy_sepolia.py` / `verify_onchain_directory.py` work unchanged on such blobs (they slice 24,575 B); the converter must emit the padding and the engine must use 6143, not 24575/4.

Count field: 14 bits (≤ 16,383). `DOOM/doom/connectome.py:41-42` permits uint32 counts, so the converter **must assert** the max; if any edge exceeds 16,383, split it into k entries to the same `post` with counts summing to the original — exactly equivalent (g adds linearly; both gated by the same refractory test). Splitting changes E and `ptr`; the engine reads N, E, chunk counts from the packed config, not constants. (Alternative 5-byte / 8-byte formats: §10 D1.)

Weight reconstruction on-chain: 0.275 = 11/40 exactly, so `w_Q24 = sign · (count · 23,068,672) / 5` (23,068,672 = 11·2^21; floor of magnitude; < 1 ulp Q24 error; float32's own weight error is up to 2.7e-4 mV at count 16,383). Fixed-point bonus: with unit 1/40 mV every weight is the integer 11·count·sign.

`meta.bin` layout (all BE; offsets declared in header so the engine never guesses):
```
[0]   u8  version = 1
[1]   u32 n            [5]  u32 nEdges         [9]  u16 entriesPerChunk = 6143
[11]  u16 delaySteps=18 [13] u16 rfcSteps=22   [15] u16 nReadouts
[17]  u32 offReadouts  [21] u32 offRetina  [25] u32 offLamina  [29] u32 offSugar  [33] u32 offPPL101
[37]  bytes32 keccak256(ids int64[n] LE bytes)          // provenance of graph order
[69]  bytes32 sha256(graph.npz)                          // must equal 346b8af8...
readouts : nReadouts × [u32 idx][u8 type][u8 side]      // the 14 manifest readouts in the converter's FIXED order (`ro` below: BCI four first — NOT manifest order, where DNp20/DNpe017 come last); type 0=DNp20 1=DNpe017 2=DNa02 3=DNp09 4=MDN 5=MN9; side 0=L 1=R
retina   : u32 count(3335) then count × [u32 idx][u16 uQ16][u16 vQ16]   // ascending idx (graph.npz `retina` order)
lamina   : u32 count(7114) then count × u32 idx
sugar    : u32 count(23)   then count × u32 idx (LB3c)
ppl101   : 2 × u32 idx (1235, 1774)
```
Decay tables are NOT stored (built at call entry from two Q64 constants, §3.2).

**warmRoot** = `[warm.bin]` — the exact `stateOut` wire format (§3.4) after 20,000 steps of black input from genesis under the port's own arithmetic; ≈5.38 MB → 219 chunks → 1 page + root. It is a function of `FlyEngine`'s numerics, so it lives in its own directory and is redeployed if the engine changes; the graph directory never changes.

### 2.4 Packed config (3 words, like `Qwen3.Config`)
```
cfg[0] = n(32) | nEdges(32) | ptrChunks(16) | edgeChunks(16) | metaChunks(16) | warmChunks(16) | delay(8) | rfc(8) | entriesPerChunk(16) | ...
cfg[1] = episodeSteps(16) | pulseSteps(16) | binSteps(8)=100 | alphaQ16(16)=41427 | decayQ16(16)=59299 | eta(16)=0 | ...
cfg[2] = minFeeBps(16)=5 | maxFeeBps(16)=100 | maxSkewBps(16)=30 | rebalSkewBps(16)=30 | rebalThresholdBps(16)=25 | devRefBps(16)=50 | maxLagWindows(8)=2 | volBarRows(16)=440 | ...   // design targets only (§4.5), no source yet
```
`FlyEngine._resolve` computes the three (four) per-blob `address[]` slices from `ptrChunks/edgeChunks/metaChunks` exactly as `Qwen3Engine._resolve` splits into two (`:121-138`); reverts `MalformedDirectory` on surplus/deficit. `checkArtifacts` sums `DataContractLib.payloadLength` per blob against the expected lengths and checks `meta[0] == 1` (≈4,208 chunks ≈ 22 M gas — fits in a constructor/eth_call, unlike Qwen's 104.3 M).

### 2.5 Converter sketch — `LLM/tools/fly_convert.py`
```python
#!/usr/bin/env python3
"""graph.npz -> ptr.bin / edges.bin / meta.bin (+ fly_manifest.json). 4-byte BE entries, 6,143 per 24,575-byte chunk."""
import hashlib, json, struct, sys
import numpy as np

CHUNK, EPC = 24_575, 6_143            # payload bytes, entries per chunk (24,572 used + 3 pad)
MAXC = (1 << 14) - 1                   # 16,383

def pack_entries(u32: np.ndarray) -> bytes:
    out = bytearray()
    for s in range(0, len(u32), EPC):
        out += u32[s:s + EPC].astype('>u4').tobytes() + b'\0\0\0'
    return bytes(out)

def main(npz, outdir):
    g = np.load(npz)
    ptr, post, w = g['ptr'], g['post'], g['weight']
    n, E = len(ptr) - 1, len(post)
    assert ptr[0] == 0 and ptr[-1] == E and np.all(np.diff(ptr) >= 0)
    count = np.rint(np.abs(w) / np.float32(0.275)).astype(np.int64)
    assert np.all(np.abs(count.astype(np.float32) * np.float32(0.275) - np.abs(w)) < 1e-3), "weight not count*0.275"
    pre = np.repeat(np.arange(n), np.diff(ptr))
    neg = w < 0
    # sign is per presynaptic neuron (prepare.py:22): every edge of a pre must agree
    pre_neg = np.zeros(n, bool); pre_neg[pre[neg]] = True
    assert not np.any(neg != pre_neg[pre]), "per-edge sign disagrees with per-neuron sign"
    print("max count", count.max(), "max out-degree", np.diff(ptr).max())
    # split rows with count > 16,383 into equivalent multi-entries
    reps = np.maximum(1, -(-count // MAXC))
    post2 = np.repeat(post, reps); pre2 = np.repeat(pre, reps)
    c2 = np.repeat(count, reps)
    first = np.r_[0, np.cumsum(reps)[:-1]]
    idx_in_group = np.arange(len(post2)) - np.repeat(first, reps)
    c2 = np.where(idx_in_group < reps.repeat(reps) - 1, np.minimum(c2, MAXC),
                  c2 - MAXC * (reps.repeat(reps) - 1))
    assert np.all((c2 >= 1) & (c2 <= MAXC)) and np.all(np.bincount(pre2, c2, n) == np.bincount(pre, count, n))
    E2 = len(post2)
    ptr2 = np.r_[0, np.cumsum(np.bincount(pre2, minlength=n))].astype(np.uint64)
    assert ptr2[-1] == E2 < (1 << 31) and n < (1 << 18)
    edges = (post2.astype(np.uint64) << 14) | c2.astype(np.uint64)
    ptrw = (pre_neg.astype(np.uint64) << 31) | ptr2[:-1]
    ptrw = np.r_[ptrw, np.uint64(E2)]                          # entry N: E, sign 0
    open(f'{outdir}/ptr.bin', 'wb').write(pack_entries(ptrw.astype(np.uint32)))
    open(f'{outdir}/edges.bin', 'wb').write(pack_entries(edges.astype(np.uint32)))
    # ---- meta.bin
    ids = g['ids'].astype('<i8').tobytes()
    ro = [(48,0,1),(146,0,0),(489,1,0),(142493,1,1),(332,2,1),(131957,2,0),(725,3,0),(1087,3,1),
          (706,4,1),(1196,4,0),(1240,4,1),(2194,4,0),(306,5,0),(6367,5,1)]   # (idx,type,side) DNp20,DNpe017,DNa02,DNp09,MDN,MN9
    body = bytearray()
    offR = 101; body += b''.join(struct.pack('>IBB', *r) for r in ro)
    offRet = offR + len(body)
    uv = np.clip(np.rint(g['uv'] * 65535), 0, 65535).astype(np.uint16)
    ret = struct.pack('>I', len(g['retina'])) + b''.join(struct.pack('>IHH', int(i), int(u), int(v))
                                                        for i, (u, v) in zip(g['retina'], uv))
    body += ret; offLam = offR + len(body)
    body += struct.pack('>I', len(g['lamina'])) + g['lamina'].astype('>u4').tobytes(); offSug = offR + len(body)
    body += struct.pack('>I', len(g['sugar'])) + g['sugar'].astype('>u4').tobytes(); offPPL = offR + len(body)
    body += struct.pack('>II', 1235, 1774)
    from eth_utils import keccak as keccak_256   # same dependency as deploy_sepolia.py:31
    hdr = struct.pack('>BIIHHHH IIIII', 1, n, E2, EPC, 18, 22, len(ro), offR, offRet, offLam, offSug, offPPL)
    hdr += keccak_256(ids) + hashlib.sha256(open(npz,'rb').read()).digest()
    assert len(hdr) == 101
    open(f'{outdir}/meta.bin', 'wb').write(hdr + body)
    json.dump({'n': n, 'nEdges': E2, 'nEdgesOriginal': E, 'maxCount': int(count.max()), 'maxOutDegree': int(np.diff(ptr2).max()),
               'ptrChunks': -(-(n+1)//EPC), 'edgeChunks': -(-E2//EPC),
               'sha256': {f: hashlib.sha256(open(f'{outdir}/{f}','rb').read()).hexdigest() for f in ('ptr.bin','edges.bin','meta.bin')}},
              open(f'{outdir}/fly_manifest.json','w'), indent=1)

if __name__ == '__main__': main(sys.argv[1], sys.argv[2])
```
Expected: ptr 28 chunks, edges 4,165 chunks (if no splits), total 4,193 chunks ≈ 103.03 MB; +≤3 meta chunks.

### 2.6 Deploy tooling — multi-blob change to `deploy_sepolia.py` / `verify_onchain_directory.py` (validated by the sdk-integration researcher on a scratch copy: byte-identical `Plan.payload(i)` for the default two blobs; the live ledger's 24,364 confirmed `c<i>` records equal the new plan's `[24299, 65]`)

Apply as a tracked commit (the two tools are currently untracked — they are the provenance record of a 171.97 ETH deploy; keep the default `--blobs weights.bin,tokenizer.bin` so the Qwen ledger stays reproducible):
- `Plan.__init__(paths: list)` replaces the two hardcoded files; `self.lens`, `self.n_per`, `self.starts` (cumulative), `blob_of(i) = bisect_right(starts, i) - 1`; `payload(i)` seeks `(i - starts[k]) * CHUNK` in blob k; keep `w_len/t_len/n_w/n_t` as back-compat properties.
- `--blobs` argparse option (`DEFAULT_BLOBS = "weights.bin,tokenizer.bin"`), `blob_paths(artifacts_dir, csv)` helper; `run()` estimate `n_full = sum(max(n-1,0) for n in n_per)`.
- `verify_onchain_directory.py`: import `DEFAULT_BLOBS, blob_paths`, add `--blobs`, build `Plan(blob_paths(...))`; add `--engine-kind fly` calling `FlyEngine.checkArtifacts(address,bytes32,bytes32[3])` (same selector shape as `:96`).
- `deploy_anvil.py:79-81` iterates `for blob in (weights, tok)` — give it the same `--blobs` list.

Invocations:
```
python3 LLM/tools/deploy_sepolia.py --artifacts .context/fly/artifacts --blobs ptr.bin,edges.bin,meta.bin --key-file ... --ledger .context/fly/deploy-ledger
python3 LLM/tools/deploy_sepolia.py --artifacts .context/fly/artifacts --blobs warm.bin --key-file ... --ledger .context/fly/warm-ledger
python3 LLM/tools/verify_onchain_directory.py --artifacts .context/fly/artifacts --blobs ptr.bin,edges.bin,meta.bin --ledger .context/fly/deploy-ledger --engine <FlyEngine> --engine-kind fly
```
Reuse the Qwen wrapper pattern (`deploy-run.sh`, resumable ledger, `settle_mined`, `verify_all`) unchanged.

---

## 3. Simulator port spec (FlyEngine)

Scope: a `view` engine, zero storage, graph read via EXTCODECOPY, all arithmetic integer, so every operator produces the identical output. `tools/fly_int.py` mirrors it bit-for-bit (as `tools/qwen3_int.py` mirrors `Qwen3.sol`). It is **not** bit-exact with `kernel.cpp` (float32, `dt = 0.1f` so its constants are `exp(-0.1000000015/20)`, order-dependent g summation, `std::exp` beyond d = 1024).

### 3.1 Exact semantics (from `DOOM/doom/kernel.cpp`, dense reference `DOOM/doom/engine.py:13-48`)
Constants: N = 166,700; DELAY = 18; RFC = 22; SLOTS = 19; REST = −52 mV; THRESH = −45 mV (strict `>`); τm = 20 ms; τg = 5 ms; a(d) = e^(−d/200), b(d) = e^(−d/50), c(d) = (a−b)/3 (exactly τg/(τm−τg) = 5/15); sleep bound GAP = 7 mV; lamina tonic 12 mV; receptor gain 30, half-saturation 0.02; sugar 30 mV.

ODE (`DOOM/tests/test_doom_reference.py:22-23`): `dv/dt = (REST − v + I + g)/τm`, `dg/dt = −g/τg`, I constant over the interval. Closed form over d steps: `g(d) = g0·b(d)`; `v(d) = REST + (v0−REST)·a(d) + I·(1−a(d)) + g0·c(d)` (verified vs RK4 to 1e-13).

`evolve(i, now, I)` (`kernel.cpp:15-23`):
```
d = now − last[i]; if d ≤ 0: return
frozen = refr[i] > 0 ? refr[i] − 1 : 0;  skip = min(d, frozen)
refr[i] = (d ≥ refr[i]) ? 0 : refr[i] − d;  d −= skip
if d > 0: v = REST + (v−REST)·a(d) + I·(1−a(d)) + g·c(d);  g = g·b(d)
last[i] = now
```
Refractory = R means R−1 frozen steps; step s+22 after a reset at s is the first integrated+tested step.

Per call `advance(steps)` with drive[] fixed for the call:
- (P) pre-pass (`:26-28`): for every i with `drive[i] != previous_drive[i]` (exact compare): `evolve(i, clock−1, previous_drive[i]); previous_drive[i] = drive[i]; awaken(i)`.
- per step: (1) `slot = clock mod 19; future = (clock+18) mod 19`. (2) Threshold pass over the active-list snapshot (`original` entries): `evolve(i, clock, drive[i])`; if `refr==0 && v > THRESH`: push i to `queue[future]`, `counts[i]++`. `can_fire = v > THRESH || drive > 7 || drive+g > 7`; keep if can_fire else `flags[i]=0` (in-place compaction). No reset yet. (3) Deliver `queue[slot]` (spikes from clock−18) in queue order; for each CSR edge: `j = post[e]; evolve(j, clock, drive[j]); if refr[j]==0 { g[j] += w[e]; awaken(j) }` — arrivals to refractory targets are **dropped**. (4) `queue_count[slot]=0`. (5) Reset every i in `queue[future]`: `v=REST, g=0, refr=22` (after delivery, so a same-step arrival to a just-fired neuron is wiped — Brian2 parity, deliberate). (6) `clock++`.
- (M) materialize (`:55`): for all i: `evolve(i, clock−1, drive[i])`.
- `counts[]` zeroed by the caller before every call (`native.py:29`).

Timing: a spike at step s is delivered at s+18 and first influences v at s+19.

Sleep bound is exact: `v(d)−REST` is a convex combination of `(v0−REST)`, `I`, `(I+g0)` (b = a^4, 4a−a^4 ≤ 3), so a neuron with all three ≤ 7 can never cross −45 until an event, and every event calls `awaken`. Active-list membership is a scheduling optimization, not semantic state — but the port keeps the C iteration order (active-list order, ring FIFO, CSR edge order) so `stateOut` bytes are canonical.

### 3.2 Fixed-point choices (decision: Q24 int64 state, Q64 tables, round-half-up)
| Quantity | Format | Rationale |
|---|---|---|
| v, g | int64 Q24 (in 64-bit fields) | float32 near −50 mV has ulp 3.8e-6 mV; Q24 (5.96e-8) is 64× finer; v can transiently reach ≈ −709 mV (a 16,383-contact inhibitory edge) and g thousands of mV — int32 Q16 would be marginal |
| drive I | int32 Q16 | input parameter, quantized at the source |
| weight | Q24 on the fly | `sign·(count·23,068,672)/5` |
| a_d, b_d, c_d | uint Q64, one per word | `v·a` is Q88 in 128 bits; `rhu64(x) = sar(64, x + 2^63)`; drive term `I(Q16)·(2^64−a)` = Q80 → `rhu56` |
| last | uint48 | 890 years of steps |
| refr | uint8 (0..22) | |
| count | uint32 | per-window spikes, zeroed at entry |

Constants: `R_Q24 = −52<<24 = −872,415,232`; `THR_Q24 = −45<<24 = −754,974,720`; `BOUND_Q16 = 7<<16 = 458,752`; `BOUND_Q24 = 7<<24`; `A1 = floor(e^(−1/200)·2^64) = 18354740553814661001` (0xfeb923493e945789); `B1 = floor(e^(−1/50)·2^64) = 18081474067879353234` (0xfaee4cdd6f62db92); `C1 = (A1−B1)/3 = 91088828645102589`; `W_NUM = 23,068,672`.

Tables built at call entry (3 × 1,025 words = 98 KB, ~60 kgas): `tA[0]=tB[0]=2^64; tA[d]=rhu64(tA[d−1]·A1); tB[d]=rhu64(tB[d−1]·B1); tC[d]=(tA[d]−tB[d])/3` (floor). Drift at d=1024: 99 ulp Q64 (5.4e-18 relative). Far decay (d > 1024): `q = d>>10, r = d&1023; a = rhu64(tA[1024]^q)·tA[r]` by square-and-multiply (≤9 multiplies), `b` likewise; `b := 0` for d ≥ 2,219; `a := b := c := 0` for d ≥ 8,873 (Q64 underflow points 50·64·ln2 = 2,218.07 and 200·64·ln2 = 8,872.28).

Evolve, integer:
```
d = now − last                          // now ≥ last validated at entry
if d == 0: return
if refr > 0: frozen = refr−1; skip = min(d, frozen); refr = (d ≥ refr) ? 0 : refr−d; d −= skip
if d > 0: (a,b,c) = tbl(d)
          v = R + rhu64((v−R)·a) + rhu56(I·(2^64−a)) + rhu64(g·c)
          g = rhu64(g·b)
last = now
```
Why round-half-up: floor gives a −1.5 ulp/step bias amplified by the contraction 1/(1−a) = 200 to 1.8e-5 mV; rhu random-walks to ~5 ulp = 3e-7 mV. Measured on a 3,000-step toy (Q24/Q64/rhu vs exact Decimal vs float32): tonic I=30: 39/39/39 spikes, identical spike steps, max|Δv| 1.25e-6 mV (fixed) vs 1.07e-4 (float32); I=12: 15/15/15, 3.0e-6 vs 1.8e-4; random EPSP train: 7/7/7, 7.9e-7 vs 4.6e-5. The port is 50-100× closer to real arithmetic than the C kernel is. Stuck zone: with rhu, |v−R| settles at 100 Q24 ulp, g at ~25 ulp, never 0 — harmless; the dense 32 B/neuron encoding is deliberate (no sparse state).

Spike-order sensitivity: a step flips only if v is within Δ≈1e-4 mV of threshold at a step boundary; P(flip) ≈ 1e-3..7e-3 per spike, ~300 primary flips per 300 ms window, chaotic growth thereafter. Hence: rasters identical for the first ~10 ms, per-neuron trains usually identical, population statistics equivalent, raster equality NOT claimed (§7.2 gates).

### 3.3 EVM memory layout (all bases compile-time constants)
Per-neuron 32-byte word:
```
bits 255..192 v int64 Q24   sar(192, w)          | bits 191..128 g int64 Q24  signextend(7, shr(128, w))
bits 127..96  drive int32 Q16 signextend(3, shr(96, w)) | bits 95..64 count uint32  count++ = add(w, shl(64,1))
bits 63..16   last uint48   and(shr(16,w), 0xffffffffffff) | bits 15..8 refr uint8 | bits 7..0 flags (bit0 = in active list)
```
| Region | Words | Notes |
|---|---|---|
| scratch/ABI head | 4 | |
| STATE: header(1) + slotCount[19] packed (3) + 166,700 neuron words | 166,704 | the working region IS the returned `stateOut` |
| ACTIVE uint32[N] packed 8/word | 20,838 | in-place compaction, C style |
| RING uint32[N] FIFO | 20,838 | single FIFO + `slotCount[19]`; because RFC(22) > DELAY(18) a neuron has ≤1 spike in flight, so N entries never overflow; avg occupancy ≈ 970 |
| PTR uint32[N+1] packed | 20,838 | copied from the 28 ptr chunks at entry |
| TBL tA,tB,tC | 3,075 | |
| DIR 4,208 × 20 B packed | ≈2,630 | `shr(96, mload(...))` |
| EDGE_SCR ≤3 chunks | 2,304 | stream chunk by chunk |
| misc | ~64 | |
| **total** | **≈237,300** | 7.59 MB; expansion 3w + w²/512 ≈ **110.7 Mgas** per call (state words alone 54.8 M) |

Implementation rules (load-bearing): `stateIn`/`driveIn` stay `calldata` and are `calldatacopy`'d once; the return is hand-built ABI + `return(ptr,len)` in assembly. Letting Solidity abi-copy a 5.3 MB `bytes memory` doubles words → ~320 Mgas. Four `int256[]` state arrays would cost ≈0.87 Ggas of expansion alone (`Qwen3.sol:89,379-406` learned this). Packed uint32 write: `mstore(sub(p,28), or(and(mload(sub(p,28)), not(0xffffffff)), x))`. The fused evolve+event loop will hit via-IR stack-too-deep (`Qwen3.sol:262-263`); keep evolve a Yul function with ≤ ~12 live locals or split unpack→compute→repack.

### 3.4 Wire format of `stateIn`/`stateOut`/`warm.bin` (≈5,376,508 B)
```
[0,32)        header: version u8 | N u32 | clock u48 | nActive u32 | inflight u32 | ringHead u32 (rest 0)
[32,128)      slotCount[19] packed uint32 (76 B, zero padded)
[128,128+32N) neuron words, index order
then          active ids uint32 × nActive (list order)
then          ring uint32 × inflight (FIFO order, head first)
```
Genesis (`genesisState()`, pure): clock = 1, every word v=R, g=0, drive=0, count=0, last=0, refr=0, flags=0; nActive = 0; inflight = 0 (native.py's `last=−1/cursor=0` is equivalent up to the +1 offset; the drive pre-pass awakens driven cells exactly as `kernel.cpp:26-28`, so `engine.py:74-76`'s pre-seeded active set is unnecessary). Entry: verify `expectStateIn`; calldatacopy/EXTCODECOPY words into STATE; scan all N words merging the sorted `driveIn` (new ≠ stored → evolve(i, clock−1, stored); store; awaken); zero `count`; **revert if `last ≥ clock`** (guards the unsigned d against tampered state). Exit: evolve all N at clock−1, linearize active + ring, hash.

### 3.5 Signatures
```solidity
contract FlyEngine {
    string  public constant DOMAIN         = "gaskiller.fly.engine.v1";
    string  public constant OVERLAY_DOMAIN = "gaskiller.fly.overlay.v1";   // distinct from gaskiller.llm.overlay.v1
    string  public constant SEG_DOMAIN     = "gaskiller.fly.seg.v1";

    /// General kernel: advance the brain nSteps × 0.1 ms from an explicit state (continuous mode, v2 sharding).
    /// driveIn = COMPLETE sorted set of nonzero drives, 8 B each: uint32 id || int32 Q16 mV (absent => 0; engine.py:88 drive.fill(0)).
    function step(address graphRoot, bytes32 manifest, bytes32[3] calldata cfg,
                  bytes calldata stateIn, bytes calldata driveIn, uint32[] calldata readoutIds,
                  uint256 nSteps, bytes32 expectStateIn)
        external view returns (bytes memory stateOut, uint32[] memory readoutCounts, bytes32 chk);
    // chk = keccak256(abi.encode(keccak256(DOMAIN), keccak256(stateIn), keccak256(driveIn),
    //        keccak256(abi.encodePacked(readoutIds)), nSteps, keccak256(stateOut), keccak256(abi.encodePacked(readoutCounts))))

    /// AMM entry (v1): warm snapshot from warmRoot, static frame, D = episodeSteps, per-10 ms bins.
    struct Stimulus { uint16 punishSteps; uint16 rewardSteps; }                 // PPL101 +4 mV / LB3c 30 mV windows from step 0
    struct Readout  { uint32[4] rateMilliHz; uint32[4] spikesLast30ms; uint32[14] windowCounts; uint64 totalSpikes; }
    function rasterize(address graphRoot, bytes32[3] calldata cfg, FlyAMM.Observation calldata o)
        external view returns (bytes memory frame);                            // 3,335 × uint16 Q16 luminance, ~1 M gas, pure given meta
    function decide(address graphRoot, address warmRoot, bytes32[3] calldata cfg,
                    bytes calldata frame, Stimulus calldata stim, uint32[4] calldata rates0)
        external view returns (Readout memory r, bytes32 spikeRoot);
    // spikeRoot = keccak256(abi.encode(keccak256(DOMAIN), keccak256(frame), stim, rates0, keccak256(stateOut), r))

    function warmup(address graphRoot, bytes32[3] calldata cfg, uint256 steps)  // 20,000 black steps from genesis
        external view returns (bytes memory stateOut, bytes32 warmCommitment);  // warmCommitment = keccak256("gaskiller.fly.amm.warm.v1" ‖ keccak(stateOut))
    function checkArtifacts(address graphRoot, address warmRoot, bytes32[3] calldata cfg) external view;
    function genesisState(bytes32[3] calldata cfg) external pure returns (bytes memory);
    function overlayChunkAddress(bytes32 manifest, uint256 i) public pure returns (address);  // keccak256(OVERLAY_DOMAIN, manifest, uint64(i))
}
```
`decide` internally = load warm state (EXTCODECOPY 219 chunks into STATE), then for each 100-step (10 ms) bin: update the 3,335 luminance filters (`Lf += (41427·(L−Lf)) >> 16`, ALPHA_Q16 = round((1−e^(−1))·65536) = round(41426.65)), build drive (retina `(30·Lf<<16)/(1311+Lf)` Q16 with 0.02·65536 = 1310.72 → 1311; lamina `12<<16`; +`4<<16` on PPL101 ('dan' in `survival.py:50-51`) idx 1235/1774 while `bin·100 < punishSteps`; `30<<16` on the 23 LB3c/sugar while `< rewardSteps`), run the pre-pass, run 100 steps, read the 4 BCI readout `count` fields (diff vs previous bin) and update the Q16 EMA (§4.3, DECAY_Q16 = 59299). At the end: materialize, record 14 window counts, hash.

### 3.6 Inner loop (Yul sketch, one step's delivery; `now`, `slot`, `head`, `nActive` locals; bases constants)
```yul
let nDeliver := shr(224, mload(add(SLOTCNT, shl(2, slot))))
for { let q := 0 } lt(q, nDeliver) { q := add(q, 1) } {
    let i := shr(224, mload(add(RING, shl(2, head))))
    head := add(head, 1) if eq(head, N) { head := 0 }
    let p0 := shr(224, mload(add(PTR, shl(2, i))))
    let p1 := shr(224, mload(add(PTR, shl(2, add(i, 1)))))
    let neg := shr(31, p0)
    let e := and(p0, 0x7fffffff)  let e1 := and(p1, 0x7fffffff)
    for {} lt(e, e1) {} {
        let ci := div(e, 6143)  let within := mod(e, 6143)
        let take := sub(6143, within)  if gt(take, sub(e1, e)) { take := sub(e1, e) }
        let chunk := shr(96, mload(add(DIR, mul(add(ci, PTR_CHUNKS), 20))))
        extcodecopy(chunk, EDGE_SCR, add(1, shl(2, within)), shl(2, take))
        let end := add(EDGE_SCR, shl(2, take))
        for { let sp := EDGE_SCR } lt(sp, end) { sp := add(sp, 4) } {
            let edge := shr(224, mload(sp))
            let j := shr(14, edge)
            let w := div(mul(and(edge, 0x3fff), 23068672), 5)          // Q24 magnitude
            if neg { w := sub(0, w) }
            // ---- evolve(j, now, drive_j) inlined
            let wp := add(STATE_WORDS, shl(5, j))
            let word := mload(wp)
            let last := and(shr(16, word), 0xffffffffffff)
            let refr := and(shr(8, word), 0xff)
            let v := sar(192, word)
            let g := signextend(7, shr(128, word))
            let d := sub(now, last)
            if d {
                if refr {
                    let frozen := sub(refr, 1)  let skip := frozen  if lt(d, frozen) { skip := d }
                    switch lt(d, refr) case 1 { refr := sub(refr, d) } default { refr := 0 }
                    d := sub(d, skip)
                }
                if d {
                    let a, b, c
                    switch lt(d, 1025)
                    case 1 { a := mload(add(TA, shl(5, d)))  b := mload(add(TB, shl(5, d)))  c := mload(add(TC, shl(5, d))) }
                    default { a, b, c := farDecay(d) }
                    let I := signextend(3, shr(96, word))
                    v := add(add(add(R_Q24, sar(64, add(mul(sub(v, R_Q24), a), HALF64))),
                                     sar(56, add(mul(I, sub(ONE64, a)), HALF56))),
                             sar(64, add(mul(g, c), HALF64)))
                    g := sar(64, add(mul(g, b), HALF64))
                }
            }
            // ---- synaptic add + awaken (kernel.cpp:45); refractory targets drop the arrival
            let flags := and(word, 0xff)
            if iszero(refr) {
                g := add(g, w)
                if iszero(and(flags, 1)) {
                    flags := or(flags, 1)
                    let ap := add(ACTIVE, shl(2, nActive))
                    mstore(sub(ap, 28), or(and(mload(sub(ap, 28)), not(0xffffffff)), j))
                    nActive := add(nActive, 1)
                }
            }
            mstore(wp, or(or(or(shl(192, and(v, M64)), shl(128, and(g, M64))), and(word, MID128)),
                          or(shl(16, now), or(shl(8, refr), flags))))
        }
        e := add(e, take)
    }
}
// slotCount[slot] = 0
```
The sweep (`kernel.cpp:32-40`) uses the same inlined evolve with a1/b1/c1 as stack constants (d = 1 for an active neuron), then `if and(iszero(refr), sgt(v, THR_Q24))`: ring push at tail, `count++`; `canFire := or(sgt(v, THR_Q24), or(sgt(I, BOUND_Q16), sgt(add(shl(8, I), g), BOUND_Q24)))`; keep ⇒ packed write at `kept++`, else clear flag. After delivery, walk `ring[tailBefore, tail)` and reset those words to v=R, g=0, refr=22 (C order), then `slotCount[(now+18) % 19] = tail − tailBefore`.

### 3.7 Per-op gas model (opcode counts × 1.4 stack overhead, calibrated to a 48 gas/int8 MAC figure for Qwen3 vs ~35 core that is itself unmeasured against any Foundry gas snapshot; expect ±30% until one exists)
| Operation | Core ops | Gas |
|---|---|---|
| evolve hot path (d=1, refr=0) | 189 | ~270 (no-op path d=0: ~50; +40 refractory; +150 far decay) |
| synaptic event (edge in scratch) | | ~360 cold target / ~140 already-evolved target |
| spike detection (ring push, count++, can_fire, later reset) | | ~60 + ~25 |
| spike delivery setup (ring pop, ptr, chunk index, EXTCODECOPY 100 warm + 3/word) | | ~335 warm; +2,500 if chunk cold; +~110 amortized for the 2.5% of fan-outs straddling chunks |
| active-neuron sweep step | | ~360 |
| per-step fixed | | ~100 |

Per simulated second at telemetry (9,500 active, 537k spikes/s, 50 M events/s = 93 effective fan-out — spiking cells are lower-degree than the 153.5 mean):
```
sweep   9,500 × 10,000 × 360 = 34.2 Ggas (65%)
events  50,000,000 × 360     = 18.0 Ggas (34%)
spikes  537,000 × 335        =  0.18 Ggas
total                        ≈ 52.4 Ggas / simulated second (52.38 G; × 0.3 s = 15.71 Ggas per 300 ms episode)   (kernel-design)
```
Other researchers: sdk-integration ≈50 Ggas/s (20 propagation + 28 sweep); amm-design ≈22 typical (10 sweep at ~100 gas/step + 12 events at ~150 gas) / ~40 bright-frame worst case; given headline 12-29 (a separate, unverified estimate). The disagreement is the per-op cost (100-360 gas/evolve), unmeasured against any Foundry gas snapshot — §10 D6. Per-call fixed: memory expansion 110.7 M + entry scan 2.5 M + exit materialization (166,700 × 270 ≈ 45 M) + hashing ~4 M + cold chunks ~10 M (touched = 4165·(1−(1−1/4165)^k) = 3,739/3,932/4,051 chunks for k = 9.5k/12k/15k distinct spiking pre-neurons) + 33 cold accounts (root, pages, 28 ptr chunks) 85.8 k + warm load 219 chunks ≈ 1.1 M ≈ **175 Mgas**.

Budget: 2^40 = 1,099,511,627,776 ≈ 1,099.5 Ggas → ≤ ~21 simulated seconds per call even at 52.4 Ggas/s. Practical bound is wall clock, not budget.

### 3.8 Analytic next-spike alternative (evaluated, rejected for v1)
With x = e^(−d/200) and e^(−d/50) = x⁴ exactly (τm/τg = 4), the crossing `v(d) = THR` is the quartic `(g0/3)x⁴ − (v0−R−I+g0/3)x + (THR−R−I) = 0`; Ferrari is useless in fixed point, and we need the first integer step. v(d) has at most one extremum at `x³ = A/(4B)` (verified: predicted peaks 92.4/99.4 vs observed 92/99 steps), so first crossing by integer bisection over the tables (~11 evals × 70 gas + a Q64 cube root ≈ 1.0 kgas per reschedule) plus a heap over ~10k pending events (~560 gas/op). Every synaptic event invalidates its target's schedule → ~1.9 kgas × 50 M = 95 Ggas/s — **worse** than the sweep. The only profitable subset: event-free tonic drivers (I > 7, no pending g — essentially the R1-R6, ~36% of the active set; ISI = 22 + ceil(200·ln(I/(I−7))) steps: 76 at I=30, 109 at I=20, 198 at I=12) → ~23% total saving. v1 ships the sweep (exact mirror of kernel.cpp); v2 may add tonic-cell sleeping, which must be trajectory-identical by construction.

### 3.9 How a decision spans rounds (decision: **stateless episodes from a warm snapshot**, continuous brain deferred)
- Every round: `decide` loads `warm.bin` (20,000 black steps from genesis, the same 2 s equilibration `DOOM/doom_learning_v6/survival.py:28` uses), then runs D = `episodeSteps` (default **3,000 = 300 ms**; cfg-tunable, 5,000 is the amm-design alternative) with the static frame; reward pulses occupy steps [0, 2000).
- Cross-round continuity is exactly three things, all in the previous round's logged `FlyState`: the 4 decoder EMA seeds (`rateMilliHz`), the pulse flags, and `prevWord` (commitment chain).
- Why not a continuous brain: the 5.38 MB state cannot go in the log (8 gas/byte ≈ 43 M; 128 KB transport cap) nor be CREATE'd in-round (shape gate); it would live off-chain behind a keccak root — precisely the overlay-availability problem `HANDOFF_DIRECTORY_MODE.md` §1 eliminated — and it serializes rounds (a timed-out round stalls the chain). `step()` + `SEG_DOMAIN` checkpoints (`chk` chaining like `Qwen3Seg.sol:155-177`) remain available for a v2 continuous/sharded mode with `settlePrefix`-style warm anchors (`gaskiller.fly.amm.resume.v1`) and periodic state checkpoints into data contracts (219 chunks, ~1.17 Ggas, ~1.5 ETH each).
- Wall clock per round at 300 ms: 16 s revm / 45 s anvil (kernel-design numbers) — one AMM decision per ~1 min; the fly runs at ~0.5-2% of real time.

---

## 4. AMM design

### 4.1 Pool choice: CPMM with fly-controlled dynamic fee + directional skew (chosen)
A round's on-chain effect is a blind, whole-word `sstore` applied up to 300 blocks after the reference block, with no consumer hook at apply time (`verifyAndUpdate` is `external`, not `virtual`). Anything the fly writes must be (i) valid regardless of swaps landed in between, (ii) bounded so a wrong/stale/colluded value cannot drain LPs, (iii) one slot. Reserves/prices/LP balances fail (i)-(ii); policy parameters pass all three.
- Rejected: RFQ / fly-quoted prices (multi-minute rounds → stale quotes = free option for searchers).
- Deferred (v2): fly oracle wrapping an existing pool (e.g. Uniswap v4 hook reading `FlyPolicy.params()`); the slot layout is designed so a hook can consume it unchanged.
- Chosen: `FlyAMM` = x·y = k; `feeBuy = clamp(fee + skew)`, `feeSell = clamp(fee − skew)`; `fee ∈ [MIN_FEE=5, MAX_FEE=100] bps`, `skew ∈ [−30, +30] bps`; `rebalance` flag overrides skew to `±REBAL_SKEW = 30 bps` surcharging trades that move spot AWAY from TWAP. LP downside per epoch ≤ (MAX_FEE − MIN_FEE) × epoch volume; the fly chooses a fee in a governance band, never a price.
- Two contracts because a 66% quorum can STORE to ANY consumer slot including the SDK's own `blsSignatureChecker`/`avs` slots: `FlyPolicy` holds zero funds; `FlyAMM` clamps everything it reads. **Do not merge them.**

### 4.2 Sensory encoding: pool state → 3,335 R1-R6 drives (baseline model; R8 chroma channel deferred, §10 D4)
`Observation` (storage reads only, no block env): `uint32 windowId` (last CLOSED window), `uint64[16] buyQuote`, `uint64[16] sellQuote` (fee-paid quote volume per closed window, oldest..newest), `uint64 volRef` (EMA of window volume, α = 1/8), `uint128 spotQ64`, `uint128 twapQ64` (cumulative-price TWAP over the closed window, as of last swap), `uint64 feeIncomeQuote`, `uint64 lpLossQuote = max(0, x0·P + y0 − x1·P − y1)` with (x0,y0) reserves at window open, (x1,y1) at close, P = twap.

Procedural virtual canvas 640×480 (matches `RES_640X480`; sampling uses (w−1),(h−1) exactly as `DOOM/doom/game.py:93`), luminance Y(x,y) ∈ Q16 [0, 65535]:
- Rows [0, 40): deviation strip. `dev = (spot − twap)/twap` in bps; if dev > 0 the LEFT half (x < 320) is lit at `min(|dev|/DEV_REF, 1)·65535`, else the RIGHT half; DEV_REF = 50 bps. (Decision made here so price deviation reaches the retina without the v6 R8 path.)
- Rows [40, 480): histogram. Left half: 16 buy bars, bar i at x ∈ [20i, 20i+20); right half x ∈ [320, 640): 16 sell bars. `h_i = 440·min(vol_i, volRef)/volRef`; lit rows y ∈ [480 − h_i, 480) at 65535. Lit area left ≈ buy pressure, right ≈ sell pressure; the overlapping eye viewports (L u ∈ [0, 0.6], R u ∈ [0.4, 1]) make this what DNp20 R−L can react to.
- Sampling per receptor: `xQ16 = u_Q16·639`, `yQ16 = v_Q16·479`; `x0 = xQ16>>16`, `x1 = min(x0+1, 639)`, `dx = xQ16 & 0xffff` (likewise y); `L = ((65536−dx)(65536−dy)·Y(y0,x0) + dx(65536−dy)·Y(y0,x1) + (65536−dx)dy·Y(y1,x0) + dx·dy·Y(y1,x1)) >> 32` — bilinear exactly as `retinal_samples` (`game.py:92-100`).
- Stated deviation from doomfly: the canvas is generated in linear units, so the sRGB→linear decode is skipped and R1-R6 sample luminance directly (a real RGB frame would leak channels through 0.2126/0.7152/0.0722). Everything downstream (10 ms filter with `ALPHA_Q16 = 41427` = round((1−e^(−1))·65536) = round(41426.65) per 100-step bin, `drive = (30·Lf<<16)/(1311 + Lf)` with 0.02·65536 = 1310.72 → 1311 in Q16, lamina 12 mV) is the doomfly definition (`engine.py:86-93`, `native.py:26-28`). 42 unmapped R1-R6, R7, ocelli get no drive — as in doomfly.
- Frame is static for the whole episode (as in doomfly's static-stimulus assays); the filter updates every 10 ms bin. The frame is 3,335 × uint16 = 6,670 B and is emitted in the log so spectators can re-render it.

### 4.3 Readout → parameters (mirrors `engine.py:111-125`, integer)
Per 10 ms bin, for r ∈ {DNp20 R (48), DNp20 L (146), DNpe017 L (489), DNpe017 R (142493)}: `raw_mHz = binCount·100_000`; `rate = (rate·DECAY_Q16 + raw·(65536 − DECAY_Q16)) >> 16`, `DECAY_Q16 = 59299` (= round(e^(−0.1)·65536) = round(59299.43); 59300 is only reachable with ceil — the rounding rule must be pinned identically in `fly_int.py` and `FlyEngine`); seeded from `prev.rateMilliHz` (the one deliberate continuity), terminal value persisted.
- `turn_m = clamp(120·(rateR − rateL)/1000, −6000, 6000)` (= clip(0.12·(R−L), ±6) in milli-units) → `skewBps = turn_m·MAX_SKEW_BPS/6000`.
- `fwd_m = clamp(400·(rateDNpe017L + rateDNpe017R)/1000, 0, 20000)` (= clip(0.4·Σ, 0, 20)) → `feeBps = MIN_FEE + fwd_m·(MAX_FEE − MIN_FEE)/20000` ∈ [5, 100].
- `rebalance = (DNpe017 spikes in the final 3 bins > 0) && |spot − twap| > REBAL_THRESHOLD (25 bps)`. The pool-side deviation guard gives it meaning: in the game "attack" fires whenever DNpe017 is active, so it is correlated with fee level.
- Rate floor / fallback (kernel-design risk 13): if all four rates are 0 the formulas yield fee = MIN_FEE, skew 0 — acceptable but degenerate; `FlyAMM` additionally falls back to `DEFAULT_FEE = 30 bps` when the decision is stale (§4.6). Budget a calibration pass on the rasterizer gains by watching DNp20/DNpe017 responses (exactly the post-hoc BCI calibration doomfly did).

### 4.4 Reward hooks (stimulation, not learning)
At the START of the next episode (the stateless analogue of "next tic", `survival.py:55`): if `prev.flags & PUNISH` (lpLossQuote > 0 in the observed window) → PPL101 idx 1235, 1774 `drive += 4<<16` for steps [0, 2000) (`survival.py:50`); if `prev.flags & REWARD` (feeIncomeQuote > 0) → LB3c 23 cells `drive = 30<<16` for [0, 2000) (`reward.py`, `native.py:28`). `ETA = 0` immutable in v1: the KC→MBON11 rule (`DOOM/doom_learning_v6/rule.py`) is never executed, the engine runs BASELINE physiology (uniform −52 rest, no adaptation, PPL101 delivering with its default sign). A v2 with ETA > 0 is a new engine deployment (v6 physiology: KC rest −60, adaptation 8 mV/200 ms, tonic 9.87/11.3125, DAN baseline 20.09 Hz, per-bin `rule.advance`, persisted `int16[4184] memoryU/W` ≈ 16.7 KB per round in the log).

Defensible sentence: "FlyAMM's fee policy is a deterministic function of on-chain pool state computed by a full-connectome (166,700-neuron, 25.6 M-edge) LIF simulation whose reinforcement inputs are driven by realized LP loss and fee income through identified PPL101/LB3c cells; every parameter is reproducible by anyone from chain state alone; the fly does not learn and is not claimed to understand markets."

### 4.5 Epoch / settlement model
Persisted struct (in the LOG; verified next round against the slot):
```solidity
struct FlyState {
    bytes32 prevWord;        // the packed word this decision replaced (commitment chain)
    uint32 epoch;            // rounds settled
    uint32 windowId;         // closed window this decision observed
    uint16 feeBps;  int16 skewBps;  uint8 flags;   // bit0 rebalance, bit1 punishNext, bit2 rewardNext
    uint32[4] rateMilliHz;   // terminal 100 ms decoder filter: DNp20 R, DNp20 L, DNpe017 L, DNpe017 R
    bytes32 memoryRoot;      // keccak256("") while ETA == 0
}
```
ONE app slot `FLY_SLOT`, packed 256 bits (PROPOSED, not yet implemented; bit budget 160+24+32+8+16+16 = 256, self-consistent): `feeBps[255:240] | skewBps[239:224] | flags[223:216] | windowId[215:184] | epoch[183:160] | stateRoot160[159:0] = low 160 bits of keccak256(abi.encode(FlyState))`. Params in the high 96 bits are readable by the pool with one SLOAD; the full struct is in the log (part of the signed payload). The band constants (fee ∈ [5,100] bps, skew ∈ [−30,30], REBAL_SKEW 30, REBAL_THRESHOLD 25 bps, DEFAULT_FEE 30, MAX_LAG_WINDOWS 2, WINDOW_BLOCKS 25) and the cfg[2] fields (§2.4) are design targets chosen here, not inherited from or measured against any existing code.

### 4.6 Trader-facing flow
- Windows: `WINDOW_BLOCKS = 25` (~5 min). The first swap in a new window closes the previous one (shifts the 16-bin histogram, snapshots reserves, finalizes TWAP/feeIncome/lpLoss; ~30-40 k extra gas once per window). Bins accumulate fee-paid quote volume (1 SLOAD+SSTORE per swap).
- Trigger: an off-chain keeper (the AVS router client) submits `decide(prev)` once per window (cron) and when `WindowClosed` reports `volume > 4·volRef` or `|spot − twap| > REBAL_THRESHOLD`; `prev` is read from the last `FlyDecided` event. Because `observe()` returns only the CLOSED window, any reference block inside a window yields the same diff (no cherry-picking within a window).
- Reads: `FlyAMM.swap` → `effectiveFee` reads `policy.params()`; applies them iff `currentWindowId − decision.windowId ≤ MAX_LAG_WINDOWS (2)` and fee within band; otherwise `DEFAULT_FEE = 30 bps`, skew 0, no rebalance. No timestamp in the tracked path.
- Timeout: no quorum within `ROUND_TIMEOUT` ⇒ nothing signed, no footprint; keeper retries next window; params decay to defaults after `MAX_LAG_WINDOWS`. `decide` never reverts on well-formed input (all math clamped); only `StateMismatch`/`WindowNotClosed` revert (operators sign nothing). Concurrent submissions serialize on `transitionIndex`.
- `addLiquidity/removeLiquidity` are ordinary and never touch `FlyPolicy`.

### 4.7 Solidity interface (proposed; not yet implemented — see §4.5)
```solidity
// Constants
bytes32 constant FLY_DOMAIN  = keccak256("gaskiller.fly.amm.policy.v1");
bytes32 constant WARM_DOMAIN = keccak256("gaskiller.fly.amm.warm.v1");
bytes32 constant FLY_SLOT    = keccak256(abi.encode(uint256(keccak256("gaskiller.FlyPolicy.flyWord")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant MEMORY_ROOT_ZERO = keccak256("");

contract FlyPolicy is GasKillerSDK {
    IFlyEngine public immutable engine;  address public immutable graphRoot;  address public immutable warmRoot;
    FlyAMM public immutable pool;  bytes32 immutable cfg0; bytes32 immutable cfg1; bytes32 immutable cfg2;
    event FlyDecided(uint256 indexed transitionIndex, bytes32 indexed flyWord, bytes32 indexed spikeRoot,
                     FlyState next, bytes frame, IFlyEngine.Readout readout);
    error StateMismatch(); error WindowNotClosed();
    constructor(address avs, address bls, IFlyEngine e, address gRoot, address wRoot, bytes32[3] memory cfg, FlyAMM p)
        GasKillerSDK(avs, bls) { ...; _validateArtifacts(); }                   // virtual hook; calls engine.checkArtifacts (~22 M gas, fine)
    function decide(FlyState calldata prev) external trackState;                // the ONLY tracked function
    function params() external view returns (uint16 feeBps, int16 skewBps, bool rebalance, uint32 windowId, uint32 epoch);
    function flyWord() external view returns (bytes32);
    function pack(FlyState memory s) public pure returns (bytes32);
    function dryRun(FlyState calldata prev) external view returns (FlyState memory next, bytes32 word);  // operator/test twin
}

contract FlyAMM {   // ordinary pool, NOT a Gas Killer consumer
    struct Observation { uint32 windowId; uint64[16] buyQuote; uint64[16] sellQuote; uint64 volRef;
                         uint128 spotQ64; uint128 twapQ64; uint64 feeIncomeQuote; uint64 lpLossQuote; }
    function swap(bool buyBase, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out);
    function addLiquidity(uint256 base, uint256 quote, address to) external returns (uint256 lp);
    function removeLiquidity(uint256 lp, address to) external returns (uint256 base, uint256 quote);
    function observe() external view returns (Observation memory);          // closed window only; storage reads only
    function effectiveFee(bool buyBase) public view returns (uint16 bps);   // clamps FlyPolicy.params(), staleness, rebalance override
    event WindowClosed(uint32 indexed windowId, uint64 buy, uint64 sell, uint64 feeIncome, uint64 lpLoss, uint128 twapQ64);
}
```
Tracked function:
```solidity
function decide(FlyState calldata prev) external trackState {
    bytes32 word = flyWord();
    if (uint160(uint256(word)) != uint160(uint256(keccak256(abi.encode(prev))))) revert StateMismatch();
    FlyAMM.Observation memory o = pool.observe();                                   // STATICCALL, storage-only
    if (o.windowId <= prev.windowId) revert WindowNotClosed();                       // one decision per closed window
    bytes memory frame = engine.rasterize(graphRoot, [cfg0,cfg1,cfg2], o);
    IFlyEngine.Stimulus memory s = IFlyEngine.Stimulus({
        punishSteps: (prev.flags & 2) != 0 ? 2000 : 0, rewardSteps: (prev.flags & 4) != 0 ? 2000 : 0 });
    (IFlyEngine.Readout memory r, bytes32 spikeRoot) =
        engine.decide(graphRoot, warmRoot, [cfg0,cfg1,cfg2], frame, s, prev.rateMilliHz);  // the Ggas call, STATICCALL
    int256 turn = _clamp(int256(120) * (int256(uint256(r.rateMilliHz[0])) - int256(uint256(r.rateMilliHz[1]))) / 1000, -6000, 6000);
    uint256 fwd  = _clampU(400 * (uint256(r.rateMilliHz[2]) + r.rateMilliHz[3]) / 1000, 0, 20000);
    FlyState memory next;
    next.prevWord = word; next.epoch = prev.epoch + 1; next.windowId = o.windowId;
    next.skewBps = int16(turn * MAX_SKEW_BPS / 6000);
    next.feeBps  = uint16(MIN_FEE_BPS + fwd * (MAX_FEE_BPS - MIN_FEE_BPS) / 20000);
    bool rebal = (r.spikesLast30ms[2] + r.spikesLast30ms[3]) > 0 && _absDevBps(o.spotQ64, o.twapQ64) > REBAL_THRESHOLD_BPS;
    next.flags = (rebal ? 1 : 0) | (o.lpLossQuote > 0 ? 2 : 0) | (o.feeIncomeQuote > 0 ? 4 : 0);
    next.rateMilliHz = r.rateMilliHz; next.memoryRoot = MEMORY_ROOT_ZERO;
    bytes32 newWord = pack(next);
    assembly ("memory-safe") { sstore(FLY_SLOT, newWord) }                          // the ONE consumer write
    emit FlyDecided(stateTransitionCount(), newWord, spikeRoot, next, frame, r);
}
function pack(FlyState memory s) public pure returns (bytes32) {
    uint256 w = uint256(uint160(uint256(keccak256(abi.encode(s)))));
    w |= uint256(s.epoch & 0xFFFFFF) << 160; w |= uint256(s.windowId) << 184;
    w |= uint256(s.flags) << 216; w |= uint256(uint16(s.skewBps)) << 224; w |= uint256(s.feeBps) << 240;
    return bytes32(w);
}
```
Pool-side read (the clamp is the real security boundary):
```solidity
function effectiveFee(bool buyBase) public view returns (uint16) {
    (uint16 fee, int16 skew, bool rebal, uint32 wid,) = policy.params();
    if (_currentWindowId() - wid > MAX_LAG_WINDOWS || fee < MIN_FEE_BPS || fee > MAX_FEE_BPS) return DEFAULT_FEE_BPS;
    skew = _clampI16(skew, -MAX_SKEW_BPS, MAX_SKEW_BPS);
    if (rebal) skew = _spotAboveTwap() ? int16(REBAL_SKEW_BPS) : -int16(REBAL_SKEW_BPS);   // surcharge away-from-TWAP direction
    int256 f = int256(uint256(fee)) + (buyBase ? skew : -skew);
    return uint16(uint256(_clamp(f, MIN_FEE_BPS, MAX_FEE_BPS)));
}
```

### 4.8 Adversarial notes
- Determinism ⇒ predictability: anyone with a bit-exact twin (~20 s) knows the next fee when the window closes, minutes before apply; searchers route around fee changes; the band bounds it.
- Steering: wash trades shape bars at cost ≥ MIN_FEE × wash volume; bars saturate at `volRef`; gain ≤ (MAX_FEE − MIN_FEE) × later volume and the lowered fee is public. Feasible for a whale; no resistance claimed.
- Reference-block/window selection: keeper picks which closed window gets decided within the 300-block stale measure; `MAX_LAG_WINDOWS = 2` caps it.
- Operator collusion (≥66%): any word into `FLY_SLOT` (⇒ any fee in band) and overwrite of `FlyPolicy`'s SDK config slots; cannot touch `FlyAMM` funds. Fraud is detectable by anyone (deterministic); slashing is the AVS's job.
- Front-running the apply tx: fee deltas per epoch are small by clamp; optional one-epoch lag.
- The settlement delay (decision lands ≥1 block after the window closes, in a tx the attacker does not control) is the only mitigation against atomic steer-and-execute. No commit-reveal, no private input, no VRF — do not promise any.

---

## 5. Gas Killer integration

- Consumer pattern = `GasKillerChat.sol` (immutables for engine/roots/config `:30-46`; `_validateArtifacts` virtual `:112-119`; tracked function = STATICCALL engine + one `sstore` + one event `:128-137`) with the invariants of its natspec `:13-18`: only `FLY_SLOT` mutates; inference is a STATICCALL into a stateless engine; graph bytes are EXTCODECOPY reads never in the payload; **no block-environment reads** (use `stateTransitionCount()` as epoch); inputs are calldata.
- `decide` is the ONLY `trackState` function on `FlyPolicy`, so user swaps never bump the counter and invalidate an in-flight round (`GasKillerSDK.sol:67`). Any second `sstore` (even a "harmless" mapping write) makes the consumer unsettleable — add the `vm.record`/`vm.accesses` regression (`test/examples/OnchainChat.t.sol:122-138`) on day one, allowing only `FLY_SLOT | TRACKER_SLOT`.
- Payload operators extract: exactly `[STORE(FLY_SLOT, newWord), LOG3(FlyDecided...)]` + the exempt tracker bump; `msgHash = sha256(abi.encode(transitionIndex, address(policy), FlyPolicy.decide.selector, storageUpdates))` (`OnchainChat.t.sol:140-169` shows the encoding). Calldata = `FlyState` (≈288 B) — far under the 128 KB cap.
- Commitment chain: `FLY_SLOT` word ← `pack(next)`; `next.prevWord` = the word it replaced; `stateRoot160` covers the whole struct including `prevWord`, `spikeRoot` (engine commitment over frame/stimulus/seeds/final state/readouts) is in the log. Anyone can replay: genesis word (0) + the sequence of `FlyDecided` logs + `pool.observe()` at each reference block ⇒ recompute every word.
- Request JSON (operator side; keep the sharded schema's shape, `.context/tenop/shard06_req.template.json:3-15`, renamed):
```json
{
  "_comment": "FlyPolicy.decide round. directory mode: graph_root/warm_root are live roots, manifest = 0.",
  "consumer": "0x<FlyPolicy>",
  "fly_engine": "0x<FlyEngine>",
  "graph_root": "0x<graphRoot>",
  "warm_root": "0x<warmRoot>",
  "manifest": "0x0",
  "packed_config": ["0x..", "0x..", "0x.."],
  "n_neurons": 166700, "n_edges": 25582938, "entries_per_chunk": 6143,
  "delay_steps": 18, "refractory_steps": 22, "episode_steps": 3000, "bin_steps": 100,
  "readouts": [48, 146, 489, 142493],
  "prev_state": { "prevWord": "0x..", "epoch": 0, "windowId": 0, "feeBps": 30, "skewBps": 0, "flags": 0,
                  "rateMilliHz": [0,0,0,0], "memoryRoot": "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470" },
  "target_function": "decide((bytes32,uint32,uint32,uint16,int16,uint8,uint32[4],bytes32))",
  "time_segments": 1
}
```
`stimulus` is NOT an input — it is derived from `pool.observe()` at the reference block (a witness at most). `time_segments > 1` and `argmax_shards` are v2 (sharded `step()` over time segments; keep the tenop rule that units cover every operator so nobody has zero executed segments and refuses to sign).
- Operator requirements (reuse what the Qwen deploy established): unbounded profile (gas limit 2^40), operators run their own node; prestate tracer `diff_mode: true, disable_code: true` so touched chunks never enter the payload (`HANDOFF_DIRECTORY_MODE.md:203`); `ROUND_TIMEOUT` 30 s default / **300 s Helm** — at 45 s/round under anvil the Helm value is required; in-process revm (1.0 Ggas/s) preferred, and its code cache must retain the ~3,900 distinct chunk blobs (96-103 MB) across rounds (I/O, not gas, is the practical bottleneck); `blockStaleMeasure` 300 blocks must exceed round wall-clock (it does: 45 s ≪ 300 × 12 s). Model identity (roots, cfg) can be per-request fields (as `weights_root/manifest` are for the LLM router: `.context/tenop/shard06_req.directory.json:2`) — but for v1 they are immutables on `FlyPolicy`, so the request is a witness.

---

## 6. Costs

### 6.1 Upload (Sepolia; measured constants: 218.3 gas/byte, 5,364,000 gas/full chunk, ~700 chunks/h at ~1.3 gwei, 1.315 ETH/Ggas from 171.97 ETH/130.78 Ggas)
| Blob | Chunks | Gas (derived) | ETH (derived) | Time |
|---|---|---|---|---|
| ptr.bin | 28 | 0.15 G | 0.2 | 2 min |
| edges.bin | 4,165 | 22.3 G | 29.4 | 6.0 h |
| meta.bin | ≤3 | 0.02 G | 0.02 | — |
| **graphRoot total** (+4 pages + root) | **4,193 + 5** | **≈22.5 G** | **≈29-30** | **≈6.0 h** |
| warm.bin (5.38 MB) + page + root | 219 + 2 | ≈1.17 G | ≈1.5 | ≈19 min |
| **everything** | ≈4,420 | ≈23.7 G | ≈31 | ≈6.3 h |

Alternatives (not chosen): 5-byte edges (E=5) 127.9 MB / 27.9 Ggas / 36.7 ETH / 7.5 h; 8-byte edges 204.7 MB / 44.7 Ggas / 58.8 ETH / 12 h; amm-design's full package (graph + neuron/retina tables + warm snapshot) ≈5,310 chunks / 28.5 Ggas / 37 ETH / 7.6 h.

### 6.2 Per decision (D = 3,000 steps = 300 ms; all estimates, ±30%)
| Source | Ggas/sim-s | Episode gas | Wall @ revm 1.0 Ggas/s | Wall @ anvil 0.35-0.40 |
|---|---|---|---|---|
| given headline (separate, unverified estimate) | 12-29 | 3.6-8.7 + 0.18 fixed | 4-9 s | 10-25 s |
| amm-design | ~22 typical / ~40 bright | 6.6-12 + 0.18 | 7-12 s | 17-35 s |
| sdk-integration | ≈50 | ≈15 | 15 s | 38-43 s |
| kernel-design | 52.4 (52.38) | 15.7 (52.38 × 0.3 = 15.71) | 16 s | 40-45 s |

Fixed per call ≈175 Mgas (memory expansion 110.7 M dominant). A 1 s episode at 52.4 Ggas/s = 52.6 Ggas = 53 s revm / 150 s anvil — exceeds the 30 s default `ROUND_TIMEOUT`, fits 300 s Helm. Qwen scale: 300 ms fly ≈ 0.56 Qwen tokens (28.6 Ggas). `checkArtifacts` on the fly directory ≈22 M gas (4,208 chunks) — constructor-safe. The 48 gas/int8 MAC calibration and the 360 (vs 100) gas/op figures remain unmeasured against any Foundry gas snapshot (D6).

### 6.3 Settlement
| Item | Gas |
|---|---|
| `verifyAndUpdate` with mock BLS (measured, chat) | 81,560 |
| with real quorum check | ~0.5 M |
| live sharded `fulfil` (measured) | 350-384 k, 16-31 s |
| FlyDecided log data (~288 B struct + 6,670 B frame + readout) | +~60 k (8 gas/byte) |
| with a 16.7 KB memory blob (v2, ETA > 0 only) | +~0.3 M |

---

## 7. Validation plan

1. **Reference Python re-implementation in fixed point** — `LLM/tools/fly_int.py`: same Q24/Q64/rhu arithmetic, same iteration order (active list, ring FIFO, CSR), same pre-pass/materialize schedule, same wire format, same rasterizer/decoder integer formulas. It is THE reference; `FlyEngine.sol` must match it byte-for-byte on `stateOut`, `readoutCounts`, `chk`/`spikeRoot`. Implement the hot loop in numpy/numba or a C twin (pure Python on 166,700 neurons × 3,000 steps is too slow for iteration).
2. **Spike-train agreement fly_int.py vs `kernel.cpp` (statistical, full graph, 300 ms from the same genesis and drive)** — gates:
   - first 100 steps (10 ms): spike raster identical (bins and neuron ids);
   - per-neuron voltages at step 100: |Δv|, |Δg| ≤ 0.002 mV (doomfly's own parity bar, `tests/test_doom_reference.py:44-46`);
   - over 300 ms: total spike count within 3% (kernel-design: "a few %"), active-set size within 3%, each of the 14 readout window counts within ±3·√max(N, 10) (Poisson), population rate consistent with ~3.3 Hz / ~537k spikes/s telemetry;
   - raster-level equality after ~10 ms is NOT a gate (chaotic divergence from ~1e-3 step-flip probability per near-threshold spike).
3. **Synthetic-graph forge tests** — `test/examples/FlyEngine.t.sol`, copying `OnchainChat.t.sol:44-78` (fixtures via `vm.readFileBinary`, `DataContractLib.write(_slice(...))`, one page, one root; `MockBLSSignatureChecker` from `OnchainLLM.t.sol:19-34`). `tools/fly_synth.py`: n = 64, ~600 edges mixed signs incl. autapses, delay 18, rfc 22, 8 input neurons, 4 readouts, one edge with count > 16,383 (exercise the split); `fly_int.py` emits `vectors.json` `{packedConfig, frame, stimulus, episodeSteps, readoutCounts, totalSpikes, stateChkHex, perStep:[{v,g}]}`. Tests: (1) `decide`/`step` bit-exact vs vectors; (2) `step([0,t1)) ∘ step([t1,T)) == step([0,T))` and the `chk` chain reproduces the monolithic root (mirror `OnchainChatSharded.t.sol:251-278`); (3) `FlyPolicy.decide` single-slot via `vm.record`/`vm.accesses`; (4) `verifyAndUpdate` with hand-built `[STORE, LOG3]` and `sha256(abi.encode(transitionIndex, policy, decide.selector, storageUpdates))`; (5) overlay parity via `vm.etch(engine.overlayChunkAddress(manifest, i), 0x00||slice)` (`OnchainChat.t.sol:176-212`); (6) `FlyAMM` clamp test: `vm.store` an out-of-range word into `FLY_SLOT`, assert `effectiveFee` clamps/defaults; (7) tampered `stateIn` with `last ≥ clock` reverts; (8) gas snapshot per evolve / per event / per sweep step on a 1,000-neuron subgraph — the first number to measure. `foundry.toml` needs no change (`gas_limit = 2^64-1`, `memory_limit = 128 MiB`).
4. **Full-graph anvil rehearsal exactly like the Qwen run** — `deploy_anvil.py --blobs ptr.bin,edges.bin,meta.bin` (setCode/etch of 4,193 chunks + pages + root), deploy `FlyEngine`, run `warmup(20000)` once (≈2 s simulated ≈ 44-105 Ggas at 22-52 Ggas/s; long but one-off), write `warm.bin`, etch it, deploy `FlyPolicy`+`FlyAMM`, run `dryRun`/`decide` via `eth_call` under the unbounded gas cap, compare against `fly_int.py`, and record gas + wall time under both `debug_traceCall` and in-process revm. Confirm the prestate diff is exactly one STORE + LOG.
5. **Sepolia** — deploy graph directory (ledger, resumable), `verify_onchain_directory.py --engine-kind fly`, deploy warm directory, deploy engine + consumer + pool, run `checkArtifacts`, then live rounds through the operator set with the request JSON; first rounds with an empty pool (all-zero histogram) to observe baseline readouts.

---

## 8. Build plan (dependency-ordered; **[B]** = hard blocker, **[N]** = nice-to-have)

| Phase | Deliverable | Done when |
|---|---|---|
| 0 [B] | `graph.npz` rebuilt from the three feathers (§2.1): place them in `DOOM/connectome_data/malecns_v1/`, then `python -m doom.connectome malecns_v1` (normalizes to `normalized/`, verifies `source.lock.json`), `python -m doom.prepare`, `python -m doom.audit_data`, `python -m doom.build_kernel` (C twin for §7.2) — the `doom/README.md` "Reproduce" sequence | sha256 = `346b8af8…`; manifest counts match (166,700 / 25,582,938 / 124,177,617; readouts 14) |
| 1 [B] | `tools/fly_convert.py` → `ptr.bin`, `edges.bin`, `meta.bin`, `fly_manifest.json` | max count and max out-degree printed and asserted; entries/chunk = 6,143; per-neuron sign consistency asserted; `nEdges` after splits recorded |
| 2 [B] | `tools/fly_synth.py` + `tools/fly_int.py` (fixed-point reference incl. rasterizer + decoder) + `vectors.json` | fly_int vs `kernel.cpp` on the synthetic graph passes §7.2 gates; vectors regenerate deterministically |
| 3 [B] | Multi-blob `deploy_sepolia.py` / `verify_onchain_directory.py` / `deploy_anvil.py` committed (§2.6) | default `--blobs` reproduces the Qwen plan (`[24299, 65]`, root `0x9d1ddc25…`); 3-blob plan round-trips |
| 4 [B] | `ChunkedBlob` library (lift `Qwen3.loadRange` loop; `Qwen3` delegates) + `FlyEngine.sol` (`step`, `decide`, `rasterize`, `warmup`, `checkArtifacts`, `genesisState`, `_resolve`) | `test/examples/FlyEngine.t.sol` tests (1),(2),(5),(7) pass bit-exact vs vectors; gas snapshot (8) recorded |
| 5 [B] | fly_int.py vs C kernel on the FULL graph, 300 ms | §7.2 statistical gates pass; document measured divergence |
| 6 [B] | `warm.bin` = `warmup(20000)` output; its `warmCommitment` | reproduced independently by fly_int.py and the Solidity engine (anvil) |
| 7 [B] | `FlyPolicy.sol`, `FlyAMM.sol`, tests (3),(4),(6) | single-slot regression green; `verifyAndUpdate` applies the diff; pool clamps |
| 8 [B] | Anvil full-graph rehearsal (§7.4) | measured gas/s and wall time for D = 3,000 under revm and anvil; payload shape = 1 STORE + LOG; D chosen |
| 9 [B] | Sepolia upload (graph + warm), verification, contract deploys, `checkArtifacts` | `verify_all` clean; engine check passes; broadcast records committed like `d44f65d`/`6c5da42` |
| 10 [B] | Live rounds via operators (request JSON, Helm 300 s timeout) | ≥3 consecutive settled rounds; replay from logs reproduces every word |
| 11 [N] | Rasterizer/gain calibration pass (watch DNp20/DNpe017 vs histogram shapes) | documented gain choices; fee responds to volume asymmetry |
| 12 [N] | Tonic-cell sleeping optimization (§3.8), v2 continuous/sharded mode (`step` time segments, resume anchors), R8 chroma channel, Uniswap v4 hook | trajectory-identical to v1 where applicable |

---

## 9. Honest limits
- **Not learning.** ETA = 0; PPL101/LB3c pulses are stimulation. doomfly's v6 rule failed its own gates (silent KCs under visual input; harmful learned change in the combat pilot; `survival_learning_demonstrated: False`).
- **Not validated fly vision/behavior.** DN readouts are a post-hoc engineered BCI; DNa02/DNp09/MDN/MN9 were silent in the intact visual test; lamina tonic drive makes controls fire under black input, so the fee may be insensitive to the histogram until calibrated.
- **Predictable and herdable.** Deterministic policy, public inputs, minutes of lead time; band + `MAX_LAG_WINDOWS` are caps, not defenses. Not manipulation-resistant, not an oracle, no LP-return claim over a static fee.
- **Not bit-exact with doomfly.** The fixed-point engine is the reference; "a fixed-point port of doomfly's declared equations", never "the same fly".
- **Unbounded-mode dependency.** Only settles under the Gas Killer unbounded profile (2^40 gas, off-chain single-slot shape gate, ≥66% quorum). Anything the consumer stores is quorum-controlled; the pool's clamps are the security boundary. Rounds are ~1 min; the fly runs at ~0.5-2% of real time.
- **Off-chain enforcement.** The single-slot rule and the no-block-env rule are analyzer-side; the SDK will happily apply any signed STORE. Regression tests, not the SDK, protect you.
- **Data availability of `warm.bin`** is on-chain (directory), so rounds are independent and replayable; a v2 continuous brain would reintroduce off-chain state availability.
- **Gas and cost numbers are derivations** from measured constants and opcode counts (±30%), except the ground-truth figures cited.

---

## 10. Where researchers disagreed or were unsure — decisions and tradeoffs

| # | Topic | Options (source) | Decision | Tradeoff |
|---|---|---|---|---|
| D1 | Edge record | 4-byte `post:18\|count:14` + sign in ptr (kernel-design); 5-byte `uint24 post + int16 signed count` (sdk-integration); 5-byte with per-edge sign bit (amm-design) | **4-byte, per-neuron sign** | 103 MB / 22.5 Ggas / ~30 ETH vs 128 MB / 27.9 Ggas / 36.7 ETH; needs count ≤ 16,383 (else row split) and forbids per-edge sign overrides (the v6 R8→aMe12 `abs` correction) — acceptable since v1 is baseline physiology |
| D2 | Fixed-point format | Q24 int64 state / Q64 tables / round-half-up (kernel-design, measured 1e-6 mV error); Q16 / Q32 floor (amm-design, sdk-integration) | **Q24/Q64/rhu** | 32 B/neuron and 110 Mgas memory expansion vs a 16-byte word saving ~64 Mgas/call but losing headroom (g can reach thousands of mV, v −709 mV) |
| D3 | Brain state across rounds | continuous brain with 5.38 MB off-chain `stateIn/stateOut` + resume anchors (kernel-design, sdk-integration); stateless episodes from an on-chain warm snapshot (amm-design) | **stateless episodes** (warm snapshot on-chain); `step()` kept for v2 | loses neural memory between decisions (only EMA seeds + pulse flags persist) but keeps calldata tiny (<128 KB cap), rounds independent, data availability on-chain; the 2 s warm-up is a one-off ~44-105 Ggas |
| D4 | Stimulus channels | R1-R6 luminance + R8 chroma (B/G) for price deviation (amm-design); R1-R6 only, "stimulus must go through retina/lamina" (sdk-integration) | **R1-R6 + lamina only**, price deviation as a luminance strip (rows [0,40)); R8 in v2 | keeps baseline kernel and per-neuron sign; the strip/bar split (440 rows) is a new design choice not in doomfly |
| D5 | Episode length D | ≤200 ms (sdk-integration), 300 ms (kernel-design), 500 ms (amm-design) | **300 ms default, cfg-tunable** | 3 decoder EMA time constants per decision; 16 s revm / 45 s anvil; 500 ms needs the 300 s Helm timeout under anvil |
| D6 | Gas per simulated second | 12-29 (given), ~22/~40 (amm-design), ≈50 (sdk-integration), 52.4 (kernel-design) | **quote the given 12-29 as headline; plan for 52 (≈16 Ggas/300 ms)** until measured | per-evolve cost 100 vs 270-360 gas is the crux; Phase 4 gas snapshot resolves it |
| D7 | Blob layout | single `fly_graph.bin` (kernel-design); three blobs via `--blobs` (sdk-integration) | **three blobs + separate warm directory** | per-blob `checkArtifacts` length checks; graph directory immutable across engine revisions |
| D8 | Consumer naming/slot | `FlyController` + `FLY_PARAMS_SLOT` with 96-bit params + bytes20 root (sdk-integration); `FlyPolicy` + `FLY_SLOT` with packed FlyState (amm-design) | **FlyPolicy / FlyAMM**, amm-design layout + `prevWord` chain field added | identical security model; explicit chain field makes replay verification self-contained |
| D9 | Decoder EMA seeding | window counts only (kernel-design `step`) vs per-bin EMA seeded from previous round (amm-design) | **per-10 ms-bin EMA seeded from `prev.rateMilliHz`** | requires bin-boundary readout diffs inside `decide` (cheap: 4 word reads per bin) |
| D10 | Max contact count | int16 (sdk), 15-bit (amm), 14-bit (kernel) — none could measure (graph.npz absent) | **assert in converter; split rows if > 16,383** | exact equivalence; E may grow slightly |
| D11 | Delivery/reset order | keep kernel.cpp order (deliver then reset) vs "reset at detection" (state-equivalent) | **keep C order** | canonical `stateOut` bytes; any change must be mirrored in fly_int.py in lockstep |
| D12 | `checkArtifacts` in constructor | Qwen skips (104.3 M gas) | **run it** (fly directory ≈22 M gas) | keep the `_validateArtifacts` virtual hook regardless |
| D13 | Uncertain (all): whether operators' harness/RPC accept multi-Ggas `eth_call`s with ~7.6 MB memory and ~3,900 code blobs per round | — | measure in Phase 8 under both anvil tracing and in-process revm | if anvil serializes a 16 Ggas trace, revm-in-process is mandatory |