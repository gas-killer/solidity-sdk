"""`gk run --fast` — execute a Python guest on the host interpreter (solidity-sdk#89).

The consensus path is `gk build` (docker, mpy-cross, the rv64im MicroPython image) and
then gk-run. This module is the opt-in dev fast path: the same script and the same typed
runtime (runtime/gk_runtime.py), but on the CPython already on the machine — sub-second
edit→test loops, working print() and pdb, tracebacks from your own interpreter.

NOT CONSENSUS, by construction, and never quiet about it:

  - no cycle metering: nothing can run out of cycles here
  - no artifact Merkle verification: pages are served straight from the blob files
    (GK_TRAP_ARTIFACT_VERIFY can never fire)
  - CPython is not the pinned MicroPython: stdlib surface, error strings and edge cases
    differ, and a CPython traceback is never the trap bytes an operator would sign
  - programHash still identifies the frozen rv64im image; the fast path merely runs the
    source `gk build` recorded next to it (guest.json)

Every run announces itself on stderr ([gk] FAST …), golden vectors refuse it
(GK_FAST_FORBID, exported by gk_vectors), and `gk run --fast-check` executes both paths
and diffs them — a standing CPython ≡ MicroPython divergence detector. Sign, pin and
ship only what came out of gk-run.

Sidecar mode speaks gk-run's CLI and output contract (`--program … --program-hash …
--input …`; one 0x-hex ASCII line on stdout; exit 0 ok / 10 trap / 12 input overflow),
so GkVmFfiShim runs it unchanged: under `GK_FAST=1` the forge prehook points GK_RUN at
a one-line wrapper that lands here. A .c guest falls through to the real gk-run
(GK_RUN_REAL) — the fast path is Python-only.
"""
import contextlib
import importlib.util
import os
import stat
import sys
import traceback
import types

import gk_python
from gk_keccak import keccak256

# Mirrors of the port/crt constants (guest-crt/micropython/gkport.h, guest-crt/crt/gkvm.h);
# never tuned here — the pinned build is the source of truth.
GK_MPY_TRAP_EXCEPTION = 0xD0000001
GK_MPY_TRAP_SYSTEM_EXIT = 0xD0000002
GK_MPY_TRAP_RESERVED_FROM = 0xD0000000
GK_MPY_TRAP_MSG_CAP = 1024
GK_TRAP_ARTIFACT_RANGE = 0xE0000003
GK_INPUT_BYTES_CAP = 131072
PAGE_SIZE = 4096

# gk-run's outcome exits (crates/gkvm/src/bin/gk-run.rs); anything else is environment class
EXIT_OK = 0
EXIT_TRAP = 10
EXIT_INPUT_OVERFLOW = 12
EXIT_ENV = 2

FAST_BANNER = ('[gk] FAST host-cpython run — not consensus: no cycle metering, no '
               'artifact verification, CPython != the pinned MicroPython. '
               'Only a gk-run result is signable.')

_HERE = os.path.dirname(os.path.abspath(__file__))


class GkFastError(Exception):
    """Environment class: this machine or invocation, never the guest's outcome."""


class Trap(Exception):
    """The guest's deterministic failure — carried, never printed as a Python error."""

    def __init__(self, code, data=b''):
        super().__init__('trap 0x%08X' % code)
        self.code = code
        self.data = bytes(data)


def _buffer_bytes(buf, what):
    if isinstance(buf, str):  # MicroPython str carries the buffer protocol; mirror that
        return buf.encode('utf-8')
    if isinstance(buf, (bytes, bytearray, memoryview)):
        return bytes(buf)
    raise TypeError('%s wants a bytes-like, got %s' % (what, type(buf).__name__))


def _gkvm_module(payload, blobs, root):
    """The host stand-in for `import gkvm` (guest-crt/micropython/modgkvm.c), plus the
    output buffer it appends to. Artifact pages come straight from the blob files —
    loudly no Merkle walk."""
    out = bytearray()
    gkvm = types.ModuleType('gkvm')
    gkvm.__doc__ = 'gk fast-path host emulation of the gkvm hostcalls — NOT consensus'
    gkvm.PAGE_SIZE = PAGE_SIZE

    def _blob(kind):
        kind = int(kind)
        if not blobs or not 0 <= kind < len(blobs):
            raise Trap(GK_TRAP_ARTIFACT_RANGE,
                       b'fast: artifact kind %d out of range' % kind)
        return blobs[kind]

    def _page(kind, page):
        path, page = _blob(kind), int(page)
        size = os.path.getsize(path)
        if page < 0 or page * PAGE_SIZE >= size:
            raise Trap(GK_TRAP_ARTIFACT_RANGE,
                       b'fast: artifact page %d of kind %d out of range' % (page, kind))
        with open(path, 'rb') as f:
            f.seek(page * PAGE_SIZE)
            raw = f.read(PAGE_SIZE)
        return raw + b'\0' * (PAGE_SIZE - len(raw))

    def gkvm_input():
        return bytes(payload)

    def gkvm_output(buf):
        out.extend(_buffer_bytes(buf, 'gkvm.output'))

    def gkvm_abort(code, msg=b''):
        code = int(code)
        if code < 0 or code >= GK_MPY_TRAP_RESERVED_FROM:
            raise ValueError('trap code must be in 0..0xCFFFFFFF')
        raise Trap(code, _buffer_bytes(msg, 'gkvm.abort')[:GK_MPY_TRAP_MSG_CAP])

    def gkvm_artifact_root():
        return bytes(root) if root else b'\0' * 32

    def gkvm_artifact_len(kind):
        return os.path.getsize(_blob(kind))

    def gkvm_artifact_readinto(kind, page, buf):
        view = memoryview(buf)
        if view.readonly or len(view) < PAGE_SIZE:
            raise ValueError('buffer smaller than a page')
        view[:PAGE_SIZE] = _page(kind, page)

    def gkvm_keccak256(buf):
        return keccak256(_buffer_bytes(buf, 'gkvm.keccak256'))

    gkvm.input = gkvm_input
    gkvm.output = gkvm_output
    gkvm.abort = gkvm_abort
    gkvm.artifact_root = gkvm_artifact_root
    gkvm.artifact_len = gkvm_artifact_len
    gkvm.artifact_read = _page
    gkvm.artifact_readinto = gkvm_artifact_readinto
    gkvm.keccak256 = gkvm_keccak256
    return gkvm, out


def _load_runtime():
    """runtime/gk_runtime.py, loaded fresh so its `import gkvm` binds the emulation
    installed in sys.modules — the exact module the frozen image runs, not a copy."""
    spec = importlib.util.spec_from_file_location('gk_runtime', gk_python.RUNTIME)
    runtime = importlib.util.module_from_spec(spec)
    sys.modules['gk_runtime'] = runtime
    spec.loader.exec_module(runtime)
    return runtime


def _traceback_bytes(exc):
    """The CPython traceback as trap data: runner frames dropped, capped like the port
    caps its (GK_MPY_TRAP_MSG_CAP) — but the BYTES still differ from MicroPython's."""
    te = traceback.TracebackException.from_exception(exc)
    own = (os.path.abspath(__file__), '<frozen importlib._bootstrap>',
           '<frozen importlib._bootstrap_external>')
    te.stack = traceback.StackSummary.from_list(
        [f for f in te.stack if not f.filename.startswith(own)])
    return ''.join(te.format()).encode('utf-8')[:GK_MPY_TRAP_MSG_CAP]


def execute(source, payload, blobs=None, root=None):
    """Run guest `source` on host CPython: ('ok', output) or ('trap', code, data).

    Typed guests go through the real runtime/gk_runtime.py against the emulated gkvm
    module; untyped guests just run (they import gkvm themselves). The guest's own
    print() goes to stderr — stdout stays the caller's output channel.
    """
    try:
        with open(source, encoding='utf-8') as f:
            text = f.read()
    except UnicodeDecodeError:
        raise GkFastError('%s is not UTF-8' % source)
    stem = os.path.splitext(os.path.basename(source))[0]
    try:
        sig = gk_python.analyze(text, os.path.basename(source))
        gk_python.check_stem(stem, sig is not None)
    except gk_python.GkPythonError as e:
        raise GkFastError(str(e))

    gkvm, out = _gkvm_module(payload, blobs, root)
    saved = {name: sys.modules.get(name) for name in ('gkvm', 'gk_runtime', stem)}
    sys.modules['gkvm'] = gkvm
    sys.modules.pop(stem, None)
    try:
        with contextlib.redirect_stdout(sys.stderr):
            try:
                module = types.ModuleType(stem)
                module.__file__ = source
                sys.modules[stem] = module  # what `from <stem> import main` would see
                exec(compile(text, source, 'exec'), module.__dict__)
                if sig is not None:
                    runtime = _load_runtime()
                    runtime.run(module.main, tuple(p[2] for p in sig['params']),
                                sig['returns'])
            except Trap as t:
                return ('trap', t.code, t.data)
            except SystemExit as e:
                if e.code not in (None, 0):  # the port: sys.exit(truthy) is a trap
                    return ('trap', GK_MPY_TRAP_SYSTEM_EXIT,
                            str(e.code).encode('utf-8')[:GK_MPY_TRAP_MSG_CAP])
            except Exception as e:  # noqa: BLE001 — an uncaught guest exception IS the outcome
                return ('trap', GK_MPY_TRAP_EXCEPTION, _traceback_bytes(e))
        return ('ok', bytes(out))
    finally:
        for name, mod in saved.items():
            if mod is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = mod


def outcome_line(result):
    """(exit code, the one stdout hex line) — gk-run's output contract."""
    if result[0] == 'ok':
        return EXIT_OK, '0x' + result[1].hex()
    _, code, data = result
    return EXIT_TRAP, '0x' + code.to_bytes(4, 'big').hex() + data.hex()


def _parse_hex(value, what):
    raw = value[2:] if value.startswith(('0x', '0X')) else value
    try:
        return bytes.fromhex(raw)
    except ValueError:
        raise GkFastError('%s must be hex, got %r' % (what, value))


def _parse_root(value):
    if not value:
        return None
    root = _parse_hex(value, '--artifact-root')
    if len(root) != 32:
        raise GkFastError('--artifact-root must be 32 bytes')
    return root


def _err(line):
    print(line, file=sys.stderr, flush=True)


def _trap_note(data):
    _err('[gk] FAST trap report: a cpython traceback/message — byte-DIFFERENT from what '
         'the rv64im run would produce. `gk explain` decodes it either way.')
    if b'abi:' in data:
        _err("[gk] the payload did not decode: if main()'s signature changed since the "
             'last `gk build`, the Solidity binding is stale — rebuild the guest')


def run_source(source, inputs, artifact=None, artifact_root=None):
    """The friendly form: `gk run --fast guest/greet.py --input 0x…` — one hex line per
    input on stdout, worst outcome as the exit code."""
    if not inputs:
        raise GkFastError('at least one --input is required (use 0x for an empty payload)')
    if not source.endswith('.py'):
        raise GkFastError('the fast path runs Python guests only (a .c guest needs the '
                          'rv64im build + gk-run)')
    blobs = artifact.split(',') if artifact else None
    root = _parse_root(artifact_root)
    _err(FAST_BANNER)
    worst = EXIT_OK
    for value in inputs:
        payload = _parse_hex(value, '--input')
        if len(payload) > GK_INPUT_BYTES_CAP:
            _err('[gk] input of %d bytes exceeds GK_INPUT_BYTES_CAP' % len(payload))
            worst = max(worst, EXIT_INPUT_OVERFLOW)
            continue
        result = execute(source, payload, blobs=blobs, root=root)
        code, line = outcome_line(result)
        print(line, flush=True)
        if code == EXIT_TRAP:
            _trap_note(result[2])
        worst = max(worst, code)
    return worst


def _sidecar_source(elf_path, program_hash):
    """--program <…/cache/gkvm/build/<stem>/guest.elf> → the recorded source, via the
    sibling guest.json — the programHash→source mapping `gk build` wrote."""
    import json
    build_dir = os.path.dirname(os.path.abspath(elf_path))
    try:
        with open(os.path.join(build_dir, 'guest.json')) as f:
            info = json.load(f)
    except (OSError, ValueError):
        raise GkFastError('no guest.json next to %s — the fast path keys off the mapping '
                          '`gk build` records; build once (or unset GK_FAST)' % elf_path)
    if program_hash and info.get('programHash', '').lower() != program_hash.lower():
        raise GkFastError('programHash %s is not the recorded build of %s (%s) — '
                          '`gk build` to realign, or unset GK_FAST'
                          % (program_hash, info.get('source'), info.get('programHash')))
    # build dir is <project>/cache/gkvm/build/<stem> — four levels below the project
    project = build_dir
    for _ in range(4):
        project = os.path.dirname(project)
    source = os.path.join(project, 'guest', info.get('source') or '')
    if not os.path.isfile(source):
        raise GkFastError('recorded source %s not found under %s'
                          % (info.get('source'), os.path.join(project, 'guest')))
    return source


def sidecar(program, program_hash, input_arg, cycle_limit=None, artifact=None,
            artifact_root=None, schedule=None):
    """gk-run's argv, the fast path's execution: what GK_RUN points at under GK_FAST=1.

    Same observable contract on the paths that exist here: one 0x-hex line on stdout,
    exit 0 / 10 / 12. No cycles, so exit 11 cannot happen (--cycle-limit is accepted
    and ignored); no JSON report on stderr, so `gk vectors` fails loudly even without
    the GK_FAST_FORBID guard.
    """
    if os.environ.get('GK_FAST_FORBID') == '1':
        raise GkFastError('golden vectors refuse the fast path: these outputs are not '
                          'consensus — record vectors with gk-run')
    source = _sidecar_source(program, program_hash)
    if source.endswith('.c'):
        real = os.environ.get('GK_RUN_REAL')
        if real and os.path.isfile(real) and os.access(real, os.X_OK):
            argv = [real, '--program', program, '--program-hash', program_hash,
                    '--input', input_arg]
            if cycle_limit is not None:
                argv += ['--cycle-limit', str(cycle_limit)]
            if artifact:
                argv += ['--artifact', artifact]
            if artifact_root:
                argv += ['--artifact-root', artifact_root]
            if schedule:
                argv += ['--schedule', schedule]
            os.execv(real, argv)
        raise GkFastError('%s is a C guest — the fast path is Python-only and no real '
                          'gk-run was found to fall through to' % os.path.basename(source))
    if input_arg.startswith('@'):
        with open(input_arg[1:], 'rb') as f:
            payload = f.read()
    else:
        payload = _parse_hex(input_arg, '--input')
    if len(payload) > GK_INPUT_BYTES_CAP:
        return EXIT_INPUT_OVERFLOW
    _err('%s (%s)' % (FAST_BANNER, os.path.relpath(source)))
    blobs = artifact.split(',') if artifact else None
    result = execute(source, payload, blobs=blobs, root=_parse_root(artifact_root))
    code, line = outcome_line(result)
    print(line, flush=True)
    if code == EXIT_TRAP:
        _trap_note(result[2])
    return code


WRAPPER_NAME = 'fast-run.sh'


def write_wrapper(project):
    """cache/gkvm/fast-run.sh — the executable GK_RUN points at under GK_FAST=1 (the
    shim invokes GK_RUN with gk-run's argv; a script is the only indirection it needs)."""
    cache = os.path.join(project, 'cache', 'gkvm')
    os.makedirs(cache, exist_ok=True)
    path = os.path.join(cache, WRAPPER_NAME)
    with open(path, 'w') as f:
        f.write('#!/bin/sh\n'
                '# gk fast-path sidecar (GK_FAST=1) — host cpython, NOT consensus.\n'
                '# Generated by the gk forge prehook; regenerated every wrapped run.\n'
                'exec %s %s run --fast --sidecar "$@"\n'
                % (_sh_quote(sys.executable), _sh_quote(_HERE)))
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def _sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def fast_check(source, inputs, sdk_root, project=None, artifact=None, artifact_root=None,
               log=print):
    """Run every input on BOTH paths and diff: the standing CPython ≡ MicroPython
    divergence detector. ok-outcomes must match to the byte; trap codes must match, and
    trap data must match except 0xD0000001 (tracebacks differ by construction)."""
    import gk_forge
    import gk_vectors
    gk_run = gk_forge.find_gk_run()
    if not gk_run:
        raise GkFastError('--fast-check needs the real gk-run (GK_RUN, PATH, or '
                          '~/.gk/bin) — that is the side being checked against')
    root_dir = project or sdk_root
    stem = os.path.splitext(os.path.basename(source))[0]
    elf = os.path.join(root_dir, 'cache', 'gkvm', 'build', stem, 'guest.elf')
    if not os.path.isfile(elf):
        raise GkFastError('no built ELF at %s — `gk build %s` first' % (elf, source))
    with open(elf, 'rb') as f:
        program_hash = '0x' + keccak256(f.read()).hex()
    art = None
    if artifact:
        art = {'blobs': artifact.split(','), 'root': artifact_root}
    blobs = artifact.split(',') if artifact else None
    root = _parse_root(artifact_root)
    _err(FAST_BANNER)
    divergent = 0
    for value in inputs:
        payload = _parse_hex(value, '--input')
        fast_code, fast_line = outcome_line(execute(source, payload, blobs=blobs, root=root))
        vector = gk_vectors.run_one(gk_run, elf, program_hash, payload, artifact=art,
                                    scratch=os.path.join(root_dir, 'cache', 'gkvm'))
        real_code, real_line = vector['exit'], vector['stdout']
        verdict, detail = _diff(fast_code, fast_line, real_code, real_line)
        log('  %-9s %s' % (verdict, _clip(value)))
        if detail:
            log('            ' + detail)
        divergent += verdict == 'DIVERGENT'
    if divergent:
        log('fast-check: %d of %d inputs DIVERGENT — trust gk-run, and treat the guest '
            'as depending on interpreter behavior' % (divergent, len(inputs)))
        return 1
    log('fast-check: fast ≡ gk-run on all %d inputs (cycle-dependent outcomes excluded '
        'by construction)' % len(inputs))
    return 0


def _diff(fast_code, fast_line, real_code, real_line):
    if (fast_code, fast_line) == (real_code, real_line):
        return 'match', None
    if fast_code == real_code == EXIT_TRAP and fast_line[:10] == real_line[:10]:
        code = int(fast_line[2:10], 16)
        if code == GK_MPY_TRAP_EXCEPTION:
            return 'match*', 'same trap 0x%08X; data differs as expected (cpython vs ' \
                             'micropython traceback)' % code
        return 'DIVERGENT', 'same trap code 0x%08X but different data' % code
    return 'DIVERGENT', 'fast: exit %d %s · gk-run: exit %d %s' % (
        fast_code, _clip(fast_line), real_code, _clip(real_line))


def _clip(hexstr, width=42):
    return hexstr if len(hexstr) <= width else hexstr[:width - 1] + '…'
