"""Tests for tools/gk.  `make -C tools/gk test` (see the Makefile for GK_RUN / GK_GUEST_CRT).

The sidecar- and compiler-dependent cases skip themselves when GK_RUN /
GK_GUEST_CRT are absent, mirroring the forge shim tests.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gk_build  # noqa: E402
import gk_vectors  # noqa: E402
from gk_keccak import hex32, keccak256, keccak256_pure  # noqa: E402

SDK_ROOT = os.path.dirname(os.path.dirname(HERE))
FIXTURES = os.path.join(SDK_ROOT, 'test', 'fixtures', 'gkvm')
HELLO_ELF = os.path.join(FIXTURES, 'hello-c.elf')
BENCH_ELF = os.path.join(FIXTURES, 'bench-c.elf')

GK_RUN = os.environ.get('GK_RUN')
GK_GUEST_CRT = os.environ.get('GK_GUEST_CRT')
HAVE_CC = bool(shutil.which(gk_build.CC) or shutil.which('docker'))

# "GKVM-HELLO-V1\n" || reversed payload
HELLO_11223344 = '0x474b564d2d48454c4c4f2d56310a44332211'


def quiet(*_):
    pass


class Keccak(unittest.TestCase):
    def test_known_answers(self):
        self.assertEqual(
            keccak256_pure(b'').hex(),
            'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470')
        self.assertEqual(
            keccak256_pure(b'abc').hex(),
            '4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45')

    def test_gkvm_address_derivation(self):
        # GkVm.sol: GKVM_ADDRESS = address(uint160(uint256(keccak256("gaskiller.gkvm.addr.v1"))))
        digest = keccak256_pure(b'gaskiller.gkvm.addr.v1')
        self.assertEqual(digest[12:].hex(), '35597421749deead8ba95049edee0b94e66f3c59')

    def test_rate_boundaries_match_pycryptodome(self):
        try:
            from Crypto.Hash import keccak as k
        except ImportError:
            self.skipTest('pycryptodome not installed')
        for n in (1, 134, 135, 136, 137, 271, 272, 273, 1000):
            data = bytes((i * 7 + n) & 0xFF for i in range(n))
            self.assertEqual(keccak256_pure(data), k.new(digest_bits=256, data=data).digest(), n)


class BuildUnits(unittest.TestCase):
    def test_binding_name(self):
        self.assertEqual(gk_build.binding_name('hello'), 'GkHello')
        self.assertEqual(gk_build.binding_name('artifact-probe'), 'GkArtifactProbe')
        self.assertEqual(gk_build.binding_name('my_guest2'), 'GkMyGuest2')
        with self.assertRaises(gk_build.GkBuildError):
            gk_build.binding_name('--')

    def test_render_binding(self):
        sol = gk_build.render_binding('GkHello', '0x' + 'ab' * 32, 'guest/hello.c',
                                      '../gkvm/GkVm.sol')
        self.assertIn('library GkHello {', sol)
        self.assertIn('bytes32 constant PROGRAM_HASH = 0x' + 'ab' * 32 + ';', sol)
        self.assertIn('import {GkVm} from "../gkvm/GkVm.sol";', sol)
        self.assertIn('GkVm.exec(gkvm, PROGRAM_HASH, artifactRoot, payload)', sol)

    def test_python_guest_rejected_with_pointer(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, 'answer.py')
            open(src, 'w').close()
            with self.assertRaisesRegex(gk_build.GkBuildError, 'M5'):
                gk_build.build(src, SDK_ROOT, out=tmp, log=quiet)

    def test_missing_crt_is_loud(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(gk_build.GkBuildError, 'gk-guest-crt not found'):
                gk_build.resolve_crt(tmp, SDK_ROOT)

    def test_compile_command_has_no_host_paths(self):
        cmds = gk_build.compile_commands('guest/hello.c')
        self.assertFalse([a for cmd in cmds for a in cmd if os.path.isabs(a)])
        # every unit gets a fixed object name — a one-shot gcc leaks /tmp/ccXXXXXX.o
        # into .symtab and breaks programHash reproducibility
        self.assertEqual([c[-1] for c in cmds], ['crt0.o', 'gkvm.o', 'guest.o', 'guest.elf'])


class Cli(unittest.TestCase):
    def gk(self, *argv, env=None):
        return subprocess.run([sys.executable, '-B', HERE] + list(argv), env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_hash(self):
        proc = self.gk('hash', HELLO_ELF)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(HELLO_ELF, 'rb') as f:
            self.assertEqual(proc.stdout.decode().strip(), hex32(keccak256_pure(f.read())))

    def test_errors_exit_1_on_stderr(self):
        env = {k: v for k, v in os.environ.items() if k != 'GK_RUN'}
        proc = self.gk('vectors', HELLO_ELF, '--input', '0x', env=env)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, b'')
        self.assertIn(b'gk: gk-run not given', proc.stderr)

    @unittest.skipUnless(GK_RUN, 'GK_RUN not set')
    def test_vectors_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, 'hello_vectors.json')
            proc = self.gk('vectors', HELLO_ELF, '--name', 'hello', '--input', '0x11223344',
                           '--out', out)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            with open(out) as f:
                doc = json.load(f)
        self.assertEqual(doc['vectors'][0]['stdout'], HELLO_11223344)


@unittest.skipUnless(GK_RUN, 'GK_RUN not set')
class Vectors(unittest.TestCase):
    def test_hello_vectors(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, 'hello_vectors.json')
            doc = gk_vectors.vectors(HELLO_ELF, ['0x11223344', '0x'], gk_run=GK_RUN,
                                     name='hello', out=out, sdk_root=tmp, log=quiet)
            with open(out) as f:
                self.assertEqual(json.load(f), doc)
        # gk-run re-verifies --program-hash against the ELF: the run succeeding is the
        # cross-check of this package's keccak against the Rust side.
        with open(HELLO_ELF, 'rb') as f:
            self.assertEqual(doc['programHash'], hex32(keccak256_pure(f.read())))
        self.assertEqual(doc['artifactRoot'], '0x' + '00' * 32)
        first, empty = doc['vectors']
        self.assertEqual((first['exit'], first['outcome']), (0, 'ok'))
        self.assertEqual(first['stdout'], HELLO_11223344)
        self.assertEqual(first['cycles'], 93)
        self.assertEqual(first['gasUsed'], 24)  # ceil(93 / 4)
        self.assertEqual(empty['input'], '0x')
        self.assertEqual(empty['cycles'], 74)

    def test_typed_failures_are_vectors(self):
        with tempfile.TemporaryDirectory() as tmp:
            trap = gk_vectors.vectors(BENCH_ELF, ['0x01'], gk_run=GK_RUN,
                                      out=os.path.join(tmp, 't.json'), sdk_root=tmp,
                                      log=quiet)['vectors'][0]
            ooc = gk_vectors.vectors(BENCH_ELF, ['0x00000000000f4240'], gk_run=GK_RUN,
                                     cycle_limit=1000, out=os.path.join(tmp, 'o.json'),
                                     sdk_root=tmp, log=quiet)['vectors'][0]
        self.assertEqual((trap['exit'], trap['outcome']), (10, 'trap'))
        self.assertTrue(trap['stdout'].startswith('0x00000001'))
        self.assertEqual((ooc['exit'], ooc['outcome']), (11, 'out-of-cycles'))
        # used (u64 BE) || limit (u64 BE): 8,000,157 / 1,000
        self.assertEqual(ooc['stdout'], '0x00000000007a129d00000000000003e8')
        self.assertEqual(ooc['cycleLimit'], 1000)

    def test_large_payload_spills_to_file(self):
        payload = '0x' + 'a5' * (gk_vectors.ARGV_INPUT_BYTES + 1)
        with tempfile.TemporaryDirectory() as tmp:
            v = gk_vectors.vectors(HELLO_ELF, [payload], gk_run=GK_RUN,
                                   out=os.path.join(tmp, 'big.json'), sdk_root=tmp,
                                   log=quiet)['vectors'][0]
        self.assertEqual(v['exit'], 0)
        self.assertTrue(v['stdout'].endswith('a5' * 16))

    def test_environment_class_is_not_a_vector(self):
        with tempfile.TemporaryDirectory() as tmp:
            bogus = os.path.join(tmp, 'not-an-elf.elf')
            with open(bogus, 'wb') as f:
                f.write(b'nope')
            with self.assertRaisesRegex(gk_vectors.GkVectorsError, 'not a vector'):
                gk_vectors.vectors(bogus, ['0x'], gk_run=GK_RUN,
                                   out=os.path.join(tmp, 'x.json'), sdk_root=tmp, log=quiet)


@unittest.skipUnless(GK_GUEST_CRT and HAVE_CC, 'GK_GUEST_CRT not set, or no compiler/docker')
class Build(unittest.TestCase):
    def test_hello_build_is_reproducible_and_runs(self):
        source = os.path.join(GK_GUEST_CRT, 'hello', 'hello.c')
        # docker bind mounts need a real host path the daemon can see; stay out of /tmp
        # sandboxes by building under the sdk's gitignored cache/.
        base = os.path.join(SDK_ROOT, 'cache', 'gkvm', 'test-build')
        infos = []
        for leg in ('a', 'b'):
            out = os.path.join(base, leg)
            infos.append(gk_build.build(source, SDK_ROOT, out=out,
                                        sol_out=os.path.join(out, 'gen'), log=quiet))
        a, b = infos
        self.assertEqual(a['programHash'], b['programHash'])
        with open(os.path.join(base, 'a', 'guest.json')) as f:
            self.assertEqual(json.load(f), a)
        with open(os.path.join(base, 'a', 'gen', 'GkHello.sol')) as f:
            self.assertIn('PROGRAM_HASH = %s;' % a['programHash'], f.read())
        print('\n  gk build hello.c -> %s (%s)' % (a['programHash'], a['cc']), file=sys.stderr)

        if GK_RUN:
            elf = os.path.join(base, 'a', 'guest.elf')
            v = gk_vectors.vectors(elf, ['0x11223344'], gk_run=GK_RUN,
                                   out=os.path.join(base, 'a', 'v.json'), sdk_root=base,
                                   log=quiet)['vectors'][0]
            self.assertEqual(v['stdout'], HELLO_11223344)


if __name__ == '__main__':
    unittest.main()
