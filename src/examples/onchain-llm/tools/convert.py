"""Convert a llama2.c checkpoint + tokenizer into on-chain artifacts.

Inputs (llama2.c "legacy" export format):
  - model .bin: 7-int32 header (dim, hidden_dim, n_layers, n_heads, n_kv_heads,
    vocab_size, seq_len; vocab_size < 0 means unshared classifier weights),
    followed by fp32 tensors in run.c order, including the legacy
    freq_cis_real/imag tables (skipped) and optional wcls.
  - tokenizer .bin: int32 max_token_length, then per token:
    fp32 score, int32 length, raw bytes.

Outputs (written to --out, default test/fixtures/onchain-llm/):
  - weights.hex          : full weight blob (hex, no 0x) — split into data
                           contracts of <= 24575 bytes at deploy time
  - tokenizer.hex        : tokenizer blob (hex, no 0x)
  - vectors.json         : bit-exact test vectors for the Foundry suite
  - Stories260K.sol      : generated Solidity config (written to --sol-out)

Weight blob layout (all big-endian):
  int16 tensors, in run.c tensor order:
    tok_emb[vocab*dim], rms_att[L*dim], wq[L*dim*dim], wk[L*dim*kvd],
    wv[L*dim*kvd], wo[L*dim*dim], rms_ffn[L*dim], w1[L*dim*hidden],
    w2[L*hidden*dim], w3[L*dim*hidden], rms_final[dim]
  then int32 Q30 RoPE tables:
    rope_cos[seqlen*hs/2], rope_sin[seqlen*hs/2]
  (classifier weights are shared with tok_emb; unshared checkpoints append
   wcls[vocab*dim] as int16 after rope_sin)

Tokenizer blob layout (V = vocab):
  [0:2]        uint16  V
  [2:3]        uint8   max_token_length
  [3 : 3+4V]   int32   score_q16 per token (round(score * 2^16))
  [3+4V : 3+5V] uint8  byte length per token
  [3+5V : 3+7V] uint16 offset of token string within strings region
  [3+7V : ]    bytes   concatenated token strings

Packed config (3 bytes32 words, consumed by LlamaConfigLib.unpack):
  word0: dim u16 | hidden u16 | nLayers u8 | nHeads u8 | nKv u8 | vocab u16
         | seqlen u16 | hs u8 | kvd u16 | sharedCls u8      (from MSB)
  word1: shifts u8 x12: tokEmb, rmsAtt, wq, wk, wv, wo, rmsFfn, w1, w2, w3,
         rmsFinal, wcls (from MSB; wcls == tokEmb when shared)
  word2: invSqrtHs u64 | weightBlobLen u32 | tokBlobLen u32 (from MSB)
"""
import argparse
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference as ref

CHUNK_MAX = 24575  # EIP-170 limit (24576) minus the 0x00 STOP prefix


def load_checkpoint(path):
    with open(path, 'rb') as f:
        data = f.read()
    dim, hidden, n_layers, n_heads, n_kv, vocab, seqlen = struct.unpack('<7i', data[:28])
    shared = vocab > 0
    vocab = abs(vocab)
    hs = dim // n_heads
    kvd = hs * n_kv
    off = 28

    def take(n):
        nonlocal off
        vals = struct.unpack(f'<{n}f', data[off:off + 4 * n])
        off += 4 * n
        return list(vals)

    w = {
        'tok_emb': take(vocab * dim),
        'rms_att': take(n_layers * dim),
        'wq': take(n_layers * dim * dim),
        'wk': take(n_layers * dim * kvd),
        'wv': take(n_layers * dim * kvd),
        'wo': take(n_layers * dim * dim),
        'rms_ffn': take(n_layers * dim),
        'w1': take(n_layers * dim * hidden),
        'w2': take(n_layers * hidden * dim),
        'w3': take(n_layers * dim * hidden),
        'rms_final': take(dim),
    }
    take(seqlen * hs // 2)  # legacy freq_cis_real, unused
    take(seqlen * hs // 2)  # legacy freq_cis_imag, unused
    w['wcls'] = w['tok_emb'] if shared else take(vocab * dim)
    assert off == len(data), f'trailing bytes: {len(data) - off}'
    cfg = dict(dim=dim, hidden=hidden, n_layers=n_layers, n_heads=n_heads,
               n_kv=n_kv, vocab=vocab, seqlen=seqlen, hs=hs, kvd=kvd,
               shared_cls=shared)
    return cfg, w


def load_tokenizer(path, vocab_size):
    with open(path, 'rb') as f:
        t = f.read()
    maxlen = struct.unpack('<i', t[:4])[0]
    off = 4
    vocab = []
    for _ in range(vocab_size):
        score = struct.unpack('<f', t[off:off + 4])[0]
        off += 4
        ln = struct.unpack('<i', t[off:off + 4])[0]
        off += 4
        vocab.append((round(score * 65536), t[off:off + ln]))
        off += ln
    assert off == len(t)
    return maxlen, vocab


def quantize(vals, bits=16):
    """Per-tensor power-of-two scale maximizing precision within int16."""
    mx = max(abs(v) for v in vals)
    lim = (1 << (bits - 1)) - 1
    shift = 0
    while mx * (1 << (shift + 1)) <= lim and shift < 30:
        shift += 1
    q = [min(lim, max(-lim - 1, round(v * (1 << shift)))) for v in vals]
    return q, shift


def rope_tables(cfg):
    hs = cfg['hs']
    cos_t, sin_t = [], []
    for pos in range(cfg['seqlen']):
        rc, rs = [], []
        for i in range(hs // 2):
            freq = 1.0 / (10000.0 ** (2 * i / hs))
            rc.append(round(math.cos(pos * freq) * (1 << 30)))
            rs.append(round(math.sin(pos * freq) * (1 << 30)))
        cos_t.append(rc)
        sin_t.append(rs)
    return cos_t, sin_t


def pack_i16(vals):
    return b''.join(struct.pack('>h', v) for v in vals)


def pack_i32(vals):
    return b''.join(struct.pack('>i', v) for v in vals)


TENSOR_ORDER = ['tok_emb', 'rms_att', 'wq', 'wk', 'wv', 'wo', 'rms_ffn',
                'w1', 'w2', 'w3', 'rms_final']


def build_weight_blob(cfg, qw, cos_t, sin_t):
    parts = [pack_i16(qw[name][0]) for name in TENSOR_ORDER]
    parts.append(pack_i32([v for row in cos_t for v in row]))
    parts.append(pack_i32([v for row in sin_t for v in row]))
    if not cfg['shared_cls']:
        parts.append(pack_i16(qw['wcls'][0]))
    return b''.join(parts)


def build_tokenizer_blob(maxlen, vocab):
    V = len(vocab)
    strings = b''
    offs, lens = [], []
    for _, b in vocab:
        offs.append(len(strings))
        lens.append(len(b))
        strings += b
    assert len(strings) < 65536
    blob = struct.pack('>HB', V, maxlen)
    blob += pack_i32([s for s, _ in vocab])
    blob += bytes(lens)
    blob += b''.join(struct.pack('>H', o) for o in offs)
    blob += strings
    return blob


def pack_config(cfg, qw, weight_blob_len, tok_blob_len):
    inv_sqrt_hs = round((1 << 32) / math.sqrt(cfg['hs']))

    def word(fields):
        acc = 0
        used = 0
        for value, bits in fields:
            assert 0 <= value < (1 << bits), (value, bits)
            acc = (acc << bits) | value
            used += bits
        return acc << (256 - used)

    w0 = word([(cfg['dim'], 16), (cfg['hidden'], 16), (cfg['n_layers'], 8),
               (cfg['n_heads'], 8), (cfg['n_kv'], 8), (cfg['vocab'], 16),
               (cfg['seqlen'], 16), (cfg['hs'], 8), (cfg['kvd'], 16),
               (1 if cfg['shared_cls'] else 0, 8)])
    w1 = word([(qw[name][1], 8) for name in TENSOR_ORDER + ['wcls']])
    w2 = word([(inv_sqrt_hs, 64), (weight_blob_len, 32), (tok_blob_len, 32)])
    return [w0, w1, w2], inv_sqrt_hs


def abi_encode_int256_array(vals):
    out = (0x20).to_bytes(32, 'big') + len(vals).to_bytes(32, 'big')
    for v in vals:
        out += (v % (1 << 256)).to_bytes(32, 'big')
    return '0x' + out.hex()


def gen_config_sol(name, words):
    return f"""// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title {name}
/// @notice GENERATED by tools/convert.py — packed model configuration for the
///         {name} checkpoint. Do not edit by hand; regenerate instead.
library {name} {{
    function packedConfig() internal pure returns (bytes32[3] memory words) {{
        words[0] = bytes32(uint256({hex(words[0])}));
        words[1] = bytes32(uint256({hex(words[1])}));
        words[2] = bytes32(uint256({hex(words[2])}));
    }}
}}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', required=True)
    ap.add_argument('--tokenizer', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--sol-out', required=True)
    ap.add_argument('--sol-name', default='Stories260K')
    ap.add_argument('--prompt', default='Once upon a time')
    ap.add_argument('--gen-short', type=int, default=32)
    ap.add_argument('--gen-long', type=int, default=200)
    args = ap.parse_args()

    cfg, fw = load_checkpoint(args.model)
    maxlen, vocab = load_tokenizer(args.tokenizer, cfg['vocab'])
    print(f'config: {cfg}', file=sys.stderr)

    qw = {}
    for name in TENSOR_ORDER:
        qw[name] = quantize(fw[name])
        print(f'  {name}: shift={qw[name][1]}', file=sys.stderr)
    qw['wcls'] = qw['tok_emb'] if cfg['shared_cls'] else quantize(fw['wcls'])

    cos_t, sin_t = rope_tables(cfg)
    weight_blob = build_weight_blob(cfg, qw, cos_t, sin_t)
    tok_blob = build_tokenizer_blob(maxlen, vocab)
    words, inv_sqrt_hs = pack_config(cfg, qw, len(weight_blob), len(tok_blob))
    print(f'weight blob: {len(weight_blob)} bytes '
          f'({(len(weight_blob) + CHUNK_MAX - 1) // CHUNK_MAX} chunks), '
          f'tokenizer blob: {len(tok_blob)} bytes', file=sys.stderr)

    # ---- run the bit-exact reference to build test vectors ----
    rcfg = dict(cfg)
    rcfg['inv_sqrt_hs'] = inv_sqrt_hs
    model = ref.Model(rcfg, qw, cos_t, sin_t)
    tok = ref.Tokenizer(vocab)

    prompt_ids = tok.encode(args.prompt.encode('utf-8'))
    state = model.new_state(1)
    logits0 = model.forward(state, prompt_ids[0], 0)

    gen_short = model.generate(prompt_ids, args.gen_short)
    story_short = tok.decode(gen_short, prev=prompt_ids[-1])
    gen_long = model.generate(prompt_ids, args.gen_long)
    story_long = tok.decode(gen_long, prev=prompt_ids[-1])
    print('story (short):', args.prompt + story_short.decode('utf-8', 'replace'),
          file=sys.stderr)

    exp_inputs = [0, -1, -42950, -(1 << 30), -(1 << 32), -(3 << 32),
                  -(10 << 32), -(63 << 32), -(64 << 32) + 1, -(64 << 32),
                  -(100 << 32), -(1 << 62)]
    isqrt_inputs = [0, 1, 2, 3, 4, 15, 16, 17, 255, 256, 65535, 65536,
                    (1 << 64) - 1, 1 << 64, (1 << 64) + 1, 3 << 64,
                    10 ** 36, (1 << 128) - 1, (1 << 200) + 12345,
                    (1 << 255) + 987654321, (1 << 256) - 1]

    vectors = {
        'packedConfig': ['0x%064x' % w for w in words],
        'prompt': args.prompt,
        'promptIds': prompt_ids,
        'expVectors': abi_encode_int256_array(
            [v for x in exp_inputs for v in (x, ref.exp_q32(x))]),
        'isqrtVectors': abi_encode_int256_array(
            [v for x in isqrt_inputs for v in (x, ref.isqrt(x))]),
        'logitsPos0': abi_encode_int256_array(logits0),
        'genShort': gen_short,
        'storyShort': story_short.decode('utf-8', 'replace'),
        'genLong': gen_long,
        'storyLong': story_long.decode('utf-8', 'replace'),
        'encodeVectors': [
            {'text': t, 'ids': tok.encode(t.encode('utf-8'))}
            for t in ['Once upon a time', 'Lily', 'The quick brown fox!',
                      'a', '']
        ],
    }

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'weights.hex'), 'w') as f:
        f.write(weight_blob.hex())
    with open(os.path.join(args.out, 'tokenizer.hex'), 'w') as f:
        f.write(tok_blob.hex())
    with open(os.path.join(args.out, 'vectors.json'), 'w') as f:
        json.dump(vectors, f, indent=1)
    os.makedirs(args.sol_out, exist_ok=True)
    with open(os.path.join(args.sol_out, f'{args.sol_name}.sol'), 'w') as f:
        f.write(gen_config_sol(args.sol_name, words))
    print('artifacts written to', args.out, file=sys.stderr)


if __name__ == '__main__':
    main()
