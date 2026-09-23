"""`gk init` — scaffold a gkvm guest INTO an existing forge project (UNBOUNDED_V3 L3).

    forge init my-project && cd my-project
    forge install gas-killer/solidity-sdk            # -> lib/solidity-sdk
    python3 lib/solidity-sdk/tools/gk init

What lands in the project: the vendored gk-guest-crt (guest/crt/, guest/link.ld), an example
guest (guest/hello.c), its generated binding, a sample consumer, a test wired to GkVmFfiShim,
a quickstart (guest/README.md), and three merges — `[profile.gkvm-ffi]` into foundry.toml,
the `gk-sdk/` remapping into remappings.txt, `cache/gkvm/` into .gitignore.

Two rules:

  - never clobber: a file that exists is left alone (reported `kept`), a config section or
    line that exists is left alone — so re-running is safe and idempotent, and a project's
    own edits to the scaffold survive it;
  - nothing half-done: everything that can refuse (not a forge project, sdk outside the
    project, no compiler) refuses BEFORE the first write.

The only file rewritten on a re-run is the generated binding (`gk build` owns it; same
guest + crt + compiler -> same bytes).
"""
import os
import re
import shutil

import gk_build

TEMPLATES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'templates')

GUEST_DIR = gk_build.PROJECT_CRT_DIR
EXAMPLE_GUEST = 'hello.c'
CONSUMER = 'HelloGk.sol'
CONSUMER_TEST = 'HelloGk.t.sol'

# `gk init --python`: the same scaffold around a typed Python guest
EXAMPLES = {
    False: {'guest': 'hello.c', 'stem': 'hello', 'consumer': 'HelloGk.sol',
            'test': 'HelloGk.t.sol', 'contract': 'HelloGkTest',
            'desc': 'example guest: answers `"GKVM-HELLO-V1\\n"` + the payload reversed',
            'lang': 'C'},
    True: {'guest': 'greet.py', 'stem': 'greet', 'consumer': 'GreetGk.sol',
           'test': 'GreetGk.t.sol', 'contract': 'GreetGkTest',
           'desc': 'example guest: a typed Python function, `main(name: str, times: int) -> str`',
           'lang': 'Python'},
}

FFI_PROFILE = 'gkvm-ffi'
FFI_PROFILE_BLOCK = '''\
# TEST ONLY — gkvm ffi shim (%(remap)sgkvm/testing/GkVmFfiShim.sol): shells out to the `gk-run`
# sidecar. `ffi = true` lives here and nowhere else; the shim-backed tests skip themselves
# unless GK_RUN names the binary:  GK_RUN=/path/to/gk-run FOUNDRY_PROFILE=gkvm-ffi forge test
# NOTE: a profile's fs_permissions REPLACE the default profile's — add your own entries here.
[profile.gkvm-ffi]
ffi = true
# ./cache/gkvm: guest ELFs from `gk build` + spill files for payloads too large for one argv
fs_permissions = [{ access = "read-write", path = "./cache/gkvm" }]
'''

GITIGNORE_ENTRY = 'cache/gkvm/'
GITIGNORE_BLOCK = '# gkvm: guest build outputs + ffi shim spill files\n%s\n' % GITIGNORE_ENTRY
# an existing line that already ignores cache/gkvm (forge init's own .gitignore has `cache/`)
_GITIGNORE_COVERS = {p + s for p in ('cache', '/cache', 'cache/gkvm', '/cache/gkvm')
                     for s in ('', '/')}


class GkInitError(Exception):
    pass


def _read(path):
    with open(path) as f:
        return f.read()


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(text)


def _append(path, block):
    """Append `block` as its own paragraph; creates the file when absent."""
    old = _read(path) if os.path.isfile(path) else ''
    if old and not old.endswith('\n'):
        old += '\n'
    _write(path, old + ('\n' if old else '') + block)


def _posix(path):
    return path.replace(os.sep, '/')


def _sol_rel(target, from_dir):
    rel = _posix(os.path.relpath(target, from_dir))
    return rel if rel.startswith('.') else './' + rel


def render(template, values):
    text = _read(os.path.join(TEMPLATES, template + '.tmpl'))
    for key, value in values.items():
        text = text.replace('{{%s}}' % key, value)
    left = re.search(r'\{\{[A-Z_]+\}\}', text)
    if left:
        raise GkInitError('template %s: unfilled placeholder %s' % (template, left.group(0)))
    return text


def has_ffi_profile(toml_text):
    try:
        import tomllib
        return FFI_PROFILE in tomllib.loads(toml_text).get('profile', {})
    except ImportError:
        return re.search(r'^\s*\[profile\.%s\]' % re.escape(FFI_PROFILE), toml_text, re.M) is not None
    except ValueError as e:
        raise GkInitError('foundry.toml does not parse (%s); fix it first — gk init will not '
                          'append to a file it cannot read' % e)


def resolve_sdk_path(project, sdk_root, sdk_path=None):
    """The sdk's location as the project's remapping will spell it (posix, project-relative)."""
    if sdk_path:
        if not os.path.isfile(os.path.join(project, sdk_path, 'src', 'gkvm', 'GkVm.sol')):
            raise GkInitError('--sdk-path %s: no src/gkvm/GkVm.sol under it' % sdk_path)
        return _posix(os.path.normpath(sdk_path))
    rel = os.path.relpath(os.path.abspath(sdk_root), project)
    if rel == '.' or rel.startswith('..'):
        raise GkInitError(
            'the sdk (%s) is not inside the project (%s): forge only compiles what lives under '
            'the project root. Install it first (`forge install gas-killer/solidity-sdk`, or '
            'clone it into lib/solidity-sdk) and run the installed copy: '
            '`python3 lib/solidity-sdk/tools/gk init` — or name that copy with --sdk-path'
            % (os.path.abspath(sdk_root), project))
    return _posix(rel)


def init(project, sdk_root, crt=None, compiler='auto', build=True, sdk_path=None, log=print,
         python=False):
    """Scaffold into `project`. Returns [(status, project-relative path)], in write order;
    status is created | kept | merged | built."""
    example = EXAMPLES[bool(python)]
    project = os.path.abspath(project)
    toml_path = os.path.join(project, 'foundry.toml')
    if not os.path.isfile(toml_path):
        raise GkInitError('%s is not a forge project (no foundry.toml): run `forge init` first'
                          % project)
    if os.path.realpath(project) == os.path.realpath(sdk_root):
        raise GkInitError('%s is the sdk itself; gk init scaffolds into a project that '
                          'installed it' % project)

    # ---- everything that can refuse, before the first write
    sdk_rel = resolve_sdk_path(project, sdk_root, sdk_path)
    toml_text = _read(toml_path)
    ffi_profile_present = has_ffi_profile(toml_text)
    if build:
        try:
            compiler = gk_build.check_compiler(compiler, prefer_docker=bool(python))
        except gk_build.GkBuildError as e:
            raise GkInitError('%s — install one, or scaffold without building: gk init '
                              '--no-build' % e)
    try:
        crt_src = gk_build.resolve_crt(crt)
    except gk_build.GkBuildError as e:
        raise GkInitError(str(e))

    src_dir, test_dir = gk_build.forge_dirs(project)
    binding = os.path.join(project, src_dir, 'gen',
                           gk_build.binding_name(example['stem']) + '.sol')
    consumer = os.path.join(project, src_dir, example['consumer'])
    consumer_test = os.path.join(project, test_dir, example['test'])
    values = {
        'SDK_PATH': sdk_rel,
        'SDK_REMAP': gk_build.SDK_REMAP_PREFIX,
        'SRC': _posix(src_dir),
        'TEST': _posix(test_dir),
        'EXAMPLE_GUEST': example['guest'],
        'EXAMPLE_DESC': example['desc'],
        'EXAMPLE_LANG': example['lang'],
        'BINDING_NAME': gk_build.binding_name(example['stem']),
        'CONSUMER': example['consumer'],
        'CONSUMER_TEST': example['test'],
        'TEST_CONTRACT': example['contract'],
    }

    actions = []

    def note(status, path):
        rel = _posix(os.path.relpath(path, project))
        actions.append((status, rel))
        log('  %-9s %s' % (status, rel))

    def create(path, text):
        if os.path.exists(path):
            note('kept', path)
        else:
            _write(path, text)
            note('created', path)

    # ---- vendored crt (byte copies: the crt is part of every programHash) + example guest
    for f in gk_build.CRT_FILES:
        dst = os.path.join(project, GUEST_DIR, f)
        if os.path.exists(dst):
            note('kept', dst)
        else:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(crt_src, f), dst)
            note('created', dst)
    create(os.path.join(project, GUEST_DIR, example['guest']),
           render(example['guest'], values))
    create(os.path.join(project, GUEST_DIR, 'README.md'), render('README.md', values))

    # ---- sample consumer + shim-wired test
    create(consumer, render(example['consumer'], dict(
        values, BINDING_IMPORT=_sol_rel(binding, os.path.dirname(consumer)))))
    create(consumer_test, render(example['test'], dict(
        values,
        BINDING_IMPORT=_sol_rel(binding, os.path.dirname(consumer_test)),
        CONSUMER_IMPORT=_sol_rel(consumer, os.path.dirname(consumer_test)))))

    # ---- merges: append what is missing, never rewrite what is there
    if ffi_profile_present:
        note('kept', toml_path)
    else:
        _append(toml_path, FFI_PROFILE_BLOCK % {'remap': gk_build.SDK_REMAP_PREFIX})
        note('merged', toml_path)

    remap_path = os.path.join(project, 'remappings.txt')
    existing = gk_build.sdk_remapping(project)
    wanted = '%s=%s/src/' % (gk_build.SDK_REMAP_PREFIX, sdk_rel)
    if existing:
        note('kept', remap_path)
        if existing != wanted:
            log('            (it says `%s`; this sdk would be `%s`)' % (existing, wanted))
    else:
        _append_line(remap_path, wanted)
        note('merged', remap_path)

    ignore_path = os.path.join(project, '.gitignore')
    ignored = os.path.isfile(ignore_path) and any(
        line.strip() in _GITIGNORE_COVERS for line in _read(ignore_path).splitlines())
    if ignored:
        note('kept', ignore_path)
    else:
        _append(ignore_path, GITIGNORE_BLOCK)
        note('merged', ignore_path)

    # ---- the binding: only a build knows the programHash
    guest = os.path.join(project, GUEST_DIR, example['guest'])
    if build:
        gk_build.build(guest, sdk_root, crt=os.path.join(project, GUEST_DIR), compiler=compiler,
                       sol_out=os.path.dirname(binding), log=log, project=project)
        actions.append(('built', _posix(os.path.relpath(binding, project))))
        log('next: `gk test` (or GK_RUN=/path/to/gk-run FOUNDRY_PROFILE=%s forge test) — see '
            '%s/README.md' % (FFI_PROFILE, GUEST_DIR))
    elif not os.path.isfile(binding):
        log('next: python3 %s/tools/gk build %s/%s   (until then `forge build` fails: %s '
            'imports the binding that build generates)'
            % (sdk_rel, GUEST_DIR, example['guest'], _posix(os.path.relpath(consumer, project))))
    return actions


def _append_line(path, line):
    """remappings.txt is line-oriented: no blank separator, no comment syntax."""
    old = _read(path) if os.path.isfile(path) else ''
    if old and not old.endswith('\n'):
        old += '\n'
    _write(path, old + line + '\n')
