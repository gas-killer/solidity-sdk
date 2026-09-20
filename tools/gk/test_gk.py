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
import gk_init  # noqa: E402
import gk_python  # noqa: E402
import gk_vectors  # noqa: E402
from gk_keccak import hex32, keccak256, keccak256_pure  # noqa: E402

SDK_ROOT = os.path.dirname(os.path.dirname(HERE))
FIXTURES = os.path.join(SDK_ROOT, 'test', 'fixtures', 'gkvm')
HELLO_ELF = os.path.join(FIXTURES, 'hello-c.elf')
BENCH_ELF = os.path.join(FIXTURES, 'bench-c.elf')

GK_RUN = os.environ.get('GK_RUN')
GK_GUEST_CRT = os.environ.get('GK_GUEST_CRT')
HAVE_CC = bool(shutil.which(gk_build.CC) or shutil.which('docker'))

FORGE = shutil.which('forge')

# "GKVM-HELLO-V1\n" || reversed payload
HELLO_11223344 = '0x474b564d2d48454c4c4f2d56310a44332211'

# keccak256(crt0.S || gkvm.c || gkvm.h || link.ld) of tools/gk/guest-crt — guest.json's
# `crtHash` for every guest built from the bundled copy. Synced from gas-analyzer f733d2b
# (the keccak fast-path crt).
BUNDLED_CRT_HASH = '0xbf6dc72fd3b710101efae1c9e25a244c56b7dbf34802ea0134099a13cc3b81d1'

# guest.json's `portHash` / `runtimeHash`: keccak256 of tools/gk/guest-crt/micropython's files
# (gk_python.PORT_FILES order; synced from gas-analyzer's crates/gkvm/guest/micropython) and of
# tools/gk/runtime/gk_runtime.py.
BUNDLED_PORT_HASH = '0xbb1a8e98ecac2cff74745c0997efdd9f1c1793fe90fcc97739c1875d714eae48'
RUNTIME_HASH = '0x981736a36ea28cddb17019a257cb6c047b1692640029cb97b3af1b23e9b86b4f'

# what `forge init` writes
FORGE_INIT_TOML = '''[profile.default]
src = "src"
out = "out"
libs = ["lib"]

# See more config options https://github.com/foundry-rs/foundry/blob/master/crates/config/README.md#all-options
'''
FORGE_INIT_GITIGNORE = '''# Compiler files
cache/
out/

# Dotenv file
.env
'''


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

    def test_unsupported_source_and_python_only_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name, kwargs, pattern in (('guest.rs', {}, r'\.c or \.py'),
                                          ('guest.c', {'heap_bytes': 1 << 20}, 'Python guests only')):
                src = os.path.join(tmp, name)
                open(src, 'w').close()
                with self.assertRaisesRegex(gk_build.GkBuildError, pattern):
                    gk_build.build(src, SDK_ROOT, out=tmp, log=quiet, **kwargs)

    def test_missing_crt_is_loud(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(gk_build.GkBuildError, 'gk-guest-crt not found'):
                gk_build.resolve_crt(tmp)

    def test_crt_resolution_order(self):
        env = os.environ.pop('GK_GUEST_CRT', None)
        try:
            with tempfile.TemporaryDirectory() as project:
                # nothing vendored -> the sdk's bundled copy; a sibling checkout is never assumed
                self.assertEqual(gk_build.resolve_crt(None, project), gk_build.BUNDLED_CRT)
                vendored = os.path.join(project, gk_build.PROJECT_CRT_DIR)
                shutil.copytree(gk_build.BUNDLED_CRT, vendored)
                self.assertEqual(gk_build.resolve_crt(None, project), vendored)
                os.environ['GK_GUEST_CRT'] = gk_build.BUNDLED_CRT
                self.assertEqual(gk_build.resolve_crt(None, project), gk_build.BUNDLED_CRT)
                self.assertEqual(gk_build.resolve_crt(vendored, project), vendored)
        finally:
            os.environ.pop('GK_GUEST_CRT', None)
            if env is not None:
                os.environ['GK_GUEST_CRT'] = env

    def test_bundled_crt_is_pinned(self):
        # The crt is linked into every guest, so its bytes are part of every programHash:
        # editing tools/gk/guest-crt silently re-keys every guest built from it. Change it
        # only by re-syncing from gas-analyzer (`make crt-check`), and re-pin here.
        blob = b''.join(gk_build._read(os.path.join(gk_build.BUNDLED_CRT, f))
                        for f in gk_build.CRT_FILES)
        self.assertEqual(hex32(keccak256_pure(blob)), BUNDLED_CRT_HASH)

    def test_find_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            nested = os.path.join(tmp, 'guest', 'deep')
            os.makedirs(nested)
            self.assertIsNone(gk_build.find_project(nested, SDK_ROOT))
            open(os.path.join(tmp, 'foundry.toml'), 'w').close()
            self.assertEqual(gk_build.find_project(nested, SDK_ROOT), tmp)
        # inside the sdk checkout the historical defaults stay: no project
        self.assertIsNone(gk_build.find_project(HERE, SDK_ROOT))

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


def make_project(root, toml=FORGE_INIT_TOML, gitignore=FORGE_INIT_GITIGNORE):
    """A stand-in for `forge init` + `forge install <sdk>`: foundry.toml, and the sdk visible at
    lib/solidity-sdk (symlinks to this checkout's src/ and tools/ — not to the whole checkout,
    which would put a directory cycle under the sdk's own cache/). Returns the sdk root as the
    project sees it."""
    os.makedirs(os.path.join(root, 'lib', 'solidity-sdk'))
    for d in ('src', 'tools'):
        os.symlink(os.path.join(SDK_ROOT, d), os.path.join(root, 'lib', 'solidity-sdk', d))
    with open(os.path.join(root, 'foundry.toml'), 'w') as f:
        f.write(toml)
    if gitignore is not None:
        with open(os.path.join(root, '.gitignore'), 'w') as f:
            f.write(gitignore)
    return os.path.join(root, 'lib', 'solidity-sdk')


def snapshot(root):
    """{project-relative path: bytes} of every regular file outside lib/."""
    files = {}
    for base, dirs, names in os.walk(root):
        if base == root:
            dirs[:] = [d for d in dirs if d != 'lib']
        for n in names:
            p = os.path.join(base, n)
            with open(p, 'rb') as f:
                files[os.path.relpath(p, root)] = f.read()
    return files


class Init(unittest.TestCase):
    """The scaffold itself — no compiler, no forge (build=False)."""

    def test_scaffolds_a_fresh_forge_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk = make_project(tmp)
            actions = gk_init.init(tmp, sdk, build=False, log=quiet)
            files = snapshot(tmp)
        self.assertEqual(sorted(files), sorted([
            '.gitignore', 'foundry.toml', 'remappings.txt',
            'guest/README.md', 'guest/hello.c', 'guest/link.ld',
            'guest/crt/crt0.S', 'guest/crt/gkvm.c', 'guest/crt/gkvm.h',
            'src/HelloGk.sol', 'test/HelloGk.t.sol']))
        for f in gk_build.CRT_FILES:
            self.assertEqual(files['guest/' + f], gk_build._read(os.path.join(gk_build.BUNDLED_CRT, f)))

        # foundry.toml: the original, byte for byte, then the profile
        toml = files['foundry.toml'].decode()
        self.assertTrue(toml.startswith(FORGE_INIT_TOML))
        import tomllib
        profiles = tomllib.loads(toml)['profile']
        self.assertEqual(profiles['default'], {'src': 'src', 'out': 'out', 'libs': ['lib']})
        self.assertEqual(profiles['gkvm-ffi'], {
            'ffi': True,
            'fs_permissions': [{'access': 'read-write', 'path': './cache/gkvm'}]})
        self.assertNotIn('ffi', profiles['default'])

        self.assertEqual(files['remappings.txt'], b'gk-sdk/=lib/solidity-sdk/src/\n')
        # forge init's .gitignore already ignores cache/ — nothing to add
        self.assertEqual(files['.gitignore'].decode(), FORGE_INIT_GITIGNORE)

        consumer = files['src/HelloGk.sol'].decode()
        self.assertIn('import {GkHello} from "./gen/GkHello.sol";', consumer)
        test = files['test/HelloGk.t.sol'].decode()
        self.assertIn('import {GkVmFfiShim} from "gk-sdk/gkvm/testing/GkVmFfiShim.sol";', test)
        self.assertIn('import {GkHello} from "../src/gen/GkHello.sol";', test)
        self.assertIn('import {HelloGk} from "../src/HelloGk.sol";', test)
        readme = files['guest/README.md'].decode()
        self.assertIn('python3 lib/solidity-sdk/tools/gk build guest/hello.c', readme)
        # the verified gk-run install story: lockfile-pinned, both tiers named
        self.assertIn('cargo install --locked --path crates/gkvm --bin gk-run', readme)
        self.assertIn('--features portable-exec', readme)
        # the honesty note: emulation only today, what live execution still needs, where it is tracked
        self.assertIn('## What works today, and what does not', readme)
        self.assertIn('`requiresGuestVm`', readme)
        self.assertIn('`test/HelloGk.t.sol` asserts exactly that', readme)
        for url in ('https://github.com/gas-killer/gas-analyzer/issues/197',
                    'https://github.com/gas-killer/service/issues/451',
                    'https://github.com/BreadchainCoop/sp1-contract-call/issues/22',
                    'https://github.com/gas-killer/solidity-sdk/issues/84',
                    'https://github.com/gas-killer/solidity-sdk/pull/85'):
            self.assertIn(url, readme)
        for name, body in files.items():
            self.assertNotIn(b'{{', body, name)

        self.assertEqual([s for s, _ in actions].count('created'), 8)
        self.assertEqual([p for s, p in actions if s == 'merged'], ['foundry.toml', 'remappings.txt'])
        self.assertEqual([p for s, p in actions if s == 'kept'], ['.gitignore'])

    def test_rerun_is_a_no_op(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk = make_project(tmp)
            gk_init.init(tmp, sdk, build=False, log=quiet)
            before = snapshot(tmp)
            actions = gk_init.init(tmp, sdk, build=False, log=quiet)
            self.assertEqual(snapshot(tmp), before)
        self.assertEqual({s for s, _ in actions}, {'kept'})

    def test_never_clobbers_what_the_project_has(self):
        mine = {
            'guest/hello.c': '/* my guest */\n',
            'guest/crt/gkvm.h': '/* a pinned older crt header */\n',
            'src/HelloGk.sol': '// mine\n',
            'remappings.txt': '@oz/=lib/openzeppelin-contracts/',   # no trailing newline
            '.gitignore': 'out/\n',
        }
        toml = FORGE_INIT_TOML + '\n[profile.gkvm-ffi]\nffi = true\nfuzz = { runs = 7 }\n'
        with tempfile.TemporaryDirectory() as tmp:
            sdk = make_project(tmp, toml=toml)
            for rel, text in mine.items():
                os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
                with open(os.path.join(tmp, rel), 'w') as f:
                    f.write(text)
            gk_init.init(tmp, sdk, build=False, log=quiet)
            files = {k: v.decode() for k, v in snapshot(tmp).items()}
        for rel in ('guest/hello.c', 'guest/crt/gkvm.h', 'src/HelloGk.sol'):
            self.assertEqual(files[rel], mine[rel])
        self.assertEqual(files['foundry.toml'], toml)
        self.assertEqual(files['remappings.txt'],
                         '@oz/=lib/openzeppelin-contracts/\ngk-sdk/=lib/solidity-sdk/src/\n')
        self.assertEqual(files['.gitignore'],
                         'out/\n\n# gkvm: guest build outputs + ffi shim spill files\ncache/gkvm/\n')
        # the rest of the scaffold still lands
        self.assertIn('guest/crt/gkvm.c', files)
        self.assertIn('test/HelloGk.t.sol', files)

    def test_existing_sdk_remapping_is_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk = make_project(tmp)
            with open(os.path.join(tmp, 'remappings.txt'), 'w') as f:
                f.write('gk-sdk/=lib/somewhere-else/src/\n')
            gk_init.init(tmp, sdk, build=False, log=quiet)
            self.assertEqual(snapshot(tmp)['remappings.txt'], b'gk-sdk/=lib/somewhere-else/src/\n')

    def test_honours_the_projects_src_and_test_dirs(self):
        toml = '[profile.default]\nsrc = "contracts"\ntest = "spec/sol"\nlibs = ["lib"]\n'
        with tempfile.TemporaryDirectory() as tmp:
            sdk = make_project(tmp, toml=toml)
            gk_init.init(tmp, sdk, build=False, log=quiet)
            files = snapshot(tmp)
        self.assertIn('contracts/HelloGk.sol', files)
        test = files['spec/sol/HelloGk.t.sol'].decode()
        self.assertIn('import {GkHello} from "../../contracts/gen/GkHello.sol";', test)
        self.assertIn('import {HelloGk} from "../../contracts/HelloGk.sol";', test)
        self.assertIn('`contracts/gen/GkHello.sol`', files['guest/README.md'].decode())

    def test_refusals_write_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(gk_init.GkInitError, 'not a forge project'):
                gk_init.init(tmp, SDK_ROOT, build=False, log=quiet)
            self.assertEqual(os.listdir(tmp), [])

            # this checkout is not inside the project: forge could not compile the imports
            make_project(tmp)
            before = snapshot(tmp)
            with self.assertRaisesRegex(gk_init.GkInitError, 'not inside the project'):
                gk_init.init(tmp, SDK_ROOT, build=False, log=quiet)
            self.assertEqual(snapshot(tmp), before)
            # …unless the caller names where the project sees it
            gk_init.init(tmp, SDK_ROOT, build=False, sdk_path='lib/solidity-sdk', log=quiet)
            self.assertEqual(snapshot(tmp)['remappings.txt'], b'gk-sdk/=lib/solidity-sdk/src/\n')

        with tempfile.TemporaryDirectory() as tmp:
            sdk = make_project(tmp, toml='[profile.default\nsrc = "src"\n')
            before = snapshot(tmp)
            with self.assertRaisesRegex(gk_init.GkInitError, 'does not parse'):
                gk_init.init(tmp, sdk, build=False, log=quiet)
            self.assertEqual(snapshot(tmp), before)

        with self.assertRaisesRegex(gk_init.GkInitError, 'is the sdk itself'):
            gk_init.init(SDK_ROOT, SDK_ROOT, build=False, log=quiet)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_project(tmp)
            gk = [sys.executable, '-B', os.path.join(tmp, 'lib', 'solidity-sdk', 'tools', 'gk')]
            proc = subprocess.run(gk + ['init', tmp, '--no-build'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn(b'created   guest/hello.c', proc.stdout)
            self.assertIn(b'next: python3 lib/solidity-sdk/tools/gk build guest/hello.c', proc.stdout)
            self.assertTrue(os.path.isfile(os.path.join(tmp, 'test', 'HelloGk.t.sol')))
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.run([sys.executable, '-B', HERE, 'init', tmp],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(proc.returncode, 1)
            self.assertIn(b'gk: ', proc.stderr)
            self.assertIn(b'not a forge project', proc.stderr)


@unittest.skipUnless(HAVE_CC and FORGE, 'needs a guest compiler (or docker) and forge')
class InitEndToEnd(unittest.TestCase):
    def test_scaffold_builds_and_its_tests_pass(self):
        # docker bind mounts need a real host path (see Build); forge-std comes from this
        # checkout's lib/, as `forge init` would have installed it.
        project = os.path.join(SDK_ROOT, 'cache', 'gkvm', 'test-init')
        if os.path.isdir(project):
            shutil.rmtree(project)
        os.makedirs(project)
        sdk = make_project(project)
        os.symlink(os.path.join(SDK_ROOT, 'lib', 'forge-std'),
                   os.path.join(project, 'lib', 'forge-std'))

        actions = gk_init.init(project, sdk, log=quiet)
        self.assertEqual(actions[-1], ('built', 'src/gen/GkHello.sol'))
        with open(os.path.join(project, 'cache', 'gkvm', 'build', 'hello', 'guest.json')) as f:
            info = json.load(f)
        self.assertEqual(info['crtHash'], BUNDLED_CRT_HASH)
        with open(os.path.join(project, 'src', 'gen', 'GkHello.sol')) as f:
            binding = f.read()
        self.assertIn('import {GkVm} from "gk-sdk/gkvm/GkVm.sol";', binding)
        self.assertIn('PROGRAM_HASH = %s;' % info['programHash'], binding)
        self.assertIn('generated by `gk build` from guest/hello.c', binding)
        print('\n  gk init -> hello %s' % info['programHash'], file=sys.stderr)

        # a second init rebuilds the same guest: same bytes everywhere
        before = snapshot(project)
        gk_init.init(project, sdk, log=quiet)
        self.assertEqual(snapshot(project), before)

        def forge_test(env):
            return subprocess.run([FORGE, 'test', '--match-contract', 'HelloGkTest'], cwd=project,
                                  env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

        base = {k: v for k, v in os.environ.items()
                if k not in ('GK_RUN', 'FOUNDRY_PROFILE', 'GK_GUEST_CRT')}
        # default profile, no GK_RUN: ffi-free and green — shim tests skip, the
        # GkVmUnavailable test runs
        plain = forge_test(base)
        self.assertEqual(plain.returncode, 0, plain.stdout.decode())
        self.assertIn(b'1 passed; 0 failed; 2 skipped', plain.stdout)
        if GK_RUN:
            ffi = forge_test(dict(base, GK_RUN=GK_RUN, FOUNDRY_PROFILE='gkvm-ffi'))
            self.assertEqual(ffi.returncode, 0, ffi.stdout.decode())
            self.assertIn(b'3 passed; 0 failed; 0 skipped', ffi.stdout)
            print('  ' + ffi.stdout.decode().strip().replace('\n', '\n  '), file=sys.stderr)


def host_runtime():
    """gk_runtime.py as CPython sees it: the guest-side ABI codec is plain Python apart from
    `import gkvm`, stubbed here. Returns (module, the gkvm stub)."""
    import importlib.util
    import types
    stub = types.ModuleType('gkvm')
    stub.outputs = []
    stub.payload = b''
    stub.input = lambda: stub.payload
    stub.output = stub.outputs.append
    sys.modules['gkvm'] = stub
    try:
        spec = importlib.util.spec_from_file_location('gk_runtime', gk_python.RUNTIME)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        del sys.modules['gkvm']
    return module, stub


DOC_GUEST = '''
def main(prompt_ids: list[int], max_new: int) -> bytes:
    return b""
'''


# two parameters keep `function call(…)` on one line, so the attributes wrap and `{` lands on
# a line of its own — forge fmt lays the body out differently under that signature
BRACE_GUEST = 'def main(%s: list[int], %s: int) -> tuple[str, list[int]]:\n    pass\n'
BRACE_RAW_GUEST = 'def main(%s: int, %s: int) -> bytes:\n    pass\n'


class PythonUnits(unittest.TestCase):
    def analyze(self, text):
        return gk_python.analyze(text, 'answer.py')

    def test_the_docs_example(self):
        sig = self.analyze(DOC_GUEST)
        self.assertEqual(sig, {'params': [('prompt_ids', 'promptIds', 'uint256[]'),
                                          ('max_new', 'maxNew', 'uint256')],
                               'returns': None})
        sol = gk_python.render_binding('GkAnswer', '0x' + 'ab' * 32, 'guest/answer.py',
                                       '../gkvm/GkVm.sol', sig)
        # the doc's binding (UNBOUNDED_V3_NATIVE.md § Writing programs), as forge fmt wraps it
        self.assertIn(
            '    function call(address gkvm, bytes32 artifactRoot, uint256[] memory promptIds, '
            'uint256 maxNew)\n        internal\n        view\n        returns (bytes memory)\n    {\n',
            sol)
        # the doc's body line verbatim; no locals — see render_binding on solc's stack depth
        self.assertIn('        return GkVm.exec(gkvm, PROGRAM_HASH, artifactRoot, '
                      'abi.encode(promptIds, maxNew));\n', sol)
        self.assertNotIn('bytes memory payload', sol)
        self.assertEqual(
            gk_python.render_entry('answer', sig),
            '# gk_entry.py — generated by `gk build` from answer.py, do not edit\n'
            'import gk_runtime\nfrom answer import main\n\n'
            "gk_runtime.run(main, ('uint256[]', 'uint256'), None)\n")

    def test_type_map(self):
        sig = self.analyze('def main(a: int, b: bool, c: bytes, d: str, e: list[list[str]], '
                           'f: "list[int]") -> tuple[str, list[bytes]]:\n    pass\n')
        self.assertEqual([t for _, _, t in sig['params']],
                         ['uint256', 'bool', 'bytes', 'string', 'string[][]', 'uint256[]'])
        self.assertEqual(sig['returns'], ('string', 'bytes[]'))
        self.assertEqual(self.analyze('def main() -> int:\n    return 1\n'),
                         {'params': [], 'returns': ('uint256',)})
        sol = gk_python.render_binding('GkX', '0x' + '00' * 32, 'x.py', './GkVm.sol', sig)
        self.assertIn('returns (string memory, bytes[] memory)', sol)
        # layout (one line or wrapped) is forge fmt's business — the fmt test below holds it
        self.assertIn('returnabi.decode(GkVm.exec(gkvm,PROGRAM_HASH,artifactRoot,'
                      'abi.encode(a,b,c,d,e,f)),(string,bytes[]));', ''.join(sol.split()))
        self.assertIn('string[][] memory e', sol)
        none = gk_python.render_binding('GkX', '0x' + '00' * 32, 'x.py', './GkVm.sol',
                                        {'params': [], 'returns': None})
        self.assertIn('return GkVm.exec(gkvm, PROGRAM_HASH, artifactRoot, new bytes(0));', none)

    def test_a_script_without_main_is_raw(self):
        self.assertIsNone(self.analyze('import gkvm\ngkvm.output(gkvm.input())\n'))
        # only a TOP-LEVEL main is the typed contract
        self.assertIsNone(self.analyze('class A:\n    def main(self):\n        pass\n'))

    def test_floats_are_rejected_at_build_time(self):
        for text, pattern in (
                ('def main(x: float) -> bytes:\n    pass\n', r'answer\.py:1: `float`'),
                ('def main() -> list[float]:\n    pass\n', r'answer\.py:1: `float`'),
                ('import gkvm\n\nx = 1.5\n', r'answer\.py:3: float literal 1\.5'),
                ('a = 1\nb = a / 2\n', r'answer\.py:2: true division'),
                ('a = 4\na /= 2\n', r'answer\.py:2: true division'),
                ('z = 2j\n', r'answer\.py:1: float literal'),
                ('def f(v):\n    return float(v)\n', r'answer\.py:2: `float`')):
            with self.assertRaisesRegex(gk_python.GkPythonError, pattern):
                self.analyze(text)
        self.assertIsNone(self.analyze('a = 7 // 2\nb = "1.5 / 2"\n'))

    def test_a_main_gk_cannot_bind_is_refused(self):
        for text, pattern in (
                ('def main(x) -> bytes:\n    pass\n', 'parameter `x` has no type hint'),
                ('def main(x: int):\n    pass\n', 'no return type hint'),
                ('def main(x: int) -> None:\n    pass\n', 'must return its answer'),
                ('def main(*xs: int) -> bytes:\n    pass\n', 'plain positional'),
                ('def main(x: int = 3) -> bytes:\n    pass\n', 'plain positional'),
                ('async def main() -> bytes:\n    pass\n', 'cannot be async'),
                ('def main(x: dict) -> bytes:\n    pass\n', 'unsupported type hint `dict`'),
                ('def main(x: list[int, int]) -> bytes:\n    pass\n', 'unsupported type hint'),
                ('def main(x: tuple[int, int]) -> bytes:\n    pass\n', 'unsupported type hint'),
                ('def main(a_b: int, aB: int) -> bytes:\n    pass\n', 'one Solidity name'),
                ('def main() -> bytes:\n    pass\ndef main() -> bytes:\n    pass\n', 'twice'),
                ('def main(:\n', r'answer\.py:1')):
            with self.assertRaisesRegex(gk_python.GkPythonError, pattern):
                self.analyze(text)

    def test_parameter_names(self):
        self.assertEqual(gk_python.sol_param_name('prompt_ids'), 'promptIds')
        self.assertEqual(gk_python.sol_param_name('_x'), 'x')
        for clash in ('gkvm', 'payload', 'address', 'memory', 'uint8', 'bytes32'):
            self.assertEqual(gk_python.sol_param_name(clash), clash + '_')
        self.assertEqual(gk_python.sol_param_name('artifact_root'), 'artifactRoot_')

    def test_module_names(self):
        gk_python.check_stem('answer', True)
        gk_python.check_stem('my-guest', False)
        for stem in ('my-guest', 'json', 'gk_runtime', 'gk_entry', '2fast'):
            with self.assertRaises(gk_python.GkPythonError):
                gk_python.check_stem(stem, True)
        with self.assertRaises(gk_python.GkPythonError):
            gk_python.check_stem('a b', False)

    def test_script_errors_surface_as_build_errors_before_any_toolchain(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, 'answer.py')
            with open(src, 'w') as f:
                f.write('def main(x: float) -> bytes:\n    pass\n')
            with self.assertRaisesRegex(gk_build.GkBuildError, 'no floats'):
                gk_build.build(src, SDK_ROOT, out=os.path.join(tmp, 'out'), log=quiet)
            self.assertFalse(os.path.exists(os.path.join(tmp, 'out')))

    def test_bundled_port_and_runtime_are_pinned(self):
        # Both are linked/frozen into every Python guest, so their bytes are part of every
        # programHash. The port changes only by re-syncing from gas-analyzer (`make
        # port-check`); gk_runtime.py is the sdk's own — re-pin deliberately.
        port = b''.join(gk_build._read(os.path.join(gk_python.BUNDLED_PORT, f))
                        for f in gk_python.PORT_FILES)
        self.assertEqual(hex32(keccak256_pure(port)), BUNDLED_PORT_HASH)
        self.assertEqual(hex32(keccak256_pure(gk_build._read(gk_python.RUNTIME))), RUNTIME_HASH)

    def test_runtime_codec_against_solc_made_bytes(self):
        rt, _ = host_runtime()
        # the golden hello-c vector's payload = solc's abi.encode(uint256(7), "prompt")
        payload = bytes.fromhex(
            '%064x%064x%064x' % (7, 0x40, 6) + b'prompt'.hex() + '00' * 26)
        self.assertEqual(rt.decode(payload, ('uint256', 'string')), [7, 'prompt'])
        self.assertEqual(rt.encode((7, 'prompt'), ('uint256', 'string')), payload)
        # abi.encode(uint256[] [1, 2, 3], uint256 7), by hand
        payload = bytes.fromhex(''.join('%064x' % w for w in (0x40, 7, 3, 1, 2, 3)))
        self.assertEqual(rt.decode(payload, ('uint256[]', 'uint256')), [[1, 2, 3], 7])
        self.assertEqual(rt.encode(([1, 2, 3], 7), ('uint256[]', 'uint256')), payload)

    def test_runtime_codec_round_trips_nested_values(self):
        rt, _ = host_runtime()
        types = ('uint256[][]', 'bool', 'bytes', 'string[]', 'uint256', 'bytes[]')
        values = [[[1, 2], [], [(1 << 256) - 1]], True, b'\x00' * 33, ['', 'héllo'], 0,
                  [b'', b'x' * 32]]
        blob = rt.encode(values, types)
        self.assertEqual(len(blob) % 32, 0)
        self.assertEqual(rt.decode(blob, types), values)

    def test_runtime_refuses_malformed_payloads_and_wrong_returns(self):
        rt, _ = host_runtime()
        word = lambda v: bytes.fromhex('%064x' % v)  # noqa: E731
        for payload, types in ((b'\x01', ('uint256',)),
                               (word(2), ('bool',)),
                               (word(0x20) + word(1 << 200), ('uint256[]',)),
                               (word(0x20) + word(64) + b'short', ('bytes',)),
                               (word(1 << 255), ('string',))):
            with self.assertRaises(ValueError, msg=(payload, types)):
                rt.decode(payload, types)
        for values, types in (((-1,), ('uint256',)), ((1 << 256,), ('uint256',))):
            with self.assertRaises(ValueError):
                rt.encode(values, types)
        for values, types in (((True,), ('uint256',)), ((1,), ('bool',)), (('x',), ('bytes',)),
                              ((b'x',), ('string',)), ((7,), ('uint256[]',)), ((1, 2), ('uint256',))):
            with self.assertRaises(TypeError):
                rt.encode(values, types)

    def test_runtime_run(self):
        rt, gkvm = host_runtime()
        gkvm.payload = rt.encode(([1, 2, 3], 7), ('uint256[]', 'uint256'))
        rt.run(lambda ids, n: bytes(ids) * n, ('uint256[]', 'uint256'), None)
        rt.run(lambda ids, n: sum(ids) + n, ('uint256[]', 'uint256'), ('uint256',))
        rt.run(lambda ids, n: ('a', ids), ('uint256[]', 'uint256'), ('string', 'uint256[]'))
        self.assertEqual(gkvm.outputs, [b'\x01\x02\x03' * 7, rt.encode((13,), ('uint256',)),
                                        rt.encode(('a', [1, 2, 3]), ('string', 'uint256[]'))])
        with self.assertRaises(TypeError):
            rt.run(lambda ids, n: 'not bytes', ('uint256[]', 'uint256'), None)

    @unittest.skipUnless(FORGE, 'needs forge')
    def test_generated_bindings_are_forge_fmt_clean(self):
        out = os.path.join(SDK_ROOT, 'cache', 'gkvm', 'test-pyfmt')
        if os.path.isdir(out):
            shutil.rmtree(out)
        os.makedirs(out)
        guests = {
            'Short': 'def main(n: int) -> int:\n    pass\n',
            'Doc': DOC_GUEST,
            'Wide': 'def main(first_list: list[int], second_list: list[list[int]], a_flag: bool, '
                    'some_bytes: bytes, the_name: str) -> tuple[str, list[int], bool]:\n    pass\n',
            'None': 'def main() -> bytes:\n    pass\n',
            # the body's layouts: exec(...) on one line at the limit / one argument per line,
            # raw and decoded; then a returns list long enough to wrap on its own
            'RawEdge': 'def main(first_list: list[int], second_list: list[list[int]], a_flag: bool, '
                       'some_bytes: bytes, the_name: str) -> bytes:\n    pass\n',
            # one character past RawEdge: exec( / all arguments on one line / )
            'RawEdge1': 'def main(first_list: list[int], second_list: list[list[int]], a_flag: bool, '
                        'some_bytes: bytes, the_namee: str) -> bytes:\n    pass\n',
            'RawLong': 'def main(first_list: list[int], second_list: list[list[int]], a_flag: bool, '
                       'some_bytes: bytes, the_name: str, another_long_name: str, '
                       'yet_another_long_name: str) -> bytes:\n    pass\n',
            'DecodeEdge': 'def main(a: int, b: bool, c: bytes, d: str, e: list[list[str]], '
                          'f: list[int]) -> tuple[str, list[bytes]]:\n    pass\n',
            # one character past DecodeEdge: 120 columns before the `;`
            'DecodeEdge1': 'def main(a: int, b: bool, c: bytes, d: str, e: list[list[str]], '
                           'ff: list[int]) -> tuple[str, list[bytes]]:\n    pass\n',
            # past it, under a `) internal view returns (…) {` signature: abi.decode( / both
            # arguments on one line / ) — up to 120 columns of them (f × 17), then one per line
            'DecodeArgs1': 'def main(a: int, b: bool, c: bytes, d: str, e: list[list[str]], '
                           'fff: list[int]) -> tuple[str, list[bytes]]:\n    pass\n',
            'DecodeArgsEdge': 'def main(a: int, b: bool, c: bytes, d: str, e: list[list[str]], '
                              '%s: list[int]) -> tuple[str, list[bytes]]:\n    pass\n' % ('f' * 17),
            'DecodeArgsEdge1': 'def main(a: int, b: bool, c: bytes, d: str, e: list[list[str]], '
                               '%s: list[int]) -> tuple[str, list[bytes]]:\n    pass\n' % ('f' * 18),
            # under a signature that left `{` on its own line (what the sdk's onchain-llm-native
            # answer.py gets), by the two names' total length: 13 = one line at the limit;
            # 14, 15 = `return` alone with the whole decode under it (15 = 120 columns WITH its
            # `;`); 16 = back to abi.decode( / arguments / ); 28 = 120 columns of arguments;
            # 29 = one per line
            'BraceEdge': BRACE_GUEST % ('a' * 7, 'b' * 6),
            'BraceUnder1': BRACE_GUEST % ('a' * 7, 'b' * 7),
            'BraceUnder2': BRACE_GUEST % ('a' * 8, 'b' * 7),
            'BraceArgs': BRACE_GUEST % ('a' * 8, 'b' * 8),
            'BraceArgsEdge': BRACE_GUEST % ('a' * 14, 'b' * 14),
            'BraceArgsEdge1': BRACE_GUEST % ('a' * 15, 'b' * 14),
            # the raw return under the same signature, one and two columns past the line:
            # `return` alone as well (forge 1.5.1 refused exec( / arguments / ) for the first)
            'BraceRaw1': BRACE_RAW_GUEST % ('a' * 24, 'b' * 23),
            'BraceRaw2': BRACE_RAW_GUEST % ('a' * 24, 'b' * 24),
            # the wrapped decode's inner exec(...) line: 120 columns before its `,`
            'CommaEdge': 'def main(%s: int, %s: int, %s: int) -> tuple[str, list[int], bool]:\n'
                         '    pass\n' % ('a' * 16, 'b' * 16, 'c' * 15),
            'DecodeLong': 'def main(first_list: list[int], second_list: list[list[int]], a_flag: bool, '
                          'some_bytes: bytes, the_name: str, another_long_name: str, '
                          'yet_another_long_name: str) -> tuple[str, list[int], bool]:\n    pass\n',
            'Returns': 'def main(n: int) -> tuple[str, list[int], bool, list[bytes], int, '
                       'list[list[str]], list[list[str]], list[list[str]], list[list[int]]]:\n'
                       '    pass\n',
        }
        paths = []
        for name, text in guests.items():
            paths.append(os.path.join(out, 'Gk%s.sol' % name))
            with open(paths[-1], 'w') as f:
                f.write(gk_python.render_binding('Gk' + name, '0x' + 'ab' * 32, 'x.py',
                                                 '../../../src/gkvm/GkVm.sol',
                                                 self.analyze(text)))
        fmt = subprocess.run([FORGE, 'fmt', '--check'] + paths, cwd=SDK_ROOT,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(fmt.returncode, 0, fmt.stdout.decode())


GK_MPY_SRC = os.environ.get('GK_MPY_SRC')
HAVE_DOCKER = bool(shutil.which('docker'))

# gas-analyzer crates/gkvm/guest/micropython/hello.py, byte for byte: the raw script whose
# image gas-analyzer commits as tests/fixtures/hello-py.elf and pins by programHash.
HELLO_PY = b'''# hello: the Python twin of guest/hello/hello.c \xe2\x80\x94 a fixed tag followed by the
# payload reversed. Same bytes out as hello-c.elf and hello-rs.elf, so one
# expected answer checks the third toolchain too.
import gkvm

payload = gkvm.input()
gkvm.output(b"GKVM-HELLO-V1\\n")
gkvm.output(bytes(reversed(payload)))
'''
HELLO_PY_PROGRAM_HASH = '0x951aafd594c660f21820e50d98df0eb61d5d32d663212cf6f2408bd1cd145443'
HELLO_PY_CYCLES = 593442


@unittest.skipUnless(GK_MPY_SRC and HAVE_DOCKER,
                     'GK_MPY_SRC not set (MicroPython at the pinned commit), or no docker')
class PythonBuild(unittest.TestCase):
    base = os.path.join(SDK_ROOT, 'cache', 'gkvm', 'test-pybuild')

    def test_raw_hello_is_gas_analyzers_committed_image(self):
        # Same script + same port + same crt + same recipe => the very ELF gas-analyzer's
        # own `make docker` built and committed. This is what holds the bundled port, the
        # staging and the docker leg to the reference build.
        if GK_GUEST_CRT:
            self.assertEqual(
                gk_build._read(os.path.join(GK_GUEST_CRT, 'micropython', 'hello.py')), HELLO_PY)
        out = os.path.join(self.base, 'hello')
        os.makedirs(out, exist_ok=True)
        source = os.path.join(out, 'hello.py')
        with open(source, 'wb') as f:
            f.write(HELLO_PY)
        info = gk_build.build(source, SDK_ROOT, out=out, sol_out=os.path.join(out, 'gen'),
                              crt=gk_build.BUNDLED_CRT, mpy_src=GK_MPY_SRC, compiler='docker',
                              log=quiet)
        print('\n  gk build hello.py -> %s (%s)' % (info['programHash'], info['cc']),
              file=sys.stderr)
        self.assertEqual(info['programHash'], HELLO_PY_PROGRAM_HASH)
        self.assertEqual(info['guest'], 'python-raw')
        self.assertEqual(info['portHash'], BUNDLED_PORT_HASH)
        self.assertNotIn('runtimeHash', info)
        with open(os.path.join(out, 'gen', 'GkHello.sol')) as f:
            self.assertIn('bytes memory payload) internal view', f.read())
        if GK_RUN:
            v = gk_vectors.vectors(os.path.join(out, 'guest.elf'), ['0x11223344'], gk_run=GK_RUN,
                                   out=os.path.join(out, 'v.json'), sdk_root=out,
                                   log=quiet)['vectors'][0]
            self.assertEqual((v['stdout'], v['cycles']), (HELLO_11223344, HELLO_PY_CYCLES))

    def test_what_micropython_cannot_compile_fails_the_build_with_its_message(self):
        # CPython parses `match`; mpy-cross (MicroPython 1.29) does not
        out = os.path.join(self.base, 'nomatch')
        os.makedirs(out, exist_ok=True)
        source = os.path.join(out, 'nomatch.py')
        with open(source, 'w') as f:
            f.write('import gkvm\n\nmatch gkvm.input():\n    case _:\n        pass\n')
        with self.assertRaisesRegex(gk_build.GkBuildError, 'SyntaxError'):
            gk_build.build(source, SDK_ROOT, out=out, crt=gk_build.BUNDLED_CRT,
                           mpy_src=GK_MPY_SRC, compiler='docker', emit_binding=False, log=quiet)
        self.assertFalse(os.path.exists(os.path.join(out, 'guest.elf')))

    def test_typed_build_is_reproducible_and_answers(self):
        source = os.path.join(HERE, 'testdata', 'answer.py')
        infos = []
        for leg in ('a', 'b'):
            out = os.path.join(self.base, 'answer-' + leg)
            infos.append(gk_build.build(source, SDK_ROOT, out=out,
                                        sol_out=os.path.join(out, 'gen'),
                                        crt=gk_build.BUNDLED_CRT, mpy_src=GK_MPY_SRC,
                                        compiler='docker', log=quiet))
        a, b = infos
        self.assertEqual(a, b)
        self.assertNotEqual(a['programHash'], HELLO_PY_PROGRAM_HASH)
        self.assertEqual(a['guest'], 'python-typed')
        self.assertEqual(a['runtimeHash'], RUNTIME_HASH)
        self.assertEqual(a['signature']['params'][0],
                         {'name': 'prompt_ids', 'solName': 'promptIds', 'type': 'uint256[]'})
        print('\n  gk build answer.py -> %s, %d bytes' % (a['programHash'], a['elfBytes']),
              file=sys.stderr)
        if GK_RUN:
            rt, _ = host_runtime()
            elf = os.path.join(self.base, 'answer-a', 'guest.elf')
            payloads = [rt.encode(([7, 65000], 3), ('uint256[]', 'uint256')),
                        rt.encode(([], 65), ('uint256[]', 'uint256')), b'\x01']
            ok, raised, malformed = gk_vectors.vectors(
                elf, ['0x' + p.hex() for p in payloads], gk_run=GK_RUN,
                out=os.path.join(self.base, 'answer-a', 'v.json'), sdk_root=self.base,
                log=quiet)['vectors']
            acc, want = 0, b''
            for t in (7, 65000):
                acc = (acc * 31 + t) % 65521
            for i in range(3):
                acc = (acc * 31 + i) % 65521
                want += acc.to_bytes(4, 'big')
            self.assertEqual((ok['outcome'], ok['stdout']), ('ok', '0x' + want.hex()))
            print('  answer.py ([7, 65000], 3) -> %s, %d cycles' % (ok['stdout'], ok['cycles']),
                  file=sys.stderr)
            # uncaught ValueError / undecodable payload: the port's 0xD0000001 trap, traceback
            # in the frame — raised from main() and from gk_runtime respectively
            for v, needle in ((raised, b'answer: max_new > 64'), (malformed, b'abi: payload truncated')):
                self.assertEqual(v['outcome'], 'trap')
                frame = bytes.fromhex(v['stdout'][2:])
                self.assertEqual(frame[:4], bytes.fromhex('d0000001'))
                self.assertIn(needle, frame)


@unittest.skipUnless(os.environ.get('GK_TEST_FETCH'),
                     'network: `make test GK_TEST_FETCH=1 TESTS=PythonFetch` clones MicroPython')
class PythonFetch(unittest.TestCase):
    def test_default_source_is_cloned_at_the_pin_and_held_to_it(self):
        root = os.path.join(SDK_ROOT, 'cache', 'gkvm', 'test-pyfetch')
        if os.path.isdir(root):
            shutil.rmtree(root)
        env = os.environ.pop('GK_MPY_SRC', None)
        try:
            src = gk_python.resolve_mpy_src(None, root, log=quiet)
            self.assertEqual(src, os.path.join(root, 'cache', 'gkvm', 'micropython', 'src'))
            self.assertEqual(gk_python.resolve_mpy_src(None, root, log=quiet), src)  # no re-clone
            # untracked build outputs are fine (mpy-cross/build lands in the tree) …
            os.makedirs(os.path.join(src, 'mpy-cross', 'build'))
            gk_python.check_pin(src)
            # … a modified interpreter is not
            with open(os.path.join(src, 'py', 'gc.c'), 'a') as f:
                f.write('/* tampered */\n')
            with self.assertRaisesRegex(gk_python.GkPythonError, 'local modifications'):
                gk_python.resolve_mpy_src(src, root, log=quiet)
        finally:
            if env is not None:
                os.environ['GK_MPY_SRC'] = env


@unittest.skipUnless(GK_MPY_SRC and HAVE_DOCKER and FORGE and GK_RUN,
                     'needs GK_MPY_SRC, docker, forge and GK_RUN')
class PythonEndToEnd(unittest.TestCase):
    def test_generated_bindings_drive_the_guests_through_forge(self):
        # `gk init` project + two Python guests built into it; then solc's abi.encode ->
        # gk_runtime -> main() -> gk_runtime -> solc's abi.decode under the ffi shim.
        project = os.path.join(SDK_ROOT, 'cache', 'gkvm', 'test-pye2e')
        if os.path.isdir(project):
            shutil.rmtree(project)
        os.makedirs(project)
        sdk = make_project(project)
        os.symlink(os.path.join(SDK_ROOT, 'lib', 'forge-std'),
                   os.path.join(project, 'lib', 'forge-std'))
        gk_init.init(project, sdk, log=quiet)
        for guest in ('answer.py', 'alltypes.py'):
            shutil.copyfile(os.path.join(HERE, 'testdata', guest),
                            os.path.join(project, 'guest', guest))
            info = gk_build.build(os.path.join(project, 'guest', guest), sdk, project=project,
                                  mpy_src=GK_MPY_SRC, compiler='docker', log=quiet)
            print('\n  gk build %s -> %s' % (guest, info['programHash']), file=sys.stderr)
        shutil.copyfile(os.path.join(HERE, 'testdata', 'PyGuests.t.sol'),
                        os.path.join(project, 'test', 'PyGuests.t.sol'))

        fmt = subprocess.run([FORGE, 'fmt', '--check', 'src/gen'], cwd=project,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(fmt.returncode, 0, fmt.stdout.decode())
        env = dict(os.environ, GK_RUN=GK_RUN, FOUNDRY_PROFILE='gkvm-ffi')
        env.pop('GK_GUEST_CRT', None)
        ffi = subprocess.run([FORGE, 'test', '--match-contract', 'PyGuestsTest'], cwd=project,
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print('  ' + ffi.stdout.decode().strip().replace('\n', '\n  '), file=sys.stderr)
        self.assertEqual(ffi.returncode, 0)
        self.assertIn(b'4 passed; 0 failed; 0 skipped', ffi.stdout)


if __name__ == '__main__':
    unittest.main()
