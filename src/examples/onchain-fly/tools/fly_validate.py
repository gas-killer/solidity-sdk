#!/usr/bin/env python3
"""Validation harness (HANDOFF §7).

  synth <synthdir>        C-core vs pure-Python bit equality (step / composition / decide / warmup),
                          kernel.cpp parity gates on the synthetic graph, and vectors.json for forge.
  full  <artifacts> <graph.npz> [--ms 300]
                          kernel.cpp (float32) vs fly_int (fixed-point) on the full graph: §7.2 gates.

kernel.cpp is driven directly through libneural.dylib (built by `python -m doom.build_kernel`), with
explicit drive arrays, so both kernels see byte-identical drive schedules (Q16 drives → float32).
"""
import argparse, ctypes as C, json, math, os, struct, sys, time
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fly_int as F

DOOM = Path(os.environ.get('DOOM_ROOT', Path(__file__).resolve().parents[2] / 'doomfly'))


# ----------------------------------------------------------------------------- kernel.cpp driver
class FloatKernel:
    """Direct ctypes driver for doomfly's neural_advance (float32 reference)."""
    def __init__(self, npz):
        lib = DOOM / 'outputs/doom' / ('libneural.dylib' if sys.platform == 'darwin' else 'libneural.so')
        self.f = C.CDLL(str(lib)).neural_advance
        self.f.argtypes = [C.c_int] + [C.c_void_p] * 11 + [C.c_int, C.c_float] + [C.c_void_p] * 5
        self.f.restype = None
        a = np.load(npz)
        self.ptr, self.post, self.weight = a['ptr'].astype(np.int64), a['post'].astype(np.int32), a['weight'].astype(np.float32)
        self.n = n = len(self.ptr) - 1
        self.v = np.full(n, -52, np.float32); self.g = np.zeros(n, np.float32); self.refr = np.zeros(n, np.int16)
        self.drive = np.zeros(n, np.float32); self.prev = np.zeros(n, np.float32)
        self.queue = np.zeros((19, n), np.int32); self.qc = np.zeros(19, np.int32); self.clock = np.zeros(1, np.int64)
        self.counts = np.zeros(n, np.int32); self.active = np.zeros(n, np.int32); self.flags = np.zeros(n, np.uint8)
        self.nactive = np.zeros(1, np.int32); self.last = np.full(n, -1, np.int64)

    def advance(self, drive_q16, steps):
        self.drive[:] = (np.asarray(drive_q16, np.int64).astype(np.float64) / 65536.0).astype(np.float32)
        self.counts.fill(0)
        arrays = [self.ptr, self.post, self.weight, self.v, self.g, self.refr, self.drive, self.prev, self.queue, self.qc, self.clock]
        self.f(self.n, *[x.ctypes.data for x in arrays], steps, C.c_float(0.1),
               *[x.ctypes.data for x in (self.counts, self.active, self.flags, self.nactive, self.last)])
        return self.counts.copy()


# ----------------------------------------------------------------------------- helpers
def load(artifacts):
    G = F.Graph(artifacts)
    return G, G.cfg()


def episode_drives(G, cfg, frame, stim):
    """The exact per-bin drive schedule decide() uses (re-derived here so kernel.cpp sees the same one)."""
    p = F.unpack_cfg(cfg); D, B = p['episodeSteps'], p['binSteps']
    L = list(struct.unpack('>%dH' % len(G.retina), frame)); Lf = [0] * len(L)
    out = []
    for b in range(D // B):
        for i in range(len(L)): Lf[i] += (p['alpha'] * (L[i] - Lf[i])) >> 16
        d = F.base_drive(G, Lf); t0 = b * B
        if t0 < stim['rewardSteps']: d[G.sugar] = F.SUGAR_Q16
        if t0 < stim['punishSteps']:
            for i in G.ppl101: d[i] += F.PPL101_Q16
        out.append(d)
    return out


def observation(kind='busy'):
    if kind == 'empty':
        return dict(windowId=1, buyQuote=[0] * 16, sellQuote=[0] * 16, volRef=0, spotQ64=1 << 64, twapQ64=1 << 64, feeIncomeQuote=0, lpLossQuote=0)
    rng = np.random.default_rng(11)
    buy = [int(x) for x in rng.integers(0, 2_000_000, 16)]; sell = [int(x) for x in rng.integers(0, 1_200_000, 16)]
    return dict(windowId=7, buyQuote=buy, sellQuote=sell, volRef=900_000, spotQ64=(1 << 64) * 1003 // 1000, twapQ64=1 << 64,
                feeIncomeQuote=1234, lpLossQuote=0)


def run_fixed(G, cfg, warm_wire, frame, stim, rates0, backend):
    t0 = time.perf_counter(); trace = []
    r, root, out = F.decide(G, cfg, warm_wire, frame, stim, rates0, backend, trace)
    return r, root, out, time.perf_counter() - t0, trace


def parity(G, cfg, npz, warm_steps, frame, stim, backend='c', per_step_ms=10):
    """§7.2 gates: float kernel.cpp vs fixed fly_int from the same genesis + drive schedule."""
    p = F.unpack_cfg(cfg); D, B = p['episodeSteps'], p['binSteps']
    fk = FloatKernel(npz)
    black = F.base_drive(G, [0] * len(G.retina))
    fk.advance(black, warm_steps)
    s = F.State.genesis(G.n, G.slots); k = F.kernel(G, s, backend)
    k.set_drives(black); k.advance(warm_steps); k.materialize()
    drives = episode_drives(G, cfg, frame, stim)
    first = per_step_ms * 10
    # --- first `first` steps one step at a time: raster
    raster_f, raster_i = [], []
    s.count[:] = 0
    for t in range(first):
        d = drives[t // B]
        if t % B == 0: k.set_drives(d)
        cf = fk.advance(d, 1); raster_f.append(np.flatnonzero(cf))
        before = s.count.copy(); k.advance(1); raster_i.append(np.flatnonzero(s.count != before))
    ident = sum(1 for a, b in zip(raster_f, raster_i) if np.array_equal(a, b))
    # --- voltages at step `first` (materialize a copy of the fixed state)
    sc = s.copy(); F.kernel(G, sc, backend).materialize()
    dv = np.abs(sc.v.astype(np.float64) / 2 ** 24 - fk.v.astype(np.float64)); dg = np.abs(sc.g.astype(np.float64) / 2 ** 24 - fk.g.astype(np.float64))
    # --- rest of the episode per bin
    tot_f = int(sum(len(x) for x in raster_f)); tot_i = int(s.count.sum())
    ro_f = np.zeros(len(G.readouts), np.int64); ro_i = np.zeros(len(G.readouts), np.int64)
    for a in raster_f:
        for j, ro in enumerate(G.readouts): ro_f[j] += int(np.sum(a == ro[0]))
    ro_i += np.array([int(s.count[ro[0]]) for ro in G.readouts])
    base_i = s.count.copy()
    assert first % B == 0, 'per-step prefix must be whole bins'
    act_hist_f, act_hist_i = [int(fk.nactive[0])], [int(s.nActive)]
    for b in range(first // B, D // B):
        d = drives[b]
        k.set_drives(d); k.advance(B); act_hist_i.append(int(s.nActive))
        cf = fk.advance(d, B); act_hist_f.append(int(fk.nactive[0])); tot_f += int(cf.sum()); ro_f += np.array([int(cf[ro[0]]) for ro in G.readouts])
    tot_i = int(s.count.sum()); ro_i = np.array([int(s.count[ro[0]]) for ro in G.readouts])
    act_f, act_i = int(fk.nactive[0]), int(s.nActive)
    mean_f, mean_i = sum(act_hist_f) / len(act_hist_f), sum(act_hist_i) / len(act_hist_i)
    gate_ro = [abs(int(a) - int(b)) <= 3 * math.sqrt(max(int(a), 10)) for a, b in zip(ro_f, ro_i)]
    rep = dict(first_steps=first, raster_identical_steps=ident, raster_gate=(ident == first),
               max_dv_mV=float(dv.max()), max_dg_mV=float(dg.max()), voltage_gate=bool(dv.max() <= 0.002 and dg.max() <= 0.002),
               spikes_float=tot_f, spikes_fixed=tot_i, spike_gate=bool(abs(tot_f - tot_i) <= 0.03 * max(tot_f, 1)),
               active_float=act_f, active_fixed=act_i, active_gate=bool(abs(act_f - act_i) <= 0.03 * max(act_f, 1)),
               active_mean_float=round(mean_f, 1), active_mean_fixed=round(mean_i, 1),
               active_mean_gate=bool(abs(mean_f - mean_i) <= 0.03 * max(mean_f, 1)),
               readout_float=ro_f.tolist(), readout_fixed=ro_i.tolist(), readout_gate=all(gate_ro),
               sim_seconds=D / 10000, pop_rate_hz_fixed=tot_i / (D / 10000) / G.n)
    return rep


# ----------------------------------------------------------------------------- synth
def cmd_synth(a):
    art = Path(a.synthdir) / 'artifacts'; npz = Path(a.synthdir) / 'graph.npz'
    G, cfg0 = load(art)
    cfg = F.pack_cfg(G.manifest, episode_steps=a.steps, pulse_steps=200, bin_steps=100, warm_chunks=1)
    report = {}
    # 1. tables: C == py
    lib = F._lib(); tA = (C.c_uint64 * 1025)(); tB = (C.c_uint64 * 1025)(); tC = (C.c_uint64 * 1025)()
    lib.fly_get_tables(tA, tB, tC)
    assert all(int(tA[d]) == F.TA[d] and int(tB[d]) == F.TB[d] and int(tC[d]) == F.TC[d] for d in range(1, 1025)), 'tables differ'
    for d in (1025, 2000, 2218, 2219, 3000, 5000, 8872, 8873, 20000, 123456):
        ca, cb, cc = C.c_uint64(), C.c_uint64(), C.c_uint64(); lib.fly_far_decay(d, C.byref(ca), C.byref(cb), C.byref(cc))
        assert (ca.value, cb.value, cc.value) == F.far_decay(d), f'far decay differs at d={d}'
    report['tables'] = 'C == py (1..1024 and far decay probes)'
    # 2. warmup: C == py
    wsteps = a.warm
    wc, cc_ = F.warmup(G, cfg, wsteps, 'c'); wp, cp = F.warmup(G, cfg, wsteps, 'py')
    assert wc == wp and cc_ == cp, 'warmup C != py'
    report['warmup'] = dict(steps=wsteps, bytes=len(wc), keccak=F.keccak(wc).hex(), warmCommitment=cc_.hex(),
                            nActive=F.State.from_wire(wc, G.n, G.slots, G.rfc).nActive)
    # 3. step: C == py, and composition step(0,t1)∘step(t1,T) == step(0,T)
    gen = F.genesis_state(G)
    drive = F.base_drive(G, [40000] * len(G.retina))
    drive_in = b''.join(struct.pack('>Ii', int(i), int(drive[i])) for i in np.flatnonzero(drive))
    ro_ids = [ro[0] for ro in G.readouts]
    T, t1 = 700, 260
    oc, cc1, hc = F.step(G, cfg, gen, drive_in, ro_ids, T, 'c'); op, cp1, hp = F.step(G, cfg, gen, drive_in, ro_ids, T, 'py')
    assert oc == op and cc1 == cp1 and hc == hp, 'step C != py'
    m1, c1, h1 = F.step(G, cfg, gen, drive_in, ro_ids, t1, 'c'); m2, c2, h2 = F.step(G, cfg, m1, drive_in, ro_ids, T - t1, 'c')
    assert F.wire_without_counts(m2, G.n) == F.wire_without_counts(oc, G.n), 'composition failed (state)'
    assert np.array_equal(F.wire_counts(m1, G.n) + F.wire_counts(m2, G.n), F.wire_counts(oc, G.n)), 'composition failed (counts)'
    assert [x + y for x, y in zip(c1, c2)] == cc1, 'composition failed (readouts)'
    # tampered stateIn (last >= clock) must be rejected
    bad = bytearray(m1); bad[128 + 24:128 + 30] = int.from_bytes(bad[5:11], 'big').to_bytes(6, 'big')
    try: F.step(G, cfg, bytes(bad), drive_in, ro_ids, 10, 'c'); raise SystemExit('tampered state accepted')
    except AssertionError as e: assert 'tampered' in str(e)
    report['step'] = dict(T=T, t1=t1, readoutCounts=cc1, chk=hc.hex(), stateOutKeccak=F.keccak(oc).hex(), composition='exact', tamper='rejected')
    # 4. decide: C == py for two observations
    o = observation('busy'); frame = F.rasterize(G, cfg, o); stim = dict(punishSteps=200, rewardSteps=200); rates0 = [120000, 30000, 50000, 0]
    rc, rootc, outc, tc, trace = run_fixed(G, cfg, wc, frame, stim, rates0, 'c')
    rp, rootp, outp, tp, _ = run_fixed(G, cfg, wc, frame, stim, rates0, 'py')
    assert rc == rp and rootc == rootp and outc == outp, 'decide C != py'
    report['decide'] = dict(frame=frame.hex(), readout=rc, spikeRoot=rootc.hex(), stateOutKeccak=F.keccak(outc).hex(),
                            wall_c=round(tc, 3), wall_py=round(tp, 1), trace_head=trace[:3])
    # 5. kernel.cpp parity gates
    report['parity'] = parity(G, cfg, npz, wsteps, frame, stim)
    # 6. vectors.json for forge
    vec = dict(packedConfig=[hex(x) for x in cfg], meta=dict(n=G.n, nEdges=G.E, delay=G.delay, rfc=G.rfc, readouts=G.readouts,
               retina=[list(r) for r in G.retina], lamina=G.lamina.tolist(), sugar=G.sugar.tolist(), ppl101=list(G.ppl101)),
               genesis=gen.hex(),
               warm=dict(steps=wsteps, stateOut=wc.hex(), warmCommitment=cc_.hex()),
               step=dict(stateIn=gen.hex(), driveIn=drive_in.hex(), readoutIds=ro_ids, nSteps=T, stateOut=oc.hex(), readoutCounts=cc1, chk=hc.hex(),
                         split=dict(t1=t1, mid=m1.hex(), chk1=h1.hex(), chk2=h2.hex(), counts1=c1, counts2=c2)),
               decide=dict(observation=o, frame=frame.hex(), stimulus=stim, rates0=rates0, readout=rc, spikeRoot=rootc.hex(),
                           stateOut=outc.hex(), episodeSteps=a.steps, binTrace=trace))
    def hx(o):   # forge-friendly: 0x-prefixed hex strings, big ints as decimal strings
        if isinstance(o, dict): return {k: hx(v) for k, v in o.items()}
        if isinstance(o, list): return [hx(v) for v in o]
        if isinstance(o, str) and o and all(ch in '0123456789abcdef' for ch in o) and len(o) % 2 == 0 and len(o) >= 16: return '0x' + o
        if isinstance(o, int) and not isinstance(o, bool) and o >= (1 << 53): return str(o)
        return o
    (Path(a.synthdir) / 'vectors.json').write_text(json.dumps(hx(vec)) + '\n')
    report['vectors'] = str(Path(a.synthdir) / 'vectors.json')
    print(json.dumps(report, indent=1, default=str))


# ----------------------------------------------------------------------------- full graph
def cmd_full(a):
    G, cfg0 = load(a.artifacts)
    cfg = F.pack_cfg(G.manifest, episode_steps=a.ms * 10, pulse_steps=2000, bin_steps=100, warm_chunks=219)
    o = observation(a.obs); frame = F.rasterize(G, cfg, o); stim = dict(punishSteps=a.punish, rewardSteps=a.reward)
    t0 = time.perf_counter()
    rep = parity(G, cfg, Path(a.npz), a.warm, frame, stim)
    rep['wall_s'] = round(time.perf_counter() - t0, 1); rep['warm_steps'] = a.warm; rep['observation'] = a.obs
    print(json.dumps(rep, indent=1))
    if a.out: Path(a.out).write_text(json.dumps(rep, indent=1) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__); sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('synth'); s.add_argument('synthdir'); s.add_argument('--steps', type=int, default=3000); s.add_argument('--warm', type=int, default=2000)
    f = sub.add_parser('full'); f.add_argument('artifacts'); f.add_argument('npz'); f.add_argument('--ms', type=int, default=300)
    f.add_argument('--warm', type=int, default=20000); f.add_argument('--obs', default='busy'); f.add_argument('--punish', type=int, default=0)
    f.add_argument('--reward', type=int, default=0); f.add_argument('--out')
    a = ap.parse_args()
    {'synth': cmd_synth, 'full': cmd_full}[a.cmd](a)


if __name__ == '__main__':
    main()
