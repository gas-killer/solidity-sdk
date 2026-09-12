#!/usr/bin/env python3
"""v2 animation builder: replays every decided intent's fly episode (bit-exact, verified against the logged
spikeRoot) at 1 ms resolution and injects positions/labels/episodes/chain events into the merged template.

  fly_viz_build2.py --artifacts artifacts --npz <graph.npz> --annotations <annotations.feather> \
                    --amm-json amm2_data.json --template tools/fly_viz_template2.html --out fly_amm_v2.html
"""
import argparse, base64, json, struct, sys, time
from pathlib import Path
import numpy as np
import pyarrow.feather as feather

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fly_int as F


def positions(npz, annotations, G):
    g = np.load(npz); ids = g['ids']; n = len(ids)
    ann = feather.read_table(annotations).to_pandas().set_index('bodyId').loc[ids]
    pos = np.full((n, 3), np.nan); loc = ann['somaLocation'].astype(object); has = loc.notna().to_numpy()
    for i in np.flatnonzero(has):
        pos[i] = [float(x) for x in str(loc.iloc[i]).strip('[]').split()]
    sc = ann['superclass'].fillna('unknown').astype(str).to_numpy(); classes = sorted(set(sc)); cls_idx = {c: k for k, c in enumerate(classes)}
    sc_id = np.array([cls_idx[c] for c in sc], dtype=np.uint8); side = ann['somaSide'].fillna('?').astype(str).to_numpy()
    ptr = G.ptr.astype(np.int64) & 0x7fffffff; post = (G.edges >> 14).astype(np.int64); pre = np.repeat(np.arange(n), np.diff(ptr))
    missing = ~has
    for _ in range(3):
        if not missing.any(): break
        sel = missing[post]; src = pre[sel]; dst = post[sel]; ok = ~np.isnan(pos[src, 0])
        sums = np.zeros((n, 3)); cnt = np.zeros(n); np.add.at(sums, dst[ok], pos[src[ok]]); np.add.at(cnt, dst[ok], 1)
        sel2 = missing[pre]; src2 = post[sel2]; dst2 = pre[sel2]; ok2 = ~np.isnan(pos[src2, 0]); np.add.at(sums, dst2[ok2], pos[src2[ok2]]); np.add.at(cnt, dst2[ok2], 1)
        fill = missing & (cnt > 0); pos[fill] = sums[fill] / cnt[fill, None]; missing = np.isnan(pos[:, 0])
    if missing.any(): pos[missing] = np.nanmean(pos, axis=0)
    center = np.nanmean(pos, axis=0); scale = np.nanstd(pos) * 3; pos_n = ((pos - center) / scale).astype(np.float32)
    def cen(mask):
        q = pos[mask & has]; return ((q.mean(0) - center) / scale).tolist()
    is_ol = np.char.startswith(sc.astype(str), 'ol_'); is_cb = np.char.startswith(sc.astype(str), 'cb_'); is_vnc = np.char.startswith(sc.astype(str), 'vnc_')
    anat = dict(olL=cen(is_ol & (side == 'L')), olR=cen(is_ol & (side == 'R')), cb=cen(is_cb), vnc=cen(is_vnc), brain=cen(is_ol | is_cb))
    return n, pos_n, classes, sc_id, anat


def episode(G, p, warm, ep, ms_per_frame, n, sc_id, nclasses):
    frame = bytes.fromhex(ep['frame'][2:]); L = list(struct.unpack('>%dH' % len(G.retina), frame)); Lf = [0] * len(L)
    s = F.State.from_wire(warm, G.n, G.slots, G.rfc); s.count[:] = 0; k = F.kernel(G, s, 'c')
    D, B = p['episodeSteps'], p['binSteps']; bci = [ro[0] for ro in G.readouts[:4]]
    rates = list(ep['rates0']); prev4 = [0] * 4; spf = ms_per_frame * 10
    frames = []; touched = np.zeros(n, bool); prev_cnt = s.count.copy(); bins = []; hist = []
    for b in range(D // B):
        for i in range(len(L)): Lf[i] += (p['alpha'] * (L[i] - Lf[i])) >> 16
        d = F.base_drive(G, Lf); tb = b * B
        if tb < ep['stim']['rewardSteps']: d[G.sugar] = F.SUGAR_Q16
        if tb < ep['stim']['punishSteps']:
            for i in G.ppl101: d[i] += F.PPL101_Q16
        k.set_drives(d)
        for _ in range(B // spf):
            k.advance(spf); spikers = np.flatnonzero(s.count != prev_cnt); frames.append(spikers.astype(np.uint32)); prev_cnt = s.count.copy()
            touched[s.active[:s.nActive]] = True; touched[spikers] = True
        c4 = [int(s.count[i]) - prev4[j] for j, i in enumerate(bci)]; prev4 = [int(s.count[i]) for i in bci]; hist.append(c4)
        raw = [c * 10_000_000 // B for c in c4]; rates = [(rates[j] * p['decay'] + raw[j] * (65536 - p['decay'])) >> 16 for j in range(4)]
        turn = max(-6000, min(6000, 120 * (rates[0] - rates[1]) // 1000)); fwd = max(0, min(20000, 400 * (rates[2] + rates[3]) // 1000))
        bins.append(dict(bin=b, counts=c4, rates=list(rates), feeBps=p['minFee'] + fwd * (p['maxFee'] - p['minFee']) // 20000, skewBps=turn * p['maxSkew'] // 6000, nActive=int(s.nActive), spikes=int(s.count.sum())))
    k.materialize()
    r = {'rateMilliHz': rates, 'spikesLast30ms': [sum(h[j] for h in hist[-3:]) for j in range(4)], 'windowCounts': [int(s.count[ro[0]]) for ro in G.readouts] + [0] * (14 - len(G.readouts)), 'totalSpikes': int(s.count.sum())}
    out = s.to_wire()
    root = F.keccak(F.word(int.from_bytes(F.keccak(F.DOMAIN), 'big')) + F.keccak(frame) + F.word(ep['stim']['punishSteps']) + F.word(ep['stim']['rewardSteps'])
                    + b''.join(F.word(x) for x in ep['rates0']) + F.keccak(out) + F.encode_readout(r))
    assert bins[-1]['feeBps'] == ep['feeBps'] and bins[-1]['skewBps'] == ep['skewBps'], f'intent {ep["id"]}: fee/skew differ from the log'
    return dict(frames=frames, bins=bins, touched=touched, totalSpikes=r['totalSpikes'], spikeRootMatches=(root.hex() == ep['spikeRoot'][2:]),
                spikesByClass=np.bincount(sc_id, weights=s.count, minlength=nclasses).astype(int).tolist(), nActiveEnd=int(s.nActive))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--artifacts', default='artifacts'); ap.add_argument('--npz', required=True); ap.add_argument('--annotations', required=True)
    ap.add_argument('--amm-json', required=True); ap.add_argument('--template', required=True); ap.add_argument('--out', required=True); ap.add_argument('--ms-per-frame', type=int, default=1)
    a = ap.parse_args()
    G = F.Graph(a.artifacts); amm = json.load(open(a.amm_json)); cfg = [int(c, 16) for c in amm['cfg']]; p = F.unpack_cfg(cfg)
    n, pos_n, classes, sc_id, anat = positions(a.npz, a.annotations, G)
    warm = (Path(a.artifacts) / 'warm.bin').read_bytes()
    b64 = lambda arr: base64.b64encode(np.ascontiguousarray(arr).tobytes()).decode()
    eps = []; touched_any = np.zeros(n, bool)
    for ep in amm['episodes']:
        t0 = time.perf_counter(); r = episode(G, p, warm, ep, a.ms_per_frame, n, sc_id, len(classes)); touched_any |= r['touched']
        print(f'intent #{ep["id"]}: fee {ep["feeBps"]} skew {ep["skewBps"]} spikes {r["totalSpikes"]} touched {int(r["touched"].sum())} spikeRoot match {r["spikeRootMatches"]} ({time.perf_counter() - t0:.2f}s)')
        eps.append(dict({k: v for k, v in ep.items() if k != 'frame'}, frames=[b64(f) for f in r['frames']], bins=r['bins'], touched=b64(np.packbits(r['touched'])),
                        touchedCount=int(r['touched'].sum()), totalSpikes=r['totalSpikes'], spikeRootMatches=r['spikeRootMatches'], spikesByClass=r['spikesByClass'], nActiveEnd=r['nActiveEnd']))
    ro_names = ['DNp20 R', 'DNp20 L', 'DNpe017 L', 'DNpe017 R', 'DNa02 R', 'DNa02 L', 'DNp09 L', 'DNp09 R', 'MDN R', 'MDN L', 'MDN R', 'MDN L', 'MN9 L', 'MN9 R']
    data = dict(n=n, classes=classes, countByClass=np.bincount(sc_id, minlength=len(classes)).astype(int).tolist(), pos=b64(pos_n), cls=b64(sc_id), touched=b64(np.packbits(touched_any)),
                msPerFrame=a.ms_per_frame, episodeMs=p['episodeSteps'] // 10, binMs=p['binSteps'] // 10, retina=[int(idx) for (idx, _u, _v) in G.retina],
                readouts=[dict(idx=int(ro[0]), name=ro_names[j]) for j, ro in enumerate(G.readouts)], anat=anat, episodes=eps,
                chain=dict(head=amm['head'], fromBlock=amm['fromBlock'], pool=amm['pool'], policy=amm['policy'], events=amm['events'], series=amm['series']))
    Path(a.out).write_text(Path(a.template).read_text().replace('__DATA__', json.dumps(data)))
    print('wrote', a.out, Path(a.out).stat().st_size // 1024, 'KB', '| episodes', len(eps), '| all spikeRoots match:', all(e['spikeRootMatches'] for e in eps))


if __name__ == '__main__':
    main()
