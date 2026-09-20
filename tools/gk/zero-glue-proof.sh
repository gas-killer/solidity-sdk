#!/usr/bin/env bash
# The fresh-checkout zero-glue proof (UNBOUNDED_V3 M5 gate): fresh clones of the sdk and of
# gas-analyzer, in a scratch directory outside every checkout, run the four-step loop
# `answer.py → gk build → forge test → local executor` by executing ONLY the commands written
# in src/examples/onchain-llm-native/README.md.
#
# Every command goes through `step <written> [<executed>]`: <written> must appear verbatim in
# that README or the proof stops; <executed> (default: <written>) is what runs, and differs
# only where the README holds a placeholder (`<branch>`) or a GitHub URL the unpublished work
# is not reachable at (→ the local checkout). Both are printed, so the transcript shows every
# substitution.
#
# Nothing warm is inherited from the source checkouts: no `target/`, no `cache/`, no `out/`, no
# MicroPython clone (so `gk build` takes its fetch route), no built gk-run. What IS shared with
# the host: the toolchains, cargo's registry cache (~/.cargo), docker's image cache.
#
#   SDK_SRC            local sdk checkout to clone (default: this one; its HEAD commit on its
#                      current branch is what the proof gets — uncommitted changes are not)
#   GAS_ANALYZER_SRC   local gas-analyzer checkout to clone (default: this checkout's sibling)
#   SCRATCH            parent directory for the clones (default: a fresh mktemp dir)
#   KEEP=1             keep the mktemp directory on success (it is always kept on failure, and
#                      a caller-named SCRATCH is never deleted)
set -euo pipefail

SDK_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK_SRC="${SDK_SRC:-$SDK_HERE}"
GAS_ANALYZER_SRC="${GAS_ANALYZER_SRC:-$(cd "$SDK_HERE/.." && pwd)/gas-analyzer}"
KEEP="${KEEP:-0}"
if [ -z "${SCRATCH:-}" ]; then
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gk-zero-glue.XXXXXX")"
else
    KEEP=1 # a directory the caller named is never deleted
fi

# the fresh checkouts must find each other as siblings, not the host's warm ones — neither
# through the environment nor through command-line variables an outer `make` hands down
unset GK_RUN GK_GUEST_CRT GK_MPY_SRC GK_MPY_PORT GAS_ANALYZER GK_NATIVE_ANSWER_ELF CARGO_TARGET_DIR
unset MAKEFLAGS MFLAGS MAKEOVERRIDES MAKELEVEL

die() { printf 'zero-glue-proof: %s\n' "$1" >&2; exit 1; }

README="$SDK_SRC/src/examples/onchain-llm-native/README.md"

step() {
    local written="$1" executed="${2:-$1}"
    grep -qF -- "$written" "$README" || die "not written in $README: $written"
    if [ "$executed" = "$written" ]; then
        printf '\n$ %s\n' "$written"
    else
        printf '\n$ %s\n  # as written in README.md: %s\n' "$executed" "$written"
    fi
    eval "$executed"
}

mkdir -p "$SCRATCH"
cd "$SCRATCH"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$SCRATCH is inside a git checkout; the proof wants a directory outside all of them"
fi
[ -f "$README" ] || die "no onchain-llm-native README under SDK_SRC=$SDK_SRC"
[ -d "$GAS_ANALYZER_SRC/crates/gkvm" ] || die "no gkvm crate under GAS_ANALYZER_SRC=$GAS_ANALYZER_SRC"
SDK_BRANCH="$(git -C "$SDK_SRC" rev-parse --abbrev-ref HEAD)"
GA_BRANCH="$(git -C "$GAS_ANALYZER_SRC" rev-parse --abbrev-ref HEAD)"

printf '# scratch       %s\n' "$SCRATCH"
printf '# forge         %s\n' "$(forge --version | head -n 1)"
printf '# python3       %s\n' "$(python3 --version)"
printf '# cargo         %s\n' "$(cd "$GAS_ANALYZER_SRC" && cargo --version)"
printf '# docker        %s\n' "$(docker --version)"
printf '# sdk           %s @ %s (%s, HEAD commit)\n' "$SDK_SRC" "$(git -C "$SDK_SRC" rev-parse --short HEAD)" "$SDK_BRANCH"
printf '# gas-analyzer  %s @ %s (%s, HEAD commit)\n' "$GAS_ANALYZER_SRC" "$(git -C "$GAS_ANALYZER_SRC" rev-parse --short HEAD)" "$GA_BRANCH"

step 'git clone --branch <branch> https://github.com/gas-killer/solidity-sdk' \
    "git clone --branch $SDK_BRANCH $SDK_SRC solidity-sdk"
step 'git clone --branch <branch> https://github.com/gas-killer/gas-analyzer' \
    "git clone --branch $GA_BRANCH $GAS_ANALYZER_SRC gas-analyzer"
step 'cd solidity-sdk'
step 'git submodule update --init --recursive'

for warm in cache out ../gas-analyzer/target; do
    [ ! -e "$warm" ] || die "the fresh checkout already has $warm — not fresh"
done

step '(cd ../gas-analyzer && cargo build --release -p gas-analyzer-gkvm --bin gk-run)'
step 'make -C tools/gk zero-glue-check' \
    'make -C tools/gk zero-glue-check 2>&1 | tee ../zero-glue-check.log'

# the target's own PASS line, and the two things a warm checkout would have hidden
LOG=../zero-glue-check.log
grep -qF 'zero-glue-check: PASS' "$LOG" || die "zero-glue-check did not print its PASS line"
grep -qF 'fetching  MicroPython' "$LOG" || die "gk build did not take the MicroPython fetch route"
grep -Eq 'test result: ok\. 2 passed; 0 failed; 0 ignored' "$LOG" \
    || die "the local-executor leg did not run both tests (an ignored test is not a pass)"

printf '\nzero-glue-proof: PASS — fresh checkouts, written steps only, answer.py → gk build → forge test → local executor\n'
if [ "$KEEP" = "1" ]; then
    printf '# kept: %s\n' "$SCRATCH"
else
    rm -rf "$SCRATCH"
fi
