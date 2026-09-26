#!/usr/bin/env bash
# gk-forge-shim — the transparent gkvm prehook around foundry's forge.
#
# `gk init` installs this as $GK_HOME/bin/forge (the directory the gas-killer installer
# put on PATH). Inside a forge project that ran `gk init` — a guest/ dir plus the gk-sdk/
# remapping — it hands the call to the project's own `tools/gk forge`, which rebuilds
# stale guests, exports GK_RUN, prints one `[gk]` line to stderr and execs the real
# forge. Anywhere else it execs the real forge untouched and prints nothing, so non-gkvm
# projects never see it. GK_FORGE_PLAIN=1 forces the untouched path everywhere.
#
# The logic lives in the sdk each project vendors (lib/solidity-sdk/tools/gk), so it is
# versioned with the project; this file only decides "gk project or not" and delegates.
set -u

find_real() {
  local d IFS=:
  for d in $PATH; do
    [ -x "${d:-.}/forge" ] || continue
    # skip every copy of this shim, wherever it is installed
    grep -q gk-forge-shim "${d:-.}/forge" 2>/dev/null && continue
    printf '%s\n' "${d:-.}/forge"
    return 0
  done
  return 1
}

real="$(find_real)" || {
  echo '[gk] forge shim: no real forge on PATH (https://getfoundry.sh)' >&2
  exit 127
}

if [ "${GK_FORGE_PLAIN:-0}" = 1 ] || [ "${GK_FORGE_WRAPPED:-0}" = 1 ]; then
  exec "$real" "$@"
fi

root="$PWD"
while [ "$root" != / ] && [ ! -f "$root/foundry.toml" ]; do
  root="$(dirname "$root")"
done

tools=""
if [ -f "$root/foundry.toml" ] && [ -d "$root/guest" ]; then
  if [ -n "${GK_SDK:-}" ] && [ -f "$GK_SDK/tools/gk/__main__.py" ]; then
    tools="$GK_SDK/tools/gk"
  elif [ -f "$root/lib/solidity-sdk/tools/gk/__main__.py" ]; then
    tools="$root/lib/solidity-sdk/tools/gk"
  fi
fi

if [ -n "$tools" ] && command -v python3 >/dev/null 2>&1; then
  exec python3 "$tools" forge -- "$@"
fi
exec "$real" "$@"
