#!/usr/bin/env python3
"""graph.npz -> ptr.bin / edges.bin / meta.bin (+ fly_manifest.json).

On-chain artifact format (HANDOFF §2.3): 4-byte big-endian entries, 6,143 entries per
24,575-byte data-contract payload (24,572 B used + 3 zero pad bytes), so no entry straddles
a chunk.  ptr.bin carries the per-presynaptic-neuron sign in bit 31; edges.bin packs
`post:18 | count:14`; meta.bin carries the index tables and provenance hashes.

Usage:  fly_convert.py <graph.npz> <outdir> [--readouts manifest.json] [--ppl101 1235,1774]
"""
import argparse, hashlib, json, struct
from pathlib import Path
import numpy as np

CHUNK, EPC = 24_575, 6_143            # payload bytes, entries per chunk
MAXC = (1 << 14) - 1                   # 16,383
META_VERSION = 1
DELAY_STEPS, RFC_STEPS = 18, 22
# HANDOFF §2.3: the 14 manifest readouts in a FIXED order, BCI four first.
# (idx, type, side): type 0=DNp20 1=DNpe017 2=DNa02 3=DNp09 4=MDN 5=MN9; side 0=L 1=R
TYPE_CODE = {'DNp20': 0, 'DNpe017': 1, 'DNa02': 2, 'DNp09': 3, 'MDN': 4, 'MN9': 5}
SIDE_CODE = {'L': 0, 'R': 1}
MALECNS_READOUTS = [(48, 0, 1), (146, 0, 0), (489, 1, 0), (142493, 1, 1), (332, 2, 1), (131957, 2, 0),
                    (725, 3, 0), (1087, 3, 1), (706, 4, 1), (1196, 4, 0), (1240, 4, 1), (2194, 4, 0),
                    (306, 5, 0), (6367, 5, 1)]
MALECNS_PPL101 = (1235, 1774)


def keccak256(data: bytes) -> bytes:
    from eth_hash.auto import keccak   # same dependency family as deploy_sepolia.py
    return keccak(data)


def pack_entries(u32: np.ndarray) -> bytes:
    """Concatenate 6,143-entry groups, each followed by 3 zero pad bytes."""
    u32 = np.ascontiguousarray(u32, dtype='>u4')
    out = bytearray()
    for s in range(0, len(u32), EPC):
        out += u32[s:s + EPC].tobytes() + b'\0\0\0'
    return bytes(out)


def chunks_for(entries: int) -> int:
    return -(-entries // EPC)


def readouts_from_manifest(manifest: dict):
    """Check the doomfly manifest carries exactly the hard-coded MaleCNS readouts; return the FIXED order."""
    ro = {(int(r['index']), TYPE_CODE[r['type']], SIDE_CODE[r['side']]) for r in manifest['readouts']}
    assert ro == set(MALECNS_READOUTS), f'manifest readouts differ from the hard-coded table: {ro ^ set(MALECNS_READOUTS)}'
    return list(MALECNS_READOUTS)


def build_meta(n, E, ro, retina_idx, uv_q16, lamina, sugar, ppl101, ids_bytes, npz_sha256):
    body = bytearray()
    off_r = 101
    body += b''.join(struct.pack('>IBB', *r) for r in ro)
    off_ret = off_r + len(body)
    body += struct.pack('>I', len(retina_idx))
    body += b''.join(struct.pack('>IHH', int(i), int(u), int(v)) for i, (u, v) in zip(retina_idx, uv_q16))
    off_lam = off_r + len(body)
    body += struct.pack('>I', len(lamina)) + np.asarray(lamina, dtype='>u4').tobytes()
    off_sug = off_r + len(body)
    body += struct.pack('>I', len(sugar)) + np.asarray(sugar, dtype='>u4').tobytes()
    off_ppl = off_r + len(body)
    body += struct.pack('>II', int(ppl101[0]), int(ppl101[1]))
    hdr = struct.pack('>BIIHHHHIIIII', META_VERSION, n, E, EPC, DELAY_STEPS, RFC_STEPS, len(ro),
                      off_r, off_ret, off_lam, off_sug, off_ppl)
    hdr += keccak256(ids_bytes) + npz_sha256
    assert len(hdr) == 101
    return bytes(hdr + body)


def convert(npz: Path, outdir: Path, readouts=None, ppl101=MALECNS_PPL101):
    outdir.mkdir(parents=True, exist_ok=True)
    g = np.load(npz)
    ptr, post, w = g['ptr'].astype(np.int64), g['post'].astype(np.int64), g['weight'].astype(np.float32)
    n, E = len(ptr) - 1, len(post)
    assert ptr[0] == 0 and ptr[-1] == E and np.all(np.diff(ptr) >= 0), 'invalid CSR'
    assert np.all((post >= 0) & (post < n)), 'post out of range'
    count = np.rint(np.abs(w) / np.float32(0.275)).astype(np.int64)
    assert np.all(count >= 1), 'zero-count edge'
    pre = np.repeat(np.arange(n, dtype=np.int64), np.diff(ptr))
    neg = w < 0
    # sign is per presynaptic neuron (prepare.py:22): every edge of a pre must agree
    pre_neg = np.zeros(n, bool)
    pre_neg[pre[neg]] = True
    assert not np.any(neg != pre_neg[pre]), 'per-edge sign disagrees with per-neuron sign'
    # exact float32 reconstruction, the way prepare.py computed it (count as f32, times sign, times f32(.275))
    sign_f = np.where(pre_neg, np.float32(-1), np.float32(1)).astype(np.float32)
    recon = (count.astype(np.float32) * sign_f[pre] * np.float32(0.275)).astype(np.float32)
    assert np.array_equal(recon, w), 'weights are not fl32(count)*sign*fl32(0.275)'
    max_count, max_deg = int(count.max()), int(np.diff(ptr).max())
    print(f'n={n} E={E} max count={max_count} max out-degree={max_deg} splits={int((count > MAXC).sum())}')
    # split rows with count > 16,383 into equivalent multi-entries (same post, counts sum to original)
    reps = np.maximum(1, -(-count // MAXC))
    post2, pre2 = np.repeat(post, reps), np.repeat(pre, reps)
    rep2 = np.repeat(reps, reps)
    first = np.r_[0, np.cumsum(reps)[:-1]]
    pos = np.arange(len(post2)) - np.repeat(first, reps)
    c_full = np.repeat(count, reps)
    c2 = np.where(pos < rep2 - 1, np.minimum(c_full, MAXC), c_full - MAXC * (rep2 - 1))
    assert np.all((c2 >= 1) & (c2 <= MAXC))
    assert np.array_equal(np.bincount(pre2, c2, n), np.bincount(pre, count, n))
    E2 = len(post2)
    ptr2 = np.r_[0, np.cumsum(np.bincount(pre2, minlength=n))].astype(np.int64)
    assert ptr2[-1] == E2 < (1 << 31) and n < (1 << 18)
    edges = (post2.astype(np.uint64) << np.uint64(14)) | c2.astype(np.uint64)
    ptrw = (pre_neg.astype(np.uint64) << np.uint64(31)) | ptr2[:-1].astype(np.uint64)
    ptrw = np.r_[ptrw, np.uint64(E2)]                          # entry N: E, sign 0
    (outdir / 'ptr.bin').write_bytes(pack_entries(ptrw.astype(np.uint32)))
    (outdir / 'edges.bin').write_bytes(pack_entries(edges.astype(np.uint32)))
    # ---- meta.bin
    ids = np.asarray(g['ids'], dtype='<i8').tobytes()
    ro = readouts if readouts is not None else MALECNS_READOUTS
    for idx, _, _ in ro:
        assert 0 <= idx < n, f'readout {idx} out of range'
    retina = np.asarray(g['retina'], dtype=np.int64)
    assert np.all(np.diff(retina) > 0), 'retina indices must be ascending'
    uv = np.clip(np.rint(np.asarray(g['uv'], dtype=np.float64) * 65535), 0, 65535).astype(np.uint16)
    assert uv.shape == (len(retina), 2)
    npz_sha = hashlib.sha256(npz.read_bytes()).digest()
    meta = build_meta(n, E2, ro, retina, uv, g['lamina'], g['sugar'], ppl101, ids, npz_sha)
    (outdir / 'meta.bin').write_bytes(meta)
    manifest = {
        'n': n, 'nEdges': E2, 'nEdgesOriginal': E, 'maxCount': max_count, 'maxOutDegree': int(np.diff(ptr2).max()),
        'entriesPerChunk': EPC, 'ptrChunks': chunks_for(n + 1), 'edgeChunks': chunks_for(E2),
        'metaChunks': -(-len(meta) // CHUNK), 'metaBytes': len(meta),
        'delaySteps': DELAY_STEPS, 'rfcSteps': RFC_STEPS, 'nReadouts': len(ro), 'readouts': ro,
        'nRetina': int(len(retina)), 'nLamina': int(len(g['lamina'])), 'nSugar': int(len(g['sugar'])),
        'ppl101': list(ppl101), 'inhibitoryPre': int(pre_neg.sum()),
        'idsKeccak': keccak256(ids).hex(), 'npzSha256': npz_sha.hex(),
        'sha256': {f: hashlib.sha256((outdir / f).read_bytes()).hexdigest() for f in ('ptr.bin', 'edges.bin', 'meta.bin')},
        'bytes': {f: (outdir / f).stat().st_size for f in ('ptr.bin', 'edges.bin', 'meta.bin')},
    }
    (outdir / 'fly_manifest.json').write_text(json.dumps(manifest, indent=1) + '\n')
    print(json.dumps({k: manifest[k] for k in ('n', 'nEdges', 'ptrChunks', 'edgeChunks', 'metaChunks', 'bytes')}))
    return manifest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('npz', type=Path)
    p.add_argument('outdir', type=Path)
    p.add_argument('--readouts', type=Path, help='doomfly manifest.json; default = hard-coded MaleCNS table')
    p.add_argument('--fixed-readouts', type=Path, help='fly_readouts.json {"readouts": [[idx,type,side]..], "ppl101": [a,b]} (fly_synth.py)')
    p.add_argument('--ppl101', default=','.join(map(str, MALECNS_PPL101)))
    a = p.parse_args()
    ppl = tuple(int(x) for x in a.ppl101.split(','))
    ro = readouts_from_manifest(json.loads(a.readouts.read_text())) if a.readouts else None
    if a.fixed_readouts:
        fr = json.loads(a.fixed_readouts.read_text())
        ro, ppl = [tuple(int(x) for x in r) for r in fr['readouts']], tuple(int(x) for x in fr['ppl101'])
    convert(a.npz, a.outdir, ro, ppl)


if __name__ == '__main__':
    main()
