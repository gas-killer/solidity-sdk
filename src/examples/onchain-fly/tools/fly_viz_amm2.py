#!/usr/bin/env python3
"""v2 (per-swap intents) chain data for the animation: pool + policy events on Sepolia, spot after every event,
and for every decided intent the episode inputs (logged SwapObservation, chained rates0, pulses) plus the
v2 retina canvas — so the builder can replay each intent's fly episode bit-exact and check the logged spikeRoot.

  fly_viz_amm2.py --rpc URL --pool A --policy A --from-block N --artifacts D --cfg-json sepolia.json --out amm2_data.json
"""
import argparse, base64, json, struct, sys
from pathlib import Path
import urllib.request
from eth_abi import decode, encode
from eth_hash.auto import keccak

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fly_int as F

STATE = '(bytes32,uint32,uint64,uint8,uint32[4],bytes32)'
OBS = '(uint64,bool,uint64,uint64,uint64,uint32,uint64[16],uint64[16],uint64,uint128,uint128,uint64,uint64)'
READOUT = '(uint32[4],uint32[4],uint32[14],uint64)'
SIGS = {
    'submitted': 'IntentSubmitted(uint64,address,bool,uint256,uint256,uint32)',
    'swap': 'Swap(uint64,address,bool,uint256,uint256,uint16,uint32)',
    'refund': 'IntentRefunded(uint64,address,uint256,string)',
    'liquidity': 'LiquidityAdded(address,uint256,uint256,uint256)',
    'epoch': 'EpochRolled(uint32,uint64,uint64,uint64,uint64,uint64,uint128)',
    'decided': 'FlyIntentDecided(uint64,bytes32,bytes32,' + OBS + ',' + READOUT + ')',
    'settled': 'FlySettled(uint256,bytes32,' + STATE + ')',
}
TOPIC = {k: '0x' + keccak(v.encode()).hex() for k, v in SIGS.items()}
MEMORY_ROOT_ZERO = bytes.fromhex('c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470')


def rpc(url, m, p):
    req = urllib.request.Request(url, json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': m, 'params': p}).encode(),
                                 {'Content-Type': 'application/json', 'User-Agent': 'curl/8.4.0'})
    out = json.loads(urllib.request.urlopen(req, timeout=120).read())
    if 'error' in out: raise RuntimeError(out['error'])
    return out['result']


def call(url, to, sig, types, args, out_types, block='latest'):
    data = '0x' + (keccak(sig.encode())[:4] + encode(types, args)).hex()
    res = rpc(url, 'eth_call', [{'to': to, 'data': data}, block if isinstance(block, str) else hex(block)])
    return decode(out_types, bytes.fromhex(res[2:]))


def obs_dict(o):
    return dict(id=o[0], buyBase=o[1], sizeBps=o[2], maxSlipBps=o[3], queueDepth=o[4], epoch=o[5], buyQuote=list(o[6]), sellQuote=list(o[7]),
                volRef=o[8], spotQ64=o[9], emaSpotQ64=o[10], feeIncomeQuote=o[11], lpLossQuote=o[12])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--rpc', default='http://127.0.0.1:18545'); ap.add_argument('--pool', required=True); ap.add_argument('--policy', required=True)
    ap.add_argument('--from-block', type=int, required=True); ap.add_argument('--artifacts', default='artifacts')
    ap.add_argument('--cfg-json', default='sepolia.json'); ap.add_argument('--cfg-key', default='cfg2v2'); ap.add_argument('--out', required=True)
    a = ap.parse_args()
    head = int(rpc(a.rpc, 'eth_blockNumber', []), 16)
    raw = rpc(a.rpc, 'eth_getLogs', [{'address': [a.pool, a.policy], 'fromBlock': hex(a.from_block), 'toBlock': 'latest'}])
    events = []
    for lg in raw:
        t0 = lg['topics'][0]; blk = int(lg['blockNumber'], 16); d = bytes.fromhex(lg['data'][2:]); tx = lg['transactionHash']; li = int(lg['logIndex'], 16)
        base = dict(block=blk, tx=tx, logIndex=li)
        if t0 == TOPIC['submitted']:
            buy, ain, mo, exp = decode(['bool', 'uint256', 'uint256', 'uint32'], d)
            events.append(dict(base, kind='intent', id=int(lg['topics'][1], 16), owner='0x' + lg['topics'][2][-40:], buyBase=buy, amountIn=ain / 1e18, minOut=mo / 1e18, expiryEpoch=exp))
        elif t0 == TOPIC['swap']:
            buy, ain, aout, fee, ep = decode(['bool', 'uint256', 'uint256', 'uint16', 'uint32'], d)
            events.append(dict(base, kind='fill', id=int(lg['topics'][1], 16), buyBase=buy, amountIn=ain / 1e18, amountOut=aout / 1e18, feeBps=fee, epoch=ep))
        elif t0 == TOPIC['refund']:
            ain, reason = decode(['uint256', 'string'], d)
            events.append(dict(base, kind='refund', id=int(lg['topics'][1], 16), amountIn=ain / 1e18, reason=reason))
        elif t0 == TOPIC['liquidity']:
            b, q, lp = decode(['uint256', 'uint256', 'uint256'], d)
            events.append(dict(base, kind='liquidity', base=b / 1e18, quote=q / 1e18))
        elif t0 == TOPIC['epoch']:
            buy, sell, fi, ll, vr, ema = decode(['uint64', 'uint64', 'uint64', 'uint64', 'uint64', 'uint128'], d)
            events.append(dict(base, kind='epoch', epoch=int(lg['topics'][1], 16), buy=buy, sell=sell, feeIncome=fi, lpLoss=ll, volRef=vr, emaSpot=ema / 2 ** 64))
        elif t0 == TOPIC['decided']:
            o, r = decode([OBS, READOUT], d); w = int(lg['topics'][2], 16)
            skew = int.from_bytes(((w >> 224) & 0xffff).to_bytes(2, 'big'), 'big', signed=True)
            events.append(dict(base, kind='decision', id=int(lg['topics'][1], 16), fillWord=lg['topics'][2], spikeRoot=lg['topics'][3], feeBps=w >> 240, skewBps=skew,
                               flags=(w >> 216) & 0xff, epoch=(w >> 192) & 0xffffff, obs=obs_dict(o), readout=dict(rates=list(r[0]), last30=list(r[1]), windowCounts=list(r[2]), total=r[3])))
        elif t0 == TOPIC['settled']:
            (s,) = decode([STATE], d)
            events.append(dict(base, kind='settle', transitionIndex=int(lg['topics'][1], 16), flyWord=lg['topics'][2],
                               next=dict(prevWord='0x' + s[0].hex(), epoch=s[1], decidedThrough=s[2], flags=s[3], rates=list(s[4]))))
    events.sort(key=lambda e: (e['block'], e['logIndex']))
    # spot after each event block + head
    blocks = sorted(set([e['block'] for e in events] + [head]))
    series = []
    for b in blocks:
        rb, = call(a.rpc, a.pool, 'reserveBase()', [], [], ['uint128'], b); rq, = call(a.rpc, a.pool, 'reserveQuote()', [], [], ['uint128'], b)
        ap_, tail = call(a.rpc, a.pool, 'pendingRange()', [], [], ['uint64', 'uint64'], b)
        series.append(dict(block=b, spot=(rq / rb) if rb else None, reserveBase=rb / 1e18, reserveQuote=rq / 1e18, applied=ap_, tail=tail))
    # episodes: per decided intent, the inputs its episode needs (chained within a settle, seeded from the previous settle's state)
    cfg = [int(json.load(open(a.cfg_json))[k], 16) for k in ('cfg0', 'cfg1', a.cfg_key)]; p = F.unpack_cfg(cfg)
    G = F.Graph(a.artifacts)
    W, H = 160, 120
    episodes = []
    prev_state = dict(epoch=0, flags=0, rates=[0, 0, 0, 0])
    cur_rates = None; cur_first = True; cur_settle_block = None
    for e in events:
        if e['kind'] == 'decision':
            if cur_settle_block != e['tx']:
                cur_settle_block = e['tx']; cur_rates = list(prev_state['rates']); cur_first = True
            stim = dict(punishSteps=p['pulseSteps'] if (cur_first and prev_state['flags'] & 2) else 0, rewardSteps=p['pulseSteps'] if (cur_first and prev_state['flags'] & 4) else 0)
            o = e['obs']
            img = bytearray()
            for y in range(H):
                for x in range(W):
                    img.append(F.canvas_swap(y * 4, x * 4, o, p['devRef'], p['volBarRows'], p['sizeRef'], p['slipRef']) >> 8)
            frame = F.rasterize_swap(G, cfg, o); lum = list(struct.unpack('>%dH' % len(G.retina), frame))
            episodes.append(dict(id=e['id'], tx=e['tx'], block=e['block'], epoch=e['epoch'], feeBps=e['feeBps'], skewBps=e['skewBps'], flags=e['flags'], spikeRoot=e['spikeRoot'],
                                 rates0=list(cur_rates), stim=stim, obs=o, readout=e['readout'], frame='0x' + frame.hex(),
                                 canvas=dict(w=W, h=H, gray=base64.b64encode(bytes(img)).decode()),
                                 retinaUV=[[u / 65535, v / 65535, l / 65535] for (idx, u, v), l in zip(G.retina, lum)], litReceptors=sum(1 for l in lum if l)))
            cur_rates = list(e['readout']['rates']); cur_first = False
        elif e['kind'] == 'settle':
            prev_state = dict(epoch=e['next']['epoch'], flags=e['next']['flags'], rates=list(e['next']['rates']))
    out = dict(head=head, fromBlock=a.from_block, pool=a.pool, policy=a.policy, events=events, series=series, episodes=episodes, cfg=[hex(c) for c in cfg])
    json.dump(out, open(a.out, 'w'))
    print(json.dumps({'events': {k: sum(1 for e in events if e['kind'] == k) for k in ('liquidity', 'intent', 'decision', 'settle', 'fill', 'refund', 'epoch')},
                      'episodes': [dict(id=x['id'], fee=x['feeBps'], skew=x['skewBps'], lit=x['litReceptors'], stim=x['stim'], rates0=x['rates0']) for x in episodes]}))


if __name__ == '__main__':
    main()
