"""Bit-exact integer reference for on-chain Qwen3.5-35B-A3B (engine v3 spec).

Mirrors .context/qwen35/SPEC.md op-for-op; SPEC.md is the contract, this file
is its executable form. Conventions inherited from engine v2
(tools/qwen3_int.py):
  - Activations Q24; 2D weights int8 per-row power-of-two (shift <= 15);
    1D norms int16 per-tensor power-of-two; KV / conv / DeltaNet state int32
    Q16; exp via reference.exp_q32; isqrt norms; SAR/SDIV EVM semantics.
  - numpy int64 is used only where products provably fit (asserts guard every
    such site); Python ints elsewhere.

New primitives (SPEC §2): sig_q32, log2_q64, softplus_q24, l2norm_q24.
"""
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from reference import exp_q32, isqrt, sar, sdiv                    # noqa: E402
from qwen3_int import (MAX_ROW_SHIFT, exp_q24, quant_i16,          # noqa: E402
                       quant_rows_i8)


def quant_rows_i16(w):
    """Per-row int16 power-of-two quantization (v2 wBits=2 rule): used for the
    hi-precision rows (router; SPEC §1). shift = clamp(floor(log2(32767/max)), 0, 15)."""
    mx = np.abs(w).max(axis=1)
    mx = np.where(mx == 0, 1e-30, mx)
    shifts = np.clip(np.floor(np.log2(32767.0 / mx)).astype(np.int64), 0, MAX_ROW_SHIFT)
    q = np.clip(np.round(w * (1 << shifts)[:, None].astype(np.float64)), -32767, 32767)
    return q.astype(np.int16), shifts.astype(np.uint8)

F = 24
ONE = 1 << F
ONE32 = 1 << 32
EPS_Q48 = round(1e-6 * (1 << 48))                 # 281474977
LN2_Q64 = 12786308645202655660                    # floor(ln2 * 2^64)
INV_SQRT_DK_Q32 = round((1 << 32) / np.sqrt(128))  # 379625062
INT31 = 1 << 31
INT63 = 1 << 62  # assert margin


# ------------------------------------------------------------- primitives

def sig_q32(x):
    """sigmoid for Q24 x (any sign) -> Q32 in [0, 2^32]. SPEC §2.1."""
    if x >= 0:
        return (1 << 64) // (ONE32 + exp_q32(-(x << 8)))
    e = exp_q32(x << 8)
    return (e << 32) // (ONE32 + e)


def silu_q24(x):
    """x * sigmoid(x), Q24 -> Q24."""
    return sar(x * sig_q32(x), 32)


def log2_q64(v):
    """log2 for Q32 v in [2^32, 2^33) -> Q64 in [0, 2^64). SPEC §2.2."""
    assert (1 << 32) <= v < (1 << 33)
    r = 0
    for _ in range(64):
        v = (v * v) >> 32
        r <<= 1
        if v >= (1 << 33):
            r |= 1
            v >>= 1
    return r


def softplus_q24(x):
    """ln(1+e^x) for Q24 x (any sign) -> Q24 >= 0. SPEC §2.3."""
    if x > 0:
        return x + softplus_q24(-x)
    e = exp_q32(x << 8)
    v = ONE32 + e
    if v >= (1 << 33):
        v = (1 << 33) - 1
    return (log2_q64(v) * LN2_Q64) >> 104


def l2norm_q24(vec):
    """FLA l2norm: x / sqrt(sum(x^2) + eps). Python-int exact. SPEC §2.4."""
    ss = 0
    for v in vec:
        v = int(v)
        ss += v * v
    s = isqrt(ss + EPS_Q48)
    return [sdiv(int(v) << 24, s) for v in vec]


def rmsnorm_int(x, g16, gshift):
    """v2 rmsnorm (mean-of-squares + eps), Q24 in/out. Python-int exact."""
    n = len(x)
    ss = 0
    for v in x:
        v = int(v)
        ss += v * v
    ss = ss // n + EPS_Q48
    s = isqrt(ss)
    out = []
    for i in range(n):
        num = int(x[i]) * int(g16[i])
        out.append(sar(sdiv(num << 24, s), gshift))
    return out


def matmul_i8(q, shifts, x64):
    """v2 int8-rows matmul; caller guarantees |acc| < 2^63 (see SPEC §8)."""
    acc = (q if q.dtype == np.int64 else q.astype(np.int64)) @ x64
    return acc >> shifts.astype(np.int64)


def _scale_q32(y, wq32):
    """sar(y * wq32, 32) elementwise; Python-int fallback when the int64
    product could wrap (EVM int256 never wraps here — SPEC §8)."""
    if np.abs(y).max() < INT31:
        return (y * wq32) >> 32
    return np.array([sar(int(v) * wq32, 32) for v in y], dtype=np.int64)


# --------------------------------------------------- conversion transforms

def permute_rope_rows_partial(w, n_heads, hd, rot):
    """SPEC §4.2: interleave HF half-pairs within the first `rot` rows of
    each head; rows rot..hd-1 unchanged. w: (n_heads*hd, cols) or vector."""
    out = np.array(w, copy=True)
    half = rot // 2
    for h in range(n_heads):
        blk = w[h * hd:h * hd + rot]
        for i in range(half):
            out[h * hd + 2 * i] = blk[i]
            out[h * hd + 2 * i + 1] = blk[i + half]
    return out


def rope_tables_q30(seq_cap, rot, theta):
    half = rot // 2
    inv = theta ** (-np.arange(half, dtype=np.float64) * 2.0 / rot)
    ang = np.arange(seq_cap, dtype=np.float64)[:, None] * inv
    cos = np.round(np.cos(ang) * (1 << 30)).astype(np.int64)
    sin = np.round(np.sin(ang) * (1 << 30)).astype(np.int64)
    return cos, sin


def quant_q24_i32(vals):
    """Small per-layer vectors (expA, dtBias): plain int32 Q24. SPEC §1."""
    q = np.round(np.asarray(vals, dtype=np.float64) * (1 << 24)).astype(np.int64)
    assert np.abs(q).max() < INT31
    return q


# ------------------------------------------------------------- providers

class FloatProvider:
    """Adapter: float tensors for one QwenInt35. Backed either by the real
    checkpoint (qwen35_float.Qwen35) or a synthetic model (converter)."""

    def __init__(self, fm):
        self.fm = fm

    # every method returns float arrays in HF orientation
    def cfg(self):
        m = self.fm
        # derive fullInterval from layer_types and assert the periodic rule
        interval = m.layer_types.index('full_attention') + 1
        for l, t in enumerate(m.layer_types):
            assert (t == 'full_attention') == ((l + 1) % interval == 0), \
                'layer_types do not follow the (l+1)%interval rule'
        return {
            'L': m.L, 'dim': m.dim, 'nh': m.nh, 'nkv': m.nkv, 'hd': m.hd,
            'rot': m.rot, 'theta': m.theta, 'n_experts': m.n_experts,
            'top_k': m.top_k, 'moe_dim': m.moe_dim, 'shared_dim': m.shared_dim,
            'nvh': m.nvh, 'nkh': m.nkh, 'dk': m.dk, 'dv': m.dv, 'convK': m.K,
            'vocab': m.vocab, 'full_interval': interval,
        }

    def get(self, name):
        """Full-precision tensor by HF-relative name (under language_model)."""
        m = self.fm
        if hasattr(m, 'tensors'):                 # synthetic dict-backed
            return m.tensors[name]
        if name == 'lm_head.weight':
            return None                           # streamed separately
        return m.ld.get(m.P + name)

    def expert_gu_down(self, l, e):
        m = self.fm
        if hasattr(m, 'tensors'):
            return (m.tensors[f'layers.{l}.mlp.experts.gate_up_proj'][e],
                    m.tensors[f'layers.{l}.mlp.experts.down_proj'][e])
        return (m.ld.get_slice0(m.P + f'layers.{l}.mlp.experts.gate_up_proj', e),
                m.ld.get_slice0(m.P + f'layers.{l}.mlp.experts.down_proj', e))

    def emb_row(self, t):
        m = self.fm
        if hasattr(m, 'tensors'):
            return m.tensors['embed_tokens.weight'][t]
        return m.ld.get_slice0(m.P + 'embed_tokens.weight', t)

    def lm_head_rows(self, r0, r1):
        m = self.fm
        if hasattr(m, 'tensors'):
            return m.tensors['lm_head.weight'][r0:r1]
        dt, shape, off, mm = m.ld.meta('lm_head.weight')
        cols = shape[1]
        u16 = mm[off + 2 * r0 * cols: off + 2 * r1 * cols].view(np.uint16)
        return (u16.astype(np.uint32) << 16).view(np.float32).reshape(r1 - r0, cols)


# ------------------------------------------------------------ int model

class QwenInt35:
    """Integer model per SPEC.md. Weights quantized lazily from the provider;
    the converter serializes identical values (same quant functions)."""

    CLS_SLICE = 4096

    def __init__(self, provider, seq_cap=128):
        self.p = provider
        c = provider.cfg()
        self.c = c
        self.L, self.dim = c['L'], c['dim']
        self.nh, self.nkv, self.hd, self.rot = c['nh'], c['nkv'], c['hd'], c['rot']
        self.kvd = self.nkv * self.hd
        self.nvh, self.nkh, self.dk, self.dv = c['nvh'], c['nkh'], c['dk'], c['dv']
        self.key_dim = self.nkh * self.dk
        self.value_dim = self.nvh * self.dv
        self.conv_dim = 2 * self.key_dim + self.value_dim
        self.convK = c['convK']
        self.n_experts, self.top_k, self.moe_dim = c['n_experts'], c['top_k'], c['moe_dim']
        self.shared_dim = c['shared_dim']
        self.vocab = c['vocab']
        self.full_interval = c['full_interval']
        self.inv_sqrt_hd = round((1 << 32) / np.sqrt(self.hd))
        self.seq_cap = seq_cap
        self.rope_cos, self.rope_sin = rope_tables_q30(seq_cap, self.rot, c['theta'])
        self._cache = {}
        self._expert_cache = {}
        self._emb_rows = {}
        self._lm_head = None

    def is_linear(self, l):
        return (l + 1) % self.full_interval != 0

    # ------------------------------------------------------ quantization

    def _norm1p(self, name):
        """Zero-centered norm: store 1 + w (SPEC §1)."""
        return quant_i16(1.0 + self.p.get(name).astype(np.float64))

    def _rows(self, name, transform=None, wbits=1):
        w = self.p.get(name)
        if transform is not None:
            w = transform(w)
        if wbits == 2:
            q, s = quant_rows_i16(w)
        else:
            q, s = quant_rows_i8(w)
        return q.astype(np.int64), s.astype(np.int64)

    def layer_weights(self, l):
        if l in self._cache:
            return self._cache[l]
        p = f'layers.{l}.'
        w = {'ln1': self._norm1p(p + 'input_layernorm.weight'),
             'ln2': self._norm1p(p + 'post_attention_layernorm.weight')}
        if self.is_linear(l):
            la = p + 'linear_attn.'
            w['wqkv'] = self._rows(la + 'in_proj_qkv.weight')
            w['wz'] = self._rows(la + 'in_proj_z.weight')
            w['wb'] = self._rows(la + 'in_proj_b.weight')
            w['wa'] = self._rows(la + 'in_proj_a.weight')
            conv = self.p.get(la + 'conv1d.weight').reshape(self.conv_dim, self.convK)
            cq, cs = quant_rows_i8(conv)
            w['conv'] = (cq.astype(np.int64), cs.astype(np.int64))
            w['expA'] = quant_q24_i32(np.exp(self.p.get(la + 'A_log').astype(np.float64)))
            w['dtBias'] = quant_q24_i32(self.p.get(la + 'dt_bias').astype(np.float64))
            w['gnorm'] = quant_i16(self.p.get(la + 'norm.weight').astype(np.float64))
            w['wout'] = self._rows(la + 'out_proj.weight')
        else:
            sa = p + 'self_attn.'
            nH, hd, rot = self.nh, self.hd, self.rot

            def reorder_qg(wq):
                """(2*nH*hd, dim): q rows (rope-permuted) then gate rows. SPEC §3."""
                qs, gs = [], []
                for h in range(nH):
                    blk = wq[h * 2 * hd:(h + 1) * 2 * hd]
                    qs.append(permute_rope_rows_partial(blk[:hd], 1, hd, rot))
                    gs.append(blk[hd:])
                return np.concatenate(qs + gs, axis=0)

            w['wqg'] = self._rows(sa + 'q_proj.weight', reorder_qg)
            w['wk'] = self._rows(sa + 'k_proj.weight',
                                 lambda t: permute_rope_rows_partial(t, self.nkv, hd, rot))
            w['wv'] = self._rows(sa + 'v_proj.weight')
            w['wo'] = self._rows(sa + 'o_proj.weight')
            qn = permute_rope_rows_partial(
                (1.0 + self.p.get(sa + 'q_norm.weight').astype(np.float64)).reshape(-1, 1), 1, hd, rot).reshape(-1)
            kn = permute_rope_rows_partial(
                (1.0 + self.p.get(sa + 'k_norm.weight').astype(np.float64)).reshape(-1, 1), 1, hd, rot).reshape(-1)
            w['qn'] = quant_i16(qn)
            w['kn'] = quant_i16(kn)
        mp = p + 'mlp.'
        w['router'] = self._rows(mp + 'gate.weight', wbits=2)   # hi-precision rows
        w['sharedGate'] = self._rows(mp + 'shared_expert_gate.weight')
        w['sharedGU'] = self._quant_shared_gu(mp)
        w['sharedDown'] = self._rows(mp + 'shared_expert.down_proj.weight')
        self._cache[l] = w
        return w

    def _quant_shared_gu(self, mp):
        g = self.p.get(mp + 'shared_expert.gate_proj.weight')
        u = self.p.get(mp + 'shared_expert.up_proj.weight')
        q, s = quant_rows_i8(np.concatenate([g, u], axis=0))
        return q.astype(np.int64), s.astype(np.int64)

    def expert(self, l, e):
        key = (l, e)
        if key not in self._expert_cache:
            gu, dn = self.p.expert_gu_down(l, e)
            gq, gs = quant_rows_i8(gu)
            dq, ds = quant_rows_i8(dn)
            self._expert_cache[key] = (gq, gs.astype(np.int64), dq, ds.astype(np.int64))
        return self._expert_cache[key]

    def emb_row_q24(self, t):
        if t not in self._emb_rows:
            q, s = quant_rows_i8(self.p.emb_row(t).reshape(1, -1))
            self._emb_rows[t] = (q[0].astype(np.int64), int(s[0]))
        q, s = self._emb_rows[t]
        return q << (F - s)

    def final_norm(self):
        if 'final' not in self._cache:
            self._cache['final'] = self._norm1p('norm.weight')
        return self._cache['final']

    # ------------------------------------------------------------ state

    def new_cache(self, max_pos):
        cache = []
        for l in range(self.L):
            if self.is_linear(l):
                cache.append({
                    'conv': np.zeros((self.conv_dim, self.convK - 1), dtype=np.int64),  # Q16
                    'S': np.zeros((self.nvh, self.dk, self.dv), dtype=np.int64),        # Q16
                })
            else:
                cache.append({
                    'k': np.zeros((max_pos, self.kvd), dtype=np.int64),  # Q16
                    'v': np.zeros((max_pos, self.kvd), dtype=np.int64),
                })
        return cache

    # ---------------------------------------------------------- kernels

    def _deltanet(self, l, st, xb):
        w = self.layer_weights(l)
        qkv = matmul_i8(*w['wqkv'], xb)
        z = matmul_i8(*w['wz'], xb)
        b = matmul_i8(*w['wb'], xb)
        a = matmul_i8(*w['wa'], xb)

        # conv4 + SiLU (SPEC §5.2)
        s3 = qkv >> 8                                          # Q16
        buf = np.concatenate([st['conv'], s3[:, None]], axis=1)
        cq, cs = w['conv']
        acc = (cq * buf).sum(axis=1)
        y = (acc >> cs) << 8                                   # Q24
        y = np.array([silu_q24(int(v)) for v in y], dtype=np.int64)
        st['conv'] = np.ascontiguousarray(buf[:, 1:])

        q = y[:self.key_dim].reshape(self.nkh, self.dk)
        k = y[self.key_dim:2 * self.key_dim].reshape(self.nkh, self.dk)
        v = y[2 * self.key_dim:].reshape(self.nvh, self.dv)
        assert np.abs(v).max() < INT31, 'v exceeds Q24 int31 bound'

        rep = self.nvh // self.nkh
        qn = np.empty((self.nvh, self.dk), dtype=np.int64)
        kn = np.empty((self.nvh, self.dk), dtype=np.int64)
        for kh in range(self.nkh):
            qq = l2norm_q24(q[kh])
            qq = [sar(x * INV_SQRT_DK_Q32, 32) for x in qq]
            kk = l2norm_q24(k[kh])
            for r in range(rep):
                qn[kh * rep + r] = qq
                kn[kh * rep + r] = kk

        S = st['S']
        o = np.empty((self.nvh, self.dv), dtype=np.int64)
        for h in range(self.nvh):
            beta = sig_q32(int(b[h]))
            sp = softplus_q24(int(a[h]) + int(w['dtBias'][h]))
            gneg = sar(int(w['expA'][h]) * sp, 24)
            decay = exp_q32(-(gneg << 8))                      # Q32
            Sh = S[h]
            Sh[:] = (Sh * decay) >> 32
            assert np.abs(Sh).max() < INT31, 'S exceeds int32'
            kvmem = (Sh * kn[h][:, None]).sum(axis=0) >> 16    # Q24
            dvv = v[h] - kvmem
            assert np.abs(dvv).max() < INT31, 'delta pre-beta exceeds int31'
            delta = (dvv * beta) >> 32                         # Q24
            Sh += (kn[h][:, None] * delta[None, :]) >> 32      # Q16
            assert np.abs(Sh).max() < INT31, 'S exceeds int32 after update'
            o[h] = (Sh * qn[h][:, None]).sum(axis=0) >> 16     # Q24

        # gated norm + z-gate (SPEC §5.5)
        gq, gs = w['gnorm']
        on = np.empty(self.value_dim, dtype=np.int64)
        for h in range(self.nvh):
            nh = rmsnorm_int(o[h], gq, gs)
            for j in range(self.dv):
                on[h * self.dv + j] = sar(nh[j] * silu_q24(int(z[h * self.dv + j])), 24)
        return matmul_i8(*w['wout'], on)

    def _rope(self, arr, n_heads, pos):
        cos, sin = self.rope_cos[pos], self.rope_sin[pos]
        half = self.rot // 2
        for h in range(n_heads):
            for p in range(half):
                c, s = int(cos[p]), int(sin[p])
                i0 = h * self.hd + 2 * p
                v0, v1 = int(arr[i0]), int(arr[i0 + 1])
                arr[i0] = sar(v0 * c - v1 * s, 30)
                arr[i0 + 1] = sar(v0 * s + v1 * c, 30)

    def _attention(self, l, st, xb, pos):
        w = self.layer_weights(l)
        qg = matmul_i8(*w['wqg'], xb)
        q = qg[:self.nh * self.hd].copy()
        gate = qg[self.nh * self.hd:]
        k = matmul_i8(*w['wk'], xb)
        v = matmul_i8(*w['wv'], xb)

        qn, qs = w['qn']
        kn, ks = w['kn']
        for h in range(self.nh):
            q[h * self.hd:(h + 1) * self.hd] = rmsnorm_int(q[h * self.hd:(h + 1) * self.hd], qn, qs)
        for h in range(self.nkv):
            k[h * self.hd:(h + 1) * self.hd] = rmsnorm_int(k[h * self.hd:(h + 1) * self.hd], kn, ks)
        self._rope(q, self.nh, pos)
        self._rope(k, self.nkv, pos)

        st['k'][pos] = k >> 8
        st['v'][pos] = v >> 8
        steps = pos + 1
        kc, vc = st['k'][:steps], st['v'][:steps]
        kv_mul = self.nh // self.nkv
        xatt = np.zeros(self.nh * self.hd, dtype=np.int64)
        for h in range(self.nh):
            kvo = (h // kv_mul) * self.hd
            qh = q[h * self.hd:(h + 1) * self.hd]
            acc = kc[:, kvo:kvo + self.hd] @ qh
            sc = [sar(sar(int(x), 16) * self.inv_sqrt_hd, 32) for x in acc]
            mx = max(sc)
            exps = [exp_q24(s - mx) for s in sc]
            tot = sum(exps)
            # vectorized weighted v-sum: e (<=2^24) * v16 (<=2^20) * steps -> < 2^63
            ev = (np.array(exps, dtype=np.int64)[:, None] * vc[:, kvo:kvo + self.hd]).sum(axis=0)
            for j in range(self.hd):
                aj = sdiv(int(ev[j]) << 8, tot)                # Q24
                gj = int(gate[h * self.hd + j])
                xatt[h * self.hd + j] = sar(aj * sig_q32(gj), 32)
        return matmul_i8(*w['wo'], xatt)

    def _swiglu(self, g, u):
        out = np.empty(len(g), dtype=np.int64)
        for i in range(len(g)):
            out[i] = sar(silu_q24(int(g[i])) * int(u[i]), 24)
        return out

    def _moe(self, l, xb):
        w = self.layer_weights(l)
        sg = sig_q32(int(matmul_i8(*w['sharedGate'], xb)[0]))
        gu = matmul_i8(*w['sharedGU'], xb)
        hb = self._swiglu(gu[:self.shared_dim], gu[self.shared_dim:])
        shared = matmul_i8(*w['sharedDown'], hb)

        # top-k over RAW router logits (softmax is monotone; avoids exp_q24
        # resolution ties in the ordering) — SPEC §7 (changelog 2026-07-12)
        rl = matmul_i8(*w['router'], xb)
        sel = []
        taken = [False] * self.n_experts
        for _ in range(self.top_k):
            best, bi = None, -1
            for i in range(self.n_experts):
                if not taken[i] and (best is None or int(rl[i]) > best):
                    best, bi = int(rl[i]), i
            sel.append(bi)
            taken[bi] = True
        mx = int(rl[sel[0]])                       # == global max
        e = {i: exp_q24(int(rl[i]) - mx) for i in sel}
        tot = sum(e[i] for i in sel)
        acc = np.zeros(self.dim, dtype=np.int64)
        for i in sel:
            wq32 = (e[i] << 32) // tot
            gq, gs, dq, ds = self.expert(l, i)
            gu = matmul_i8(gq.astype(np.int64), gs, xb)
            hb = self._swiglu(gu[:self.moe_dim], gu[self.moe_dim:])
            y = matmul_i8(dq.astype(np.int64), ds, hb)
            acc += _scale_q32(y, wq32)
        return acc + _scale_q32(shared, sg)

    # ---------------------------------------------------------- forward

    def forward(self, cache, token, pos, want_logits=True):
        x = self.emb_row_q24(token)
        for l in range(self.L):
            w = self.layer_weights(l)
            xb = np.array(rmsnorm_int(x, *w['ln1']), dtype=np.int64)
            if self.is_linear(l):
                x = x + self._deltanet(l, cache[l], xb)
            else:
                x = x + self._attention(l, cache[l], xb, pos)
            xb = np.array(rmsnorm_int(x, *w['ln2']), dtype=np.int64)
            x = x + self._moe(l, xb)
        if not want_logits:
            return None
        xb = np.array(rmsnorm_int(x, *self.final_norm()), dtype=np.int64)
        return self.logits_from_hidden(xb)

    def _ensure_lm_head(self):
        """Quantize the classifier once; kept int8 (+ per-row shifts)."""
        if self._lm_head is None:
            qs, ss = [], []
            for r0 in range(0, self.vocab, self.CLS_SLICE):
                r1 = min(r0 + self.CLS_SLICE, self.vocab)
                q, s = quant_rows_i8(self.p.lm_head_rows(r0, r1))
                qs.append(q)
                ss.append(s)
            self._lm_head = (np.concatenate(qs, axis=0),
                             np.concatenate(ss).astype(np.int64))
        return self._lm_head

    def logits_from_hidden(self, xb):
        q, s = self._ensure_lm_head()
        out = np.empty(self.vocab, dtype=np.int64)
        for r0 in range(0, self.vocab, self.CLS_SLICE):
            r1 = min(r0 + self.CLS_SLICE, self.vocab)
            out[r0:r1] = matmul_i8(q[r0:r1].astype(np.int64), s[r0:r1], xb)
        return out

    def generate(self, ids, n_new, stop_ids=(248046, 248044), progress=None):
        max_pos = len(ids) + n_new
        assert max_pos <= self.seq_cap
        cache = self.new_cache(max_pos)
        out = []
        token = ids[0]
        for pos in range(max_pos - 1):
            need = pos + 1 >= len(ids)
            logits = self.forward(cache, token, pos, want_logits=need)
            if not need:
                nxt = ids[pos + 1]
            else:
                nxt = int(np.argmax(logits))      # first maximum wins
                out.append(nxt)
                if progress:
                    progress(pos, nxt)
                if nxt in stop_ids:
                    break
            token = nxt
        return out


def main():
    import argparse
    import json
    import time
    ap = argparse.ArgumentParser()
    ap.add_argument('--prompt', default='What is Ethereum?')
    ap.add_argument('-n', type=int, default=32)
    ap.add_argument('--out', default=None, help='write gen json here')
    args = ap.parse_args()

    from qwen35_float import Qwen35, chat_ids
    tok, ids = chat_ids(args.prompt)
    print('prompt ids:', ids, file=sys.stderr)
    im = QwenInt35(FloatProvider(Qwen35()), seq_cap=len(ids) + args.n + 8)
    t0 = time.time()

    def prog(pos, nxt):
        print(f'pos {pos} -> {nxt} ({time.time()-t0:.0f}s)', file=sys.stderr, flush=True)

    out = im.generate(ids, args.n, progress=prog)
    print('int ids:', out, file=sys.stderr)
    text = tok.decode(out)
    print(text)
    if args.out:
        json.dump({'prompt_ids': list(ids), 'gen_ids': out, 'text': text},
                  open(args.out, 'w'), indent=1)


if __name__ == '__main__':
    main()
