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

    def test_python_guest_rejected_with_pointer(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, 'answer.py')
            open(src, 'w').close()
            with self.assertRaisesRegex(gk_build.GkBuildError, 'M5'):
                gk_build.build(src, SDK_ROOT, out=tmp, log=quiet)

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


if __name__ == '__main__':
    unittest.main()
