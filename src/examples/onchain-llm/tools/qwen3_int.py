"""Bit-exact integer reference for on-chain Qwen3 inference (engine v2 spec).

Mirrors the planned Solidity v2 engine op-for-op, like reference.py does for v1:
  - Activations: Q24 signed (chosen so every matmul accumulation fits int64 for
    the numpy-accelerated hot path; Qwen3's residual stream peaks ~2^13).
  - 2D weights: int8 with a per-output-row power-of-two shift (max 15).
  - 1D norm weights: int16 with a per-tensor power-of-two shift.
  - KV cache: int32 Q16 (values are stored as sar(x_q24, 8)).
  - exp: reuses reference.exp_q32 exactly via  e_q24 = sar(exp_q32(x_q24 << 8), 8).
  - RMSNorm eps is a per-model Q48 constant (Qwen3: round(1e-6 * 2^48)).
  - RoPE: interleaved-pair kernel over Q30 tables; HF half-dim convention is
    handled by permuting wq/wk rows (and qk-norm weights) at quantization time.
  - Sampling: greedy argmax, first maximum wins. Stops on configured stop ids.

numpy int64 is used ONLY where products provably fit (big matmuls, attention
scores); norms, softmax, SiLU and attention-weighted sums use Python ints with
the exact EVM semantics (sar floor, sdiv trunc) from reference.py.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reference import exp_q32, isqrt, sar, sdiv

F = 24
ONE = 1 << F
ONE32 = 1 << 32
MAX_ROW_SHIFT = 15


def exp_q24(x):
    """exp for Q24 x <= 0 via the Q32 kernel; result Q24."""
    return sar(exp_q32(x << 8), 8)


def quant_rows_i8(w):
    """Per-row int8 power-of-two quantization. w: (rows, cols) float array.
    Returns (int8 ndarray, uint8 shifts ndarray): w ~= q / 2^shift per row."""
    mx = np.abs(w).max(axis=1)
    mx = np.where(mx == 0, 1e-30, mx)
    shifts = np.minimum(np.floor(np.log2(127.0 / mx)).astype(np.int64), MAX_ROW_SHIFT)
    shifts = np.maximum(shifts, 0)
    q = np.clip(np.round(w * (1 << shifts)[:, None].astype(np.float64)), -127, 127)
    return q.astype(np.int8), shifts.astype(np.uint8)


def quant_i16(vals, max_shift=30):
    """Per-tensor int16 power-of-two quantization (v1 scheme)."""
    mx = float(np.abs(vals).max()) or 1e-30
    shift = 0
    while mx * (1 << (shift + 1)) <= 32767 and shift < max_shift:
        shift += 1
    q = np.clip(np.round(np.asarray(vals, dtype=np.float64) * (1 << shift)), -32768, 32767)
    return q.astype(np.int16), shift


def permute_rope_rows(w, n_heads, hd):
    """Reorder rows so interleaved-pair RoPE == HF half-dim RoPE."""
    out = np.empty_like(w)
    half = hd // 2
    for h in range(n_heads):
        blk = w[h * hd:(h + 1) * hd]
        for i in range(half):
            out[h * hd + 2 * i] = blk[i]
            out[h * hd + 2 * i + 1] = blk[i + half]
    return out


def permute_rope_vec(g, hd):
    return permute_rope_rows(g.reshape(-1, 1), 1, hd).reshape(-1)


def rope_tables_q30(seq_cap, hd, theta):
    half = hd // 2
    inv = theta ** (-np.arange(half, dtype=np.float64) / half)
    pos = np.arange(seq_cap, dtype=np.float64)[:, None]
    ang = pos * inv
    cos = np.round(np.cos(ang) * (1 << 30)).astype(np.int64)
    sin = np.round(np.sin(ang) * (1 << 30)).astype(np.int64)
    return cos, sin


def matmul_i8(q, shifts, x64):
    """out_i = sar(sum_j q[i,j] * x_j, shifts[i]); all int64, provably no overflow
    for |x| < 2^40 and cols <= 4096."""
    acc = q.astype(np.int64) @ x64
    return acc >> shifts.astype(np.int64)


def rmsnorm_int(x, g16, gshift, eps_q48):
    """x: list/array of Q24 ints; g16 int16; returns Q24 list. Python-int exact."""
    n = len(x)
    ss = 0
    for v in x:
        v = int(v)
        ss += v * v                              # Q48
    ss = ss // n + eps_q48
    s = isqrt(ss)                                # Q24
    out = []
    for i in range(n):
        num = int(x[i]) * int(g16[i])            # Q(24+gshift)
        v = sdiv(num << 24, s)
        out.append(sar(v, gshift))
    return out


class QwenInt:
    """Integer model. Weights quantized in-memory from the float Loader; the
    converter serializes the identical values, so this class IS the spec."""

    def __init__(self, fm, seq_cap=1024):
        # fm: qwen3_float.Qwen3 instance (float weights + config)
        self.L, self.nh, self.nkv, self.hd, self.dim = fm.L, fm.nh, fm.nkv, fm.hd, fm.dim
        self.hidden = fm.layers[0]['wg'].shape[0]
        self.vocab = fm.emb.shape[0]
        self.kv_mul = self.nh // self.nkv
        self.eps_q48 = round(fm.eps * (1 << 48))
        self.inv_sqrt_hd = round((1 << 32) / np.sqrt(self.hd))
        self.seq_cap = seq_cap
        self.rope_cos, self.rope_sin = rope_tables_q30(seq_cap, self.hd, fm.theta)

        self.emb_q, self.emb_s = quant_rows_i8(fm.emb)
        self.layers = []
        for w in fm.layers:
            wq = permute_rope_rows(w['wq'], self.nh, self.hd)
            wk = permute_rope_rows(w['wk'], self.nkv, self.hd)
            qn = permute_rope_vec(w['qn'], self.hd)
            kn = permute_rope_vec(w['kn'], self.hd)
            self.layers.append({
                'ln1': quant_i16(w['ln1']),
                'qn': quant_i16(qn),
                'kn': quant_i16(kn),
                'wq': quant_rows_i8(wq),
                'wk': quant_rows_i8(wk),
                'wv': quant_rows_i8(w['wv']),
                'wo': quant_rows_i8(w['wo']),
                'ln2': quant_i16(w['ln2']),
                'wg': quant_rows_i8(w['wg']),
                'wu': quant_rows_i8(w['wu']),
                'wd': quant_rows_i8(w['wd']),
            })
        self.norm = quant_i16(fm.norm)

    def new_cache(self, max_pos):
        return {
            'k': np.zeros((self.L, max_pos, self.nkv * self.hd), dtype=np.int64),
            'v': np.zeros((self.L, max_pos, self.nkv * self.hd), dtype=np.int64),
        }

    def _rope(self, arr, n_heads, pos):
        cos, sin = self.rope_cos[pos], self.rope_sin[pos]
        for h in range(n_heads):
            for p in range(self.hd // 2):
                c, s = int(cos[p]), int(sin[p])
                i0 = h * self.hd + 2 * p
                v0, v1 = int(arr[i0]), int(arr[i0 + 1])
                arr[i0] = sar(v0 * c - v1 * s, 30)
                arr[i0 + 1] = sar(v0 * s + v1 * c, 30)

    def forward(self, cache, token, pos):
        # embedding row -> Q24 (row shift <= 15 <= 24)
        x = self.emb_q[token].astype(np.int64) << (F - int(self.emb_s[token]))
        for li, w in enumerate(self.layers):
            xb = np.array(rmsnorm_int(x, *w['ln1'], self.eps_q48), dtype=np.int64)
            q = matmul_i8(*w['wq'], xb)
            k = matmul_i8(*w['wk'], xb)
            v = matmul_i8(*w['wv'], xb)
            # per-head qk-norm (Python-int exact), then interleaved RoPE
            qn, qs = w['qn']
            kn, ks = w['kn']
            for h in range(self.nh):
                q[h * self.hd:(h + 1) * self.hd] = rmsnorm_int(
                    q[h * self.hd:(h + 1) * self.hd], qn, qs, self.eps_q48)
            for h in range(self.nkv):
                k[h * self.hd:(h + 1) * self.hd] = rmsnorm_int(
                    k[h * self.hd:(h + 1) * self.hd], kn, ks, self.eps_q48)
            self._rope(q, self.nh, pos)
            self._rope(k, self.nkv, pos)
            # store as Q16 int32 (spec: sar by 8)
            cache['k'][li][pos] = k >> 8
            cache['v'][li][pos] = v >> 8

            xatt = np.zeros(self.nh * self.hd, dtype=np.int64)
            steps = pos + 1
            kc = cache['k'][li][:steps]          # (T, nkv*hd) Q16
            vc = cache['v'][li][:steps]
            for h in range(self.nh):
                kvo = (h // self.kv_mul) * self.hd
                qh = q[h * self.hd:(h + 1) * self.hd]           # Q24
                # scores: sum(q * k) Q40 -> sar 16 -> Q24 -> * invSqrtHd >> 32
                acc = kc[:, kvo:kvo + self.hd] @ qh              # int64 safe
                sc = [sar(sar(int(a), 16) * self.inv_sqrt_hd, 32) for a in acc]
                mx = max(sc)
                exps = [exp_q24(s - mx) for s in sc]
                tot = sum(exps)
                for j in range(self.hd):
                    a = 0
                    col = vc[:, kvo + j]
                    for t in range(steps):
                        a += exps[t] * int(col[t])               # Q40
                    xatt[h * self.hd + j] = sdiv(a << 8, tot)    # Q24
            x = x + matmul_i8(*w['wo'], xatt)

            xb = np.array(rmsnorm_int(x, *w['ln2'], self.eps_q48), dtype=np.int64)
            g = matmul_i8(*w['wg'], xb)
            u = matmul_i8(*w['wu'], xb)
            hbuf = np.empty(self.hidden, dtype=np.int64)
            for i in range(self.hidden):
                z = int(g[i])
                if z >= 0:
                    e = exp_q32(-(z << 8))
                    sig = (ONE32 << 32) // (ONE32 + e)           # Q32
                else:
                    e = exp_q32(z << 8)
                    sig = (e << 32) // (ONE32 + e)
                sz = sar(z * sig, 32)                            # Q24
                hbuf[i] = sar(sz * int(u[i]), 24)                # Q24
            x = x + matmul_i8(*w['wd'], hbuf)

        xb = np.array(rmsnorm_int(x, *self.norm, self.eps_q48), dtype=np.int64)
        return matmul_i8(self.emb_q, self.emb_s, xb)             # logits Q24

    def generate(self, ids, n_new, stop_ids=(151643, 151645)):
        max_pos = len(ids) + n_new
        assert max_pos <= self.seq_cap
        cache = self.new_cache(max_pos)
        out = []
        token = ids[0]
        for pos in range(max_pos - 1):
            logits = self.forward(cache, token, pos)
            if pos + 1 < len(ids):
                nxt = ids[pos + 1]
            else:
                nxt = int(np.argmax(logits))     # ties: lowest index, matches spec
                out.append(nxt)
                if nxt in stop_ids:
                    break
            token = nxt
        return out


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', default='.context/qwen3/model.safetensors')
    ap.add_argument('--config', default='.context/qwen3/config.json')
    ap.add_argument('--tokenizer', default='.context/qwen3/tokenizer.json')
    ap.add_argument('--prompt', default='What is Ethereum?')
    ap.add_argument('-n', type=int, default=40)
    args = ap.parse_args()

    from qwen3_float import Qwen3, chat_ids
    tok, ids = chat_ids(args.tokenizer, args.prompt)
    fm = Qwen3(args.model, args.config)

    print('float generating...', file=sys.stderr)
    fout = fm.generate(ids, args.n)
    print('float:', tok.decode(fout), file=sys.stderr)

    print('quantizing...', file=sys.stderr)
    im = QwenInt(fm, seq_cap=len(ids) + args.n + 8)
    print('int generating...', file=sys.stderr)
    iout = im.generate(ids, args.n)
    match = sum(1 for a, b in zip(fout, iout) if a == b)
    print(f'token match: {match}/{min(len(fout), len(iout))}', file=sys.stderr)
    print('int  :', tok.decode(iout))


if __name__ == '__main__':
    main()
