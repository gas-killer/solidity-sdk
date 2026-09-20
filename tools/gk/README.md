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

## In this repository

`make -C tools/gk test | golden | golden-check | crt-check` — see the Makefile header.
