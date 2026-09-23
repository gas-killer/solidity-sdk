"""gk — the gkvm guest toolchain (UNBOUNDED_V3 native guest execution).

Run from the solidity-sdk root:

    python3 tools/gk build guest/hello.c
        compiled  hello.c + gk-guest-crt
        linked    cache/gkvm/build/hello/guest.elf
        program   0x…  (keccak256 of the ELF)
        emitted   src/gen/GkHello.sol

    python3 tools/gk build guest/answer.py
        frozen    answer.py + gk_runtime.py + gk_entry.py  →  micropython-gkvm image
        linked    cache/gkvm/build/answer/guest.elf
        program   0x…
        emitted   src/gen/GkAnswer.sol      (call(gkvm, artifactRoot, <main()'s arguments>))

    python3 tools/gk vectors cache/gkvm/build/hello/guest.elf --name hello \\
        --input 0x11223344 --input 0x
        emitted   test/fixtures/hello_vectors.json

    python3 tools/gk hash guest.elf

From a forge project that installed the sdk (outputs then hang off the project):

    python3 lib/solidity-sdk/tools/gk init
        scaffolds guest/ (vendored crt + hello.c), a sample consumer + shim-wired test,
        [profile.gkvm-ffi], the gk-sdk/ remapping — never overwrites, safe to re-run
    python3 lib/solidity-sdk/tools/gk build guest/hello.c

`build` needs gk-guest-crt (--crt, GK_GUEST_CRT, the project's vendored guest/, else the
copy bundled in tools/gk/guest-crt) and riscv64-unknown-elf-gcc or docker; a Python guest
also needs MicroPython at the pinned commit (--mpy-src, GK_MPY_SRC, else cloned). `vectors` needs
the gk-run sidecar (--gk-run or GK_RUN). Python standard library only.

See src/examples/onchain-llm/UNBOUNDED_V3_NATIVE.md (§ Writing programs).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gk_build  # noqa: E402
import gk_init  # noqa: E402
import gk_test  # noqa: E402
import gk_anvil  # noqa: E402
import gk_vectors  # noqa: E402
from gk_keccak import hex32, keccak256  # noqa: E402

SDK_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main(argv=None):
    ap = argparse.ArgumentParser(prog='gk', description='gkvm guest toolchain')
    ap.add_argument('--sdk-root', default=SDK_ROOT,
                    help='solidity-sdk checkout the default output paths hang off')
    sub = ap.add_subparsers(dest='cmd', required=True)

    b = sub.add_parser('build', help='guest source -> guest.elf + programHash + Solidity binding')
    b.add_argument('source', help='guest source (.c, or .py — see gk_python.py)')
    b.add_argument('--out', help='build dir (default cache/gkvm/build/<name>)')
    b.add_argument('--sol-out', help='binding dir (default src/gen)')
    b.add_argument('--project', help='forge project to build into (default: the project the '
                                     'cwd sits in; the sdk itself when there is none)')
    b.add_argument('--name', help='binding library name (default Gk<Source>)')
    b.add_argument('--crt', help="gk-guest-crt dir (default $GK_GUEST_CRT, else the project's "
                                 "vendored guest/, else the sdk's bundled copy)")
    b.add_argument('--compiler', default='auto', choices=['auto', 'native', 'docker'])
    b.add_argument('--no-binding', action='store_true', help='skip the Solidity binding')
    b.add_argument('--mpy-src', help='Python guests: MicroPython checkout at the pinned commit '
                                     '(default $GK_MPY_SRC, else fetched into '
                                     'cache/gkvm/micropython/src)')
    b.add_argument('--heap-bytes', type=int, help='Python guests: MicroPython heap baked into '
                                                  'the image (default 16777216; part of '
                                                  'programHash, and startup cycles scale with it)')
    b.add_argument('--stack-bytes', type=int, help='Python guests: C-stack limit of the '
                                                   'recursion check (default 1048576)')

    v = sub.add_parser('vectors', help='run a guest under gk-run, write golden vectors')
    v.add_argument('elf', help='guest ELF (from `gk build`)')
    v.add_argument('--input', action='append', default=[], metavar='0xHEX',
                   help='payload; repeat for several vectors')
    v.add_argument('--name', help='fixture name (default: the ELF file stem)')
    v.add_argument('--out', help='output file (default test/fixtures/<name>_vectors.json)')
    v.add_argument('--gk-run', help='gk-run binary (default $GK_RUN)')
    v.add_argument('--cycle-limit', type=int, help='pinned cycle budget for every vector')
    v.add_argument('--artifact', help='artifact blob[,blob…]')
    v.add_argument('--artifact-root', help='manifest v3 root of the artifact bundle')
    v.add_argument('--schedule', help='kind:page,… page-serving order')

    h = sub.add_parser('hash', help='print programHash = keccak256(ELF)')
    h.add_argument('elf')

    i = sub.add_parser('init', help='scaffold a guest into an existing forge project '
                                    '(never overwrites; safe to re-run)')
    i.add_argument('project', nargs='?', default='.', help='forge project root (default: .)')
    i.add_argument('--crt', help='gk-guest-crt dir to vendor (default $GK_GUEST_CRT, else the '
                                 "sdk's bundled copy)")
    i.add_argument('--sdk-path', help='where the project sees the sdk, project-relative '
                                      '(default: derived from this checkout)')
    i.add_argument('--compiler', default='auto', choices=['auto', 'native', 'docker'])
    i.add_argument('--no-build', action='store_true',
                   help='skip building the example guest (its binding is then missing until '
                        '`gk build guest/hello.c`)')
    i.add_argument('--python', action='store_true',
                   help='scaffold a typed Python guest (guest/greet.py → GkGreet.sol) instead '
                        'of the C one; needs docker (or the prebuilt toolchain image)')

    t = sub.add_parser('test', help='forge test with the guest really executing (gk-run + the '
                                    'gkvm-ffi profile); extra arguments go to forge')
    t.add_argument('forge_args', nargs=argparse.REMAINDER, help='passed to `forge test`')

    a = sub.add_parser('anvil', help='start gk-anvil (anvil + the gkvm precompile) with every '
                                     'guest built in this project installed; extra arguments '
                                     'go to anvil')
    a.add_argument('anvil_args', nargs=argparse.REMAINDER, help='passed to `gk-anvil`')

    # `gk test --match-contract X`: argparse would claim the forge options as gk's own, so
    # everything unknown after `test` goes to forge.
    args, unknown = ap.parse_known_args(argv)
    if args.cmd == 'test':
        args.forge_args = unknown + args.forge_args
    elif args.cmd == 'anvil':
        args.anvil_args = unknown + args.anvil_args
    elif unknown:
        ap.error('unrecognized arguments: %s' % ' '.join(unknown))
    try:
        if args.cmd == 'build':
            project = args.project or gk_build.find_project(os.getcwd(), args.sdk_root)
            gk_build.build(args.source, args.sdk_root, out=args.out, sol_out=args.sol_out,
                           crt=args.crt, name=args.name, compiler=args.compiler,
                           emit_binding=not args.no_binding, project=project,
                           mpy_src=args.mpy_src, heap_bytes=args.heap_bytes,
                           stack_bytes=args.stack_bytes)
        elif args.cmd == 'init':
            gk_init.init(args.project, args.sdk_root, crt=args.crt, compiler=args.compiler,
                         build=not args.no_build, sdk_path=args.sdk_path, python=args.python)
        elif args.cmd == 'test':
            forge_args = args.forge_args[1:] if args.forge_args[:1] == ['--'] else args.forge_args
            return gk_test.run(args.sdk_root, forge_args)
        elif args.cmd == 'anvil':
            anvil_args = args.anvil_args[1:] if args.anvil_args[:1] == ['--'] else args.anvil_args
            return gk_anvil.run(args.sdk_root, anvil_args)
        elif args.cmd == 'vectors':
            if bool(args.artifact) != bool(args.artifact_root):
                raise gk_vectors.GkVectorsError(
                    '--artifact and --artifact-root are all-or-nothing')
            artifact = None
            if args.artifact:
                artifact = {'blobs': args.artifact.split(','), 'root': args.artifact_root,
                            'schedule': args.schedule}
            gk_vectors.vectors(args.elf, args.input, gk_run=args.gk_run, name=args.name,
                               out=args.out, sdk_root=args.sdk_root,
                               cycle_limit=args.cycle_limit, artifact=artifact)
        else:
            with open(args.elf, 'rb') as f:
                print(hex32(keccak256(f.read())))
    except (gk_build.GkBuildError, gk_init.GkInitError, gk_vectors.GkVectorsError,
            OSError) as e:
        print('gk: %s' % e, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
