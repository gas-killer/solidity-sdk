"""Float32 numpy reference for Qwen3-0.6B — architecture ground truth.

No torch/transformers: parses safetensors directly (bf16 -> f32) and implements
the Qwen3 forward pass from the paper/HF source:
  pre-norm RMSNorm(eps 1e-6) -> q/k/v proj (no bias) -> per-head QK-RMSNorm ->
  RoPE (HF half-dim rotation, theta 1e6) -> GQA -> o proj -> residual ->
  RMSNorm -> SwiGLU MLP -> residual; final norm; tied-embedding classifier.

Used to (a) prove the architecture port is right (coherent greedy chat output)
and (b) provide the float baseline the integer reference is validated against.
"""
import argparse
import json
import struct
import sys

import numpy as np


def load_safetensors(path):
    with open(path, 'rb') as f:
        hlen = struct.unpack('<Q', f.read(8))[0]
        header = json.loads(f.read(hlen))
        base = 8 + hlen
        tensors = {}
        for name, meta in header.items():
            if name == '__metadata__':
                continue
            tensors[name] = (meta['dtype'], meta['shape'], base + meta['data_offsets'][0],
                             meta['data_offsets'][1] - meta['data_offsets'][0])
    return tensors


class Loader:
    def __init__(self, path):
        self.path = path
        self.meta = load_safetensors(path)
        self.f = open(path, 'rb')

    def names(self):
        return sorted(self.meta)

    def get(self, name):
        dtype, shape, off, nbytes = self.meta[name]
        self.f.seek(off)
        raw = self.f.read(nbytes)
        if dtype == 'BF16':
            u16 = np.frombuffer(raw, dtype=np.uint16)
            arr = (u16.astype(np.uint32) << 16).view(np.float32)
        elif dtype == 'F32':
            arr = np.frombuffer(raw, dtype=np.float32)
        else:
            raise ValueError(f'unsupported dtype {dtype}')
        return arr.reshape(shape).astype(np.float32)


def rmsnorm(x, w, eps):
    return x / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + eps) * w


def rope_half(x, pos, theta):
    """HF-style rotation: pairs are (i, i + hd/2). x shape (heads, hd)."""
    hd = x.shape[-1]
    half = hd // 2
    inv = theta ** (-np.arange(half, dtype=np.float64) / half)
    ang = pos * inv
    cos, sin = np.cos(ang).astype(np.float32), np.sin(ang).astype(np.float32)
    x1, x2 = x[..., :half], x[..., half:]
    return np.concatenate([x1 * cos - x2 * sin, x2 * cos + x1 * sin], axis=-1)


class Qwen3:
    def __init__(self, model_path, config_path):
        cfg = json.load(open(config_path))
        self.eps = cfg['rms_norm_eps']
        self.theta = cfg['rope_theta']
        self.L = cfg['num_hidden_layers']
        self.nh = cfg['num_attention_heads']
        self.nkv = cfg['num_key_value_heads']
        self.hd = cfg['head_dim']
        self.dim = cfg['hidden_size']
        ld = Loader(model_path)
        g = ld.get
        self.emb = g('model.embed_tokens.weight')
        self.layers = []
        for i in range(self.L):
            p = f'model.layers.{i}.'
            self.layers.append({
                'ln1': g(p + 'input_layernorm.weight'),
                'wq': g(p + 'self_attn.q_proj.weight'),
                'wk': g(p + 'self_attn.k_proj.weight'),
                'wv': g(p + 'self_attn.v_proj.weight'),
                'wo': g(p + 'self_attn.o_proj.weight'),
                'qn': g(p + 'self_attn.q_norm.weight'),
                'kn': g(p + 'self_attn.k_norm.weight'),
                'ln2': g(p + 'post_attention_layernorm.weight'),
                'wg': g(p + 'mlp.gate_proj.weight'),
                'wu': g(p + 'mlp.up_proj.weight'),
                'wd': g(p + 'mlp.down_proj.weight'),
            })
        self.norm = g('model.norm.weight')
        # prefer the tied embedding even if the file ships an lm_head copy
        self.cls = self.emb

    def new_cache(self):
        return [{'k': [], 'v': []} for _ in range(self.L)]

    def forward(self, cache, token, pos):
        x = self.emb[token].copy()
        kv_mul = self.nh // self.nkv
        for li, w in enumerate(self.layers):
            h = rmsnorm(x, w['ln1'], self.eps)
            q = (w['wq'] @ h).reshape(self.nh, self.hd)
            k = (w['wk'] @ h).reshape(self.nkv, self.hd)
            v = (w['wv'] @ h).reshape(self.nkv, self.hd)
            q = rmsnorm(q, w['qn'], self.eps)
            k = rmsnorm(k, w['kn'], self.eps)
            q = rope_half(q, pos, self.theta)
            k = rope_half(k, pos, self.theta)
            c = cache[li]
            c['k'].append(k)
            c['v'].append(v)
            ks = np.stack(c['k'])            # (T, nkv, hd)
            vs = np.stack(c['v'])
            out = np.empty((self.nh, self.hd), dtype=np.float32)
            for hh in range(self.nh):
                kvh = hh // kv_mul
                sc = ks[:, kvh, :] @ q[hh] / np.sqrt(self.hd)
                sc = sc - sc.max()
                e = np.exp(sc)
                p = e / e.sum()
                out[hh] = p @ vs[:, kvh, :]
            x = x + w['wo'] @ out.reshape(-1)
            h = rmsnorm(x, w['ln2'], self.eps)
            gate = w['wg'] @ h
            up = w['wu'] @ h
            act = gate / (1.0 + np.exp(-gate)) * up
            x = x + w['wd'] @ act
        x = rmsnorm(x, self.norm, self.eps)
        return self.cls @ x

    def generate(self, ids, n_new, stop_ids=(151643, 151645)):
        cache = self.new_cache()
        out = []
        token = ids[0]
        pos = 0
        while pos < len(ids) + n_new - 1:
            logits = self.forward(cache, token, pos)
            if pos + 1 < len(ids):
                nxt = ids[pos + 1]
            else:
                nxt = int(np.argmax(logits))
                out.append(nxt)
                if nxt in stop_ids:
                    break
            token = nxt
            pos += 1
        return out


def chat_ids(tok_json, prompt):
    from tokenizers import Tokenizer
    tok = Tokenizer.from_file(tok_json)
    text = f'<|im_start|>user\n{prompt}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'
    return tok, tok.encode(text).ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', default='.context/qwen3/model.safetensors')
    ap.add_argument('--config', default='.context/qwen3/config.json')
    ap.add_argument('--tokenizer', default='.context/qwen3/tokenizer.json')
    ap.add_argument('--prompt', default='What is Ethereum?')
    ap.add_argument('-n', type=int, default=40)
    args = ap.parse_args()

    tok, ids = chat_ids(args.tokenizer, args.prompt)
    print('prompt ids:', ids, file=sys.stderr)
    model = Qwen3(args.model, args.config)
    out = model.generate(ids, args.n)
    print('out ids:', out, file=sys.stderr)
    print(tok.decode(out))


if __name__ == '__main__':
    main()
