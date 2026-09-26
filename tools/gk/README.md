# tools/gk — the gkvm guest toolchain

`gk init` scaffolds a gkvm guest into a forge project, `gk build` turns guest source into
`guest.elf` + `programHash` + a Solidity binding, `gk vectors` records golden vectors from the
`gk-run` sidecar. Python standard library only; `python3 tools/gk --help` lists everything.

Status: draft ([gas-killer/solidity-sdk#85](https://github.com/gas-killer/solidity-sdk/pull/85)).
What a fresh project gets today is the forge emulation only — the scaffolded `guest/README.md`
spells out what does and does not work.

## Quickstart: a Python function inside Solidity, in a fresh forge project

Needs `forge`, `python3` and docker (for the guest build). Everything else is one line:

    curl -fsSL https://gaskiller.xyz/bash | sh
    # → ~/.gk/bin/gk-run (prebuilt, sha256-verified), ~/.gk/bin/gk, and the guest toolchain image

    forge init demo && cd demo
    forge install gas-killer/solidity-sdk@gkvm-preview
    gk init --python          # guest/greet.py, its Solidity binding, a consumer and a test
                              # …and the `forge` prehook into ~/.gk/bin (see below)
    forge test                # the Python really runs: the prehook exports GK_RUN, rebuilds
                              # edited guests, and says so in one `[gk]` line first
    gk anvil                  # a local node where GkVm.exec works (anvil + the precompile)
    forge create src/GreetGk.sol:GreetGk --rpc-url http://127.0.0.1:8545 --private-key $ANVIL_KEY \
        --broadcast --constructor-args 0x35597421749DeEad8ba95049eDEe0B94E66F3c59
    cast call <address> "preview(string,uint256)(string)" world 2 --rpc-url http://127.0.0.1:8545
    # → "hello world hello world" — the Python function, called through a contract on a chain

`guest/greet.py` is a typed function; `gk build` turned its hints into `src/gen/GkGreet.sol`,
and `src/GreetGk.sol` calls `GkGreet.call(gkvm, root, name, times)` like any library. Edit the
`.py` and `forge test` — the prehook rebuilds it; that is the whole loop. `gk init` (without
`--python`) scaffolds the C equivalent (`guest/hello.c`).

`@gkvm-preview` is a tag on the gkvm branch: `forge install` takes tags and commits (not
branches), and the sdk's default branch does not carry `tools/gk` yet — drop the suffix once
it does. Installing from a local checkout instead:

    git -c protocol.file.allow=always submodule add /path/to/solidity-sdk lib/solidity-sdk
    git submodule update --init --recursive lib/solidity-sdk

`gk anvil` is anvil with the gkvm precompile (Phase B): every guest built in the project is
installed, everything else is anvil's own command line. It is a developer node — the
precompile exists there and on no real chain; operators run the same guest inside their own
executor and the chain only ever sees the signed state diff.

The `gk` command finds `lib/solidity-sdk/tools/gk` from anywhere inside the project (or
`$GK_SDK`); without the installer, `python3 lib/solidity-sdk/tools/gk …` is the same thing
with `GK_RUN` set by hand. The scaffolded `guest/README.md` covers the rest, including what a
fresh project does and does not get today.

## The `forge` prehook

`gk init` copies `tools/gk/forge-shim.sh` to `$GK_HOME/bin/forge` — the directory the
installer put on PATH ahead of foundry's — so inside a gk project the plain foundry commands
are seamless. Every wrapped run says so up front: exactly one line, first, on stderr —

    [gk] forge test wrapped by the gas-killer sdk · gk-run jit tier · profile gkvm-ffi · guests fresh

stdout stays byte-identical to forge's own, so `forge test --json` and anything else that
parses it keep working. What the prehook does before exec'ing the real forge:

- **rebuild what you edited**: a guest is stale when the content hashes its `guest.json`
  recorded no longer match the bytes on disk — the source, the vendored crt, and for Python
  guests the MicroPython port and typed runtime (`forge test` after editing `greet.py` tests
  the new `greet.py`, never a stale binding). mtimes are never consulted. A failed rebuild
  stops the run instead of testing the old ELF. Rebuilds keep the previous `--heap-bytes` /
  `--stack-bytes`.
- **wire the sidecar**: `GK_RUN` is resolved ($GK_RUN, PATH, `~/.gk/bin/gk-run`) and
  exported, and test-running subcommands (`test`, `snapshot`, `coverage`) get
  `FOUNDRY_PROFILE=gkvm-ffi` unless a profile is already chosen — so shim-backed tests
  execute instead of skipping. Without a sidecar the banner says so and the tests skip as
  before.
- **stay out of the way**: outside a gk project (no `guest/` dir + `gk-sdk/` remapping at
  the project root) the shim execs the real forge untouched and prints nothing; the sdk
  checkout itself is never wrapped. `forge fmt`, `forge install`, … skip the rebuild.

Escape hatches: `GK_FORGE_PLAIN=1 forge …` is always the untouched forge; `gk init
--no-forge-shim` skips installing it; deleting `~/.gk/bin/forge` removes it. `gk forge -- …`
is the prehook invoked explicitly (what the shim calls), and `gk test` remains the spelling
that needs no PATH shim at all. If `which forge` does not resolve to `~/.gk/bin/forge`, PATH
order is putting the real forge first — the prehook then simply never runs.

## Python guests

`gk build guest/answer.py` freezes the script into the MicroPython gkvm port (mpy-cross
bytecode, linked into the ELF — `programHash` commits to the interpreter *and* the script) and
generates the binding from `main()`'s type hints:

    def main(prompt_ids: list[int], max_new: int) -> bytes:
        ...

    // src/gen/GkAnswer.sol
    function call(address gkvm, bytes32 artifactRoot, uint256[] memory promptIds, uint256 maxNew)
        internal view returns (bytes memory)

| Python hint | Solidity | |
|---|---|---|
| `int` | `uint256` | big ints; a negative or ≥ 2^256 return value raises in the guest |
| `bool` | `bool` | |
| `bytes` | `bytes` | |
| `str` | `string` | UTF-8 |
| `list[T]` | `T[]` | nests |
| `float` | — | **rejected at build time**, with float literals and `/` (use `//`): the port has no floats |

`-> bytes` is the guest's raw output and comes back undecoded; any other return type —
`tuple[...]` for several values — is ABI-encoded by the guest and `abi.decode`d by the binding.
An uncaught exception (a malformed payload included) is a `GkGuestTrap(0xD0000001, traceback)`.
A script with no top-level `main` is a *raw* guest: it is the image's `__main__`, calls
`gkvm.input()` / `gkvm.output()` itself, and gets the same bytes-payload binding a C guest does.

What it needs beyond the C path: MicroPython at the pinned commit (`--mpy-src`, `GK_MPY_SRC`,
else cloned into `cache/gkvm/micropython/src` on first use — a checkout at any other commit, or
with local modifications, is refused) and docker (the tested leg; `--compiler native` wants
`riscv64-unknown-elf-gcc` + picolibc headers and is untested). One script per image — it can
`import` the port's built-in modules (`struct`, `json`, `re`, `hashlib`, `collections`, …) but
not a second file of yours yet. `--heap-bytes` sizes the MicroPython heap baked into the image
(default 16 MiB; startup cycles scale with it). solc's stack limit applies to the generated
`call` (it holds no locals for that reason): 6 parameters + 5 return values is the largest
shape tested without `via_ir`; expect "stack too deep" not far beyond it.

## In this repository

`make -C tools/gk test | golden | golden-check | crt-check | port-check` — see the Makefile header.

## Hosts: x86_64 Linux, aarch64, Apple silicon

Everything above runs unchanged on an Apple-silicon Mac (verified 2026-09-20: macOS, Docker
Desktop, forge 1.5.1, system bash 3.2) — `make test`, `golden-check`, `crt-check`,
`port-check`, `zero-glue-check`, `native-stories-check`, and `gk init` / `gk build` for C and
Python guests. What differs by host:

- **One executor tier.** SP1's jit is x86_64-only; elsewhere a plain `cargo build --release -p
  gas-analyzer-gkvm --bin gk-run` already yields the portable interpreter (`gk-run --print-tier`
  → `interp`), no feature flag needed. Outputs and cycle counts are identical across tiers and
  architectures — the committed vectors were recorded on x86_64 and replay bit for bit on arm64
  — but the interpreter is several times slower than the jit (measured with the 80,000,157-cycle
  bench guest: ≈ 259 Mcycles/s on an M-series Mac's interpreter, against ≈ 72 interp / ≈ 780 jit
  on the x86_64 laptop the vectors were recorded on), so wall-clock numbers taken on such a
  host say nothing about the jit tier.
- **Guest builds go through Docker** on every host (`ubuntu:24.04` +
  `gcc-riscv64-unknown-elf`); Docker Desktop must be running. `programHash` is host-independent:
  an arm64 container produces the same ELF bytes as an x86_64 one, and the frozen-module order
  of Python guests is fixed by a generated manifest rather than by the filesystem.
- **Fixtures that carry contract bytecode** (`native_tasks.json`) are compared with
  `fixture_diff.py`, which ignores solc's metadata trailer: its hash covers forge's
  auto-detected remappings, which depend on which nested submodules are checked out.
