#!/bin/sh
# Fetch a split model artifact (parts.json + weights.bin.partNNN) from a public
# GitHub Release and reassemble it. Designed to run as a k8s initContainer for
# operator artifact provisioning: POSIX sh only, curl + sha256sum as the only
# external dependencies (no gh, no python, no bash-isms).
#
# Counterpart to tools/upload_release_parts.py, which produces parts.json and
# uploads the parts this script downloads.
#
# Usage:
#   fetch_release_parts.sh <base-url> <output-path>
#
#   <base-url>    the release's public asset base URL, e.g.
#                 https://github.com/gas-killer/solidity-sdk/releases/download/qwen35-v1
#                 (parts.json and each part are fetched as <base-url>/<name>)
#   <output-path> where to write the reassembled file, e.g. /artifacts/weights.bin
#
# Env overrides:
#   WORKDIR   scratch directory for downloaded parts (default: mktemp -d)
#   CURL_OPTS extra curl flags, e.g. "-H 'Authorization: token ...'"
#
# Exit non-zero on any download failure, sha256 mismatch, or final size mismatch.
set -eu

BASE_URL="${1:?usage: fetch_release_parts.sh <base-url> <output-path>}"
OUT_PATH="${2:?usage: fetch_release_parts.sh <base-url> <output-path>}"
WORKDIR="${WORKDIR:-}"
CURL_OPTS="${CURL_OPTS:-}"

if [ -z "$WORKDIR" ]; then
    WORKDIR=$(mktemp -d)
    CLEANUP_WORKDIR=1
else
    mkdir -p "$WORKDIR"
    CLEANUP_WORKDIR=0
fi

cleanup() {
    if [ "$CLEANUP_WORKDIR" = 1 ]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT INT TERM

log() {
    echo "fetch_release_parts: $*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

MANIFEST="$WORKDIR/parts.json"
log "fetching manifest: $BASE_URL/parts.json"
# shellcheck disable=SC2086
curl -fsSL $CURL_OPTS -o "$MANIFEST" "$BASE_URL/parts.json" \
    || fail "failed to download parts.json from $BASE_URL"

# ---- parse parts.json without a JSON library --------------------------------
# Manifest shape (written by upload_release_parts.py):
#   {"artifact": ..., "totalSize": N, "partSize": N, "partCount": N,
#    "sha256Combined": "...", "keccak256": "0x..."|null,
#    "parts": [{"name": "...", "size": N, "sha256": "..."}, ...]}
# Extract name/sha256 pairs (in manifest order) and the declared totalSize with
# portable sed/grep rather than assuming a JSON tool is present.

TOTAL_SIZE=$(sed -n 's/.*"totalSize": *\([0-9][0-9]*\).*/\1/p' "$MANIFEST" | head -n1)
[ -n "$TOTAL_SIZE" ] || fail "could not parse totalSize from parts.json"

PARTS_LIST="$WORKDIR/.parts_list"
# One "name sha256" pair per line, extracted in manifest order.
sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' "$MANIFEST" > "$WORKDIR/.names"
sed -n 's/.*"sha256": *"\([0-9a-fA-F]*\)".*/\1/p' "$MANIFEST" > "$WORKDIR/.hashes"
# "parts" entries interleave name then sha256 per object; the two greps above
# preserve per-line order across the whole file, and each part object has
# exactly one name and one sha256, so pairing by line number is correct as
# long as sha256Combined (also a hex string) doesn't collide with the pattern.
# sha256Combined has a different key name, so it is excluded by the sed match.
paste "$WORKDIR/.names" "$WORKDIR/.hashes" > "$PARTS_LIST"

N_PARTS=$(wc -l < "$PARTS_LIST" | tr -d ' ')
[ "$N_PARTS" -gt 0 ] || fail "no parts found in parts.json"
log "manifest declares $N_PARTS part(s), totalSize=$TOTAL_SIZE"

CONCAT="$WORKDIR/.assembled"
: > "$CONCAT"

i=0
while IFS="$(printf '\t')" read -r NAME SHA256; do
    i=$((i + 1))
    [ -n "$NAME" ] || fail "part $i has an empty name in manifest"
    [ -n "$SHA256" ] || fail "part $NAME has no sha256 in manifest"

    PART_PATH="$WORKDIR/$NAME"
    log "downloading part $i/$N_PARTS: $NAME"
    # shellcheck disable=SC2086
    curl -fsSL $CURL_OPTS -o "$PART_PATH" "$BASE_URL/$NAME" \
        || fail "failed to download $NAME from $BASE_URL"

    ACTUAL_SHA256=$(sha256sum "$PART_PATH" | awk '{print $1}')
    if [ "$ACTUAL_SHA256" != "$SHA256" ]; then
        fail "sha256 mismatch for $NAME: expected $SHA256, got $ACTUAL_SHA256"
    fi
    log "verified $NAME (sha256 ok)"

    cat "$PART_PATH" >> "$CONCAT"
    rm -f "$PART_PATH"
done < "$PARTS_LIST"

ASSEMBLED_SIZE=$(wc -c < "$CONCAT" | tr -d ' ')
if [ "$ASSEMBLED_SIZE" != "$TOTAL_SIZE" ]; then
    fail "assembled size $ASSEMBLED_SIZE does not match manifest totalSize $TOTAL_SIZE"
fi

OUT_DIR=$(dirname "$OUT_PATH")
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"
mv "$CONCAT" "$OUT_PATH"

log "assembled $N_PARTS part(s) into $OUT_PATH ($ASSEMBLED_SIZE bytes, size verified)"
