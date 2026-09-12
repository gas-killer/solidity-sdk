#!/usr/bin/env python3
"""Keeper for the v2 per-swap policy (HANDOFF_PER_SWAP §7): rebuilds `prev` from the last FlySettled log,
submits settle(prev) to the Gas Killer router, polls the rendered payload, broadcasts it, applies the fills.

  fly_keeper2.py state      --rpc URL --policy A                     the FlyStateV2 the next round extends + slot/decidedThrough
  fly_keeper2.py should-run --rpc URL --policy A --pool A            exit 0 iff pool.tail > policy.decidedThrough()
  fly_keeper2.py calldata   --rpc URL --policy A                     0x… settle(prev)
  fly_keeper2.py round      --rpc URL --policy A --pool A --router URL --api-key K --key-file F [--from A]
                            submit → poll /tasks/{id} until ready → send payload.data → pool.applyUpTo(N) → verify
  fly_keeper2.py verify     --rpc URL --policy A --pool A            replay FlySettled/FlyIntentDecided logs: chain, fills[id], slot
  fly_keeper2.py watch      ...round args... [--interval 30]         loop `round` whenever should-run

Standard library + eth_abi/eth_hash/eth_account only. Sends use eth_sendRawTransaction on --rpc.
"""
import argparse, json, sys, time, urllib.request
from eth_abi import encode, decode
from eth_hash.auto import keccak
from eth_utils import to_checksum_address

STATE = '(bytes32,uint32,uint64,uint8,uint32[4],bytes32)'
OBS = '(uint64,bool,uint64,uint64,uint64,uint32,uint64[16],uint64[16],uint64,uint128,uint128,uint64,uint64)'
READOUT = '(uint32[4],uint32[4],uint32[14],uint64)'
SETTLED_SIG = 'FlySettled(uint256,bytes32,' + STATE + ')'
DECIDED_SIG = 'FlyIntentDecided(uint64,bytes32,bytes32,' + OBS + ',' + READOUT + ')'
MEMORY_ROOT_ZERO = bytes.fromhex('c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470')
LOG_LOOKBACK = 90_000
UA = {'Content-Type': 'application/json', 'User-Agent': 'curl/8.4.0'}


def rpc(url, method, params):
    req = urllib.request.Request(url, json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(), UA)
    with urllib.request.urlopen(req, timeout=120) as r:
        out = json.loads(r.read())
    if 'error' in out:
        raise RuntimeError(out['error'])
    return out['result']


def sel(sig): return keccak(sig.encode())[:4]


def call(url, to, sig, types=(), args=(), out_types=(), block='latest'):
    data = '0x' + (sel(sig) + encode(list(types), list(args))).hex()
    res = rpc(url, 'eth_call', [{'to': to, 'data': data}, block])
    return decode(list(out_types), bytes.fromhex(res[2:])) if out_types else res


def slot_const(name):
    x = int.from_bytes(keccak(name.encode()), 'big') - 1
    return int.from_bytes(keccak(x.to_bytes(32, 'big')), 'big') & ~0xff


FLY_SLOT = slot_const('gaskiller.FlySwapPolicy.flyWord')
DECIDED_SLOT = slot_const('gaskiller.FlySwapPolicy.decidedThrough')
FILLS_BASE = slot_const('gaskiller.FlySwapPolicy.fills')


def fill_slot(id_): return int.from_bytes(keccak(encode(['uint256', 'bytes32'], [id_, FILLS_BASE.to_bytes(32, 'big')])), 'big')


def genesis(): return (b'\0' * 32, 0, 0, 0, (0, 0, 0, 0), MEMORY_ROOT_ZERO)


def pack(s):
    """FlySwapPolicy.pack: epoch[255:232] | decidedThrough[231:168] | flags[167:160] | keccak(abi.encode(s))[159:0]"""
    w = int.from_bytes(keccak(encode([STATE], [s])), 'big') & ((1 << 160) - 1)
    w |= s[3] << 160; w |= s[2] << 168; w |= (s[1] & 0xffffff) << 232
    return w.to_bytes(32, 'big')


def state_json(s):
    return {'prevWord': '0x' + s[0].hex(), 'epoch': s[1], 'decidedThrough': s[2], 'flags': s[3], 'rateMilliHz': list(s[4]), 'memoryRoot': '0x' + s[5].hex()}


def logs(url, policy, sig, decode_types, from_block=None):
    if from_block is None:
        head = int(rpc(url, 'eth_blockNumber', []), 16); from_block = hex(max(0, head - LOG_LOOKBACK))
    raw = rpc(url, 'eth_getLogs', [{'address': policy, 'topics': ['0x' + keccak(sig.encode()).hex()], 'fromBlock': from_block, 'toBlock': 'latest'}])
    out = []
    for lg in raw:
        out.append(dict(topics=lg['topics'], data=decode(decode_types, bytes.fromhex(lg['data'][2:])), block=int(lg['blockNumber'], 16), tx=lg['transactionHash']))
    return sorted(out, key=lambda x: x['block'])


def last_state(url, policy):
    ls = logs(url, policy, SETTLED_SIG, [STATE])
    return (ls[-1]['data'][0], bytes.fromhex(ls[-1]['topics'][2][2:])) if ls else (genesis(), b'\0' * 32)


def storage(url, addr, slot): return bytes.fromhex(rpc(url, 'eth_getStorageAt', [addr, hex(slot), 'latest'])[2:].rjust(64, '0'))


def calldata(prev): return sel('settle(' + STATE + ')') + encode([STATE], [prev])


def pending(url, pool, policy):
    applied, tail = call(url, pool, 'pendingRange()', out_types=['uint64', 'uint64'])
    decided = call(url, policy, 'decidedThrough()', out_types=['uint256'])[0]
    return applied, tail, decided


# ------------------------------------------------------------------ tx sending
def send_tx(url, key, to, data, gas):
    from eth_account import Account
    acct = Account.from_key(key)
    nonce = int(rpc(url, 'eth_getTransactionCount', [acct.address, 'pending']), 16)
    gas_price = int(rpc(url, 'eth_gasPrice', []), 16)
    tx = {'to': to_checksum_address(to), 'data': data, 'gas': gas, 'maxFeePerGas': int(gas_price * 2), 'maxPriorityFeePerGas': min(int(0.05e9), gas_price), 'nonce': nonce,
          'chainId': int(rpc(url, 'eth_chainId', []), 16), 'value': 0, 'type': 2}
    raw = Account.sign_transaction(tx, key).raw_transaction
    h = rpc(url, 'eth_sendRawTransaction', ['0x' + raw.hex()])
    for _ in range(120):
        rc = rpc(url, 'eth_getTransactionReceipt', [h])
        if rc: return rc
        time.sleep(2)
    raise RuntimeError('receipt timeout ' + h)


# ------------------------------------------------------------------ commands
def cmd_state(a):
    prev, word = last_state(a.rpc, a.policy)
    print(json.dumps({'prev': state_json(prev), 'word': '0x' + word.hex(), 'slot': '0x' + storage(a.rpc, a.policy, FLY_SLOT).hex(),
                      'decidedThrough': int.from_bytes(storage(a.rpc, a.policy, DECIDED_SLOT), 'big')}, indent=1))


def cmd_should_run(a):
    applied, tail, decided = pending(a.rpc, a.pool, a.policy)
    print(json.dumps({'applied': applied, 'tail': tail, 'decidedThrough': decided, 'shouldRun': tail > decided, 'undecided': tail - decided, 'unapplied': decided - applied}))
    sys.exit(0 if tail > decided else 1)


def cmd_calldata(a):
    prev, _ = last_state(a.rpc, a.policy); print('0x' + calldata(prev).hex())


def submit(a, prev):
    ti = call(a.rpc, a.policy, 'stateTransitionCount()', out_types=['uint256'])[0]
    block = int(rpc(a.rpc, 'eth_blockNumber', []), 16)
    body = {'body': {'target_address': a.policy, 'from_address': a.sender, 'call_data': list(calldata(prev)), 'transition_index': ti, 'value': '0x0', 'block_height': block}}
    req = urllib.request.Request(a.router.rstrip('/') + '/tasks', json.dumps(body).encode(), dict(UA, Authorization='Bearer ' + a.api_key))
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.loads(r.read())
    print('submitted', out); return out['task_id']


def poll_ready(a, task_id, timeout=1800):
    t0 = time.time()
    while time.time() - t0 < timeout:
        req = urllib.request.Request(a.router.rstrip('/') + f'/tasks/{task_id}', headers=dict(UA, Authorization='Bearer ' + a.api_key))
        with urllib.request.urlopen(req, timeout=60) as r:
            t = json.loads(r.read())
        print(f'  {time.strftime("%H:%M:%S")} task {t["status"]}', flush=True)
        if t['status'] == 'ready': return t['payload']
        if t['status'] in ('failed', 'expired'): raise RuntimeError(f'task {t["status"]}: {t.get("error")}')
        time.sleep(15)
    raise RuntimeError('task not ready in time')


def finish(a, payload, applied_before):
    key = open(a.key_file).read().strip()
    head = int(rpc(a.rpc, 'eth_blockNumber', []), 16)
    if head > payload['valid_until_block']:
        sys.exit(f'rendered payload expired (valid until {payload["valid_until_block"]}, head {head}); re-run round')
    rc = send_tx(a.rpc, key, payload['to'], payload['data'], int(payload['estimated_gas'] * 1.5) + 100_000)
    print('verifyAndUpdate', rc['transactionHash'], 'status', rc['status'], 'block', int(rc['blockNumber'], 16), 'gasUsed', int(rc['gasUsed'], 16), flush=True)
    assert rc['status'] == '0x1', 'settlement reverted'
    n = call(a.rpc, a.policy, 'decidedThrough()', out_types=['uint256'])[0] - applied_before
    rc2 = send_tx(a.rpc, key, a.pool, '0x' + (sel('applyUpTo(uint64)') + encode(['uint64'], [n])).hex(), 400_000 * max(1, n) + 100_000)
    print('applyUpTo', rc2['transactionHash'], 'status', rc2['status'], 'logs', len(rc2['logs']), flush=True)
    cmd_verify(a)


def cmd_resume(a):
    """Broadcast an already-rendered task (after a keeper crash between ready and send)."""
    req = urllib.request.Request(a.router.rstrip('/') + f'/tasks/{a.task_id}', headers=dict(UA, Authorization='Bearer ' + a.api_key))
    with urllib.request.urlopen(req, timeout=60) as r:
        t = json.loads(r.read())
    if t['status'] != 'ready': sys.exit(f'task {a.task_id} is {t["status"]}')
    applied, tail, decided = pending(a.rpc, a.pool, a.policy)
    finish(a, t['payload'], applied)


def cmd_round(a):
    key = open(a.key_file).read().strip()
    prev, word = last_state(a.rpc, a.policy)
    if storage(a.rpc, a.policy, FLY_SLOT) != word:
        sys.exit('FLY_SLOT does not match the last FlySettled word: a round is in flight')
    applied, tail, decided = pending(a.rpc, a.pool, a.policy)
    if tail <= decided:
        print('nothing to decide'); return
    print(f'round: prev epoch {prev[1]} decidedThrough {decided} tail {tail} → deciding {decided + 1}..{min(tail, decided + a.max_batch)}')
    task_id = submit(a, prev)
    payload = poll_ready(a, task_id)
    finish(a, payload, applied)


def cmd_verify(a):
    settled = logs(a.rpc, a.policy, SETTLED_SIG, [STATE]); decided = logs(a.rpc, a.policy, DECIDED_SIG, [OBS, READOUT])
    prev_word = b'\0' * 32
    for k, lg in enumerate(settled):
        nxt = lg['data'][0]
        assert nxt[0] == prev_word, f'settle {k}: prevWord chain broken'
        assert pack(nxt) == bytes.fromhex(lg['topics'][2][2:]), f'settle {k}: pack(next) != flyWord'
        prev_word = pack(nxt)
        print(f'settle #{k + 1} tx {lg["tx"][:12]}… epoch {nxt[1]} decidedThrough {nxt[2]} flags {nxt[3]} rates {list(nxt[4])}')
    assert storage(a.rpc, a.policy, FLY_SLOT) == prev_word, 'FLY_SLOT != last word'
    for lg in decided:
        id_ = int(lg['topics'][1], 16); fw = bytes.fromhex(lg['topics'][2][2:]); o, r = lg['data']
        assert storage(a.rpc, a.policy, fill_slot(id_)) == fw, f'fills[{id_}] != log word'
        w = int.from_bytes(fw, 'big')
        st = call(a.rpc, a.pool, 'intents(uint64)', ['uint64'], [id_], ['address', 'bool', 'uint8', 'uint32', 'uint128', 'uint128'])
        fl = call(a.rpc, a.pool, 'fills(uint64)', ['uint64'], [id_], ['uint128', 'uint16', 'uint32'])
        print(f'intent #{id_}: {"BUY" if o[1] else "SELL"} size {o[2]} bps slip {o[3]} bps queue {o[4]} → fee {w >> 240} skew {int.from_bytes(((w >> 224) & 0xffff).to_bytes(2, "big"), "big", signed=True)} '
              f'epoch {(w >> 192) & 0xffffff} spikes {r[3]} | status {["PENDING", "FILLED", "REFUNDED"][st[2]]} paid {fl[1]} bps out {fl[0] / 1e18:.6f}')
    print(f'OK: {len(settled)} rounds, {len(decided)} intents decided; chain + fills + slot consistent')


def cmd_watch(a):
    while True:
        try:
            applied, tail, decided = pending(a.rpc, a.pool, a.policy)
            if tail > decided: cmd_round(a)
            elif decided > applied:
                key = open(a.key_file).read().strip()
                rc = send_tx(a.rpc, key, a.pool, '0x' + (sel('applyUpTo(uint64)') + encode(['uint64'], [decided - applied])).hex(), 400_000 * (decided - applied) + 100_000)
                print('applyUpTo', rc['transactionHash'], rc['status'])
            else:
                print(f'{time.strftime("%H:%M:%S")} idle: tail {tail} decided {decided} applied {applied}', flush=True)
        except Exception as e:
            print('error:', e, flush=True)
        time.sleep(a.interval)


def main():
    ap = argparse.ArgumentParser(description=__doc__); sub = ap.add_subparsers(dest='cmd', required=True)
    def common(s, pool=False, rt=False):
        s.add_argument('--rpc', required=True); s.add_argument('--policy', required=True)
        if pool: s.add_argument('--pool', required=True)
        if rt:
            s.add_argument('--router', required=True); s.add_argument('--api-key', required=True); s.add_argument('--key-file', required=True)
            s.add_argument('--from', dest='sender', default='0x6636A1CCBdf54485067304C1a590DE016DeaD9F0'); s.add_argument('--max-batch', type=int, default=1)
    common(sub.add_parser('state')); common(sub.add_parser('calldata')); common(sub.add_parser('should-run'), pool=True); common(sub.add_parser('verify'), pool=True)
    common(sub.add_parser('round'), pool=True, rt=True)
    rs = sub.add_parser('resume'); common(rs, pool=True, rt=True); rs.add_argument('--task-id', required=True)
    w = sub.add_parser('watch'); common(w, pool=True, rt=True); w.add_argument('--interval', type=int, default=30)
    a = ap.parse_args()
    {'state': cmd_state, 'calldata': cmd_calldata, 'should-run': cmd_should_run, 'verify': cmd_verify, 'round': cmd_round, 'resume': cmd_resume, 'watch': cmd_watch}[a.cmd](a)


if __name__ == '__main__':
    main()
