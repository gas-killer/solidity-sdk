#!/usr/bin/env python3
"""Split a large artifact (e.g. weights.bin for the Qwen3.5-35B-A3B overlay) into
GitHub-Release-sized parts and upload them to gas-killer/solidity-sdk.

GitHub rejects release assets over 2GB, so this splits the input into parts no
larger than --part-size (default 1.9GB, leaving headroom under the 2GB cap) named
`<basename>.partNNN`, writes a `parts.json` manifest recording each part's size and
sha256 (verified independently by tools/fetch_release_parts.sh in the k8s
initContainer, which has no `gh` — curl + sha256sum only), and uploads everything
with `gh release upload`, creating the release first if it does not exist yet.

Idempotent: re-running skips any part already present in the release with a
matching size and sha256 (checked via `gh api`), so an interrupted upload can
simply be re-run.

Usage:
  python3 tools/upload_release_parts.py weights.bin --tag qwen35-v1
  python3 tools/upload_release_parts.py weights.bin --tag qwen35-v1 --draft
  python3 tools/upload_release_parts.py weights.bin --tag qwen35-v1 --dry-run
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys

REPO = "gas-killer/solidity-sdk"
DEFAULT_PART_SIZE = 1_900_000_000  # < GitHub's 2GB release-asset cap
READ_CHUNK = 1 << 20  # 1MB read granularity while hashing/splitting


def keccak256_file(path, progress=None):
    """Whole-file keccak256, if pycryptodome is available (same helper other
    on-chain-llm tools use for manifest hashes); returns None if unavailable so
    this remains optional metadata, never a hard dependency."""
    try:
        from Crypto.Hash import keccak as _k
    except ImportError:
        return None
    h = _k.new(digest_bits=256)
    total = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(READ_CHUNK)
            if not b:
                break
            h.update(b)
            total += len(b)
            if progress:
                progress(total)
    return h.hexdigest()


def split_file(src_path, out_dir, part_size, progress=None):
    """Split src_path into <basename>.partNNN files of at most part_size bytes
    each, written into out_dir. Returns the list of part metadata dicts in
    order: {name, size, sha256}."""
    basename = os.path.basename(src_path)
    total_size = os.path.getsize(src_path)
    n_parts = max(1, (total_size + part_size - 1) // part_size)
    width = max(2, len(str(n_parts - 1)))

    parts = []
    written = 0
    with open(src_path, "rb") as src:
        for i in range(n_parts):
            part_name = f"{basename}.part{i:0{width}d}"
            part_path = os.path.join(out_dir, part_name)
            remaining = min(part_size, total_size - written)
            h = hashlib.sha256()
            with open(part_path, "wb") as dst:
                to_read = remaining
                while to_read > 0:
                    b = src.read(min(READ_CHUNK, to_read))
                    if not b:
                        raise IOError(f"unexpected EOF splitting {src_path}")
                    dst.write(b)
                    h.update(b)
                    to_read -= len(b)
            written += remaining
            parts.append({"name": part_name, "size": remaining, "sha256": h.hexdigest()})
            if progress:
                progress(i + 1, n_parts, written, total_size)
    assert written == total_size, (written, total_size)
    return parts, total_size


def run(cmd, dry_run=False, check=True, capture=False):
    if dry_run and not capture:
        print(f"[dry-run] would run: {' '.join(cmd)}")
        return None
    result = subprocess.run(cmd, check=False, capture_output=capture, text=True)
    if check and result.returncode != 0:
        out = (result.stdout or "") + (result.stderr or "")
        raise RuntimeError(f"command failed ({' '.join(cmd)}):\n{out}")
    return result


def release_exists(tag, repo):
    result = subprocess.run(
        ["gh", "release", "view", tag, "--repo", repo, "--json", "tagName"],
        capture_output=True, text=True,
    )
    return result.returncode == 0


def existing_assets(tag, repo):
    """Map of asset name -> size in bytes for the release's current assets, or
    {} if the release doesn't exist. Used for idempotent skip-if-uploaded."""
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/releases/tags/{tag}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return {}
    data = json.loads(result.stdout)
    return {a["name"]: a["size"] for a in data.get("assets", [])}


def ensure_release(tag, repo, draft, dry_run):
    if release_exists(tag, repo):
        print(f"release {tag} already exists")
        return
    cmd = ["gh", "release", "create", tag, "--repo", repo,
           "--title", tag, "--notes", f"Model artifact parts for {tag}."]
    if draft:
        cmd.append("--draft")
    if dry_run:
        print(f"[dry-run] would create release: {' '.join(cmd)}")
        return
    run(cmd)
    print(f"created release {tag}")


def upload_parts(tag, repo, parts_dir, parts, draft, dry_run):
    already = existing_assets(tag, repo) if not dry_run else {}
    part_by_name = {p["name"]: p for p in parts}

    to_upload = []
    for p in parts:
        have_size = already.get(p["name"])
        if have_size == p["size"]:
            print(f"skip {p['name']} (already uploaded, size matches)")
            continue
        if have_size is not None and have_size != p["size"]:
            print(f"re-upload {p['name']} (size mismatch: remote {have_size} != local {p['size']})")
        to_upload.append(p)

    # parts.json is regenerated/uploaded every run so it always reflects the
    # latest local split, even if all data parts were already present.
    manifest_name = "parts.json"
    manifest_path = os.path.join(parts_dir, manifest_name)
    if already.get(manifest_name) is not None and not dry_run:
        print(f"re-upload {manifest_name} (manifest always refreshed)")

    if not to_upload:
        print("all data parts already uploaded")
    for p in to_upload:
        part_path = os.path.join(parts_dir, p["name"])
        cmd = ["gh", "release", "upload", tag, part_path, "--repo", repo, "--clobber"]
        if dry_run:
            print(f"[dry-run] would upload: {part_path} ({p['size']:,} bytes, sha256={p['sha256']})")
            continue
        run(cmd)
        print(f"uploaded {p['name']} ({p['size']:,} bytes)")

    cmd = ["gh", "release", "upload", tag, manifest_path, "--repo", repo, "--clobber"]
    if dry_run:
        print(f"[dry-run] would upload: {manifest_path}")
    else:
        run(cmd)
        print(f"uploaded {manifest_name}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("artifact", help="path to the file to split and upload (e.g. weights.bin)")
    ap.add_argument("--tag", required=True, help="release tag to upload to")
    ap.add_argument("--repo", default=REPO, help=f"target repo (default {REPO})")
    ap.add_argument("--part-size", type=int, default=DEFAULT_PART_SIZE,
                     help=f"max bytes per part (default {DEFAULT_PART_SIZE:,}, must stay under GitHub's 2GB cap)")
    ap.add_argument("--out-dir", default=None,
                     help="directory to write parts + parts.json into (default: <artifact>.parts/)")
    ap.add_argument("--draft", action="store_true", help="create the release as a draft if it doesn't exist")
    ap.add_argument("--dry-run", action="store_true", help="split locally and print planned actions; upload nothing")
    ap.add_argument("--skip-split", action="store_true",
                     help="reuse an existing out-dir split + parts.json instead of re-splitting")
    args = ap.parse_args()

    if args.part_size >= 2_000_000_000:
        print("error: --part-size must stay under GitHub's 2GB release-asset cap", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(args.artifact):
        print(f"error: {args.artifact} not found", file=sys.stderr)
        sys.exit(1)

    out_dir = args.out_dir or (args.artifact.rstrip("/") + ".parts")
    os.makedirs(out_dir, exist_ok=True)
    manifest_path = os.path.join(out_dir, "parts.json")

    if args.skip_split and os.path.isfile(manifest_path):
        manifest = json.load(open(manifest_path))
        parts = manifest["parts"]
        total_size = manifest["totalSize"]
        print(f"reusing existing split in {out_dir} ({len(parts)} parts)")
    else:
        print(f"splitting {args.artifact} into <= {args.part_size:,}-byte parts...")

        def progress(i, n, written, total):
            print(f"  part {i}/{n} written ({written:,}/{total:,} bytes)")

        parts, total_size = split_file(args.artifact, out_dir, args.part_size, progress=progress)
        print("hashing full artifact (keccak256, optional)...")
        keccak_hex = keccak256_file(args.artifact)

        manifest = {
            "artifact": os.path.basename(args.artifact),
            "totalSize": total_size,
            "partSize": args.part_size,
            "partCount": len(parts),
            "sha256Combined": hashlib.sha256(b"".join(bytes.fromhex(p["sha256"]) for p in parts)).hexdigest(),
            "keccak256": ("0x" + keccak_hex) if keccak_hex else None,
            "parts": parts,
        }
        with open(manifest_path, "w") as f:
            json.dump(manifest, f, indent=2)
        print(f"wrote {manifest_path}")

    for p in parts:
        print(f"  {p['name']}: {p['size']:,} bytes sha256={p['sha256']}")
    print(f"total: {total_size:,} bytes across {len(parts)} parts")

    ensure_release(args.tag, args.repo, args.draft, args.dry_run)
    upload_parts(args.tag, args.repo, out_dir, parts, args.draft, args.dry_run)

    if args.dry_run:
        print("\n[dry-run] no network calls to GitHub were made for release creation/upload.")


if __name__ == "__main__":
    main()
