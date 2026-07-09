"""Convert Qwen3 safetensors + tokenizer.json into on-chain artifacts (engine v2).

Weight blob layout (all offsets statically computable from config; big-endian
where multi-byte):
  emb        : vocab rows x [u8 rowShift || wBits x dim]      (row-major, stride dim*wB+1)
  per layer l in 0..L-1:
    ln1      : [u8 shift][int16 x dim]
    qn       : [u8 shift][int16 x headDim]     (RoPE-permuted)
    kn       : [u8 shift][int16 x headDim]     (RoPE-permuted)
    wq       : (nH*headDim) rows x [u8 || dim]     (RoPE-permuted rows)
    wk       : (nKv*headDim) rows x [u8 || dim]    (RoPE-permuted rows)
    wv       : (nKv*headDim) rows x [u8 || dim]
    wo       : dim rows x [u8 || nH*headDim]
    ln2      : [u8 shift][int16 x dim]
    wg, wu   : hidden rows x [u8 || dim]
    wd       : dim rows x [u8 || hidden]
  norm       : [u8 shift][int16 x dim]
  ropeCos    : int32 Q30 x (seqCap * headDim/2)
  ropeSin    : int32 Q30 x (seqCap * headDim/2)
(classifier is the tied emb tensor; wBits is 1 for int8 rows, 2 for int16 rows)

Tokenizer blob (decode-only byte-level BPE, type 1):
  [u8 type=1][u32 vocab][u32 stringsLen][(vocab+1) x u32 offsets][strings raw bytes]
Token strings are stored as RAW BYTES (the GPT-2 byte<->unicode indirection is
resolved here at conversion time), so on-chain decode is pure concatenation.

Packed config (bytes32[3], from MSB):
  w0: dim u16 | hidden u16 | L u8 | nH u8 | nKv u8 | headDim u16 | vocab u32
      | seqCap u16 | tokType u8 | wBits u8
  w1: epsQ48 u64 | invSqrtHd u64 (Q32) | weightLen u64
  w2: tokLen u32 | stop0 u32 | stop1 u32

Also emits vectors.json test fixtures via the integer reference (qwen3_int.py),
and supports --synthetic to build a tiny random Qwen-architecture model for CI.
"""
import argparse
import json
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qwen3_int as qi

CHUNK_MAX = 24_575


def pack_1d_i16(q16, shift):
    return bytes([shift]) + np.asarray(q16, dtype='>i2').tobytes()


def pack_rows(q, shifts, wbits):
    rows = []
    dt = '>i2' if wbits == 2 else 'i1'
    for i in range(q.shape[0]):
        rows.append(bytes([int(shifts[i])]) + np.asarray(q[i], dtype=dt).tobytes())
    return b''.join(rows)


def quant_rows(w, wbits):
    if wbits == 1:
        return qi.quant_rows_i8(w)
    # int16 per-row variant (same shift rule, wider range)
    mx = np.abs(w).max(axis=1)
    mx = np.where(mx == 0, 1e-30, mx)
    shifts = np.clip(np.floor(np.log2(32767.0 / mx)).astype(np.int64), 0, qi.MAX_ROW_SHIFT)
    qv = np.clip(np.round(w * (1 << shifts)[:, None].astype(np.float64)), -32767, 32767)
    return qv.astype(np.int16), shifts.astype(np.uint8)


def build_weight_blob(im, wbits):
    parts = [pack_rows(im.emb_q, im.emb_s, wbits)]
    for w in im.layers:
        parts.append(pack_1d_i16(*w['ln1']))
        parts.append(pack_1d_i16(*w['qn']))
        parts.append(pack_1d_i16(*w['kn']))
        for name in ('wq', 'wk', 'wv', 'wo'):
            parts.append(pack_rows(*w[name], wbits))
        parts.append(pack_1d_i16(*w['ln2']))
        for name in ('wg', 'wu', 'wd'):
            parts.append(pack_rows(*w[name], wbits))
    parts.append(pack_1d_i16(*im.norm))
    parts.append(np.asarray(im.rope_cos.reshape(-1), dtype='>i4').tobytes())
    parts.append(np.asarray(im.rope_sin.reshape(-1), dtype='>i4').tobytes())
    return b''.join(parts)


GPT2_BYTE_DECODER = None


def gpt2_byte_decoder():
    """The GPT-2 byte->unicode table, inverted (unicode char -> byte)."""
    global GPT2_BYTE_DECODER
    if GPT2_BYTE_DECODER is None:
        bs = list(range(ord('!'), ord('~') + 1)) + list(range(0xA1, 0xAD)) + list(range(0xAE, 0x100))
        cs = bs[:]
        n = 0
        for b in range(256):
            if b not in bs:
                bs.append(b)
                cs.append(256 + n)
                n += 1
        GPT2_BYTE_DECODER = {chr(c): b for b, c in zip(bs, cs)}
    return GPT2_BYTE_DECODER


def token_raw_bytes(tok_json_path, vocab_size):
    """Vocab id -> raw bytes, resolving byte-level BPE + added special tokens."""
    tj = json.load(open(tok_json_path))
    dec = gpt2_byte_decoder()
    strings = [b''] * vocab_size
    for s, i in tj['model']['vocab'].items():
        if i < vocab_size:
            strings[i] = bytes(dec[ch] for ch in s)
    for added in tj.get('added_tokens', []):
        if added['id'] < vocab_size:
            strings[added['id']] = added['content'].encode('utf-8')
    return strings


def build_tokenizer_blob(strings):
    offs = [0]
    blob = b''
    for s in strings:
        blob += s
        offs.append(len(blob))
    assert len(blob) < (1 << 32)
    out = struct.pack('>BII', 1, len(strings), len(blob))
    out += b''.join(struct.pack('>I', o) for o in offs)
    out += blob
    return out


def pack_config(im, wbits, weight_len, tok_len, stops):
    def word(fields):
        acc, used = 0, 0
        for value, bits in fields:
            assert 0 <= value < (1 << bits), (value, bits)
            acc = (acc << bits) | value
            used += bits
        return acc << (256 - used)

    w0 = word([(im.dim, 16), (im.hidden, 16), (im.L, 8), (im.nh, 8), (im.nkv, 8),
               (im.hd, 16), (im.vocab, 32), (im.seq_cap, 16), (1, 8), (wbits, 8)])
    w1 = word([(im.eps_q48, 64), (im.inv_sqrt_hd, 64), (weight_len, 64)])
    w2 = word([(tok_len, 32), (stops[0], 32), (stops[1], 32)])
    return [w0, w1, w2]


class SyntheticFloat:
    """A tiny random Qwen-architecture model for CI fixtures (float side)."""

    def __init__(self, seed=1337, dim=48, hidden=96, L=2, nh=4, nkv=2, hd=16, vocab=256):
        rng = np.random.default_rng(seed)
        self.eps = 1e-6
        self.theta = 1e6
        self.L, self.nh, self.nkv, self.hd, self.dim = L, nh, nkv, hd, dim

        def t(*shape, scale=0.6):
            return (rng.standard_normal(shape) * scale).astype(np.float32)

        self.emb = t(vocab, dim, scale=0.5)
        self.layers = []
        for _ in range(L):
            self.layers.append({
                'ln1': 1.0 + t(dim, scale=0.2), 'qn': 1.0 + t(hd, scale=0.2),
                'kn': 1.0 + t(hd, scale=0.2), 'wq': t(nh * hd, dim), 'wk': t(nkv * hd, dim),
                'wv': t(nkv * hd, dim), 'wo': t(dim, nh * hd), 'ln2': 1.0 + t(dim, scale=0.2),
                'wg': t(hidden, dim), 'wu': t(hidden, dim), 'wd': t(dim, hidden),
            })
        self.norm = 1.0 + t(dim, scale=0.2)
        self.cls = self.emb


def abi_encode_int256_array(vals):
    out = (0x20).to_bytes(32, 'big') + len(vals).to_bytes(32, 'big')
    for v in vals:
        out += (int(v) % (1 << 256)).to_bytes(32, 'big')
    return '0x' + out.hex()


def emit(im, wbits, tok_blob, stops, out_dir, sol_out, sol_name, prompt_ids, gens, tok_note):
    weight_blob = build_weight_blob(im, wbits)
    words = pack_config(im, wbits, len(weight_blob), len(tok_blob), stops)
    print(f'weight blob: {len(weight_blob):,} bytes '
          f'({(len(weight_blob) + CHUNK_MAX - 1) // CHUNK_MAX} chunks); '
          f'tokenizer blob: {len(tok_blob):,} bytes', file=sys.stderr)

    cache = im.new_cache(1)
    logits0 = im.forward(cache, prompt_ids[0], 0)

    vectors = {
        'packedConfig': ['0x%064x' % w for w in words],
        'promptIds': [int(x) for x in prompt_ids],
        'logitsPos0': abi_encode_int256_array(logits0),
        'tokenizer': tok_note,
    }
    for name, (n_new, ids, text_bytes) in gens.items():
        vectors[name] = {
            'maxNew': n_new,
            'ids': [int(x) for x in ids],
            'text': text_bytes.decode('utf-8', 'replace'),
            'textHex': '0x' + text_bytes.hex(),
        }

    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, 'weights.bin'), 'wb') as f:
        f.write(weight_blob)
    with open(os.path.join(out_dir, 'tokenizer.bin'), 'wb') as f:
        f.write(tok_blob)
    with open(os.path.join(out_dir, 'vectors.json'), 'w') as f:
        json.dump(vectors, f, indent=1)
    os.makedirs(sol_out, exist_ok=True)
    with open(os.path.join(sol_out, f'{sol_name}.sol'), 'w') as f:
        f.write(f"""// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title {sol_name}
/// @notice GENERATED by tools/qwen3_convert.py — packed engine-v2 model config.
///         Do not edit by hand; regenerate instead.
library {sol_name} {{
    function packedConfig() internal pure returns (bytes32[3] memory words) {{
        words[0] = bytes32(uint256({hex(words[0])}));
        words[1] = bytes32(uint256({hex(words[1])}));
        words[2] = bytes32(uint256({hex(words[2])}));
    }}
}}
""")
    print('artifacts written to', out_dir, file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--synthetic', action='store_true', help='build the tiny CI model')
    ap.add_argument('--model', default='.context/qwen3/model.safetensors')
    ap.add_argument('--config', default='.context/qwen3/config.json')
    ap.add_argument('--tokenizer', default='.context/qwen3/tokenizer.json')
    ap.add_argument('--out', required=True)
    ap.add_argument('--sol-out', required=True)
    ap.add_argument('--sol-name', default=None)
    ap.add_argument('--wbits', type=int, default=1, choices=(1, 2))
    ap.add_argument('--seq-cap', type=int, default=1024)
    ap.add_argument('--prompt', default='What is Ethereum?')
    ap.add_argument('--gen-short', type=int, default=8)
    ap.add_argument('--gen-long', type=int, default=40)
    args = ap.parse_args()

    if args.synthetic:
        fm = SyntheticFloat()
        im = qi.QwenInt(fm, seq_cap=64)
        # identity byte tokenizer: token id i decodes to byte i (ids 0..255)
        strings = [bytes([i]) for i in range(256)]
        tok_blob = build_tokenizer_blob(strings)
        stops = (0, 0)  # never emitted by argmax on this model in practice; id 0 stops
        prompt_ids = [7, 42, 99, 3]
        short = im.generate(prompt_ids, 6, stop_ids=stops)
        long_ = im.generate(prompt_ids, 16, stop_ids=stops)
        gens = {
            'genShort': (6, short, bytes(t for t in short if t not in stops)),
            'genLong': (16, long_, bytes(t for t in long_ if t not in stops)),
        }
        emit(im, args.wbits, tok_blob, stops, args.out, args.sol_out,
             args.sol_name or 'SyntheticQwen', prompt_ids, gens, 'identity-bytes')
        return

    from qwen3_float import Qwen3, chat_ids
    tok, prompt_ids = chat_ids(args.tokenizer, args.prompt)
    fm = Qwen3(args.model, args.config)
    cfg = json.load(open(args.config))
    stops = (cfg['eos_token_id'], cfg['bos_token_id'])
    print('quantizing...', file=sys.stderr)
    im = qi.QwenInt(fm, seq_cap=args.seq_cap)
    if args.wbits == 2:
        # requantize 2D tensors at int16 rows
        for w, fw in zip(im.layers, fm.layers):
            for name, src in (('wq', qi.permute_rope_rows(fw['wq'], im.nh, im.hd)),
                              ('wk', qi.permute_rope_rows(fw['wk'], im.nkv, im.hd)),
                              ('wv', fw['wv']), ('wo', fw['wo']), ('wg', fw['wg']),
                              ('wu', fw['wu']), ('wd', fw['wd'])):
                w[name] = quant_rows(src, 2)
        im.emb_q, im.emb_s = quant_rows(fm.emb, 2)

    print('generating reference outputs...', file=sys.stderr)
    short = im.generate(prompt_ids, args.gen_short, stop_ids=stops)
    long_ = im.generate(prompt_ids, args.gen_long, stop_ids=stops)
    strings = token_raw_bytes(args.tokenizer, im.vocab)
    tok_blob = build_tokenizer_blob(strings)
    gens = {
        'genShort': (args.gen_short, short,
                     b''.join(strings[t] for t in short if t not in stops)),
        'genLong': (args.gen_long, long_,
                    b''.join(strings[t] for t in long_ if t not in stops)),
    }
    emit(im, args.wbits, tok_blob, stops, args.out, args.sol_out,
         args.sol_name or 'Qwen3_0_6B', prompt_ids, gens, 'qwen3-byte-bpe')


if __name__ == '__main__':
    main()
