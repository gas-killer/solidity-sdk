# tools/gk — the gkvm guest toolchain

`gk init` scaffolds a gkvm guest into a forge project, `gk build` turns guest source into
`guest.elf` + `programHash` + a Solidity binding, `gk vectors` records golden vectors from the
`gk-run` sidecar. Python standard library only; `python3 tools/gk --help` lists everything.

Status: draft ([gas-killer/solidity-sdk#85](https://github.com/gas-killer/solidity-sdk/pull/85)).
What a fresh project gets today is the forge emulation only — the scaffolded `guest/README.md`
spells out what does and does not work.

## Quickstart: a guest in a fresh forge project

Needs `forge`, `python3`, `cargo`, and either `riscv64-unknown-elf-gcc` or docker.

1. **A forge project with the sdk installed:**

       forge init hello-gk
       cd hello-gk
       forge install gas-killer/solidity-sdk

   Until the gkvm work is on the sdk's default branch (it is not yet), that last command
   installs an sdk without `tools/gk`. Install from a checkout that has it instead — what
   `forge install` does underneath, pointed at a local clone (`forge install` itself only
   takes GitHub shorthand and remote URLs):

       git -c protocol.file.allow=always submodule add /path/to/solidity-sdk lib/solidity-sdk
       git submodule update --init --recursive lib/solidity-sdk

2. **Scaffold the guest:**

       python3 lib/solidity-sdk/tools/gk init

   This vendors the guest runtime into `guest/`, writes an example guest, a sample consumer, a
   shim-wired test and `guest/README.md`, appends `[profile.gkvm-ffi]` to `foundry.toml` and the
   `gk-sdk/` remapping to `remappings.txt`, and builds the example guest. Nothing existing is
   overwritten; re-running is a no-op.

3. **Continue with `guest/README.md`** in your project — its Quickstart builds the guest,
   installs `gk-run` and runs the tests under the ffi profile.

`make -C tools/gk quickstart-proof` replays exactly these steps, and then the scaffolded
README's, in a scratch directory outside any checkout, and fails unless the shim-backed tests
run (not skip) green. It refuses to run a command that is not written in one of the two READMEs.

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
