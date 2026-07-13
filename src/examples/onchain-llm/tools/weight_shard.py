"""Weight-sharding for the sharded on-chain LLM driver.

A worker assigned a layer range (and possibly the embedding-lookup / classifier
roles) only needs the DATA-CONTRACT CHUNKS that cover the byte ranges it actually
reads — not the whole 597MB model. This module is the pure, model-agnostic
arithmetic that turns

    (packed config, layer range [lo,hi), role flags) -> set of chunk indices

and proves that, over a whole DAG, the UNION of every worker's chunk set equals
the chunk set the monolithic run reads: no gap (a needed chunk missing from all
workers) and no leak (a worker holding a chunk the model never reads).

LAYOUT MIRRORS Qwen3.sol `layout()` EXACTLY (verified against the real Qwen3-0.6B
artifacts: layerBase 155,734,400 = 155.7MB, layerLen 15,745,540 = 15.75MB/layer,
normOff 596,609,520, weightLen 597,135,857 == weights.bin, tail 526,337 = 0.53MB).
Everything is parameterized on the config fields so the 35B reuses it unchanged.

CHUNK MODEL (mirrors Qwen3.loadRange + tools/deploy_anvil.py):
  The weight blob is one logical byte array; chunk `i` holds bytes
  [i*CHUNK, min((i+1)*CHUNK, weightLen)). The tokenizer blob is chunked
  separately and appended, so global chunk index space is:
      weight chunks   [0, nWeightChunks)
      tokenizer chunks[nWeightChunks, nWeightChunks + nTokChunks)
  loadRange(off, len) reads chunk indices off//CHUNK .. (off+len-1)//CHUNK, so a
  byte range [b0, b1) maps to chunk indices range(b0//CHUNK, (b1-1)//CHUNK + 1).

Run standalone (no anvil, no artifacts needed — everything derives from the
packed config) to self-check the chunk-set logic over several DAG topologies:
    python3 src/examples/onchain-llm/tools/weight_shard.py
"""
from dataclasses import dataclass, field

# Data-contract payload size (EIP-170 minus the STOP prefix) == Qwen3.CHUNK.
CHUNK = 24_575


# --------------------------------------------------------------- config / layout


def _to_int(word):
    """Accept a 32-byte value as hex str ('0x..'), bytes, or int."""
    if isinstance(word, int):
        return word
    if isinstance(word, (bytes, bytearray)):
        return int.from_bytes(word, "big")
    return int(word, 16)


def parse_config(packed):
    """Unpack the 3-word packed config exactly as Qwen3.unpack does.

    `packed` is the 3-element packedConfig (hex strings / bytes / ints).
    Returns the fields weight-sharding needs (a superset of the driver's).
    """
    w0, w1, w2 = (_to_int(packed[0]), _to_int(packed[1]), _to_int(packed[2]))
    c = {
        "dim": w0 >> 240,
        "hidden": (w0 >> 224) & 0xFFFF,
        "nLayers": (w0 >> 216) & 0xFF,
        "nHeads": (w0 >> 208) & 0xFF,
        "nKv": (w0 >> 200) & 0xFF,
        "headDim": (w0 >> 184) & 0xFFFF,
        "vocab": (w0 >> 152) & 0xFFFFFFFF,
        "seqCap": (w0 >> 136) & 0xFFFF,
        "wBits": (w0 >> 120) & 0xFF,
        "weightLen": (w1 >> 64) & 0xFFFFFFFFFFFFFFFF,
        "tokLen": w2 >> 224,
    }
    c["qd"] = c["nHeads"] * c["headDim"]
    c["kvd"] = c["nKv"] * c["headDim"]
    return c


@dataclass
class Layout:
    """Byte offsets into the weight blob — the Python mirror of Qwen3.Layout."""

    cfg: dict
    embRowStride: int = 0
    layerBase: int = 0  # == embedding-table length; classifier is TIED (reuses it)
    layerLen: int = 0
    normOff: int = 0
    ropeCosOff: int = 0
    ropeSinOff: int = 0
    weightLen: int = 0
    tokLen: int = 0
    nWeightChunks: int = 0
    nTokChunks: int = 0

    def __post_init__(self):
        c = self.cfg
        wB, dim, hd = c["wBits"], c["dim"], c["headDim"]
        qd, kvd, hidden = c["qd"], c["kvd"], c["hidden"]
        self.embRowStride = 1 + dim * wB
        self.layerBase = c["vocab"] * self.embRowStride
        at = 0  # relative to layer base — mirrors Qwen3.layout() line for line
        at += 1 + dim * 2          # ln1
        at += 1 + hd * 2           # oQn
        at += 1 + hd * 2           # oKn
        at += qd * (1 + dim * wB)  # oWq
        at += kvd * (1 + dim * wB) # oWk
        at += kvd * (1 + dim * wB) # oWv
        at += dim * (1 + qd * wB)  # oWo
        at += 1 + dim * 2          # oLn2
        at += hidden * (1 + dim * wB)  # oWg
        at += hidden * (1 + dim * wB)  # oWu
        at += dim * (1 + hidden * wB)  # oWd
        self.layerLen = at
        self.normOff = self.layerBase + c["nLayers"] * self.layerLen
        self.ropeCosOff = self.normOff + 1 + dim * 2
        ropeLen = c["seqCap"] * (hd // 2) * 4
        self.ropeSinOff = self.ropeCosOff + ropeLen
        self.weightLen = self.ropeSinOff + ropeLen
        # config carries weightLen/tokLen; assert our arithmetic reproduces it
        if c["weightLen"] and self.weightLen != c["weightLen"]:
            raise ValueError(
                f"layout weightLen {self.weightLen} != config weightLen {c['weightLen']}"
            )
        self.tokLen = c["tokLen"]
        self.nWeightChunks = (self.weightLen + CHUNK - 1) // CHUNK
        self.nTokChunks = (self.tokLen + CHUNK - 1) // CHUNK

    # ----- byte-range -> chunk indices --------------------------------------

    def chunks_for_bytes(self, b_lo, b_hi):
        """Weight-blob byte range [b_lo, b_hi) -> set of weight chunk indices."""
        if b_hi <= b_lo:
            return set()
        assert 0 <= b_lo and b_hi <= self.weightLen, (b_lo, b_hi, self.weightLen)
        return set(range(b_lo // CHUNK, (b_hi - 1) // CHUNK + 1))

    def emb_chunks(self, v_lo=0, v_hi=None):
        """Embedding/tied-classifier rows [v_lo, v_hi) -> chunk indices."""
        v_hi = self.cfg["vocab"] if v_hi is None else v_hi
        return self.chunks_for_bytes(v_lo * self.embRowStride, v_hi * self.embRowStride)

    def layer_chunks(self, lo, hi):
        """Transformer layers [lo, hi) -> chunk indices."""
        if hi <= lo:
            return set()
        return self.chunks_for_bytes(
            self.layerBase + lo * self.layerLen, self.layerBase + hi * self.layerLen
        )

    def tail_chunks(self, max_pos=None):
        """Final-norm + RoPE tables -> chunk indices.

        Every forwardRange stage reads RoPE (per-position, every layer) and the
        last stage reads the final norm. RoPE rows are read only for positions
        [0, max_pos); pass max_pos to get the exact set read, or None for the
        whole table (a safe superset)."""
        s = self.chunks_for_bytes(self.normOff, self.normOff + 1 + self.cfg["dim"] * 2)
        if max_pos is None:
            s |= self.chunks_for_bytes(self.ropeCosOff, self.weightLen)
        else:
            half4 = (self.cfg["headDim"] // 2) * 4
            s |= self.chunks_for_bytes(self.ropeCosOff, self.ropeCosOff + max_pos * half4)
            s |= self.chunks_for_bytes(self.ropeSinOff, self.ropeSinOff + max_pos * half4)
        return s

    def tokenizer_chunks(self):
        return set(range(self.nWeightChunks, self.nWeightChunks + self.nTokChunks))

    def all_chunks(self):
        return set(range(self.nWeightChunks + self.nTokChunks))

    # ----- installed-footprint accounting -----------------------------------

    def chunk_payload_len(self, i):
        if i < self.nWeightChunks:
            return min(CHUNK, self.weightLen - i * CHUNK)
        j = i - self.nWeightChunks
        return min(CHUNK, self.tokLen - j * CHUNK)

    def installed_bytes(self, chunk_set):
        return sum(self.chunk_payload_len(i) for i in chunk_set)

    def full_bytes(self):
        return self.weightLen + self.tokLen


# ------------------------------------------------------- role -> chunk set


def worker_chunks(layout, layer_ranges, needs_embedding, classifier_ranges,
                  max_pos=None, include_tokenizer=True):
    """The chunk set a single worker must hold.

    layer_ranges       list of (lo, hi) layer ranges this worker computes
                       (forwardRange stages). Empty -> holds no layer/tail.
    needs_embedding    True if this worker does the layer-0 embedding lookup
                       (arbitrary token ids -> needs the WHOLE embedding table).
    classifier_ranges  list of (v_lo, v_hi) tied-classifier vocab shards this
                       worker runs argmaxRange over (each needs only its rows;
                       pass [(0, vocab)] for a whole-embedding classifier).
    max_pos            KV/rope position bound of the run (rope rows [0,max_pos)).
    """
    s = set()
    runs_forward = any(hi > lo for lo, hi in layer_ranges)
    for lo, hi in layer_ranges:
        s |= layout.layer_chunks(lo, hi)
    if runs_forward:
        s |= layout.tail_chunks(max_pos)
    if needs_embedding:
        s |= layout.emb_chunks()  # whole tied table (token ids are unpredictable)
    for v_lo, v_hi in classifier_ranges:
        s |= layout.emb_chunks(v_lo, v_hi)
    if include_tokenizer:
        s |= layout.tokenizer_chunks()
    return s


def monolithic_read_chunks(layout, max_pos=None, include_tokenizer=True):
    """The chunk set a monolithic (full-model) run actually READS for one
    generation with >= 1 generating position:
      * whole embedding table (argmaxClassifier scans all vocab rows),
      * every transformer layer,
      * final norm + RoPE rows [0, max_pos),
      * the tokenizer (chat decodes ids -> text).
    """
    s = layout.emb_chunks()
    s |= layout.layer_chunks(0, layout.cfg["nLayers"])
    s |= layout.tail_chunks(max_pos)
    if include_tokenizer:
        s |= layout.tokenizer_chunks()
    return s


# ------------------------------------------------------ DAG assignment (shared)


@dataclass
class DagPlan:
    """The scheduler's worker assignment — the SINGLE source of truth shared by
    the live driver (ShardedRunner) and the standalone self-check, so the chunk
    sets we install can never drift from the calls we actually dispatch."""

    stages: int
    committee: int
    argmax_shards: int
    n_workers: int
    bounds: list = field(default_factory=list)       # [(layerLo, layerHi)] per stage
    stage_workers: list = field(default_factory=list)  # [[worker idx]] per stage
    argmax: list = field(default_factory=list)       # [(members[idx], vLo, vHi)] per shard


def dag_plan(n_layers, vocab, stages, committee, argmax_shards, n_workers=None):
    """Reproduce ShardedRunner's assignment arithmetic exactly."""
    s = min(stages, n_layers)
    k, m = committee, argmax_shards
    n = n_workers or s * k
    bounds = [(i * n_layers // s, (i + 1) * n_layers // s) for i in range(s)]
    stage_workers = [[(i * k + j) % n for j in range(k)] for i in range(s)]
    step = vocab // m
    argmax = []
    for j in range(m):
        v_lo, v_hi = j * step, (vocab if j + 1 == m else (j + 1) * step)
        members = [(j * k + i) % n for i in range(k)]
        argmax.append((members, v_lo, v_hi))
    return DagPlan(s, k, m, n, bounds, stage_workers, argmax)


def plan_worker_chunks(layout, plan, max_pos=None):
    """Per-worker chunk sets for a whole DAG. Returns {worker_idx: set}."""
    assign = {
        w: {"layers": [], "needs_emb": False, "cls": []} for w in range(plan.n_workers)
    }
    for i, workers in enumerate(plan.stage_workers):
        lo, hi = plan.bounds[i]
        for w in workers:
            assign[w]["layers"].append((lo, hi))
            if lo == 0:
                assign[w]["needs_emb"] = True
    for members, v_lo, v_hi in plan.argmax:
        for w in members:
            assign[w]["cls"].append((v_lo, v_hi))
    return {
        w: worker_chunks(layout, a["layers"], a["needs_emb"], a["cls"], max_pos)
        for w, a in assign.items()
    }


# --------------------------------------------------------------- self-check


def selfcheck(layout, per_worker, max_pos=None):
    """Assert union(per-worker chunk sets) == chunks the monolithic run reads.

    Returns (union, reference). Raises AssertionError on any gap or leak.
    """
    union = set().union(*per_worker.values()) if per_worker else set()
    ref = monolithic_read_chunks(layout, max_pos)
    gap = ref - union       # a needed chunk held by NO worker
    leak = union - ref      # a chunk held by some worker but never read
    assert not gap, f"GAP: {len(gap)} chunk(s) read by mono but held by no worker: " \
                    f"{sorted(gap)[:8]}{'...' if len(gap) > 8 else ''}"
    assert not leak, f"LEAK: {len(leak)} chunk(s) held but never read: " \
                     f"{sorted(leak)[:8]}{'...' if len(leak) > 8 else ''}"
    return union, ref


# ------------------------------------------------------------------ standalone

# Known packed configs (self-contained; no artifacts required).
_REAL_06B = [
    "0x04000c001c100800800002518004000101000000000000000000000000000000",
    "0x0000000010c6f7a10000000016a09e6600000000239791f10000000000000000",
    "0x00182bc20002505d0002505b0000000000000000000000000000000000000000",
]
_SYNTH = [
    "0x0030006002040200100000010000400101000000000000000000000000000000",
    "0x0000000010c6f7a10000000040000000000000000000faa90000000000000000",
    "0x0000050d00000000000000000000000000000000000000000000000000000000",
]


def _mb(n):
    return n / (1024 * 1024)


def _report(name, packed, topos):
    c = parse_config(packed)
    lay = Layout(c)
    print(f"\n=== {name}: dim {c['dim']}, {c['nLayers']} layers, vocab {c['vocab']}, "
          f"weightLen {lay.weightLen:,} ({_mb(lay.weightLen):.1f}MB), "
          f"{lay.nWeightChunks:,} weight + {lay.nTokChunks} tok chunks ===")
    print(f"    layerBase {lay.layerBase:,} ({_mb(lay.layerBase):.1f}MB, "
          f"{100*lay.layerBase/lay.weightLen:.0f}%)  "
          f"layerLen {lay.layerLen:,} ({_mb(lay.layerLen):.2f}MB)  "
          f"tail {lay.weightLen - lay.normOff:,} ({_mb(lay.weightLen - lay.normOff):.2f}MB)")
    for stages, committee, m, max_pos in topos:
        plan = dag_plan(c["nLayers"], c["vocab"], stages, committee, m)
        pw = plan_worker_chunks(lay, plan, max_pos)
        union, ref = selfcheck(lay, pw, max_pos)  # raises on gap/leak
        full = lay.full_bytes()
        foot = [(w, lay.installed_bytes(s)) for w, s in sorted(pw.items())]
        lo_pct = min(100 * b / full for _, b in foot)
        hi_pct = max(100 * b / full for _, b in foot)
        print(f"  S={plan.stages} k={plan.committee} M={m} N={plan.n_workers} "
              f"maxPos={max_pos}: union=={{mono reads}} ({len(union)} chunks) OK; "
              f"per-worker {lo_pct:.1f}%..{hi_pct:.1f}% of full "
              f"({_mb(min(b for _, b in foot)):.1f}..{_mb(max(b for _, b in foot)):.1f}MB)")


def main():
    print("weight_shard self-check: union(per-worker) == chunks the monolithic run reads")
    _report("synthetic fixture", _SYNTH,
            [(2, 1, 2, 7), (2, 2, 2, 7), (2, 1, 1, 7)])
    _report("real Qwen3-0.6B", _REAL_06B,
            [(4, 1, 4, 18), (4, 1, 4, None), (28, 1, 8, 18), (7, 2, 4, 18)])
    print("\nALL SELF-CHECKS PASSED: no gap, no leak.")


if __name__ == "__main__":
    main()
