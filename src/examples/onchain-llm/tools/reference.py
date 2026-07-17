"""Bit-exact integer reference for the on-chain Llama-2 inference (OnchainLLM).

Every operation in this module maps 1:1 onto an EVM opcode sequence used by the
Solidity implementation:

  - `+`, `-`, `*` on Python ints  <->  ADD/SUB/MUL on int256 (magnitudes are
    proven to stay far below 2^255, so no wrapping ever occurs on-chain)
  - `sar(x, n)`                   <->  SAR (arithmetic shift right, floor)
  - `shr` on non-negative values  <->  SHR
  - `sdiv(a, b)`                  <->  SDIV (truncated toward zero)
  - `a // b` with a, b >= 0       <->  DIV
  - `isqrt(x)`                    <->  floor integer sqrt (Newton, exact)

No floating point is used anywhere in this module. Conversion-time float code
(quantization, RoPE table generation) lives in convert.py.

Fixed-point formats:
  - Activations: Q32 (value * 2^32), one int256 word each on-chain.
  - Weights: int16 with a per-tensor power-of-two scale `shift`
    (real value = int16 / 2^shift).
  - RoPE cos/sin tables: int32, Q30.
  - exp/softmax intermediates: Q32/Q64 as documented inline.
"""
import math

F = 32                      # activation fraction bits
ONE = 1 << F                # 1.0 in Q32
LOG2E_Q32 = 6196328018      # floor(log2(e) * 2^32)
EPS_Q32 = 42950             # round(1e-5 * 2^32), rmsnorm epsilon
EXP_ITERS = 32              # fraction bits consumed by exp2's bit-product

# EXP2_C[i] = 2^(2^-(i+1)) in Q64, derived purely by an integer sqrt chain:
#   EXP2_C[0] = isqrt(2 << 128)         (= sqrt(2) in Q64)
#   EXP2_C[i] = isqrt(EXP2_C[i-1] << 64)
EXP2_C = []
_c = math.isqrt(2 << 128)
for _ in range(EXP_ITERS):
    EXP2_C.append(_c)
    _c = math.isqrt(_c << 64)


def sar(x, n):
    """Arithmetic shift right == EVM SAR (floor toward -inf)."""
    return x >> n


def sdiv(a, b):
    """Truncated division == EVM SDIV (round toward zero)."""
    if (a < 0) != (b < 0):
        return -((-a if a < 0 else a) // (b if b > 0 else -b))
    return (a if a >= 0 else -a) // (b if b >= 0 else -b)


def isqrt(x):
    """Floor integer square root == the Solidity Newton implementation."""
    return math.isqrt(x)


def exp_q32(x):
    """exp(x) for Q32 x <= 0. Result is Q32 in [0, 2^32]."""
    assert x <= 0
    y = sar(x * LOG2E_Q32, 32)          # x * log2(e), Q32
    if y <= -(64 << 32):
        return 0
    n = y >> 32                          # floor(y) <= 0
    f = y - (n << 32)                    # fractional part in [0, 2^32)
    acc = 1 << 64                        # 2^f accumulator, Q64
    for i in range(EXP_ITERS):
        if (f >> (31 - i)) & 1:
            acc = (acc * EXP2_C[i]) >> 64
    shift = 32 - n                       # Q64 -> Q32 plus 2^n (n <= 0)
    if shift >= 256:
        return 0
    return acc >> shift


def rmsnorm(x, g, gshift, dim):
    """out_i = x_i * g_i / rms(x), inputs Q32, g int16/2^gshift, out Q32."""
    ss = 0
    for v in x:
        ss += v * v                      # Q64, non-negative
    ss = ss // dim + (EPS_Q32 << 32)     # mean of squares + eps, Q64
    s = isqrt(ss)                        # rms in Q32, > 0 (eps guarantees)
    out = []
    for i in range(dim):
        num = x[i] * g[i]                # Q(32+gshift)
        v = sdiv(num << 32, s)           # / rms, still Q(32+gshift)
        out.append(sar(v, gshift))       # -> Q32
    return out


def matmul(rows, cols, x, w, wshift, wbase):
    """out_i = sum_j w[wbase + i*cols + j] * x_j; w int16-scale, x Q32 -> Q32."""
    out = []
    for i in range(rows):
        acc = 0
        base = wbase + i * cols
        for j in range(cols):
            acc += w[base + j] * x[j]
        out.append(sar(acc, wshift))
    return out


def rope(arr, n_heads, hs, cos_row, sin_row):
    """In-place rotation of consecutive pairs within each head. Tables Q30."""
    for h in range(n_heads):
        for p in range(hs // 2):
            c, s = cos_row[p], sin_row[p]
            i0 = h * hs + 2 * p
            v0, v1 = arr[i0], arr[i0 + 1]
            arr[i0] = sar(v0 * c - v1 * s, 30)
            arr[i0 + 1] = sar(v0 * s + v1 * c, 30)


class Model:
    """cfg: dict with dim, hidden, n_layers, n_heads, n_kv, vocab, seqlen, hs, kvd,
    inv_sqrt_hs (Q32). weights: dict tensor-name -> (int list, shift).
    rope_cos/rope_sin: [pos][pair] int Q30."""

    def __init__(self, cfg, weights, rope_cos, rope_sin):
        self.cfg = cfg
        self.w = weights
        self.rope_cos = rope_cos
        self.rope_sin = rope_sin

    def new_state(self, max_pos):
        L, kvd = self.cfg['n_layers'], self.cfg['kvd']
        return {
            'k': [[[0] * kvd for _ in range(max_pos)] for _ in range(L)],
            'v': [[[0] * kvd for _ in range(max_pos)] for _ in range(L)],
        }

    def forward(self, state, token, pos):
        c = self.cfg
        dim, hidden, hs, kvd = c['dim'], c['hidden'], c['hs'], c['kvd']
        n_heads, n_kv, L = c['n_heads'], c['n_kv'], c['n_layers']
        kv_mul = n_heads // n_kv
        w = self.w

        emb, embs = w['tok_emb']
        x = [e << (F - embs) for e in emb[token * dim:(token + 1) * dim]]

        for l in range(L):
            g, gs = w['rms_att']
            xb = rmsnorm(x, g[l * dim:(l + 1) * dim], gs, dim)

            wq, wqs = w['wq']
            wk, wks = w['wk']
            wv, wvs = w['wv']
            q = matmul(dim, dim, xb, wq, wqs, l * dim * dim)
            k = matmul(kvd, dim, xb, wk, wks, l * dim * kvd)
            v = matmul(kvd, dim, xb, wv, wvs, l * dim * kvd)

            rope(q, n_heads, hs, self.rope_cos[pos], self.rope_sin[pos])
            rope(k, n_kv, hs, self.rope_cos[pos], self.rope_sin[pos])

            state['k'][l][pos] = k
            state['v'][l][pos] = v

            xatt = [0] * dim
            for h in range(n_heads):
                qbase = h * hs
                kvbase = (h // kv_mul) * hs
                scores = []
                for t in range(pos + 1):
                    kt = state['k'][l][t]
                    acc = 0
                    for j in range(hs):
                        acc += x_mul(q[qbase + j], kt[kvbase + j])
                    sc = sar(acc, F)                          # q.k in Q32
                    sc = sar(sc * c['inv_sqrt_hs'], 32)       # / sqrt(hs)
                    scores.append(sc)
                mx = max(scores)
                exps = [exp_q32(s - mx) for s in scores]
                tot = 0
                for e in exps:
                    tot += e                                  # >= 2^32 (max term)
                for j in range(hs):
                    acc = 0
                    for t in range(pos + 1):
                        acc += exps[t] * state['v'][l][t][kvbase + j]  # Q64
                    xatt[qbase + j] = sdiv(acc, tot)          # Q32
            wo, wos = w['wo']
            xo = matmul(dim, dim, xatt, wo, wos, l * dim * dim)
            for i in range(dim):
                x[i] += xo[i]

            g, gs = w['rms_ffn']
            xb = rmsnorm(x, g[l * dim:(l + 1) * dim], gs, dim)
            w1, w1s = w['w1']
            w2, w2s = w['w2']
            w3, w3s = w['w3']
            h1 = matmul(hidden, dim, xb, w1, w1s, l * dim * hidden)
            h3 = matmul(hidden, dim, xb, w3, w3s, l * dim * hidden)
            hb = []
            for i in range(hidden):
                z = h1[i]
                if z >= 0:
                    e = exp_q32(-z)
                    sig = (ONE << 32) // (ONE + e)            # Q32, args >= 0
                else:
                    e = exp_q32(z)
                    sig = (e << 32) // (ONE + e)
                sz = sar(z * sig, 32)                         # silu(z), Q32
                hb.append(sar(sz * h3[i], 32))                # * h3, Q32
            xo = matmul(dim, hidden, hb, w2, w2s, l * hidden * dim)
            for i in range(dim):
                x[i] += xo[i]

        g, gs = w['rms_final']
        x = rmsnorm(x, g, gs, dim)
        wc, wcs = w['wcls']
        return matmul(c['vocab'], dim, x, wc, wcs, 0)

    def generate(self, prompt_ids, n_new):
        """Greedy decode. Returns list of generated token ids (may stop at BOS/EOS)."""
        max_pos = len(prompt_ids) + n_new
        state = self.new_state(max_pos)
        out = []
        token = prompt_ids[0]
        for pos in range(max_pos - 1):
            logits = self.forward(state, token, pos)
            if pos + 1 < len(prompt_ids):
                nxt = prompt_ids[pos + 1]
            else:
                nxt = argmax(logits)
                out.append(nxt)
                if nxt == 1 or nxt == 2:      # BOS/EOS terminate generation
                    break
            token = nxt
        return out


def x_mul(a, b):
    return a * b


def argmax(logits):
    """First maximum wins (strict > comparison), matching the Solidity loop."""
    best, best_i = logits[0], 0
    for i in range(1, len(logits)):
        if logits[i] > best:
            best, best_i = logits[i], i
    return best_i


# ---------------------------- tokenizer ----------------------------

class Tokenizer:
    """vocab: list of (score_q16 int, bytes). Mirrors run.c's greedy BPE."""

    def __init__(self, vocab):
        self.vocab = vocab
        self.lookup = {}
        for i, (_, b) in enumerate(vocab):
            if b not in self.lookup:
                self.lookup[b] = i

    def encode(self, text_bytes):
        """BOS + dummy-prefix-space + byte-fallback + greedy merges (run.c encode)."""
        ids = []
        if len(text_bytes) > 0:
            text_bytes = b' ' + text_bytes
        for ch in text_bytes:
            b = bytes([ch])
            if b in self.lookup:
                ids.append(self.lookup[b])
            else:
                ids.append(ch + 3)           # byte-fallback tokens at +3
        while True:
            best_score = None
            best_id = -1
            best_idx = -1
            for i in range(len(ids) - 1):
                merged = self.vocab[ids[i]][1] + self.vocab[ids[i + 1]][1]
                j = self.lookup.get(merged)
                if j is not None and (best_score is None or self.vocab[j][0] > best_score):
                    best_score = self.vocab[j][0]
                    best_id = j
                    best_idx = i
            if best_idx == -1:
                break
            ids[best_idx] = best_id
            del ids[best_idx + 1]
        return [1] + ids

    def decode_piece(self, tid, prev):
        b = self.vocab[tid][1]
        if prev == 1 and b.startswith(b' '):
            b = b[1:]
        if len(b) == 6 and b.startswith(b'<0x') and b.endswith(b'>'):
            return bytes([int(b[3:5], 16)])
        return b

    def decode(self, ids, prev=1):
        out = b''
        for t in ids:
            out += self.decode_piece(t, prev)
            prev = t
        return out
