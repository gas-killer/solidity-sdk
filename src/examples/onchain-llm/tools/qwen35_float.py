"""Float reference for Qwen3.5-35B-A3B text decoder — architecture ground truth.

From-scratch numpy implementation of the qwen3_5_moe text forward pass, written
against transformers' modeling_qwen3_5_moe.py (vendored copy:
modeling_qwen3_5_moe_github.py). No torch needed at inference time; bf16
shards are memmapped and converted per-tensor / per-expert-slice.

Architecture (Qwen3.5-35B-A3B):
  40 layers; hidden 2048; layer_types: 30x linear_attention (Gated DeltaNet)
  + 10x full_attention (every 4th, l%4==3).
  - RMSNorm everywhere is ZERO-CENTERED: y = x/sqrt(mean(x^2)+eps) * (1+w)
    (Qwen3_5MoeRMSNorm; eps 1e-6) — EXCEPT the DeltaNet gated output norm
    (Qwen3_5MoeRMSNormGated), whose weight is used directly (ones-init):
    y = x/sqrt(mean(x^2)+eps) * w * silu(z).
  - full attention: 16 Q heads / 2 KV heads, head_dim 256; q_proj emits
    per-head [q(256) || gate(256)] (2*nH*hd rows); q/k per-head zero-centered
    RMSNorm BEFORE RoPE; partial RoPE over first 64 dims (theta 1e7, HF
    half-dim pairs (j, j+32) within the rotary part); softmax(q.k/16);
    attn_out *= sigmoid(gate) before o_proj. mrope collapses to standard RoPE
    for text-only (all 3 position sections equal).
  - linear attention (Gated DeltaNet): in_proj_qkv (2048->8192 = q2048|k2048
    |v4096), in_proj_z (->4096), in_proj_b (->32), in_proj_a (->32);
    depthwise causal conv4 (NO bias) over qkv channels then SiLU; q,k heads
    (16x128) repeat_interleave -> 32; per-head l2norm(x)=x*rsqrt(sum(x^2)+1e-6)
    on q,k; q *= 1/sqrt(128); beta=sigmoid(b);
    g = -exp(A_log)*softplus(a+dt_bias); per v-head state S[128k,128v]:
      S = S*exp(g); kv_mem = S^T k; delta = (v - kv_mem)*beta;
      S += outer(k, delta); o = S^T q
    then per-head gated norm (see above), out_proj (4096->2048).
  - MoE every layer: router (2048->256, no bias) -> softmax(ALL experts,
    fp32) -> top-8 probs -> renormalize; experts gate_up fused (1024x2048,
    gate=rows 0..511, up=rows 512..1023), down (2048x512); PLUS shared expert
    (512) scaled by sigmoid(shared_expert_gate(x)) — added to sparse output.
  - untied lm_head. vocab 248320 (top 250 ids unused by tokenizer).
"""
import argparse
import json
import os
import struct
import sys

import numpy as np

MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'model')


def softplus(x):
    x = np.asarray(x, dtype=np.float64)
    return np.where(x > 30, x, np.log1p(np.exp(np.minimum(x, 30))))


def sigmoid(x):
    x = np.asarray(x, dtype=np.float64)
    return np.where(x >= 0, 1.0 / (1.0 + np.exp(-x)), np.exp(np.maximum(x, -745)) / (1.0 + np.exp(np.maximum(x, -745))))


def silu(x):
    return x * sigmoid(x)


class ShardedLoader:
    """Memmap-backed loader over a sharded safetensors checkpoint."""

    def __init__(self, model_dir):
        self.dir = model_dir
        idx = json.load(open(os.path.join(model_dir, 'model.safetensors.index.json')))
        self.weight_map = idx['weight_map']
        self.headers = {}   # shard -> (header dict, data base offset)
        self.mmaps = {}     # shard -> np.memmap uint8

    def _shard(self, shard):
        if shard not in self.headers:
            path = os.path.join(self.dir, shard)
            with open(path, 'rb') as f:
                hlen = struct.unpack('<Q', f.read(8))[0]
                header = json.loads(f.read(hlen))
            self.headers[shard] = (header, 8 + hlen)
            self.mmaps[shard] = np.memmap(path, dtype=np.uint8, mode='r')
        return self.headers[shard], self.mmaps[shard]

    def meta(self, name):
        shard = self.weight_map[name]
        (header, base), mm = self._shard(shard)
        m = header[name]
        return m['dtype'], m['shape'], base + m['data_offsets'][0], mm

    def get(self, name, dtype=np.float32):
        """Full tensor -> float array."""
        dt, shape, off, mm = self.meta(name)
        n = int(np.prod(shape))
        if dt == 'BF16':
            u16 = mm[off:off + 2 * n].view(np.uint16)
            arr = (u16.astype(np.uint32) << 16).view(np.float32)
        elif dt == 'F32':
            arr = mm[off:off + 4 * n].view(np.float32)
        else:
            raise ValueError(f'unsupported dtype {dt} for {name}')
        return np.ascontiguousarray(arr.reshape(shape).astype(dtype))

    def get_slice0(self, name, i, dtype=np.float32):
        """tensor[i] along axis 0 (e.g. one expert / one embedding row)."""
        dt, shape, off, mm = self.meta(name)
        assert dt == 'BF16'
        sub = int(np.prod(shape[1:]))
        start = off + 2 * i * sub
        u16 = mm[start:start + 2 * sub].view(np.uint16)
        arr = (u16.astype(np.uint32) << 16).view(np.float32)
        return arr.reshape(shape[1:]).astype(dtype)

    def matvec_rows(self, name, x, chunk=8192):
        """(rows, cols) @ x streamed in row chunks; returns float32 (rows,)."""
        dt, shape, off, mm = self.meta(name)
        assert dt == 'BF16'
        rows, cols = shape
        out = np.empty(rows, dtype=np.float32)
        xf = x.astype(np.float32)
        for r0 in range(0, rows, chunk):
            r1 = min(r0 + chunk, rows)
            u16 = mm[off + 2 * r0 * cols: off + 2 * r1 * cols].view(np.uint16)
            w = (u16.astype(np.uint32) << 16).view(np.float32).reshape(r1 - r0, cols)
            out[r0:r1] = w @ xf
        return out


class Qwen35:
    P = 'model.language_model.'

    def __init__(self, model_dir=MODEL_DIR):
        cfg = json.load(open(os.path.join(model_dir, 'config.json')))['text_config']
        self.eps = cfg['rms_norm_eps']                     # 1e-6
        self.L = cfg['num_hidden_layers']                  # 40
        self.dim = cfg['hidden_size']                      # 2048
        self.layer_types = cfg['layer_types']
        self.nh = cfg['num_attention_heads']               # 16
        self.nkv = cfg['num_key_value_heads']              # 2
        self.hd = cfg['head_dim']                          # 256
        rp = cfg['rope_parameters']
        self.rot = int(self.hd * rp['partial_rotary_factor'])  # 64
        self.theta = rp['rope_theta']                      # 1e7
        self.n_experts = cfg['num_experts']                # 256
        self.top_k = cfg['num_experts_per_tok']            # 8
        self.moe_dim = cfg['moe_intermediate_size']        # 512
        self.shared_dim = cfg['shared_expert_intermediate_size']  # 512
        self.nvh = cfg['linear_num_value_heads']           # 32
        self.nkh = cfg['linear_num_key_heads']             # 16
        self.dk = cfg['linear_key_head_dim']               # 128
        self.dv = cfg['linear_value_head_dim']             # 128
        self.key_dim = self.nkh * self.dk                  # 2048
        self.value_dim = self.nvh * self.dv                # 4096
        self.conv_dim = 2 * self.key_dim + self.value_dim  # 8192
        self.K = cfg['linear_conv_kernel_dim']             # 4
        self.vocab = cfg['vocab_size']

        self.ld = ShardedLoader(model_dir)
        self._f32 = {}

    def w(self, name):
        """Cached f32 tensor (small/medium tensors only)."""
        if name not in self._f32:
            self._f32[name] = self.ld.get(self.P + name if not name.startswith('lm_head') else name)
        return self._f32[name]

    # ---------------------------------------------------------------- norms

    def rmsnorm_zc(self, x, g):
        """Zero-centered rmsnorm: x/sqrt(mean(x^2)+eps) * (1+g)."""
        x = x.astype(np.float64)
        return (x / np.sqrt(np.mean(x * x) + self.eps) * (1.0 + g.astype(np.float64)))

    def rmsnorm_zc_rows(self, x, g):
        x = x.astype(np.float64)
        return x / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + self.eps) * (1.0 + g.astype(np.float64))

    # ---------------------------------------------------------------- state

    def new_cache(self):
        cache = []
        for lt in self.layer_types:
            if lt == 'linear_attention':
                cache.append({
                    'conv': np.zeros((self.conv_dim, self.K - 1), dtype=np.float64),  # last K-1 pre-conv inputs
                    'S': np.zeros((self.nvh, self.dk, self.dv), dtype=np.float64),
                })
            else:
                cache.append({'k': [], 'v': []})
        return cache

    # -------------------------------------------------------------- kernels

    def _deltanet(self, li, st, xn):
        p = f'layers.{li}.linear_attn.'
        qkv = self.w(p + 'in_proj_qkv.weight').astype(np.float64) @ xn        # (8192,)
        z = self.w(p + 'in_proj_z.weight').astype(np.float64) @ xn           # (4096,)
        b = self.w(p + 'in_proj_b.weight').astype(np.float64) @ xn           # (32,)
        a = self.w(p + 'in_proj_a.weight').astype(np.float64) @ xn           # (32,)

        # depthwise causal conv4 (no bias) + SiLU over qkv channels
        convw = self.w(p + 'conv1d.weight').reshape(self.conv_dim, self.K).astype(np.float64)
        buf = np.concatenate([st['conv'], qkv[:, None]], axis=1)             # (8192, K)
        y = silu(np.sum(convw * buf, axis=1))                                # (8192,)
        st['conv'] = buf[:, 1:]                                              # roll window

        q = y[:self.key_dim].reshape(self.nkh, self.dk)
        k = y[self.key_dim:2 * self.key_dim].reshape(self.nkh, self.dk)
        v = y[2 * self.key_dim:].reshape(self.nvh, self.dv)
        rep = self.nvh // self.nkh
        q = np.repeat(q, rep, axis=0)                                        # (32,128)
        k = np.repeat(k, rep, axis=0)

        # l2norm (eps INSIDE the sum, not mean), then q scaled by 1/sqrt(dk)
        q = q / np.sqrt(np.sum(q * q, axis=-1, keepdims=True) + 1e-6)
        k = k / np.sqrt(np.sum(k * k, axis=-1, keepdims=True) + 1e-6)
        q = q / np.sqrt(self.dk)

        beta = sigmoid(b)                                                    # (32,)
        A_log = self.w(p + 'A_log').astype(np.float64)
        dt_bias = self.w(p + 'dt_bias').astype(np.float64)
        g = -np.exp(A_log) * softplus(a + dt_bias)                           # (32,) <= 0
        decay = np.exp(g)

        S = st['S']                                                          # (32,128k,128v)
        S *= decay[:, None, None]
        kv_mem = np.einsum('hkv,hk->hv', S, k)
        delta = (v - kv_mem) * beta[:, None]
        S += k[:, :, None] * delta[:, None, :]
        o = np.einsum('hkv,hk->hv', S, q)                                    # (32,128)

        # gated per-head norm: rmsnorm(o) * w * silu(z)   (w NOT zero-centered)
        nw = self.w(p + 'norm.weight').astype(np.float64)                    # (128,)
        on = o / np.sqrt(np.mean(o * o, axis=-1, keepdims=True) + self.eps) * nw
        on = on * silu(z.reshape(self.nvh, self.dv))
        return self.w(p + 'out_proj.weight').astype(np.float64) @ on.reshape(-1)

    def _rope(self, x, pos):
        """Partial RoPE on rows (heads, hd): rotate first `rot` dims, pairs (j, j+rot/2)."""
        half = self.rot // 2                                                  # 32
        inv = self.theta ** (-np.arange(half, dtype=np.float64) * 2.0 / self.rot)
        ang = pos * inv
        cos, sin = np.cos(ang), np.sin(ang)
        x1 = x[:, :half].copy()
        x2 = x[:, half:self.rot].copy()
        x[:, :half] = x1 * cos - x2 * sin
        x[:, half:self.rot] = x2 * cos + x1 * sin
        return x

    def _attention(self, li, st, xn, pos):
        p = f'layers.{li}.self_attn.'
        qg = self.w(p + 'q_proj.weight').astype(np.float64) @ xn             # (2*nh*hd,)
        qg = qg.reshape(self.nh, 2 * self.hd)
        q = qg[:, :self.hd].copy()                                           # (16,256)
        gate = qg[:, self.hd:].copy()                                        # (16,256)
        k = (self.w(p + 'k_proj.weight').astype(np.float64) @ xn).reshape(self.nkv, self.hd)
        v = (self.w(p + 'v_proj.weight').astype(np.float64) @ xn).reshape(self.nkv, self.hd)

        q = self.rmsnorm_zc_rows(q, self.w(p + 'q_norm.weight'))
        k = self.rmsnorm_zc_rows(k, self.w(p + 'k_norm.weight'))
        q = self._rope(q, pos)
        k = self._rope(k, pos)

        st['k'].append(k)
        st['v'].append(v)
        ks = np.stack(st['k'])                                               # (T,2,256)
        vs = np.stack(st['v'])
        kv_mul = self.nh // self.nkv
        out = np.empty((self.nh, self.hd))
        for h in range(self.nh):
            kh = h // kv_mul
            sc = ks[:, kh, :] @ q[h] / np.sqrt(self.hd)
            e = np.exp(sc - sc.max())
            pr = e / e.sum()
            out[h] = pr @ vs[:, kh, :]
        out = out * sigmoid(gate)
        return self.w(p + 'o_proj.weight').astype(np.float64) @ out.reshape(-1)

    def _moe(self, li, xn):
        p = f'layers.{li}.mlp.'
        # shared expert (always on), scaled by sigmoid(shared_expert_gate . x)
        sg = sigmoid(self.w(p + 'shared_expert_gate.weight').astype(np.float64) @ xn)[0]
        gs = self.w(p + 'shared_expert.gate_proj.weight').astype(np.float64) @ xn
        us = self.w(p + 'shared_expert.up_proj.weight').astype(np.float64) @ xn
        shared = self.w(p + 'shared_expert.down_proj.weight').astype(np.float64) @ (silu(gs) * us)

        logits = self.w(p + 'gate.weight').astype(np.float64) @ xn           # (256,)
        probs = np.exp(logits - logits.max())
        probs = probs / probs.sum()
        topk = np.argsort(-probs, kind='stable')[:self.top_k]
        wts = probs[topk]
        wts = wts / wts.sum()

        acc = np.zeros(self.dim)
        for e, wt in zip(topk, wts):
            gu = self.ld.get_slice0(self.P + p + 'experts.gate_up_proj', int(e)).astype(np.float64)  # (1024,2048)
            dn = self.ld.get_slice0(self.P + p + 'experts.down_proj', int(e)).astype(np.float64)     # (2048,512)
            g = gu[:self.moe_dim] @ xn
            u = gu[self.moe_dim:] @ xn
            acc += wt * (dn @ (silu(g) * u))
        return acc + sg * shared

    # -------------------------------------------------------------- forward

    def forward(self, cache, token, pos, want_logits=True):
        x = self.ld.get_slice0(self.P + 'embed_tokens.weight', token).astype(np.float64)
        for li in range(self.L):
            st = cache[li]
            xn = self.rmsnorm_zc(x, self.w(f'layers.{li}.input_layernorm.weight'))
            if self.layer_types[li] == 'linear_attention':
                x = x + self._deltanet(li, st, xn)
            else:
                x = x + self._attention(li, st, xn, pos)
            xn = self.rmsnorm_zc(x, self.w(f'layers.{li}.post_attention_layernorm.weight'))
            x = x + self._moe(li, xn)
        if not want_logits:
            return None
        xn = self.rmsnorm_zc(x, self.w('norm.weight'))
        return self.ld.matvec_rows('lm_head.weight', xn.astype(np.float32))

    def generate(self, ids, n_new, stop_ids=(248046, 248044), progress=True):
        cache = self.new_cache()
        out = []
        token = ids[0]
        pos = 0
        while pos < len(ids) + n_new - 1:
            need = pos + 1 >= len(ids)
            logits = self.forward(cache, token, pos, want_logits=need)
            if not need:
                nxt = ids[pos + 1]
            else:
                nxt = int(np.argmax(logits))
                out.append(nxt)
                if progress:
                    print(f'  pos {pos} -> {nxt}', file=sys.stderr, flush=True)
                if nxt in stop_ids:
                    break
            token = nxt
            pos += 1
        return out


def chat_ids(prompt, model_dir=MODEL_DIR):
    from tokenizers import Tokenizer
    tok = Tokenizer.from_file(os.path.join(model_dir, 'tokenizer.json'))
    text = f'<|im_start|>user\n{prompt}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'
    return tok, tok.encode(text).ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--prompt', default='What is Ethereum?')
    ap.add_argument('-n', type=int, default=24)
    args = ap.parse_args()
    tok, ids = chat_ids(args.prompt)
    print('prompt ids:', ids, file=sys.stderr)
    model = Qwen35()
    out = model.generate(ids, args.n)
    print('out ids:', out, file=sys.stderr)
    print(tok.decode(out))


if __name__ == '__main__':
    main()
