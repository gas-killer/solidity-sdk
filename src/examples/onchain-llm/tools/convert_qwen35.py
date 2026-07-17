"""Convert Qwen3.5-35B-A3B (qwen3_5_moe) into on-chain engine-v3 artifacts.

Layout, formats and semantics: .context/qwen35/SPEC.md. Quantized values come
from the SAME code paths as the integer reference (qwen35_int.QwenInt35), so
the serialized blob is bit-identical to what the reference computes with.

Outputs (into --out):
  weights.bin    streamed in engine read order (SPEC §3)
  tokenizer.bin  v2 type-1 raw-bytes token table (248320 entries)
  vectors.json   packedConfig (bytes32[4]) + promptIds + logitsPos0 + gens
  manifest.json  keccak manifest + overlay chunk derivation + chunk counts
plus --sol-out/<name>.sol (packed config library) and, for the real model,
qwen35-tokenizer.json (site vocab+merges) via --site-tokenizer.

--synthetic builds the tiny CI model (SPEC-shaped: 2 DeltaNet + 1 full-attn
layer, 4 experts top-2 + shared) and its test vectors.

Disk discipline: --delete-shards removes each bf16 shard once every tensor it
holds has been serialized (the weight blob is written in engine order, so
shards are released as the layer sweep passes them).
"""
import argparse
import json
import os
import struct
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from qwen3_convert import (CHUNK_MAX, abi_encode_int256_array,  # noqa: E402
                           build_tokenizer_blob, pack_1d_i16, token_raw_bytes)
from qwen35_int import (FloatProvider, QwenInt35, rmsnorm_int)  # noqa: E402


def keccak256(data):
    from Crypto.Hash import keccak as _k
    h = _k.new(digest_bits=256)
    h.update(data)
    return h.digest()


OVERLAY_DOMAIN = b'gaskiller.llm.overlay.v1'


# ------------------------------------------------------------- serialization

def pack_rows_i8(q, shifts):
    """rows of [u8 shift || int8 x cols]."""
    rows, cols = q.shape
    out = np.empty((rows, 1 + cols), dtype=np.uint8)
    out[:, 0] = np.asarray(shifts, dtype=np.uint8)
    out[:, 1:] = np.asarray(q, dtype=np.int8).view(np.uint8)
    return out.tobytes()


def pack_rows_i16(q, shifts):
    """hi-precision rows [u8 shift || int16(BE) x cols] (router; SPEC rev 2)."""
    rows, cols = q.shape
    out = np.empty((rows, 1 + 2 * cols), dtype=np.uint8)
    out[:, 0] = np.asarray(shifts, dtype=np.uint8)
    out[:, 1:] = np.asarray(q, dtype='>i2').view(np.uint8).reshape(rows, 2 * cols)
    return out.tobytes()


def pack_i32_q24(vals):
    return np.asarray(vals, dtype='>i4').tobytes()


class BlobWriter:
    def __init__(self, path):
        self.f = open(path, 'wb')
        self.n = 0

    def write(self, b):
        self.f.write(b)
        self.n += len(b)

    def close(self):
        self.f.close()


def word(fields):
    acc, used = 0, 0
    for value, bits in fields:
        assert 0 <= value < (1 << bits), (value, bits)
        acc = (acc << bits) | value
        used += bits
    return acc << (256 - used)


def pack_config(im, weight_len, tok_len, stops, wbits=1):
    """SPEC §10 packed config, bytes32[4]."""
    w0 = word([(im.dim, 16), (im.moe_dim, 16), (im.L, 8), (im.nh, 8), (im.nkv, 8),
               (im.hd, 16), (im.vocab, 32), (im.seq_cap, 16), (1, 8), (wbits, 8),
               (im.rot, 16), (im.full_interval, 8), (im.top_k, 8),
               (im.n_experts, 16), (im.shared_dim, 16)])
    w1 = word([(round(1e-6 * (1 << 48)), 64), (im.inv_sqrt_hd, 64), (weight_len, 64)])
    w2 = word([(tok_len, 32), (stops[0], 32), (stops[1], 32), (im.nvh, 8),
               (im.nkh, 8), (im.dk, 16), (im.dv, 16), (im.convK, 8)])
    from qwen35_int import INV_SQRT_DK_Q32
    w3 = word([(INV_SQRT_DK_Q32, 64)])
    return [w0, w1, w2, w3]


# ------------------------------------------------- streaming build + forward

def build_weights(im, out_path, prompt0, progress=print, evict=True,
                  shard_release=None):
    """Write weights.bin in engine order while running forward(prompt0, pos 0)
    layer-by-layer; returns (weight_len, logits_pos0)."""
    w = BlobWriter(out_path)

    # emb — quantize in slices (per-row quantization is row-independent, so
    # slice-wise == per-row == what emb_row_q24 computes with)
    from qwen3_int import quant_rows_i8
    S = QwenInt35.CLS_SLICE

    def emb_rows(r0, r1):
        if hasattr(im.p.fm, 'tensors'):
            return im.p.fm.tensors['embed_tokens.weight'][r0:r1]
        dt, shape, off, mm = im.p.fm.ld.meta(im.p.fm.P + 'embed_tokens.weight')
        cols = shape[1]
        u16 = mm[off + 2 * r0 * cols: off + 2 * r1 * cols].view(np.uint16)
        return (u16.astype(np.uint32) << 16).view(np.float32).reshape(r1 - r0, cols)

    for r0 in range(0, im.vocab, S):
        r1 = min(r0 + S, im.vocab)
        q, s = quant_rows_i8(emb_rows(r0, r1))
        w.write(pack_rows_i8(q, s))
    progress(f'emb written ({w.n:,} bytes)')

    # forward state for logitsPos0
    x = im.emb_row_q24(prompt0)
    cache = im.new_cache(1)

    for l in range(im.L):
        lw = im.layer_weights(l)
        w.write(pack_1d_i16(*lw['ln1']))
        if im.is_linear(l):
            for name in ('wqkv', 'wz', 'wb', 'wa'):
                q, s = lw[name]
                w.write(pack_rows_i8(q, s))
            q, s = lw['conv']
            w.write(pack_rows_i8(q, s))
            w.write(pack_i32_q24(lw['expA']))
            w.write(pack_i32_q24(lw['dtBias']))
            w.write(pack_1d_i16(*lw['gnorm']))
            q, s = lw['wout']
            w.write(pack_rows_i8(q, s))
        else:
            w.write(pack_1d_i16(*lw['qn']))
            w.write(pack_1d_i16(*lw['kn']))
            for name in ('wqg', 'wk', 'wv', 'wo'):
                q, s = lw[name]
                w.write(pack_rows_i8(q, s))
        w.write(pack_1d_i16(*lw['ln2']))
        q, s = lw['router']
        w.write(pack_rows_i16(q, s))                # hi-precision rows (rev 2)
        for name in ('sharedGate', 'sharedGU', 'sharedDown'):
            q, s = lw[name]
            w.write(pack_rows_i8(q, s))
        for e in range(im.n_experts):
            gq, gs, dq, ds = im.expert(l, e)
            w.write(pack_rows_i8(gq, gs))
            w.write(pack_rows_i8(dq, ds))

        # interleaved forward step at pos 0 (uses cached quantized weights)
        xb = np.array(rmsnorm_int(x, *lw['ln1']), dtype=np.int64)
        if im.is_linear(l):
            x = x + im._deltanet(l, cache[l], xb)
        else:
            x = x + im._attention(l, cache[l], xb, 0)
        xb = np.array(rmsnorm_int(x, *lw['ln2']), dtype=np.int64)
        x = x + im._moe(l, xb)

        if evict:
            im._cache.pop(l, None)
            im._expert_cache.clear()
        if shard_release is not None:
            shard_release(l)
        progress(f'layer {l} written ({w.n:,} bytes)')

    w.write(pack_1d_i16(*im.final_norm()))
    xb = np.array(rmsnorm_int(x, *im.final_norm()), dtype=np.int64)

    # lm_head — same slices as the reference classifier
    q, s = im._ensure_lm_head()
    logits0 = np.empty(im.vocab, dtype=np.int64)
    from qwen35_int import matmul_i8
    for r0 in range(0, im.vocab, S):
        r1 = min(r0 + S, im.vocab)
        w.write(pack_rows_i8(q[r0:r1], s[r0:r1]))
        logits0[r0:r1] = matmul_i8(q[r0:r1].astype(np.int64), s[r0:r1], xb)
    progress(f'lm_head written ({w.n:,} bytes)')

    w.write(np.asarray(im.rope_cos.reshape(-1), dtype='>i4').tobytes())
    w.write(np.asarray(im.rope_sin.reshape(-1), dtype='>i4').tobytes())
    w.close()
    return w.n, logits0


def keccak_file(path, chunk=1 << 24):
    from Crypto.Hash import keccak as _k
    h = _k.new(digest_bits=256)
    with open(path, 'rb') as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.digest()


def emit(im, out_dir, sol_out, sol_name, tok_blob, stops, prompt_ids, gens,
         tok_note, progress=print, delete_shards=False):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, 'tokenizer.bin'), 'wb') as f:
        f.write(tok_blob)

    shard_release = None
    if delete_shards:
        shard_release = make_shard_releaser(im, progress)

    weight_len, logits0 = build_weights(
        im, os.path.join(out_dir, 'weights.bin'), prompt_ids[0],
        progress=progress, shard_release=shard_release)

    if shard_release is not None:
        # emb (read before the layer loop) and lm_head/final-norm (read after
        # it) are both fully consumed once build_weights returns; sweep the
        # shards marked "keep to the very end" (im.L + 1) so no bf16 data
        # lingers on disk past the point it's needed.
        shard_release(im.L + 1)

    words = pack_config(im, weight_len, len(tok_blob), stops)
    n_w_chunks = (weight_len + CHUNK_MAX - 1) // CHUNK_MAX
    n_t_chunks = (len(tok_blob) + CHUNK_MAX - 1) // CHUNK_MAX
    progress(f'weights {weight_len:,} bytes ({n_w_chunks} chunks); '
             f'tokenizer {len(tok_blob):,} bytes ({n_t_chunks} chunks)')

    wh = keccak_file(os.path.join(out_dir, 'weights.bin'))
    th = keccak256(tok_blob)
    manifest = keccak256(wh + th)
    json.dump({
        'manifest': '0x' + manifest.hex(),
        'keccakWeights': '0x' + wh.hex(),
        'keccakTokenizer': '0x' + th.hex(),
        'weightChunks': n_w_chunks,
        'tokenizerChunks': n_t_chunks,
        'chunkPayloadBytes': CHUNK_MAX,
        'overlayDomain': OVERLAY_DOMAIN.decode(),
        'chunkAddress': 'address(uint160(uint256(keccak256(overlayDomain || manifest || u64be(i))))); '
                        'weights chunks i in [0, weightChunks), tokenizer chunks i in '
                        '[weightChunks, weightChunks+tokenizerChunks)',
    }, open(os.path.join(out_dir, 'manifest.json'), 'w'), indent=1)

    vectors = {
        'packedConfig': ['0x%064x' % wd for wd in words],
        'promptIds': [int(t) for t in prompt_ids],
        'logitsPos0': abi_encode_int256_array(logits0),
        'tokenizer': tok_note,
    }
    for name, (n_new, ids, text_bytes) in gens.items():
        vectors[name] = {
            'maxNew': n_new,
            'ids': [int(t) for t in ids],
            'text': text_bytes.decode('utf-8', 'replace'),
            'textHex': '0x' + text_bytes.hex(),
        }
    json.dump(vectors, open(os.path.join(out_dir, 'vectors.json'), 'w'), indent=1)

    os.makedirs(sol_out, exist_ok=True)
    with open(os.path.join(sol_out, f'{sol_name}.sol'), 'w') as f:
        f.write(f"""// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title {sol_name}
/// @notice GENERATED by tools/convert_qwen35.py — packed engine-v3 model config.
///         Do not edit by hand; regenerate instead.
library {sol_name} {{
    function packedConfig() internal pure returns (bytes32[4] memory words) {{
        words[0] = bytes32(uint256({hex(words[0])}));
        words[1] = bytes32(uint256({hex(words[1])}));
        words[2] = bytes32(uint256({hex(words[2])}));
        words[3] = bytes32(uint256({hex(words[3])}));
    }}
}}
""")
    progress(f'manifest 0x{manifest.hex()}')
    return manifest


def make_shard_releaser(im, progress):
    """Delete each bf16 shard once the layer sweep is past every tensor in it.
    Only valid for the real-model provider (memmap-backed)."""
    fm = im.p.fm
    wm = json.load(open(os.path.join(fm.ld.dir, 'model.safetensors.index.json')))['weight_map']
    last_layer_in_shard = {}
    for name, shard in wm.items():
        if name.startswith('model.language_model.layers.'):
            l = int(name.split('.')[3])
        elif name.startswith(('model.visual', 'mtp.')):
            l = -1                       # never needed
        else:
            l = im.L + 1                 # emb/norm/lm_head: keep to the very end
        last_layer_in_shard[shard] = max(last_layer_in_shard.get(shard, -1), l)

    def release(l_done):
        for shard, last in list(last_layer_in_shard.items()):
            if last <= l_done:
                path = os.path.join(fm.ld.dir, shard)
                if os.path.exists(path):
                    fm.ld.headers.pop(shard, None)
                    mm = fm.ld.mmaps.pop(shard, None)
                    del mm
                    os.remove(path)
                    progress(f'  released shard {shard}')
                last_layer_in_shard.pop(shard)
    return release


# ----------------------------------------------------------------- synthetic

def run_synthetic(args):
    from synth35 import SyntheticFloat35
    fm = SyntheticFloat35()
    im = QwenInt35(FloatProvider(fm), seq_cap=64)
    strings = [bytes([i]) for i in range(fm.vocab)]
    tok_blob = build_tokenizer_blob(strings)
    stops = (0, 0)
    prompt_ids = [7, 42, 99, 3]
    short = im.generate(prompt_ids, 6, stop_ids=stops)
    long_ = im.generate(prompt_ids, 16, stop_ids=stops)
    gens = {
        'genShort': (6, short, bytes(t for t in short if t not in stops)),
        'genLong': (16, long_, bytes(t for t in long_ if t not in stops)),
    }
    emit(im, args.out, args.sol_out, args.sol_name or 'SyntheticQwen35',
         tok_blob, stops, prompt_ids, gens, 'identity-bytes')


# ---------------------------------------------------------------- real model

def run_real(args):
    from qwen35_float import Qwen35, chat_ids
    tok, prompt_ids = chat_ids(args.prompt, args.model_dir)
    fm = Qwen35(args.model_dir)
    im = QwenInt35(FloatProvider(fm), seq_cap=args.seq_cap)
    stops = (248046, 248044)

    gen_ids = json.load(open(args.gens_from))['gen_ids'] if args.gens_from else \
        im.generate(prompt_ids, args.gen_long, stop_ids=stops)
    # greedy decode is prefix-stable: genShort is a truncation of genLong
    short = gen_ids[:args.gen_short]
    strings = token_raw_bytes(os.path.join(args.model_dir, 'tokenizer.json'), im.vocab)
    tok_blob = build_tokenizer_blob(strings)
    gens = {
        'genShort': (args.gen_short, short,
                     b''.join(strings[t] for t in short if t not in stops)),
        'genLong': (args.gen_long, gen_ids,
                    b''.join(strings[t] for t in gen_ids if t not in stops)),
    }
    emit(im, args.out, args.sol_out, args.sol_name or 'Qwen35_35B_A3B',
         tok_blob, stops, prompt_ids, gens, 'qwen35-byte-bpe',
         delete_shards=args.delete_shards)

    if args.site_tokenizer:
        tj = json.load(open(os.path.join(args.model_dir, 'tokenizer.json')))
        site = {
            'vocab': tj['model']['vocab'],
            'merges': tj['model']['merges'],
            'added': {a['content']: a['id'] for a in tj.get('added_tokens', [])},
            'chatTemplate': '<|im_start|>user\\n{prompt}<|im_end|>\\n<|im_start|>assistant\\n<think>\\n\\n</think>\\n\\n',
            'promptIdsWhatIsEthereum': [int(t) for t in prompt_ids],
            'stops': list(stops),
        }
        json.dump(site, open(args.site_tokenizer, 'w'), ensure_ascii=False)
        print('site tokenizer json ->', args.site_tokenizer)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--synthetic', action='store_true')
    ap.add_argument('--model-dir', default='.context/qwen35/model')
    ap.add_argument('--out', required=True)
    ap.add_argument('--sol-out', required=True)
    ap.add_argument('--sol-name', default=None)
    ap.add_argument('--seq-cap', type=int, default=256)
    ap.add_argument('--prompt', default='What is Ethereum?')
    ap.add_argument('--gen-short', type=int, default=8)
    ap.add_argument('--gen-long', type=int, default=32)
    ap.add_argument('--gens-from', default=None,
                    help='reuse gen ids from a prior integer-reference run (json)')
    ap.add_argument('--site-tokenizer', default=None)
    ap.add_argument('--delete-shards', action='store_true',
                    help='delete bf16 shards as the layer sweep passes them')
    args = ap.parse_args()
    if args.synthetic:
        run_synthetic(args)
    else:
        run_real(args)


if __name__ == '__main__':
    main()
