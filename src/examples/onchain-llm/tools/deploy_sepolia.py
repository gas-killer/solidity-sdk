#!/usr/bin/env python3
"""Deploy the Qwen3 on-chain artifact set to a real network as CREATE transactions.

Real-transaction counterpart of deploy_anvil.py: splits weights.bin + tokenizer.bin
into DataContractLib chunks (payload <= 24,575 bytes, runtime = 0x00 || payload),
deploys each as a bare CREATE from the sender EOA, then builds the two-level
directory (pages of 20-byte chunk addresses in global order, then the root page
list) exactly as Qwen3Engine._resolve expects.

Crash-safe by construction:
  * append-only JSONL ledger, one record per state change; latest record per key wins
  * records are written BEFORE broadcasting, so every possibly-landed tx is known
  * on restart, mined-nonce records settle from receipts or the derived CREATE
    address (keccak(rlp(sender, nonce))) + codehash comparison; free-nonce records
    are re-adopted in place (same key, same nonce, bumped fee) so a lingering
    mempool tx can never race a different payload on its own nonce
  * chunks are freestanding; pages/root are only deployed after all chunks confirm

Fee-adaptive: pauses sending when base fee exceeds --pause-gwei, resumes below
--resume-gwei, replaces stuck txs with properly out-priced bumps, and hard-stops
if the sender balance drops under --reserve-eth.
"""

import argparse
import json
import os
import time
import urllib.request

from eth_account import Account
from eth_utils import keccak
import rlp

CHUNK = 24_575                     # DataContractLib.MAX_PAYLOAD
PRELUDE = bytes.fromhex("80600C6000396000F3")
CODE_DEPOSIT_GAS = 200
PAGE_CAP_DEFAULT = 1_228           # 1228*20 = 24,560 <= 24,575
STUCK_BLOCKS = 8
MAX_BUMPS = 8


# ---------------------------------------------------------------- RPC plumbing

class RpcError(Exception):
    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


class Rpc:
    def __init__(self, urls):
        self.urls = urls
        self.i = 0
        self.req_id = 0

    def _post(self, body):
        url = self.urls[self.i % len(self.urls)]
        req = urllib.request.Request(
            url, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "User-Agent": "curl/8.4.0"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)

    def call(self, method, params, tries=12):
        last = None
        for attempt in range(tries):
            self.req_id += 1
            try:
                out = self._post({"jsonrpc": "2.0", "id": self.req_id,
                                  "method": method, "params": params})
                if "error" in out:
                    raise RpcError(out["error"].get("message", str(out["error"])),
                                   out["error"].get("code"))
                return out["result"]
            except RpcError:
                raise
            except Exception as e:  # transport error: rotate + retry
                last = e
                self.i += 1
                time.sleep(min(2 ** attempt, 45))
        raise RuntimeError(f"rpc {method} failed on all endpoints: {last}")

    def batch(self, calls, tries=4):
        """calls: list of (method, params). Returns results in order (None on error)."""
        if not calls:
            return []
        for attempt in range(tries):
            base = self.req_id + 1
            self.req_id += len(calls)
            body = [{"jsonrpc": "2.0", "id": base + j, "method": m, "params": p}
                    for j, (m, p) in enumerate(calls)]
            try:
                out = self._post(body)
                if isinstance(out, dict):
                    raise RuntimeError("no batch support")
                by_id = {o["id"]: o for o in out}
                return [None if (o := by_id.get(base + j)) is None or "error" in o
                        else o["result"] for j in range(len(calls))]
            except Exception:
                self.i += 1
                time.sleep(min(2 ** attempt, 10))
        res = []
        for m, p in calls:
            try:
                res.append(self.call(m, p))
            except Exception:
                res.append(None)
        return res


def to_int(h):
    return int(h, 16)


# ------------------------------------------------------------------- planning

def initcode_for(payload: bytes) -> bytes:
    assert 0 < len(payload) <= CHUNK
    runtime_len = len(payload) + 1
    return b"\x61" + runtime_len.to_bytes(2, "big") + PRELUDE + b"\x00" + payload


def expected_codehash(payload: bytes) -> str:
    return "0x" + keccak(b"\x00" + payload).hex()


def create_address(sender: str, nonce: int) -> str:
    raw = rlp.encode([bytes.fromhex(sender[2:]), nonce])
    return "0x" + keccak(raw)[12:].hex()


def gas_limit_for(initcode: bytes) -> int:
    nz = sum(1 for b in initcode if b)
    z = len(initcode) - nz
    calldata = 16 * nz + 4 * z
    words = (len(initcode) + 31) // 32
    runtime_len = len(initcode) - 12
    return 21_000 + calldata + 2 * words + CODE_DEPOSIT_GAS * runtime_len + 60_000


class Plan:
    """Chunk table over the two blobs. Keys: c0..c<N-1>, then p0.., then root."""

    def __init__(self, weights_path, tok_path):
        self.weights = open(weights_path, "rb")
        self.tok = open(tok_path, "rb")
        self.w_len = os.path.getsize(weights_path)
        self.t_len = os.path.getsize(tok_path)
        self.n_w = (self.w_len + CHUNK - 1) // CHUNK
        self.n_t = (self.t_len + CHUNK - 1) // CHUNK
        self.n_chunks = self.n_w + self.n_t

    def payload(self, i: int) -> bytes:
        if i < self.n_w:
            f, base, total = self.weights, i * CHUNK, self.w_len
        else:
            f, base, total = self.tok, (i - self.n_w) * CHUNK, self.t_len
        f.seek(base)
        return f.read(min(CHUNK, total - base))


# --------------------------------------------------------------------- ledger

class Ledger:
    def __init__(self, path):
        self.path = path
        self.state = {}          # key -> latest record
        if os.path.exists(path):
            with open(path) as fh:
                for line in fh:
                    line = line.strip()
                    if line:
                        rec = json.loads(line)
                        self.state[rec["k"]] = rec
        self.fh = open(path, "a")

    def put(self, rec):
        self.state[rec["k"]] = rec
        self.fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
        self.fh.flush()
        os.fsync(self.fh.fileno())

    def get(self, key):
        return self.state.get(key)

    def n_confirmed(self):
        return sum(1 for r in self.state.values() if r.get("st") == "conf")


# ------------------------------------------------------------------- deployer

class Deployer:
    def __init__(self, args):
        self.args = args
        self.rpc = Rpc([u.strip() for u in args.rpc.split(",") if u.strip()])
        key = open(args.key_file).read().strip()
        self.acct = Account.from_key(key)
        self.sender = self.acct.address.lower()
        self.chain_id = args.chain_id
        self.plan = Plan(os.path.join(args.artifacts, "weights.bin"),
                         os.path.join(args.artifacts, "tokenizer.bin"))
        os.makedirs(args.ledger, exist_ok=True)
        self.ledger = Ledger(os.path.join(args.ledger, "ledger.jsonl"))
        self.spent_wei = sum(
            r["gasUsed"] * r["gasPrice"] for r in self.ledger.state.values()
            if r.get("st") == "conf" and r.get("gasUsed") and r.get("gasPrice"))
        self.paused = False
        self.last_send = 0.0
        self.next_nonce = None

    # ---- payloads ----

    def payload_for_key(self, key):
        if key[0] == "c":
            return self.plan.payload(int(key[1:]))
        if key[0] == "p":
            return self.page_payload(int(key[1:]))
        if key == "root":
            return self.root_payload()
        raise KeyError(key)

    def chunk_addresses(self):
        addrs = []
        for i in range(self.plan.n_chunks):
            rec = self.ledger.get(f"c{i}")
            if not rec or rec.get("st") != "conf":
                return None
            addrs.append(rec["addr"])
        return addrs

    def n_pages(self):
        return (self.plan.n_chunks + self.args.page_cap - 1) // self.args.page_cap

    def page_payload(self, p):
        addrs = self.chunk_addresses()
        assert addrs is not None, "pages require all chunks confirmed"
        lo = p * self.args.page_cap
        hi = min(lo + self.args.page_cap, len(addrs))
        return b"".join(bytes.fromhex(a[2:]) for a in addrs[lo:hi])

    def root_payload(self):
        out = b""
        for p in range(self.n_pages()):
            rec = self.ledger.get(f"p{p}")
            assert rec and rec.get("st") == "conf", "root requires all pages confirmed"
            out += bytes.fromhex(rec["addr"][2:])
        return out

    # ---- chain state ----

    def base_fee_gwei(self):
        blk = self.rpc.call("eth_getBlockByNumber", ["latest", False])
        return to_int(blk["baseFeePerGas"]) / 1e9, to_int(blk["number"])

    def balance_eth(self):
        return to_int(self.rpc.call("eth_getBalance", [self.sender, "latest"])) / 1e18

    def chain_nonce(self):
        return to_int(self.rpc.call("eth_getTransactionCount", [self.sender, "latest"]))

    def codehash_at(self, addr):
        try:
            return self.rpc.call("eth_getProof", [addr, [], "latest"])["codeHash"]
        except Exception:
            code = self.rpc.call("eth_getCode", [addr, "latest"])
            return "0x" + keccak(bytes.fromhex(code[2:])).hex()

    def find_receipt(self, rec):
        for tx in rec.get("txs", []):
            rcpt = self.rpc.call("eth_getTransactionReceipt", [tx])
            if rcpt is not None:
                return rcpt
        return None

    # ---- recovery ----

    def settle_mined(self):
        """Settle 'sent' records whose nonce has been consumed on-chain.

        Records whose nonce is still free stay 'sent' and are re-adopted by
        deploy_items (same key, same nonce), so a lingering mempool tx can only
        ever race an identical payload.
        """
        pending = [(k, r) for k, r in self.ledger.state.items() if r.get("st") == "sent"]
        if not pending:
            return
        chain_nonce = self.chain_nonce()
        print(f"[recover] {len(pending)} unresolved records, chain nonce {chain_nonce}", flush=True)
        for key, rec in sorted(pending, key=lambda kr: kr[1]["nonce"]):
            if rec["nonce"] >= chain_nonce:
                continue                      # still free -> re-adopt later
            rcpt = self.find_receipt(rec)
            if rcpt is not None:
                if rcpt["status"] != "0x1":
                    raise SystemExit(f"FATAL: CREATE reverted for {key} ({rec['txs']})")
                self.confirm(key, rec, rcpt)
                continue
            addr = create_address(self.sender, rec["nonce"])
            if self.codehash_at(addr) == expected_codehash(self.payload_for_key(key)):
                self.ledger.put({"k": key, "st": "conf", "nonce": rec["nonce"],
                                 "addr": addr, "gasUsed": None, "gasPrice": None})
                print(f"[recover] {key} confirmed via derived address {addr}", flush=True)
            else:
                print(f"[recover] {key} nonce {rec['nonce']} consumed by foreign tx; will redeploy", flush=True)
                self.ledger.put({"k": key, "st": "dead", "nonce": rec["nonce"]})

    def confirm(self, key, rec, rcpt):
        gas_used = to_int(rcpt["gasUsed"])
        price = to_int(rcpt.get("effectiveGasPrice", "0x0"))
        self.spent_wei += gas_used * price
        self.ledger.put({"k": key, "st": "conf", "nonce": rec["nonce"],
                         "addr": rcpt["contractAddress"], "gasUsed": gas_used,
                         "gasPrice": price, "blk": to_int(rcpt["blockNumber"])})

    # ---- fee governor ----

    def fee_gate(self):
        """Returns (base_fee_gwei, head). head is fresh so callers never stamp
        sent_block from a pre-pause block number (which reads as instantly stuck)."""
        while True:
            bf, head = self.base_fee_gwei()
            if self.paused:
                if bf <= self.args.resume_gwei:
                    self.paused = False
                    print(f"[fees] base fee {bf:.3f} gwei — resuming", flush=True)
                    return bf, head
                time.sleep(24)
            elif bf >= self.args.pause_gwei:
                self.paused = True
                print(f"[fees] base fee {bf:.3f} gwei >= {self.args.pause_gwei} — pausing", flush=True)
                time.sleep(24)
            else:
                return bf, head

    # ---- sending ----

    def sign_and_send(self, key, nonce, base_fee_gwei, prev_rec=None):
        payload = self.payload_for_key(key)
        init = initcode_for(payload)
        tip = self.args.tip_gwei
        max_fee = max(2 * base_fee_gwei, base_fee_gwei + 0.5) + tip
        if prev_rec is not None:  # replacement: outprice the previous variant >=+15%
            tip = max(tip, prev_rec.get("tipGwei", tip) * 1.15)
            max_fee = max(max_fee, prev_rec.get("maxFeeGwei", 0) * 1.15)
        max_fee = min(max_fee, self.args.max_fee_gwei)
        tip = min(tip, max_fee)
        tx = {
            "chainId": self.chain_id,
            "nonce": nonce,
            "gas": gas_limit_for(init),
            "maxPriorityFeePerGas": int(tip * 1e9),
            "maxFeePerGas": int(max_fee * 1e9),
            "value": 0,
            "data": "0x" + init.hex(),
        }
        signed = self.acct.sign_transaction(tx)
        tx_hash = "0x" + keccak(signed.raw_transaction).hex()
        txs = (prev_rec.get("txs", []) if prev_rec else []) + [tx_hash]
        # record BEFORE broadcast so a crash can never lose a possibly-landed tx
        self.ledger.put({"k": key, "st": "sent", "nonce": nonce, "txs": txs,
                         "maxFeeGwei": max_fee, "tipGwei": tip})
        try:
            self.rpc.call("eth_sendRawTransaction", ["0x" + signed.raw_transaction.hex()])
        except RpcError as e:
            msg = str(e).lower()
            if ("nonce too low" in msg or "already known" in msg
                    or "underpriced" in msg or "already imported" in msg):
                pass  # settles via receipts / derived address
            else:
                raise

    def deploy_items(self, keys, label):
        recs = {k: self.ledger.get(k) for k in keys}
        todo = [k for k in keys if not recs[k] or recs[k].get("st") != "conf"]
        if not todo:
            return
        chain_nonce = self.chain_nonce()
        adopted = {k: recs[k] for k in todo
                   if recs[k] and recs[k].get("st") == "sent"}
        queue = [k for k in todo if k not in adopted]
        # Floor the nonce by every nonce this ledger has ever claimed, not just
        # the node's view: a lagging RPC would otherwise hand out nonces we
        # already used, and every such collision is silently swallowed.
        start_nonce = max([chain_nonce]
                          + [r["nonce"] + 1 for r in self.ledger.state.values()
                             if r.get("st") in ("sent", "conf") and r.get("nonce") is not None])
        if self.next_nonce is None or self.next_nonce < start_nonce:
            self.next_nonce = start_nonce
        bf, head = self.base_fee_gwei()
        # re-adopted records look "stuck" immediately -> rebroadcast with a bump.
        # bumps restarts at 0: the per-process budget must not be consumed by
        # hashes accumulated across earlier restarts, or a key can never recover.
        inflight = {k: {"nonce": r["nonce"], "sent_block": head - STUCK_BLOCKS,
                        "bumps": 0}
                    for k, r in adopted.items()}
        print(f"[{label}] {len(todo)} of {len(keys)} to deploy "
              f"({len(adopted)} re-adopted), nonce from {self.next_nonce}", flush=True)
        send_interval = 12.0 / self.args.chunks_per_block
        done = len(keys) - len(todo)
        qi = 0
        last_report = 0.0
        while qi < len(queue) or inflight:
            while qi < len(queue) and len(inflight) < self.args.max_inflight:
                bf, head = self.fee_gate()
                wait = self.last_send + send_interval - time.time()
                if wait > 0:
                    time.sleep(wait)
                key = queue[qi]
                nonce = self.next_nonce
                self.sign_and_send(key, nonce, bf)
                inflight[key] = {"nonce": nonce, "sent_block": head, "bumps": 0}
                self.next_nonce += 1
                self.last_send = time.time()
                qi += 1
            time.sleep(3 if self.chain_id == 11155111 else 0.05)
            # poll receipts: every candidate hash of every inflight key
            ordered = list(inflight.items())
            flat, spans = [], []
            for key, _ in ordered:
                txs = self.ledger.get(key).get("txs", [])
                spans.append((len(flat), len(txs)))
                flat.extend(("eth_getTransactionReceipt", [tx]) for tx in txs)
            results = self.rpc.batch(flat)
            bf, head = self.base_fee_gwei()
            fresh_nonce = None
            for (key, info), (lo, n) in zip(ordered, spans):
                rcpt = next((r for r in results[lo:lo + n] if r is not None), None)
                rec = self.ledger.get(key)
                if rcpt is not None:
                    if rcpt["status"] != "0x1":
                        raise SystemExit(f"FATAL: CREATE reverted for {key}")
                    self.confirm(key, rec, rcpt)
                    del inflight[key]
                    done += 1
                    continue
                if head - info["sent_block"] < STUCK_BLOCKS:
                    continue
                if fresh_nonce is None:
                    fresh_nonce = self.chain_nonce()
                if info["nonce"] < fresh_nonce:
                    # nonce consumed but none of our hashes has a receipt
                    addr = create_address(self.sender, info["nonce"])
                    if self.codehash_at(addr) == expected_codehash(self.payload_for_key(key)):
                        self.ledger.put({"k": key, "st": "conf", "nonce": info["nonce"],
                                         "addr": addr, "gasUsed": None, "gasPrice": None})
                        del inflight[key]
                        done += 1
                    else:
                        print(f"[{label}] {key} nonce {info['nonce']} taken by foreign tx; reassigning", flush=True)
                        self.ledger.put({"k": key, "st": "dead", "nonce": info["nonce"]})
                        nonce = self.next_nonce
                        self.next_nonce += 1
                        self.sign_and_send(key, nonce, bf)
                        inflight[key] = {"nonce": nonce, "sent_block": head, "bumps": 0}
                elif info["bumps"] < MAX_BUMPS:
                    info["bumps"] += 1
                    self.sign_and_send(key, info["nonce"], bf, prev_rec=rec)
                    info["sent_block"] = head
                    print(f"[{label}] rebumped {key} (bump {info['bumps']})", flush=True)
                else:
                    # Bump budget exhausted on a nonce the chain still hasn't
                    # consumed. Without this branch the key stays inflight
                    # forever and the loop spins silently -- exit so the wrapper
                    # restarts with a fresh bump budget and a re-adopted record.
                    raise SystemExit(
                        f"STALLED: {key} (nonce {info['nonce']}) unmined after "
                        f"{MAX_BUMPS} bumps; exiting for wrapper restart")
            if time.time() - last_report > 60:
                last_report = time.time()
                bal = self.balance_eth()
                gas_conf = sum(r.get("gasUsed") or 0 for r in self.ledger.state.values()
                               if r.get("st") == "conf")
                avg = (self.spent_wei / 1e9 / gas_conf) if gas_conf else 0.0
                n_left = self.plan.n_chunks - self.ledger.n_confirmed()
                usable = bal - self.args.reserve_eth
                proj = n_left * 5_364_000 * max(avg, bf + self.args.tip_gwei) / 1e9
                flag = "" if proj <= usable else "  ** OVER BUDGET **"
                print(f"[{label}] {done}/{len(keys)} conf | inflight {len(inflight)} | "
                      f"spent {self.spent_wei/1e18:.3f} ETH | avg {avg:.3f} gwei | "
                      f"bal {bal:.3f} ETH | basefee {bf:.3f} | "
                      f"proj {proj:.0f}/{usable:.0f} ETH{flag}", flush=True)
                if bal < self.args.reserve_eth:
                    raise SystemExit(f"HALT: balance {bal:.4f} < reserve {self.args.reserve_eth}")
        print(f"[{label}] complete: {len(keys)} confirmed", flush=True)

    # ---- verification ----

    def verify_all(self):
        keys = ([f"c{i}" for i in range(self.plan.n_chunks)]
                + [f"p{p}" for p in range(self.n_pages())] + ["root"])
        print(f"[verify] checking codehashes of {len(keys)} contracts", flush=True)
        bad = 0
        B = 10
        for lo in range(0, len(keys), B):
            group = keys[lo:lo + B]
            calls = [("eth_getProof", [self.ledger.get(k)["addr"], [], "latest"])
                     for k in group]
            results = self.rpc.batch(calls)
            for k, res in zip(group, results):
                addr = self.ledger.get(k)["addr"]
                want = expected_codehash(self.payload_for_key(k))
                got = res["codeHash"] if res else self.codehash_at(addr)
                if got != want:
                    bad += 1
                    print(f"[verify] MISMATCH {k} at {addr}: want {want} got {got}", flush=True)
            if lo and lo % 2000 < B:
                print(f"[verify] {lo}/{len(keys)}", flush=True)
        if bad:
            raise SystemExit(f"FATAL: {bad} codehash mismatches")
        print(f"[verify] all {len(keys)} contracts match expected codehashes", flush=True)

    # ---- main ----

    def run(self):
        n_full = (self.plan.n_w - 1) + (self.plan.n_t - 1)
        est_gas = n_full * 5_364_000 + 6_000_000 + self.n_pages() * 5_400_000
        print(f"[plan] sender {self.sender} | chunks {self.plan.n_chunks} "
              f"(w {self.plan.n_w} + t {self.plan.n_t}) | pages {self.n_pages()} | "
              f"est gas {est_gas/1e9:.2f}B", flush=True)
        print(f"[plan] weights {self.plan.w_len} B, tokenizer {self.plan.t_len} B", flush=True)
        if self.args.dry_run:
            return
        print(f"[plan] balance {self.balance_eth():.4f} ETH | "
              f"ledger: {self.ledger.n_confirmed()} confirmed", flush=True)
        self.settle_mined()
        limit = self.args.limit or self.plan.n_chunks
        self.deploy_items([f"c{i}" for i in range(min(limit, self.plan.n_chunks))], "chunks")
        if limit < self.plan.n_chunks:
            print("[plan] --limit reached; skipping directory/verify", flush=True)
            return
        self.deploy_items([f"p{p}" for p in range(self.n_pages())], "pages")
        self.deploy_items(["root"], "root")
        self.verify_all()
        root = self.ledger.get("root")["addr"]
        print(f"[done] DIRECTORY ROOT = {root}", flush=True)
        print(f"[done] total spent {self.spent_wei/1e18:.4f} ETH | "
              f"balance {self.balance_eth():.4f} ETH", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--key-file", required=True)
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--rpc", default="https://ethereum-sepolia-rpc.publicnode.com,https://sepolia.drpc.org,https://1rpc.io/sepolia")
    ap.add_argument("--chain-id", type=int, default=11155111)
    ap.add_argument("--page-cap", type=int, default=PAGE_CAP_DEFAULT)
    ap.add_argument("--pause-gwei", type=float, default=1.6)
    ap.add_argument("--resume-gwei", type=float, default=1.25)
    ap.add_argument("--max-fee-gwei", type=float, default=3.0)
    ap.add_argument("--tip-gwei", type=float, default=0.05)
    ap.add_argument("--chunks-per-block", type=float, default=4.0)
    ap.add_argument("--max-inflight", type=int, default=8)
    ap.add_argument("--reserve-eth", type=float, default=2.0)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    Deployer(args).run()


if __name__ == "__main__":
    main()
