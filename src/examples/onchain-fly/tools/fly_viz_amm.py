#!/usr/bin/env python3
"""Collect the AMM side of the story from Sepolia for the animation: pool events (liquidity, swaps with the fee
charged, window closes), spot price after every event, effective fee over time, the policy's decisions, and the
exact Observation the animated round's decision was computed from (eth_call observe() at the settlement's parent
block) rendered to the 640x480 canvas the retina sampled.

  fly_viz_amm.py --rpc URL --pool A --policy A --from-block N --round-tx 0x.. --artifacts D --cfg-json sepolia.json --out amm_data.json
"""
import argparse, base64, json, struct, sys, zlib
from pathlib import Path
import urllib.request
from eth_abi import decode
from eth_hash.auto import keccak

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fly_int as F


def rpc(url, m, p):
    req = urllib.request.Request(url, json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': m, 'params': p}).encode(),
                                 {'Content-Type': 'application/json', 'User-Agent': 'curl/8.4.0'})
    out = json.loads(urllib.request.urlopen(req, timeout=120).read())
    if 'error' in out: raise RuntimeError(out['error'])
    return out['result']


def call(url, to, sig, types, args, out_types, block='latest'):
    from eth_abi import encode
    data = '0x' + (keccak(sig.encode())[:4] + encode(types, args)).hex()
    res = rpc(url, 'eth_call', [{'to': to, 'data': data}, block if isinstance(block, str) else hex(block)])
    return decode(out_types, bytes.fromhex(res[2:]))


def topic(sig): return '0x' + keccak(sig.encode()).hex()


SWAP = 'Swap(address,address,bool,uint256,uint256,uint16)'
LIQ = 'LiquidityAdded(address,uint256,uint256,uint256)'
WCL = 'WindowClosed(uint32,uint64,uint64,uint64,uint64,uint128,uint64)'
FLY = 'FlyDecided(uint256,bytes32,bytes32,(bytes32,uint32,uint32,uint16,int16,uint8,uint32[4],bytes32),bytes,(uint32[4],uint32[4],uint32[14],uint64))'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--rpc', default='http://127.0.0.1:18545'); ap.add_argument('--pool', required=True); ap.add_argument('--policy', required=True)
    ap.add_argument('--from-block', type=int, required=True); ap.add_argument('--artifacts', default='artifacts')
    ap.add_argument('--cfg-json', default='sepolia.json'); ap.add_argument('--out', required=True)
    a = ap.parse_args()
    head = int(rpc(a.rpc, 'eth_blockNumber', []), 16)
    logs = rpc(a.rpc, 'eth_getLogs', [{'address': [a.pool, a.policy], 'fromBlock': hex(a.from_block), 'toBlock': 'latest'}])
    events = []
    for lg in logs:
        t0 = lg['topics'][0]; blk = int(lg['blockNumber'], 16); d = bytes.fromhex(lg['data'][2:]); tx = lg['transactionHash']
        if t0 == topic(SWAP):
            buy, ain, aout, fee = decode(['bool', 'uint256', 'uint256', 'uint16'], d)
            events.append(dict(kind='swap', block=blk, tx=tx, buyBase=buy, amountIn=ain / 1e18, amountOut=aout / 1e18, feeBps=fee))
        elif t0 == topic(LIQ):
            b, q, lp = decode(['uint256', 'uint256', 'uint256'], d)
            events.append(dict(kind='liquidity', block=blk, tx=tx, base=b / 1e18, quote=q / 1e18))
        elif t0 == topic(WCL):
            buy, sell, feeInc, lpLoss, twap, volRef = decode(['uint64', 'uint64', 'uint64', 'uint64', 'uint128', 'uint64'], d)
            events.append(dict(kind='window', block=blk, tx=tx, windowId=int(lg['topics'][1], 16), buy=buy, sell=sell, feeIncome=feeInc, lpLoss=lpLoss,
                               twap=twap / 2 ** 64, volRef=volRef))
        elif t0 == topic(FLY):
            nxt, frame, r = decode(['(bytes32,uint32,uint32,uint16,int16,uint8,uint32[4],bytes32)', 'bytes', '(uint32[4],uint32[4],uint32[14],uint64)'], d)
            events.append(dict(kind='decision', block=blk, tx=tx, epoch=nxt[1], windowId=nxt[2], feeBps=nxt[3], skewBps=nxt[4], flags=nxt[5],
                               rates=list(r[0]), totalSpikes=r[3], spikeRoot=lg['topics'][3]))
    events.sort(key=lambda e: e['block'])
    # spot + effective fee after each event block, plus at window boundaries up to head
    blocks = sorted(set([e['block'] for e in events] + list(range((a.from_block // 25 + 1) * 25, head + 1, 25)) + [head]))
    series = []
    for b in blocks:
        rb, = call(a.rpc, a.pool, 'reserveBase()', [], [], ['uint128'], b); rq, = call(a.rpc, a.pool, 'reserveQuote()', [], [], ['uint128'], b)
        fb, = call(a.rpc, a.pool, 'effectiveFee(bool)', ['bool'], [True], ['uint16'], b); fs, = call(a.rpc, a.pool, 'effectiveFee(bool)', ['bool'], [False], ['uint16'], b)
        series.append(dict(block=b, window=b // 25, spot=(rq / rb) if rb else None, reserveBase=rb / 1e18, reserveQuote=rq / 1e18, feeBuy=fb, feeSell=fs))
    # per decision: the Observation decide() read (observe() at the settlement's parent block) + the canvas the retina sampled
    cfg = [int(json.load(open(a.cfg_json))[k], 16) for k in ('cfg0', 'cfg1', 'cfg2')]; p = F.unpack_cfg(cfg)
    G = F.Graph(a.artifacts)
    obs_types = '(uint32,uint64[16],uint64[16],uint64,uint128,uint128,uint64,uint64)'
    W, H = 160, 120
    rounds = {}
    for e in events:
        if e['kind'] != 'decision': continue
        sblk = e['block']
        (o,) = call(a.rpc, a.pool, 'observe()', [], [], [obs_types], sblk - 1)
        obs = dict(windowId=o[0], buyQuote=list(o[1]), sellQuote=list(o[2]), volRef=o[3], spotQ64=o[4], twapQ64=o[5], feeIncomeQuote=o[6], lpLossQuote=o[7])
        img = bytearray()
        for y in range(H):
            for x in range(W):
                img.append(F.canvas_value(y * 4, x * 4, obs, p['devRef'], p['volBarRows']) >> 8)
        frame = F.rasterize(G, cfg, obs); lum = list(struct.unpack('>%dH' % len(G.retina), frame))
        rounds[e['tx']] = dict(settleBlock=sblk, obs=obs, canvas=dict(w=W, h=H, gray=base64.b64encode(bytes(img)).decode()),
                               retinaUV=[[u / 65535, v / 65535, l / 65535] for (idx, u, v), l in zip(G.retina, lum)],
                               litReceptors=sum(1 for l in lum if l), frameKeccak='0x' + keccak(frame).hex())
    out = dict(head=head, fromBlock=a.from_block, events=events, series=series, rounds=rounds)
    json.dump(out, open(a.out, 'w'))
    print(json.dumps({'events': {k: sum(1 for e in events if e['kind'] == k) for k in ('liquidity', 'swap', 'window', 'decision')}, 'seriesPoints': len(series),
                      'rounds': {tx[:10]: dict(block=r['settleBlock'], window=r['obs']['windowId'], lit=r['litReceptors']) for tx, r in rounds.items()}}))


if __name__ == '__main__':
    main()
