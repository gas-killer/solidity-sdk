#!/usr/bin/env python3
"""Mirror a live on-chain Qwen3 directory onto a local anvil at the REAL addresses.

Why: an eth_call that walks 24,385 contracts and burns hundreds of Ggas cannot be
served by a public RPC (rpc.gascap), and an anvil fork fetching 597 MB lazily over
a public RPC never converges. So we rebuild the exact chain state locally:

  * root + pages  : bytes fetched LIVE from the network via eth_getCode and etched
                    verbatim at their real addresses (the directory IS the chain's);
  * chunks        : local blobs etched at the ledger's real CREATE addresses. Their
                    identity with the chain is established by eth_getProof codeHash
                    (deploy_sepolia.py verify_all, all 24,385) and re-spot-checked
                    here with live eth_getCode on a random sample.

Every page fetched from the chain is also checked against the ledger's chunk
addresses, and the root against the page addresses, so a wrong ledger cannot
silently produce a self-consistent-but-fake directory.

Usage:
  mirror_directory_anvil.py --artifacts <dir> --ledger <dir> \
      --rpc https://ethereum-sepolia-rpc.publicnode.com --anvil http://127.0.0.1:8630 \
      [--sample 48] [--blobs weights.bin,tokenizer.bin]
"""
import argparse
import json
import os
import random
import sys
import time
import urllib.request

CHUNK = 24_575
PAGE_CAP = 1_228


def rpc_batch(url, calls, retries=5):
    payload = json.dumps(
        [{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in enumerate(calls)]
    ).encode()
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, payload, {"Content-Type": "application/json", "User-Agent": "curl/8.4.0"})
            with urllib.request.urlopen(req, timeout=120) as r:
                out = json.loads(r.read())
            if isinstance(out, dict):
                raise RuntimeError(out.get("error", out))
            for item in out:
                if "error" in item:
                    raise RuntimeError(item["error"])
            return [item["result"] for item in sorted(out, key=lambda x: x["id"])]
        except Exception as e:  # noqa: BLE001
            if attempt == retries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def load_ledger(path):
    state = {}
    with open(os.path.join(path, "ledger.jsonl")) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "k" in rec:
                state[rec["k"]] = rec
    return state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--rpc", required=True, help="live network RPC (read-only eth_getCode)")
    ap.add_argument("--anvil", required=True, help="local anvil RPC to etch into")
    ap.add_argument("--blobs", default="weights.bin,tokenizer.bin")
    ap.add_argument("--sample", type=int, default=48, help="random chunks to spot-check live")
    ap.add_argument("--batch", type=int, default=10)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    blobs = [open(os.path.join(args.artifacts, b), "rb").read() for b in args.blobs.split(",")]
    n_per = [(len(b) + CHUNK - 1) // CHUNK for b in blobs]
    starts = [sum(n_per[:i]) for i in range(len(n_per))]
    n_chunks = sum(n_per)

    def payload(i):
        k = max(j for j in range(len(starts)) if starts[j] <= i)
        off = (i - starts[k]) * CHUNK
        return blobs[k][off:off + CHUNK]

    led = load_ledger(args.ledger)
    n_pages = (n_chunks + PAGE_CAP - 1) // PAGE_CAP
    keys = [f"c{i}" for i in range(n_chunks)] + [f"p{p}" for p in range(n_pages)] + ["root"]
    missing = [k for k in keys if led.get(k, {}).get("st") != "conf"]
    if missing:
        sys.exit(f"FATAL: {len(missing)} ledger keys not confirmed, e.g. {missing[:5]}")
    addr = {k: led[k]["addr"].lower() for k in keys}
    print(f"[ledger] {n_chunks} chunks in {n_pages} pages, root {addr['root']}", flush=True)

    # ---- 1. live directory bytes -------------------------------------------------
    live = {}
    dir_keys = ["root"] + [f"p{p}" for p in range(n_pages)]
    for lo in range(0, len(dir_keys), 5):
        group = dir_keys[lo:lo + 5]
        res = rpc_batch(args.rpc, [("eth_getCode", [addr[k], "latest"]) for k in group])
        for k, code in zip(group, res):
            live[k] = bytes.fromhex(code[2:])
    exp_root = b"\x00" + b"".join(bytes.fromhex(addr[f"p{p}"][2:]) for p in range(n_pages))
    if live["root"] != exp_root:
        sys.exit(f"FATAL: live root bytes != ledger page addresses ({len(live['root'])} vs {len(exp_root)} B)")
    for p in range(n_pages):
        lo, hi = p * PAGE_CAP, min((p + 1) * PAGE_CAP, n_chunks)
        exp = b"\x00" + b"".join(bytes.fromhex(addr[f"c{i}"][2:]) for i in range(lo, hi))
        if live[f"p{p}"] != exp:
            sys.exit(f"FATAL: live page {p} != ledger chunk addresses")
    print(f"[live] root + {n_pages} pages fetched from chain; all match the ledger's addresses", flush=True)

    # ---- 2. live spot-check of chunk bytes ---------------------------------------
    rng = random.Random(args.seed)
    sample = sorted(set([0, n_chunks - 1, starts[-1] - 1, starts[-1]] + rng.sample(range(n_chunks), args.sample)))
    bad = 0
    for lo in range(0, len(sample), 4):
        group = sample[lo:lo + 4]
        res = rpc_batch(args.rpc, [("eth_getCode", [addr[f"c{i}"], "latest"]) for i in group])
        for i, code in zip(group, res):
            if bytes.fromhex(code[2:]) != b"\x00" + payload(i):
                bad += 1
                print(f"  MISMATCH live chunk c{i} at {addr[f'c{i}']}", flush=True)
    if bad:
        sys.exit(f"FATAL: {bad} live chunk mismatches")
    print(f"[live] {len(sample)} chunks fetched from chain are byte-identical to the local blobs", flush=True)

    # ---- 3. etch into anvil at the real addresses --------------------------------
    calls = [("anvil_setCode", [addr[k], "0x" + live[k].hex()]) for k in dir_keys]
    calls += [("anvil_setCode", [addr[f"c{i}"], "0x00" + payload(i).hex()]) for i in range(n_chunks)]
    done = 0
    t0 = time.time()
    for lo in range(0, len(calls), args.batch):
        rpc_batch(args.anvil, calls[lo:lo + args.batch])
        done += len(calls[lo:lo + args.batch])
        if done % 5000 < args.batch:
            print(f"  setCode {done}/{len(calls)} ({time.time() - t0:.0f}s)", flush=True)
    print(f"[anvil] etched {len(calls)} contracts in {time.time() - t0:.0f}s", flush=True)

    # ---- 4. read-back --------------------------------------------------------------
    check = ["root", "p0", f"p{n_pages - 1}", "c0", f"c{n_chunks - 1}", f"c{starts[-1]}"]
    res = rpc_batch(args.anvil, [("eth_getCode", [addr[k], "latest"]) for k in check])
    for k, code in zip(check, res):
        want = live[k] if k in live else b"\x00" + payload(int(k[1:]))
        assert bytes.fromhex(code[2:]) == want, f"anvil read-back mismatch for {k}"
    print("[anvil] read-back OK", flush=True)
    print(json.dumps({"root": addr["root"], "chunks": n_chunks, "pages": n_pages,
                      "live_sampled_chunks": len(sample)}))


if __name__ == "__main__":
    main()
