#!/usr/bin/env python3
"""Build the 3D animation dataset of one settled fly-AMM round and inject it into the Three.js template.

Recomputes the settled episode with the fixed-point reference (bit-exact with what the operators traced) from the
on-chain FlyDecided frame, at 1 ms resolution: which neurons spike in each millisecond, which neurons the kernel
touched (active set), the photoreceptor luminances the pool state was rendered to, the DN readouts and the decoded
fee/skew per 10 ms bin. Soma positions + superclass come from the MaleCNS annotations; neurons without a soma
location are placed at the mean of their positioned presynaptic partners (visual imputation only).

  fly_viz_build.py --artifacts artifacts --npz <graph.npz> --annotations <annotations.feather> \
                   --log-json <FlyDecided log dump> --template tools/fly_viz_template.html --out fly_brain_amm.html
"""
import argparse, base64, json, struct, sys, time
from pathlib import Path
import numpy as np
import pyarrow.feather as feather

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fly_int as F


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--artifacts', default='artifacts'); ap.add_argument('--npz', required=True); ap.add_argument('--annotations', required=True)
    ap.add_argument('--log-json', required=True, action='append', help='{"frame": "0x..", "rates0": [..], "punish": n, "reward": n, "windowId":.., "fee":.., "skew":.., "tx":..}')
    ap.add_argument('--cfg-json', default='sepolia.json'); ap.add_argument('--template', required=True); ap.add_argument('--out', required=True)
    ap.add_argument('--ms-per-frame', type=int, default=1); ap.add_argument('--amm-json', help='output of fly_viz_amm.py')
    a = ap.parse_args()

    G = F.Graph(a.artifacts)
    cfgj = json.load(open(a.cfg_json)); cfg = [int(cfgj[k], 16) for k in ('cfg0', 'cfg1', 'cfg2')]
    p = F.unpack_cfg(cfg); D, B = p['episodeSteps'], p['binSteps']
    # ---------------- positions + labels
    g = np.load(a.npz); ids = g['ids']; n = len(ids)
    ann = feather.read_table(a.annotations).to_pandas().set_index('bodyId').loc[ids]
    pos = np.full((n, 3), np.nan, dtype=np.float64)
    loc = ann['somaLocation'].astype(object)
    has = loc.notna().to_numpy()
    for i in np.flatnonzero(has):
        pos[i] = [float(x) for x in str(loc.iloc[i]).strip('[]').split()]
    sc = ann['superclass'].fillna('unknown').astype(str).to_numpy()
    classes = sorted(set(sc)); cls_idx = {c: k for k, c in enumerate(classes)}
    sc_id = np.array([cls_idx[c] for c in sc], dtype=np.uint8)
    side = ann['somaSide'].fillna('?').astype(str).to_numpy()
    typ = ann['type'].fillna('').astype(str).to_numpy()
    # impute missing positions from positioned presynaptic partners (CSR is by pre; build post->pre via edges)
    ptr = G.ptr.astype(np.int64) & 0x7fffffff; post = (G.edges >> 14).astype(np.int64)
    pre = np.repeat(np.arange(n), np.diff(ptr))
    missing = ~has
    for _ in range(3):
        m_idx = np.flatnonzero(missing)
        if not len(m_idx): break
        # neighbours of missing neurons = their pre partners (incoming) and post partners (outgoing)
        sel = missing[post]; src = pre[sel]; dst = post[sel]
        ok = ~np.isnan(pos[src, 0])
        sums = np.zeros((n, 3)); cnt = np.zeros(n)
        np.add.at(sums, dst[ok], pos[src[ok]]); np.add.at(cnt, dst[ok], 1)
        sel2 = missing[pre]; src2 = post[sel2]; dst2 = pre[sel2]; ok2 = ~np.isnan(pos[src2, 0])
        np.add.at(sums, dst2[ok2], pos[src2[ok2]]); np.add.at(cnt, dst2[ok2], 1)
        fill = missing & (cnt > 0)
        pos[fill] = sums[fill] / cnt[fill, None]
        missing = np.isnan(pos[:, 0])
    n_imputed = int((~has & ~missing).sum()); n_none = int(missing.sum())
    if n_none:
        pos[missing] = np.nanmean(pos, axis=0)
    center = np.nanmean(pos, axis=0); scale = np.nanstd(pos) * 3
    pos_n = ((pos - center) / scale).astype(np.float32)
    # anatomy landmarks (normalized frame) for the procedural fly body: optic lobes L/R, central brain, VNC
    def cen(mask):
        q = pos[mask & has]; return (((q.mean(0) - center) / scale).tolist() if len(q) else None)
    def ext(mask):
        q = pos[mask & has]; return (((np.percentile(q, 98, axis=0) - np.percentile(q, 2, axis=0)) / scale).tolist() if len(q) else None)
    is_ol = np.char.startswith(sc.astype(str), 'ol_'); is_cb = np.char.startswith(sc.astype(str), 'cb_'); is_vnc = np.char.startswith(sc.astype(str), 'vnc_')
    anat = dict(olL=cen(is_ol & (side == 'L')), olR=cen(is_ol & (side == 'R')), cb=cen(is_cb), vnc=cen(is_vnc), brain=cen(is_ol | is_cb),
                brainExt=ext(is_ol | is_cb), vncExt=ext(is_vnc), olLExt=ext(is_ol & (side == 'L')), olRExt=ext(is_ol & (side == 'R')))

    # ---------------- recompute each settled round's episode at ms resolution
    warm = (Path(a.artifacts) / 'warm.bin').read_bytes()
    bci = [ro[0] for ro in G.readouts[:4]]
    rounds = []
    spf = a.ms_per_frame * 10
    for lj in a.log_json:
        lg = json.load(open(lj))
        frame = bytes.fromhex(lg['frame'][2:]); rates0 = lg.get('rates0', [0, 0, 0, 0])
        stim = dict(punishSteps=lg.get('punish', 0), rewardSteps=lg.get('reward', 0))
        s = F.State.from_wire(warm, G.n, G.slots, G.rfc); s.count[:] = 0
        k = F.kernel(G, s, 'c')
        L = list(struct.unpack('>%dH' % len(G.retina), frame)); Lf = [0] * len(L)
        rates = [int(x) for x in rates0]; prev4 = [0] * 4
        frames = []; touched = np.zeros(n, bool); prev_cnt = s.count.copy(); bins = []
        t0 = time.perf_counter()
        for b in range(D // B):
            for i in range(len(L)): Lf[i] += (p['alpha'] * (L[i] - Lf[i])) >> 16
            d = F.base_drive(G, Lf); tb = b * B
            if tb < stim['rewardSteps']: d[G.sugar] = F.SUGAR_Q16
            if tb < stim['punishSteps']:
                for i in G.ppl101: d[i] += F.PPL101_Q16
            k.set_drives(d)
            for _ in range(B // spf):
                k.advance(spf)
                spikers = np.flatnonzero(s.count != prev_cnt)
                frames.append(spikers.astype(np.uint32)); prev_cnt = s.count.copy()
                touched[s.active[:s.nActive]] = True; touched[spikers] = True
            c4 = [int(s.count[i]) - prev4[j] for j, i in enumerate(bci)]; prev4 = [int(s.count[i]) for i in bci]
            raw = [c * 10_000_000 // B for c in c4]
            rates = [(rates[j] * p['decay'] + raw[j] * (65536 - p['decay'])) >> 16 for j in range(4)]
            turn = max(-6000, min(6000, 120 * (rates[0] - rates[1]) // 1000)); fwd = max(0, min(20000, 400 * (rates[2] + rates[3]) // 1000))
            bins.append(dict(bin=b, counts=c4, rates=list(rates), feeBps=p['minFee'] + fwd * (p['maxFee'] - p['minFee']) // 20000,
                             skewBps=turn * p['maxSkew'] // 6000, nActive=int(s.nActive), spikes=int(s.count.sum())))
        k.materialize()
        sim_wall = time.perf_counter() - t0
        total = int(s.count.sum())
        assert bins[-1]['feeBps'] == lg['fee'] and bins[-1]['skewBps'] == lg['skew'], f'{lj}: recomputed fee/skew differ from the on-chain decision'
        rounds.append(dict(tx=lg['tx'], epoch=lg.get('epoch'), windowId=lg.get('windowId'), feeBps=lg['fee'], skewBps=lg['skew'], flags=lg.get('flags', 0),
                           spikeRoot=lg.get('spikeRoot'), stim=stim, rates0=rates0, frames=frames, bins=bins, totalSpikes=total, touched=touched,
                           retinaLum=L, litReceptors=sum(1 for l in L if l), nActiveEnd=int(s.nActive), simWall=round(sim_wall, 2),
                           spikesByClass=np.bincount(sc_id, weights=s.count, minlength=len(classes)).astype(int).tolist(),
                           touchedByClass=np.bincount(sc_id[touched], minlength=len(classes)).astype(int).tolist()))
        print(f'{lj}: epoch {lg.get("epoch")} window {lg.get("windowId")} fee {lg["fee"]} skew {lg["skew"]} spikes {total} touched {int(touched.sum())} ({sim_wall:.2f}s)')
    count_by_class = np.bincount(sc_id, minlength=len(classes)).astype(int).tolist()
    touched_any = np.zeros(n, bool)
    for r in rounds: touched_any |= r['touched']
    def b64(arr): return base64.b64encode(np.ascontiguousarray(arr).tobytes()).decode()
    ro_names = ['DNp20 R', 'DNp20 L', 'DNpe017 L', 'DNpe017 R', 'DNa02 R', 'DNa02 L', 'DNp09 L', 'DNp09 R', 'MDN R', 'MDN L', 'MDN R', 'MDN L', 'MN9 L', 'MN9 R']
    data = dict(
        n=n, classes=classes, countByClass=count_by_class, pos=b64(pos_n), cls=b64(sc_id), touched=b64(np.packbits(touched_any)),
        msPerFrame=a.ms_per_frame, episodeMs=D // 10, binMs=B // 10,
        retina=[[int(idx)] for (idx, _u, _v) in G.retina], lamina=[int(x) for x in G.lamina[:2000]],
        readouts=[dict(idx=int(ro[0]), name=ro_names[j], type=ro[1], side=ro[2]) for j, ro in enumerate(G.readouts)],
        rounds=[dict({k: v for k, v in r.items() if k not in ('frames', 'touched')}, frames=[b64(f) for f in r['frames']], touched=b64(np.packbits(r['touched'])),
                     touched_count=int(r['touched'].sum())) for r in rounds],
        anat=anat, amm=(json.load(open(a.amm_json)) if a.amm_json else None), unplaced=n_none, imputed=n_imputed)
    html = Path(a.template).read_text().replace('__DATA__', json.dumps(data))
    Path(a.out).write_text(html)
    print(json.dumps({'n': n, 'rounds': len(rounds), 'imputed': n_imputed, 'unplaced': n_none}))
    print('wrote', a.out, Path(a.out).stat().st_size // 1024, 'KB')


if __name__ == '__main__':
    main()
