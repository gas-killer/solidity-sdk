"""`gk build` — guest source -> guest.elf -> programHash -> Solidity binding.

C guest path (UNBOUNDED_V3 M2). The Python path (mpy-cross freeze into the
MicroPython gkvm port, binding generated from type hints) is M5 and rejected
here with a pointer rather than half-implemented.

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
    if os.path.isdir(stage_dir):
        shutil.rmtree(stage_dir)
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


def check_compiler(compiler):
    """Resolve 'auto' and fail before any work when nothing can compile a guest."""
    if compiler not in ('auto', 'native', 'docker'):
        raise GkBuildError('--compiler is auto, native or docker')
    if compiler == 'auto':
        if not (shutil.which(CC) or shutil.which('docker')):
            raise GkBuildError('neither %s nor docker is on PATH' % CC)
        return 'native' if shutil.which(CC) else 'docker'
    tool = CC if compiler == 'native' else 'docker'
    if not shutil.which(tool):
        raise GkBuildError('%s is not on PATH' % tool)
    return compiler


def build(source, sdk_root, out=None, sol_out=None, crt=None, name=None,
          compiler='auto', emit_binding=True, log=print, project=None):
    """Build one guest. Returns the guest.json dict (also written next to the ELF).

    `project` = the forge project to build into (see find_project); default outputs, the
    vendored crt and the binding's import path hang off it instead of the sdk root.
    """
    root = project or sdk_root
    if not os.path.isfile(source):
        raise GkBuildError('no such guest source: %s' % source)
    stem, ext = os.path.splitext(os.path.basename(source))
    if ext == '.py':
        raise GkBuildError(
            'Python guests need the MicroPython gkvm port (campaign lane L1 / milestone M5); '
            'this gk builds C guests')
    if ext != '.c':
        raise GkBuildError('unsupported guest source %r (expected a .c file)' % ext)
    compiler = check_compiler(compiler)

    crt = resolve_crt(crt, project)
    out = out or os.path.join(root, 'cache', 'gkvm', 'build', stem)
    stage_dir = os.path.join(out, 'stage')
    guest_rel = stage(source, crt, stage_dir)

    cc_version = (compile_native if compiler == 'native' else compile_docker)(stage_dir, guest_rel)

    elf_path = os.path.join(out, 'guest.elf')
    shutil.copyfile(os.path.join(stage_dir, 'guest.elf'), elf_path)
    with open(elf_path, 'rb') as f:
        elf = f.read()
    program_hash = hex32(keccak256(elf))
    log('  compiled  %s + gk-guest-crt  (%s, %s)' % (os.path.basename(source), compiler, cc_version))
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

    if emit_binding:
        sol_out = sol_out or os.path.join(root, forge_dirs(root)[0], 'gen')
        os.makedirs(sol_out, exist_ok=True)
        name = name or binding_name(stem)
        sol_path = os.path.join(sol_out, name + '.sol')
        source_rel = os.path.relpath(source, root).replace(os.sep, '/')
        if source_rel.startswith('..'):
            source_rel = os.path.basename(source)
        with open(sol_path, 'w') as f:
            f.write(render_binding(name, program_hash, source_rel,
                                   _sol_import_path(sol_out, sdk_root, project)))
        info['binding'] = name
        log('  emitted   %s' % os.path.relpath(sol_path))

    with open(os.path.join(out, 'guest.json'), 'w') as f:
        json.dump(info, f, indent=1)
        f.write('\n')
    return info
