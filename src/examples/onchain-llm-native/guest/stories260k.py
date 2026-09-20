# stories260k: the engine-v1 on-chain LLM (../../onchain-llm: Llama2.sol + LlamaTokenizer.sol,
# 10,467,959,687 gas for a 200-token story) as a Python gkvm guest — tokenizer, integer
# Llama-2 forward pass, greedy decode.
#
#   python3 tools/gk build src/examples/onchain-llm-native/guest/stories260k.py \
#       --sol-out src/examples/onchain-llm-native/gen
#
# The arithmetic is ../../onchain-llm/tools/reference.py op for op (Q32 activations, int16
# weights with per-tensor shifts, floor isqrt, bit-product exp, first-max argmax), so the
# answers are the donor's test vectors bit for bit; only the loops are reshaped for the
# MicroPython VM (rows as tuples, no classifier on teacher-forced positions). Python ints are
# arbitrary precision, like the donor's int256 that never wraps: there is no overflow case.
#
# Artifacts, the donor's blobs byte for byte (tools/convert.py): kind 0 = the weight blob,
# kind 1 = the tokenizer blob. Both are read once, front to back, before anything else — the
# page schedule is "the whole bundle in order" (gk-run --schedule sequential).
#
# CONFIG is tools/convert.py's packedConfig for stories260K (Stories260K.sol): the image
# commits to the model's shape, artifactRoot to its bytes.
import gkvm
import struct

CONFIG = (
    0x004000AC05080402000200080020010000000000000000000000000000000000,
    0x0E0D0E0E100F0E0F0F0F0C0E0000000000000000000000000000000000000000,
    0x000000005A82799A00082F800000165200000000000000000000000000000000,
)

ONE = 1 << 32  # 1.0 in Q32
LOG2E_Q32 = 6196328018  # floor(log2(e) * 2^32)
EPS_Q64 = 42950 << 32  # round(1e-5 * 2^32), in the Q64 mean of squares
BOS = 1
EOS = 2


def isqrt(n):
    """Floor integer square root (Newton from above; there is no math module here)."""
    if n < 2:
        return n
    bits = 0
    t = n
    while t:
        t >>= 16
        bits += 16
    x = 1 << ((bits + 1) >> 1)
    while True:
        y = (x + n // x) >> 1
        if y >= x:
            return x
        x = y


# EXP2_C[i] = 2^(2^-(i+1)) in Q64, by the donor's integer sqrt chain
EXP2_C = []
_c = isqrt(2 << 128)
for _ in range(32):
    EXP2_C.append(_c)
    _c = isqrt(_c << 64)
EXP2_C = tuple(EXP2_C)


def exp_q32(x):
    """exp(x) for Q32 x <= 0, Q32 in [0, 2^32]."""
    y = (x * LOG2E_Q32) >> 32
    if y <= -(64 << 32):
        return 0
    n = y >> 32
    f = y - (n << 32)
    acc = 1 << 64
    bit = 1 << 31
    for c in EXP2_C:
        if f & bit:
            acc = (acc * c) >> 64
        bit >>= 1
    return acc >> (32 - n)


def sdiv(a, b):
    """EVM SDIV for b > 0: truncation toward zero."""
    return -((-a) // b) if a < 0 else a // b


def rmsnorm(x, g, gshift):
    ss = 0
    for v in x:
        ss += v * v
    s = isqrt(ss // len(x) + EPS_Q64)
    out = []
    j = 0
    for v in x:
        out.append(sdiv((v * g[j]) << 32, s) >> gshift)
        j += 1
    return out


def matmul(rows, x, shift):
    out = []
    for row in rows:
        acc = 0
        j = 0
        for wv in row:
            acc += wv * x[j]
            j += 1
        out.append(acc >> shift)
    return out


def rope(arr, n_heads, hs, cos_row, sin_row):
    half = hs >> 1
    for h in range(n_heads):
        i0 = h * hs
        for p in range(half):
            c = cos_row[p]
            s = sin_row[p]
            v0 = arr[i0]
            v1 = arr[i0 + 1]
            arr[i0] = (v0 * c - v1 * s) >> 30
            arr[i0 + 1] = (v0 * s + v1 * c) >> 30
            i0 += 2


def argmax(logits):
    best = logits[0]
    best_i = 0
    i = 0
    for v in logits:
        if v > best:
            best = v
            best_i = i
        i += 1
    return best_i


def _bits(word, at, width):
    """`width` bits of a config word, `at` bits below its most significant bit."""
    return (word >> (256 - at - width)) & ((1 << width) - 1)


def _read_artifact(kind, want_len):
    if gkvm.artifact_len(kind) != want_len:
        raise ValueError("stories260k: artifact %d is not the configured length" % kind)
    page = gkvm.PAGE_SIZE
    pages = (want_len + page - 1) // page
    buf = bytearray(pages * page)
    view = memoryview(buf)
    for p in range(pages):
        gkvm.artifact_readinto(kind, p, view[p * page:(p + 1) * page])
    return buf


def _rows(blob, off, n_rows, fmt):
    rows = []
    step = struct.calcsize(fmt)
    for _ in range(n_rows):
        rows.append(struct.unpack_from(fmt, blob, off))
        # MicroPython's allocator only moves its first-free cursor on a ONE-block allocation;
        # a run of multi-block ones (these tuples) rescans everything allocated since, which
        # made the load quadratic (measured: 876,750,338 cycles without this line). A
        # throwaway one-block object per row keeps the cursor current.
        object()
        off += step
    return rows, off


class Model:
    def __init__(self):
        w0, w1, w2 = CONFIG
        self.dim = dim = _bits(w0, 0, 16)
        self.hidden = hidden = _bits(w0, 16, 16)
        self.n_layers = L = _bits(w0, 32, 8)
        self.n_heads = _bits(w0, 40, 8)
        self.n_kv = _bits(w0, 48, 8)
        self.vocab = vocab = _bits(w0, 56, 16)
        self.seqlen = seqlen = _bits(w0, 72, 16)
        self.hs = hs = _bits(w0, 88, 8)
        kvd = _bits(w0, 96, 16)
        shared_cls = _bits(w0, 112, 8)
        # tok_emb, rms_att, wq, wk, wv, wo, rms_ffn, w1, w2, w3, rms_final, wcls
        self.shifts = tuple(_bits(w1, 8 * i, 8) for i in range(12))
        self.inv_sqrt_hs = _bits(w2, 0, 64)
        weight_len = _bits(w2, 64, 32)
        tok_len = _bits(w2, 96, 32)

        blob = _read_artifact(0, weight_len)
        self.tok_blob = _read_artifact(1, tok_len)

        row_dim = ">%dh" % dim
        row_hidden = ">%dh" % hidden
        self.tok_emb, off = _rows(blob, 0, vocab, row_dim)
        rms_att, off = _rows(blob, off, L, row_dim)
        wq, off = _rows(blob, off, L * dim, row_dim)
        wk, off = _rows(blob, off, L * kvd, row_dim)
        wv, off = _rows(blob, off, L * kvd, row_dim)
        wo, off = _rows(blob, off, L * dim, row_dim)
        rms_ffn, off = _rows(blob, off, L, row_dim)
        w1_, off = _rows(blob, off, L * hidden, row_dim)
        w2_, off = _rows(blob, off, L * dim, row_hidden)
        w3_, off = _rows(blob, off, L * hidden, row_dim)
        rms_final, off = _rows(blob, off, 1, row_dim)
        self.rms_final = rms_final[0]
        row_rope = ">%di" % (hs >> 1)
        self.rope_cos, off = _rows(blob, off, seqlen, row_rope)
        self.rope_sin, off = _rows(blob, off, seqlen, row_rope)
        if shared_cls:
            self.wcls = self.tok_emb
        else:
            self.wcls, off = _rows(blob, off, vocab, row_dim)
        if off != weight_len:
            raise ValueError("stories260k: weight blob does not match the config layout")
        self.layers = tuple(
            (rms_att[l], wq[l * dim:(l + 1) * dim], wk[l * kvd:(l + 1) * kvd],
             wv[l * kvd:(l + 1) * kvd], wo[l * dim:(l + 1) * dim], rms_ffn[l],
             w1_[l * hidden:(l + 1) * hidden], w2_[l * dim:(l + 1) * dim],
             w3_[l * hidden:(l + 1) * hidden])
            for l in range(L))
        self.kcache = [[] for _ in range(L)]
        self.vcache = [[] for _ in range(L)]

    def forward(self, token, pos, want_logits):
        """One position; the KV rows of `pos` are appended. Logits only when asked: a
        teacher-forced position never looks at them."""
        sh = self.shifts
        hs = self.hs
        n_heads = self.n_heads
        n_kv = self.n_kv
        kv_mul = n_heads // n_kv
        inv_sqrt_hs = self.inv_sqrt_hs
        cos_row = self.rope_cos[pos]
        sin_row = self.rope_sin[pos]
        up = 32 - sh[0]
        x = [e << up for e in self.tok_emb[token]]

        for l in range(self.n_layers):
            rms_att, wq, wk, wv, wo, rms_ffn, w1, w2, w3 = self.layers[l]
            xb = rmsnorm(x, rms_att, sh[1])
            q = matmul(wq, xb, sh[2])
            k = matmul(wk, xb, sh[3])
            v = matmul(wv, xb, sh[4])
            rope(q, n_heads, hs, cos_row, sin_row)
            rope(k, n_kv, hs, cos_row, sin_row)
            keys = self.kcache[l]
            vals = self.vcache[l]
            keys.append(k)
            vals.append(v)

            xatt = []
            for h in range(n_heads):
                qh = q[h * hs:(h + 1) * hs]
                kvbase = (h // kv_mul) * hs
                scores = []
                for kt in keys:
                    acc = 0
                    j = kvbase
                    for qv in qh:
                        acc += qv * kt[j]
                        j += 1
                    scores.append(((acc >> 32) * inv_sqrt_hs) >> 32)
                mx = max(scores)
                exps = [exp_q32(s - mx) for s in scores]
                tot = 0
                for e in exps:
                    tot += e
                for j in range(kvbase, kvbase + hs):
                    acc = 0
                    t = 0
                    for e in exps:
                        acc += e * vals[t][j]
                        t += 1
                    xatt.append(sdiv(acc, tot))
            xo = matmul(wo, xatt, sh[5])
            for i in range(len(x)):
                x[i] += xo[i]

            xb = rmsnorm(x, rms_ffn, sh[6])
            h1 = matmul(w1, xb, sh[7])
            h3 = matmul(w3, xb, sh[9])
            hb = []
            i = 0
            for z in h1:
                if z >= 0:
                    sig = (ONE << 32) // (ONE + exp_q32(-z))
                else:
                    e = exp_q32(z)
                    sig = (e << 32) // (ONE + e)
                hb.append((((z * sig) >> 32) * h3[i]) >> 32)
                i += 1
            xo = matmul(w2, hb, sh[8])
            for i in range(len(x)):
                x[i] += xo[i]

        if not want_logits:
            return None
        return matmul(self.wcls, rmsnorm(x, self.rms_final, sh[10]), sh[11])


class Tokenizer:
    """The donor's tok512 blob: greedy highest-score BPE merges, dummy-prefix space,
    byte-fallback tokens at +3 (llama2.c run.c)."""

    def __init__(self, blob):
        V, _maxlen = struct.unpack_from(">HB", blob, 0)
        self.scores = struct.unpack_from(">%di" % V, blob, 3)
        lens = struct.unpack_from(">%dB" % V, blob, 3 + 4 * V)
        offs = struct.unpack_from(">%dH" % V, blob, 3 + 5 * V)
        base = 3 + 7 * V
        self.pieces = [bytes(blob[base + offs[i]:base + offs[i] + lens[i]]) for i in range(V)]
        self.lookup = {}
        for i in range(V):
            if self.pieces[i] not in self.lookup:
                self.lookup[self.pieces[i]] = i

    def encode(self, text):
        ids = []
        if len(text) > 0:
            text = b" " + text
        for ch in text:
            tid = self.lookup.get(bytes((ch,)))
            ids.append(ch + 3 if tid is None else tid)
        while True:
            best_score = None
            best_id = -1
            best_idx = -1
            for i in range(len(ids) - 1):
                j = self.lookup.get(self.pieces[ids[i]] + self.pieces[ids[i + 1]])
                if j is not None and (best_score is None or self.scores[j] > best_score):
                    best_score = self.scores[j]
                    best_id = j
                    best_idx = i
            if best_idx == -1:
                break
            ids[best_idx] = best_id
            del ids[best_idx + 1]
        return [BOS] + ids

    def decode(self, ids, prev):
        out = []
        for t in ids:
            b = self.pieces[t]
            if prev == BOS and b[:1] == b" ":
                b = b[1:]
            if len(b) == 6 and b[:3] == b"<0x" and b[5:] == b">":
                b = bytes((int(str(b[3:5], "ascii"), 16),))
            out.append(b)
            prev = t
        return b"".join(out)


def main(prompt: str, max_new: int) -> tuple[str, list[int]]:
    model = Model()
    tok = Tokenizer(model.tok_blob)
    prompt_ids = tok.encode(prompt.encode())
    n_prompt = len(prompt_ids)
    if n_prompt >= model.seqlen:
        raise ValueError("stories260k: prompt too long")
    max_pos = min(n_prompt + max_new, model.seqlen)

    out = []
    token = prompt_ids[0]
    for pos in range(max_pos - 1):
        forced = pos + 1 < n_prompt
        logits = model.forward(token, pos, not forced)
        if forced:
            token = prompt_ids[pos + 1]
        else:
            token = argmax(logits)
            out.append(token)
            if token == BOS or token == EOS:
                break
    # invalid UTF-8 (a story cut inside a byte-fallback sequence) is an uncaught
    # UnicodeError: the deterministic 0xD0000001 trap, where the donor returns the raw bytes
    return str(tok.decode(out, prompt_ids[-1]), "utf-8"), out
