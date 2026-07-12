"""Synthetic tiny qwen3_5_moe-shaped model (float side) for CI fixtures."""
import numpy as np


class SyntheticFloat35:
    def __init__(self, seed=1337, L=3, full_interval=3, dim=64, nh=2, nkv=1, hd=32,
                 nvh=4, nkh=2, dk=16, dv=16, convK=4, n_experts=4, top_k=2,
                 moe_dim=32, shared_dim=32, vocab=256, theta=1e7):
        rng = np.random.default_rng(seed)
        self.L, self.dim, self.nh, self.nkv, self.hd = L, dim, nh, nkv, hd
        self.rot = hd // 4
        self.theta = theta
        self.n_experts, self.top_k, self.moe_dim, self.shared_dim = n_experts, top_k, moe_dim, shared_dim
        self.nvh, self.nkh, self.dk, self.dv, self.K = nvh, nkh, dk, dv, convK
        self.vocab = vocab
        self.layer_types = ['full_attention' if (l + 1) % full_interval == 0
                            else 'linear_attention' for l in range(L)]
        key_dim, value_dim = nkh * dk, nvh * dv
        conv_dim = 2 * key_dim + value_dim

        def t(*shape, scale=0.5):
            return (rng.standard_normal(shape) * scale).astype(np.float32)

        T = {'embed_tokens.weight': t(vocab, dim, scale=0.5),
             'lm_head.weight': t(vocab, dim, scale=0.5),
             'norm.weight': t(dim, scale=0.2)}          # zero-centered
        for l in range(L):
            p = f'layers.{l}.'
            T[p + 'input_layernorm.weight'] = t(dim, scale=0.2)
            T[p + 'post_attention_layernorm.weight'] = t(dim, scale=0.2)
            if self.layer_types[l] == 'linear_attention':
                la = p + 'linear_attn.'
                T[la + 'in_proj_qkv.weight'] = t(conv_dim, dim, scale=0.35)
                T[la + 'in_proj_z.weight'] = t(value_dim, dim, scale=0.35)
                T[la + 'in_proj_b.weight'] = t(nvh, dim, scale=0.35)
                T[la + 'in_proj_a.weight'] = t(nvh, dim, scale=0.35)
                T[la + 'conv1d.weight'] = t(conv_dim, 1, convK, scale=0.25)
                T[la + 'A_log'] = np.log(rng.uniform(1, 8, nvh)).astype(np.float32)
                T[la + 'dt_bias'] = t(nvh, scale=0.5) + 1.0
                T[la + 'norm.weight'] = 1.0 + t(dv, scale=0.2)   # NOT zero-centered
                T[la + 'out_proj.weight'] = t(dim, value_dim, scale=0.3)
            else:
                sa = p + 'self_attn.'
                T[sa + 'q_proj.weight'] = t(2 * nh * hd, dim)
                T[sa + 'k_proj.weight'] = t(nkv * hd, dim)
                T[sa + 'v_proj.weight'] = t(nkv * hd, dim)
                T[sa + 'o_proj.weight'] = t(dim, nh * hd)
                T[sa + 'q_norm.weight'] = t(hd, scale=0.2)       # zero-centered
                T[sa + 'k_norm.weight'] = t(hd, scale=0.2)
            mp = p + 'mlp.'
            T[mp + 'gate.weight'] = t(n_experts, dim, scale=0.4)
            T[mp + 'shared_expert_gate.weight'] = t(1, dim, scale=0.4)
            T[mp + 'shared_expert.gate_proj.weight'] = t(shared_dim, dim, scale=0.3)
            T[mp + 'shared_expert.up_proj.weight'] = t(shared_dim, dim, scale=0.3)
            T[mp + 'shared_expert.down_proj.weight'] = t(dim, shared_dim, scale=0.3)
            T[mp + 'experts.gate_up_proj'] = t(n_experts, 2 * moe_dim, dim, scale=0.3)
            T[mp + 'experts.down_proj'] = t(n_experts, dim, moe_dim, scale=0.3)
        self.tensors = T
