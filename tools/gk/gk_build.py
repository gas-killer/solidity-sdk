"""`gk build` — guest source -> guest.elf -> programHash -> Solidity binding.

C guests (UNBOUNDED_V3 M2) build here; Python guests (M5: mpy-cross freeze into
the MicroPython gkvm port, binding generated from main()'s type hints) share
this entry point and the outputs, the path itself is gk_python.py.

programHash = keccak256(guest.elf), so the build must be a pure function of
(guest source, gk-guest-crt, compiler, flags). Two things make it one:

  - a staged build tree: sources are copied to a fixed relative layout
    (crt/, guest/, link.ld) and compiled from inside it with relative paths,
    so no host path can leak into the ELF (`.file` symbols, etc.);
  - the pinned flag set below, kept identical to gas-analyzer's
    crates/gkvm/guest/Makefile (the M1 fixtures' recipe).

The compiler itself is `riscv64-unknown-elf-gcc`; hosts without it build inside
ubuntu:24.04 (gcc-riscv64-unknown-elf 13.2.0 — the toolchain M1 validated
against the SP1 v6 loader). The compiler version is recorded in guest.json
next to the ELF: a different gcc is a different programHash.
"""
import json
import os
import re
import shutil
import subprocess

import gk_python
from gk_keccak import hex32, keccak256

CC = 'riscv64-unknown-elf-gcc'

# Keep in lockstep with gas-analyzer crates/gkvm/guest/Makefile. link.ld
# encodes the SP1 v6 loader contract (PT_LOAD >= 0x78000000, W^X, pure rv64im
# exec segments); -fno-jump-tables keeps data out of .text.
CFLAGS = [
    '-march=rv64im', '-mabi=lp64', '-mcmodel=medany', '-O2', '-Wall', '-Wextra',
    '-ffreestanding', '-fno-builtin', '-fno-common', '-fno-jump-tables',
    '-nostdlib', '-nostartfiles', '-static', '-T', 'link.ld', '-Wl,--build-id=none',
]

CRT_FILES = ['crt/crt0.S', 'crt/gkvm.c', 'crt/gkvm.h', 'link.ld']

DOCKER_IMAGE = 'ubuntu:24.04'
DOCKER_PACKAGE = 'gcc-riscv64-unknown-elf'

# The sdk's own copy of gk-guest-crt (byte-identical to gas-analyzer's
# crates/gkvm/guest — `make -C tools/gk crt-check`), used when neither --crt, GK_GUEST_CRT
# nor a project-vendored guest/ says otherwise. It is what `gk init` vendors, and what
# makes a forge-installed sdk self-sufficient: no sibling gas-analyzer checkout is assumed.
BUNDLED_CRT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'guest-crt')

# Project mode (a forge project that installed the sdk, see gk_init.py): where `gk init`
# vendors the crt, and the remapping prefix generated bindings import the sdk through.
PROJECT_CRT_DIR = 'guest'
SDK_REMAP_PREFIX = 'gk-sdk/'


class GkBuildError(Exception):
    pass


def find_project(start, sdk_root):
    """The forge project `start` sits in (nearest foundry.toml upward), or None when that is
    the sdk itself — the sdk keeps its historical defaults (src/gen, cache/gkvm under it)."""
    cur = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(cur, 'foundry.toml')):
            same = os.path.realpath(cur) == os.path.realpath(sdk_root)
            return None if same else cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def forge_dirs(project):
    """(src, test) of the project's default profile; forge's defaults when unset/unreadable."""
    try:
        import tomllib
        with open(os.path.join(project, 'foundry.toml'), 'rb') as f:
            default = tomllib.load(f).get('profile', {}).get('default', {})
    except (ImportError, OSError, ValueError):
        default = {}
    return str(default.get('src', 'src')), str(default.get('test', 'test'))


def has_crt(crt):
    return all(os.path.isfile(os.path.join(crt, f)) for f in CRT_FILES)


def sdk_remapping(project):
    """The `gk-sdk/=…` line of the project's remappings.txt, or None."""
    path = os.path.join(project, 'remappings.txt')
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        for line in f:
            if line.strip().startswith(SDK_REMAP_PREFIX + '='):
                return line.strip()
    return None


def binding_name(stem):
    """hello -> GkHello, artifact-probe -> GkArtifactProbe, my_guest2 -> GkMyGuest2."""
    parts = [p for p in re.split(r'[^0-9A-Za-z]+', stem) if p]
    if not parts:
        raise GkBuildError('cannot derive a binding name from %r' % stem)
    return 'Gk' + ''.join(p[0].upper() + p[1:] for p in parts)


def resolve_crt(crt, project=None):
    """--crt, else GK_GUEST_CRT, else the project's vendored guest/, else the sdk's bundled copy."""
    crt = crt or os.environ.get('GK_GUEST_CRT')
    if not crt and project and has_crt(os.path.join(project, PROJECT_CRT_DIR)):
        crt = os.path.join(project, PROJECT_CRT_DIR)
    crt = crt or BUNDLED_CRT
    missing = [f for f in CRT_FILES if not os.path.isfile(os.path.join(crt, f))]
    if missing:
        raise GkBuildError(
            'gk-guest-crt not found at %s (missing %s); pass --crt or set GK_GUEST_CRT to a '
            "dir laid out like gas-analyzer's crates/gkvm/guest" % (crt, ', '.join(missing)))
    return os.path.abspath(crt)


def stage(source, crt, stage_dir):
    """Lay out the fixed build tree; returns the guest path relative to it."""
    gk_python.empty_dir(stage_dir)
    os.makedirs(os.path.join(stage_dir, 'crt'))
    os.makedirs(os.path.join(stage_dir, 'guest'))
    for f in CRT_FILES:
        shutil.copyfile(os.path.join(crt, f), os.path.join(stage_dir, f))
    rel = 'guest/' + os.path.basename(source)
    shutil.copyfile(source, os.path.join(stage_dir, rel))
    return rel


def compile_commands(guest_rel):
    """Compile each unit to a NAMED object, then link.

    A one-shot `gcc a.S b.c -o guest.elf` is not reproducible: gcc assembles into
    /tmp/ccXXXXXX.o and, for units without a `.file` directive (crt0.S), ld names the
    .symtab FILE symbol after that random object — 6 bytes of the ELF, hence the
    programHash, change on every build. Fixed object names close that.
    """
    # -Icrt: guests may include "gkvm.h" directly; the in-tree guests'
    # "../crt/gkvm.h" resolves through the staged layout as well.
    units = [('crt/crt0.S', 'crt0.o'), ('crt/gkvm.c', 'gkvm.o'), (guest_rel, 'guest.o')]
    cmds = [[CC] + CFLAGS + ['-Icrt', '-c', src, '-o', obj] for src, obj in units]
    cmds.append([CC] + CFLAGS + [obj for _, obj in units] + ['-o', 'guest.elf'])
    return cmds


def _read(path):
    with open(path, 'rb') as f:
        return f.read()


def _run(cmd, cwd=None):
    proc = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise GkBuildError('%s failed (exit %d):\n%s' % (
            cmd[0], proc.returncode, proc.stderr.decode('utf-8', 'replace').strip()))
    return proc.stdout.decode('utf-8', 'replace')


def compile_native(stage_dir, guest_rel):
    for cmd in compile_commands(guest_rel):
        _run(cmd, cwd=stage_dir)
    return _run([CC, '--version']).splitlines()[0].strip()


def compile_docker(stage_dir, guest_rel):
    script = (
        'set -e; apt-get update -qq >/dev/null; '
        'apt-get install -y -qq %s >/dev/null; '
        '%s; %s --version | head -n1 > cc.version; '
        'chown %d:%d *.o guest.elf cc.version'
        % (DOCKER_PACKAGE, '; '.join(' '.join(c) for c in compile_commands(guest_rel)), CC,
           os.getuid(), os.getgid()))
    _run(['docker', 'run', '--rm', '-v', '%s:/build' % os.path.abspath(stage_dir),
          '-w', '/build', DOCKER_IMAGE, 'bash', '-c', script])
    with open(os.path.join(stage_dir, 'cc.version')) as f:
        return f.read().strip()


def render_binding(name, program_hash, source_rel, import_path):
    return '''// SPDX-License-Identifier: AGPL-3.0-only
// %(name)s.sol — generated by `gk build` from %(source)s, do not edit
pragma solidity ^0.8.4;

import {GkVm} from "%(import_path)s";

/// @dev C guests take the raw payload; typed arguments arrive with the Python path's type hints.
library %(name)s {
    bytes32 constant PROGRAM_HASH = %(hash)s;

    function call(address gkvm, bytes32 artifactRoot, bytes memory payload) internal view returns (bytes memory) {
        return GkVm.exec(gkvm, PROGRAM_HASH, artifactRoot, payload);
    }
}
''' % {'name': name, 'hash': program_hash, 'source': source_rel, 'import_path': import_path}


def _sol_import_path(sol_out, sdk_root, project=None):
    # a project that ran `gk init` reaches the sdk through its remapping, wherever it lives
    if project and sdk_remapping(project):
        return SDK_REMAP_PREFIX + 'gkvm/GkVm.sol'
    rel = os.path.relpath(os.path.join(sdk_root, 'src', 'gkvm', 'GkVm.sol'), sol_out)
    rel = rel.replace(os.sep, '/')
    return rel if rel.startswith('.') else './' + rel


def check_compiler(compiler, prefer_docker=False):
    """Resolve 'auto' and fail before any work when nothing can compile a guest.

    `prefer_docker`: Python guests — only the docker leg compiles MicroPython at fixed source
    paths (and is the tested one), so 'auto' takes it whenever docker exists.
    """
    if compiler not in ('auto', 'native', 'docker'):
        raise GkBuildError('--compiler is auto, native or docker')
    if compiler == 'auto':
        if not (shutil.which(CC) or shutil.which('docker')):
            raise GkBuildError('neither %s nor docker is on PATH' % CC)
        if prefer_docker and shutil.which('docker'):
            return 'docker'
        return 'native' if shutil.which(CC) else 'docker'
    tool = CC if compiler == 'native' else 'docker'
    if not shutil.which(tool):
        raise GkBuildError('%s is not on PATH' % tool)
    return compiler


def _build_python(source, stem, sig, crt, out, compiler, log, root, mpy_src, heap_bytes,
                  stack_bytes):
    """The MicroPython leg of build(): -> (staged ELF path, cc version, guest.json extras)."""
    port = gk_python.resolve_port()
    mpy_src = gk_python.resolve_mpy_src(mpy_src, root, log=log)
    stage_dir = os.path.join(out, 'stage')
    guest_py, extra = gk_python.stage(source, sig, crt, CRT_FILES, port, stage_dir)
    args = gk_python.make_args(guest_py, extra, heap_bytes, stack_bytes)
    compile_leg = gk_python.compile_native if compiler == 'native' else gk_python.compile_docker
    cc_version = compile_leg(stage_dir, mpy_src, args, CC)
    frozen = [os.path.basename(source)] + (['gk_runtime.py', 'gk_entry.py'] if sig else [])
    log('  frozen    %s  →  micropython-gkvm image (MicroPython %s, %s, %s)'
        % (' + '.join(frozen), gk_python.MPY_TAG, compiler, cc_version))
    extras = {
        'guest': 'python-typed' if sig else 'python-raw',
        'micropython': {'tag': gk_python.MPY_TAG, 'commit': gk_python.MPY_COMMIT},
        'portHash': hex32(keccak256(b''.join(_read(os.path.join(port, f))
                                             for f in gk_python.PORT_FILES))),
        'makeArgs': args,
    }
    if sig:
        extras['runtimeHash'] = hex32(keccak256(_read(gk_python.RUNTIME)))
        extras['signature'] = {
            'params': [{'name': p, 'solName': n, 'type': t} for p, n, t in sig['params']],
            'returns': None if sig['returns'] is None else list(sig['returns']),
        }
    return gk_python.built_elf(stage_dir, guest_py), cc_version, extras


def build(source, sdk_root, out=None, sol_out=None, crt=None, name=None,
          compiler='auto', emit_binding=True, log=print, project=None, mpy_src=None,
          heap_bytes=None, stack_bytes=None):
    """Build one guest. Returns the guest.json dict (also written next to the ELF).

    `project` = the forge project to build into (see find_project); default outputs, the
    vendored crt and the binding's import path hang off it instead of the sdk root.
    `mpy_src` / `heap_bytes` / `stack_bytes` are Python-guest only (see gk_python.py).
    """
    root = project or sdk_root
    if not os.path.isfile(source):
        raise GkBuildError('no such guest source: %s' % source)
    stem, ext = os.path.splitext(os.path.basename(source))
    if ext not in ('.c', '.py'):
        raise GkBuildError('unsupported guest source %r (expected a .c or .py file)' % ext)
    python = ext == '.py'
    sig = None
    if python:
        # everything the script itself can get wrong fails here, before any toolchain runs
        try:
            sig = gk_python.analyze(_read(source).decode('utf-8'), os.path.basename(source))
            gk_python.check_stem(stem, sig is not None)
        except UnicodeDecodeError:
            raise GkBuildError('%s is not UTF-8' % source)
        except gk_python.GkPythonError as e:
            raise GkBuildError(str(e))
    elif mpy_src or heap_bytes is not None or stack_bytes is not None:
        raise GkBuildError('--mpy-src / --heap-bytes / --stack-bytes apply to Python guests only')
    compiler = check_compiler(compiler, prefer_docker=python)

    crt = resolve_crt(crt, project)
    out = out or os.path.join(root, 'cache', 'gkvm', 'build', stem)
    extras = {}
    if python:
        try:
            built, cc_version, extras = _build_python(source, stem, sig, crt, out, compiler,
                                                      log, root, mpy_src, heap_bytes,
                                                      stack_bytes)
        except gk_python.GkPythonError as e:
            raise GkBuildError(str(e))
    else:
        stage_dir = os.path.join(out, 'stage')
        guest_rel = stage(source, crt, stage_dir)
        compile_leg = compile_native if compiler == 'native' else compile_docker
        cc_version = compile_leg(stage_dir, guest_rel)
        built = os.path.join(stage_dir, 'guest.elf')
        log('  compiled  %s + gk-guest-crt  (%s, %s)'
            % (os.path.basename(source), compiler, cc_version))

    elf_path = os.path.join(out, 'guest.elf')
    shutil.copyfile(built, elf_path)
    with open(elf_path, 'rb') as f:
        elf = f.read()
    program_hash = hex32(keccak256(elf))
    log('  linked    %s (riscv64im, %d bytes)' % (os.path.relpath(elf_path), len(elf)))
    log('  program   %s  (keccak256 of the ELF)' % program_hash)

    info = {
        'name': stem,
        'programHash': program_hash,
        'elfBytes': len(elf),
        'source': os.path.basename(source),
        'sourceHash': hex32(keccak256(_read(source))),
        'crtHash': hex32(keccak256(b''.join(_read(os.path.join(crt, f)) for f in CRT_FILES))),
        'cc': cc_version,
        'cflags': CFLAGS,
        'compiler': compiler,
    }
    if python:
        del info['cflags']  # the port's flags live in port.mk, committed to by portHash
        info.update(extras)

    if emit_binding:
        sol_out = sol_out or os.path.join(root, forge_dirs(root)[0], 'gen')
        os.makedirs(sol_out, exist_ok=True)
        name = name or binding_name(stem)
        sol_path = os.path.join(sol_out, name + '.sol')
        source_rel = os.path.relpath(source, root).replace(os.sep, '/')
        if source_rel.startswith('..'):
            source_rel = os.path.basename(source)
        import_path = _sol_import_path(sol_out, sdk_root, project)
        with open(sol_path, 'w') as f:
            if sig:
                f.write(gk_python.render_binding(name, program_hash, source_rel, import_path, sig))
            else:
                f.write(render_binding(name, program_hash, source_rel, import_path))
        info['binding'] = name
        log('  emitted   %s' % os.path.relpath(sol_path))

    with open(os.path.join(out, 'guest.json'), 'w') as f:
        json.dump(info, f, indent=1)
        f.write('\n')
    return info
