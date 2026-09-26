#!/usr/bin/env bash
# The clean-directory quickstart proof (UNBOUNDED_V3 L3 gate): a fresh forge project, in a
# scratch directory outside every checkout, reaches green shim-backed tests by running ONLY
# the commands written in tools/gk/README.md and then in the guest/README.md `gk init` wrote.
# It also proves the forge prehook: plain `forge test` announces itself with one [gk] line
# and runs the guests, an edited guest is rebuilt automatically, and GK_FORGE_PLAIN=1 is the
# untouched forge. GK_HOME is pinned into the scratch dir — the proof never touches $HOME.
#
# Every command goes through `step <readme> <written> [<executed>]`: <written> must appear
# verbatim in <readme> or the proof stops; <executed> (default: <written>) is what runs, and
# differs only where the README holds a placeholder or names an option (`--root`). Both are
# printed, so the transcript shows every substitution.
#
#   SDK_SRC        local sdk checkout to install (default: this one; its HEAD commit is what
#                  the project gets — uncommitted changes are not installed). Empty = take the
#                  published route, `forge install gas-killer/solidity-sdk`.
#   GAS_ANALYZER   gas-analyzer checkout `gk-run` is installed from
#   SCRATCH        parent directory for the project (default: a fresh mktemp dir)
#   KEEP=1         keep the mktemp directory on success (it is always kept on failure, and a
#                  caller-named SCRATCH is never deleted)
set -euo pipefail

SDK_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK_SRC="${SDK_SRC-$SDK_HERE}"
GAS_ANALYZER="${GAS_ANALYZER:-$(cd "$SDK_HERE/.." && pwd)/gas-analyzer}"
KEEP="${KEEP:-0}"
if [ -z "${SCRATCH:-}" ]; then
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gk-quickstart.XXXXXX")"
else
    KEEP=1 # a directory the caller named is never deleted
fi

die() { printf 'quickstart-proof: %s\n' "$1" >&2; exit 1; }

step() {
    local readme="$1" written="$2" executed="${3:-$2}"
    grep -qF -- "$written" "$readme" || die "not written in $readme: $written"
    if [ "$executed" = "$written" ]; then
        printf '\n$ %s\n' "$written"
    else
        printf '\n$ %s\n  # as written in %s: %s\n' "$executed" "$(basename "$readme")" "$written"
    fi
    eval "$executed"
}

mkdir -p "$SCRATCH"
cd "$SCRATCH"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$SCRATCH is inside a git checkout; the proof wants a directory outside all of them"
fi
[ -d "$GAS_ANALYZER/crates/gkvm" ] || die "no gkvm crate under GAS_ANALYZER=$GAS_ANALYZER"

printf '# scratch       %s\n' "$SCRATCH"
printf '# forge         %s\n' "$(forge --version | head -n 1)"
printf '# python3       %s\n' "$(python3 --version)"
printf '# cargo         %s\n' "$(cd "$GAS_ANALYZER" && cargo --version)"
printf '# gas-analyzer  %s @ %s\n' "$GAS_ANALYZER" "$(git -C "$GAS_ANALYZER" rev-parse --short HEAD)"
if [ -n "$SDK_SRC" ]; then
    printf '# sdk           %s @ %s (local checkout, HEAD commit)\n' "$SDK_SRC" "$(git -C "$SDK_SRC" rev-parse --short HEAD)"
    TOP="$SDK_SRC/tools/gk/README.md"
else
    printf '# sdk           gas-killer/solidity-sdk (published)\n'
    TOP="$SDK_HERE/tools/gk/README.md"
fi

# --- tools/gk/README.md, quickstart ------------------------------------------------------
# `gk init` installs the forge prehook into $GK_HOME/bin; pinning GK_HOME into the scratch
# dir keeps the proof out of the caller's home. The dir must exist for the install to land.
export GK_HOME="$SCRATCH/gk-home"
mkdir -p "$GK_HOME/bin"
step "$TOP" 'forge init demo && cd demo'
if [ -n "$SDK_SRC" ]; then
    step "$TOP" 'git -c protocol.file.allow=always submodule add /path/to/solidity-sdk lib/solidity-sdk' \
        "git -c protocol.file.allow=always submodule add $SDK_SRC lib/solidity-sdk"
    step "$TOP" 'git submodule update --init --recursive lib/solidity-sdk'
else
    step "$TOP" 'forge install gas-killer/solidity-sdk'
fi
printf '# installed sdk commit: %s\n' "$(git -C lib/solidity-sdk rev-parse --short HEAD)"
# the README's `gk init` is the installer's `gk` command; without the installer the same
# thing is the sdk's tools/gk, as the README says
step "$TOP" 'gk init' 'python3 lib/solidity-sdk/tools/gk init'
[ -x "$GK_HOME/bin/forge" ] || die 'gk init did not install the forge prehook into $GK_HOME/bin'

# --- guest/README.md (scaffolded), Quickstart steps 1-3 ----------------------------------
GUEST="$PWD/guest/README.md"
[ -f "$GUEST" ] || die "gk init wrote no guest/README.md"
step "$GUEST" 'python3 lib/solidity-sdk/tools/gk build guest/hello.c'

# `--root` is the README's own option; it keeps the proof out of ~/.cargo/bin.
grep -qF -- '--root <dir>' "$GUEST" || die "guest/README.md no longer documents --root"
step "$GUEST" 'cargo install --locked --path crates/gkvm --bin gk-run' \
    "(cd $GAS_ANALYZER && cargo install --locked --path crates/gkvm --bin gk-run --root $SCRATCH/gk-run-root)"
export PATH="$SCRATCH/gk-run-root/bin:$PATH"
printf '# gk-run on PATH: %s\n' "$(command -v gk-run)"

# --- the forge prehook: plain `forge test` runs the guests, one [gk] line first ----------
export PATH="$GK_HOME/bin:$PATH"
command -v forge | grep -qF "$GK_HOME/bin/forge" || die "PATH does not resolve forge to the prehook"
step "$GUEST" 'forge test --match-contract HelloGkTest' \
    'forge test --match-contract HelloGkTest 2> ../prehook.log | tee ../ffi-test.log'
sed 's/^/  # stderr: /' ../prehook.log
head -n 1 ../prehook.log | grep -q '^\[gk\] forge test' \
    || die "the wrapped forge did not announce itself first on stderr"
grep -Eq 'Suite result: ok\. [1-9][0-9]* passed; 0 failed; 0 skipped' ../ffi-test.log \
    || die "the shim-backed tests did not all run green (a skip is not a pass)"

# an edited guest is rebuilt before the tests run (content hashes, not mtimes)
printf '\n$ printf "/* edited */\\n" >> guest/hello.c   # then the same forge test again\n'
printf '/* edited */\n' >> guest/hello.c
forge test --match-contract HelloGkTest 2> ../prehook2.log | tee ../ffi-test2.log
sed 's/^/  # stderr: /' ../prehook2.log
grep -qF 'rebuilt hello.c (source changed)' ../prehook2.log \
    || die "editing guest/hello.c did not trigger a rebuild"
grep -Eq 'Suite result: ok\. [1-9][0-9]* passed; 0 failed; 0 skipped' ../ffi-test2.log \
    || die "the rebuilt guest's tests did not run green"

# "`GK_FORGE_PLAIN=1` gives you the untouched forge" — the ffi tests then skip, staying green
step "$GUEST" 'GK_FORGE_PLAIN=1' 'GK_FORGE_PLAIN=1 forge test 2> ../plain.log'
if grep -q '^\[gk\]' ../plain.log; then die "GK_FORGE_PLAIN=1 still went through the prehook"; fi

printf '\nquickstart-proof: PASS — fresh project, written steps only: the prehook wrapped forge test\n'
printf 'green, an edited guest was rebuilt automatically, GK_FORGE_PLAIN=1 stayed untouched\n'
if [ "$KEEP" = "1" ]; then
    printf '# kept: %s\n' "$SCRATCH"
else
    rm -rf "$SCRATCH"
fi
