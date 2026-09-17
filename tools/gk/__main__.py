"""gk — the gkvm guest toolchain (UNBOUNDED_V3 native guest execution).

Run from the solidity-sdk root:

    python3 tools/gk build guest/hello.c
        compiled  hello.c + gk-guest-crt
        linked    cache/gkvm/build/hello/guest.elf
        program   0x…  (keccak256 of the ELF)
        emitted   src/gen/GkHello.sol

    python3 tools/gk vectors cache/gkvm/build/hello/guest.elf --name hello \\
        --input 0x11223344 --input 0x
        emitted   test/fixtures/hello_vectors.json

    python3 tools/gk hash guest.elf

`build` needs gk-guest-crt (gas-analyzer crates/gkvm/guest: --crt, GK_GUEST_CRT, or a
sibling gas-analyzer checkout) and riscv64-unknown-elf-gcc or docker. `vectors` needs the
gk-run sidecar (--gk-run or GK_RUN). Python standard library only.

See src/examples/onchain-llm/UNBOUNDED_V3_NATIVE.md (§ Writing programs).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gk_build  # noqa: E402
import gk_vectors  # noqa: E402
from gk_keccak import hex32, keccak256  # noqa: E402

SDK_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main(argv=None):
    ap = argparse.ArgumentParser(prog='gk', description='gkvm guest toolchain')
    ap.add_argument('--sdk-root', default=SDK_ROOT,
                    help='solidity-sdk checkout the default output paths hang off')
    sub = ap.add_subparsers(dest='cmd', required=True)

    b = sub.add_parser('build', help='guest source -> guest.elf + programHash + Solidity binding')
    b.add_argument('source', help='guest source (.c)')
    b.add_argument('--out', help='build dir (default cache/gkvm/build/<name>)')
    b.add_argument('--sol-out', help='binding dir (default src/gen)')
    b.add_argument('--name', help='binding library name (default Gk<Source>)')
    b.add_argument('--crt', help='gk-guest-crt dir (default $GK_GUEST_CRT, else the sibling '
                                 'gas-analyzer checkout)')
    b.add_argument('--compiler', default='auto', choices=['auto', 'native', 'docker'])
    b.add_argument('--no-binding', action='store_true', help='skip the Solidity binding')

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

    args = ap.parse_args(argv)
    try:
        if args.cmd == 'build':
            gk_build.build(args.source, args.sdk_root, out=args.out, sol_out=args.sol_out,
                           crt=args.crt, name=args.name, compiler=args.compiler,
                           emit_binding=not args.no_binding)
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
    except (gk_build.GkBuildError, gk_vectors.GkVectorsError, OSError) as e:
        print('gk: %s' % e, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
