#!/usr/bin/env python3
"""Synthetic small graph in doomfly's graph.npz layout, for forge vectors and kernel parity tests.

HANDOFF §7.3: n = 64, ~600 edges, mixed per-neuron signs incl. autapses, 8 input (retina)
neurons, 14 readouts (BCI four first), one edge with count > 16,383 (exercises the row split).
Deterministic (seed 7).  Writes <outdir>/graph.npz and <outdir>/fly_readouts.json.
"""
import argparse, json
from pathlib import Path
import numpy as np

N, SEED = 64, 7


def build(outdir: Path):
    rng = np.random.default_rng(SEED)
    outdir.mkdir(parents=True, exist_ok=True)
    inhibitory = rng.random(N) < 0.25
    sign = np.where(inhibitory, -1, 1).astype(np.int8)
    pre, post, count = [], [], []
    for i in range(N):
        deg = 1 + rng.poisson(8)
        targets = rng.choice(N, size=min(deg, N), replace=False)
        for j in targets:
            c = 1 + rng.geometric(0.12)                       # mostly 1..40
            if rng.random() < 0.03:
                c = int(rng.integers(100, 400))              # a few strong edges
            pre.append(i); post.append(int(j)); count.append(int(c))
    # three autapses (self edges), like the 101 in MaleCNS
    for i in (5, 17, 40):
        if not any(p == i and q == i for p, q in zip(pre, post)):
            pre.append(i); post.append(i); count.append(int(3 + rng.integers(0, 5)))
    # one edge over the 14-bit count limit, from an inhibitory neuron (exercises the converter split)
    big_pre = int(np.flatnonzero(inhibitory)[0])
    pre.append(big_pre); post.append((big_pre + 7) % N); count.append(20_000)
    pre, post, count = np.asarray(pre), np.asarray(post, dtype=np.int32), np.asarray(count, dtype=np.int64)
    order = np.argsort(pre, kind='stable')
    ptr = np.r_[0, np.cumsum(np.bincount(pre, minlength=N))].astype(np.int64)
    # exactly prepare.py:23 — count as float32, times int8 sign, times python-float .275, in float32
    weight = (count[order].astype(np.float32) * sign[pre[order]] * .275).astype(np.float32)
    retina = np.sort(rng.choice(N, size=8, replace=False)).astype(np.int32)
    uv = rng.random((8, 2)).astype(np.float32)
    rest = np.setdiff1d(np.arange(N), retina)
    lamina = np.sort(rng.choice(rest, size=6, replace=False)).astype(np.int32)
    rest = np.setdiff1d(rest, lamina)
    sugar = np.sort(rng.choice(rest, size=2, replace=False)).astype(np.int32)
    rest = np.setdiff1d(rest, sugar)
    ppl101 = [int(x) for x in np.sort(rng.choice(rest, size=2, replace=False))]
    rest = np.setdiff1d(rest, ppl101)
    # BCI four = two retina + two lamina cells so the decoder EMA / spikesLast30ms paths are exercised
    ro_idx = [int(retina[0]), int(lamina[0]), int(retina[3]), int(lamina[2])] + [int(x) for x in rng.choice(rest, size=10, replace=False)]
    # (idx, type, side) in the converter's FIXED order: DNp20 R/L, DNpe017 L/R, DNa02 R/L, DNp09 L/R, MDN R/L/R/L, MN9 L/R
    pattern = [(0, 1), (0, 0), (1, 0), (1, 1), (2, 1), (2, 0), (3, 0), (3, 1), (4, 1), (4, 0), (4, 1), (4, 0), (5, 0), (5, 1)]
    readouts = [(i, t, s) for i, (t, s) in zip(ro_idx, pattern)]
    np.savez(outdir / 'graph.npz', ptr=ptr, post=post[order], weight=weight, ids=np.arange(N, dtype=np.int64),
             retina=retina, uv=uv, confidence=np.ones(8), hexes=np.zeros((8, 2)), lamina=lamina, sugar=sugar,
             superclass=np.asarray(['test'] * N, dtype='U64'))
    (outdir / 'fly_readouts.json').write_text(json.dumps({'readouts': readouts, 'ppl101': ppl101}) + '\n')
    print(json.dumps({'n': N, 'edges': int(len(post)), 'inhibitory': int(inhibitory.sum()), 'maxCount': int(count.max()),
                      'retina': retina.tolist(), 'lamina': lamina.tolist(), 'sugar': sugar.tolist(), 'ppl101': ppl101,
                      'readouts': readouts}))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('outdir', type=Path)
    build(p.parse_args().outdir)
