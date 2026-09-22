"""`gk build` — the Python guest path (UNBOUNDED_V3 M5).

answer.py -> mpy-cross frozen bytecode -> the MicroPython gkvm port image -> guest.elf.
The port is an out-of-tree MicroPython port over gk-guest-crt: tools/gk/guest-crt/micropython
is a byte copy of gas-analyzer's crates/gkvm/guest/micropython (`make -C tools/gk
port-check`); upstream MicroPython is NOT vendored — it is fetched at the pinned commit and
refused when it is anything else, because the interpreter's bytes are part of programHash.

Two kinds of guest script:

  typed  a top-level `def main(...)` with type hints. gk freezes the script, gk_runtime.py
         (ABI decode/encode) and a generated gk_entry.py, and generates a Solidity binding
         whose `call` takes the same arguments: int -> uint256, bool -> bool, bytes ->
         bytes, str -> string, list[T] -> T[]; float is rejected here, at build time.
         `-> bytes` is the raw output; any other return (tuple[...] for several values)
         is ABI-encoded by the guest and abi.decode()d by the binding.
  raw    no top-level `main`: the script is the image's __main__ and talks to `gkvm`
         itself (gkvm.input() / gkvm.output()), like a C guest; bytes-payload binding.

The build tree mirrors gas-analyzer's guest dir (crt/, link.ld, micropython/) and docker
mounts it at the same fixed paths (/guest, /mpy), so a raw script builds to the very ELF
gas-analyzer's own `make docker` produces.
"""
import ast
import os
import re
import shutil
import subprocess

MPY_REPO = 'https://github.com/micropython/micropython'
MPY_TAG = 'v1.29.0'
MPY_COMMIT = '0fd6c573ea815774668bbb16b8e197c8822368b2'
# lib/micropython-lib at that tag; py/manifest.mk refuses to freeze without it.
MPY_LIB_COMMIT = 'ee4bb8ff139e24c42b739935fbd8ec7c4d061e02'

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLED_PORT = os.path.join(HERE, 'guest-crt', 'micropython')
RUNTIME = os.path.join(HERE, 'runtime', 'gk_runtime.py')
# fixed order: guest.json's portHash is keccak of these, concatenated
PORT_FILES = ['port.mk', 'manifest.py', 'mpconfigport.h', 'mphalport.h', 'gkport.h',
              'qstrdefsport.h', 'main.c', 'modgkvm.c', 'gk_libc.c']

ENTRY_STEM = 'gk_entry'
# module names a typed guest script cannot take: gk's own, and the port's built-ins a
# frozen module of the same name would fight with
RESERVED_STEMS = {ENTRY_STEM, 'gk_runtime', 'gkvm', 'array', 'binascii', 'builtins',
                  'collections', 'errno', 'gc', 'hashlib', 'heapq', 'io', 'json',
                  'micropython', 're', 'struct', 'sys'}

DOCKER_IMAGE = 'ubuntu:24.04'
DOCKER_PACKAGES = ('make gcc libc6-dev python3 gcc-riscv64-unknown-elf '
                   'picolibc-riscv64-unknown-elf')

SCALARS = {'int': 'uint256', 'bool': 'bool', 'bytes': 'bytes', 'str': 'string'}

SOL_LINE = 120  # forge fmt's default line_length

# identifiers a generated parameter cannot be called: the binding's own names, and the
# Solidity keywords a snake_case Python name can plausibly turn into
SOL_RESERVED = {
    'gkvm', 'artifactRoot', 'payload', 'result', 'call',
    'abstract', 'address', 'after', 'alias', 'anonymous', 'apply', 'as', 'assembly', 'auto',
    'bool', 'break', 'byte', 'bytes', 'calldata', 'case', 'catch', 'constant', 'constructor',
    'continue', 'contract', 'copyof', 'days', 'default', 'define', 'delete', 'do', 'else',
    'emit', 'enum', 'error', 'ether', 'event', 'external', 'fallback', 'false', 'final',
    'fixed', 'for', 'from', 'function', 'global', 'gwei', 'hex', 'hours', 'if', 'immutable',
    'implements', 'import', 'in', 'indexed', 'inline', 'int', 'interface', 'internal', 'is',
    'let', 'library', 'macro', 'mapping', 'match', 'memory', 'minutes', 'modifier', 'mutable',
    'new', 'null', 'of', 'override', 'partial', 'payable', 'pragma', 'private', 'promise',
    'public', 'pure', 'receive', 'reference', 'relocatable', 'return', 'returns', 'revert',
    'sealed', 'seconds', 'sizeof', 'static', 'storage', 'string', 'struct', 'super',
    'supports', 'switch', 'this', 'throw', 'transient', 'true', 'try', 'type', 'typedef',
    'typeof', 'ufixed', 'uint', 'unchecked', 'unicode', 'using', 'var', 'view', 'virtual',
    'weeks', 'while', 'wei', 'years',
}


class GkPythonError(Exception):
    pass


# --- the script: floats, main()'s signature --------------------------------------------


def _where(source_name, node):
    return '%s:%d' % (source_name, getattr(node, 'lineno', 0))


def reject_floats(tree, source_name):
    """The gkvm port has no float type (MICROPY_FLOAT_IMPL_NONE — the integer-only engine
    doctrine): what CPython would quietly turn into a float fails here, before the build."""
    for node in ast.walk(tree):
        what = None
        if isinstance(node, ast.Constant) and isinstance(node.value, (float, complex)):
            what = 'float literal %r' % (node.value,)
        elif isinstance(node, ast.Name) and node.id in ('float', 'complex'):
            what = '`%s`' % node.id
        elif isinstance(node, (ast.BinOp, ast.AugAssign)) and isinstance(node.op, ast.Div):
            what = 'true division `/` (always a float in Python 3; use `//`)'
        if what:
            raise GkPythonError('%s: %s — gkvm guests have no floats'
                                % (_where(source_name, node), what))


def _sol_type(node, source_name):
    """One type hint -> a Solidity type string (the doc's type map)."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):  # "list[int]"
        try:
            node = ast.parse(node.value, mode='eval').body
        except SyntaxError:
            raise GkPythonError('%s: cannot parse the type hint %r'
                                % (_where(source_name, node), node.value))
    if isinstance(node, ast.Name):
        if node.id == 'float':
            raise GkPythonError('%s: `float` — gkvm guests have no floats'
                                % _where(source_name, node))
        if node.id in SCALARS:
            return SCALARS[node.id]
    if (isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name)
            and node.value.id == 'list'):
        inner = node.slice
        if not isinstance(inner, ast.Tuple):
            return _sol_type(inner, source_name) + '[]'
    raise GkPythonError(
        '%s: unsupported type hint `%s` (int, bool, bytes, str, list[T])'
        % (_where(source_name, node), ast.unparse(node)))


def _return_types(node, source_name):
    """None = `-> bytes`, the raw output; else the tuple of ABI-encoded return types."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        try:
            node = ast.parse(node.value, mode='eval').body
        except SyntaxError:
            raise GkPythonError('%s: cannot parse the return hint' % _where(source_name, node))
    if isinstance(node, ast.Name) and node.id == 'bytes':
        return None
    if (isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name)
            and node.value.id == 'tuple'):
        elts = node.slice.elts if isinstance(node.slice, ast.Tuple) else [node.slice]
        if not elts:
            raise GkPythonError('%s: empty tuple[...] return' % _where(source_name, node))
        return tuple(_sol_type(e, source_name) for e in elts)
    if isinstance(node, ast.Constant) and node.value is None:
        raise GkPythonError('%s: main() must return its answer (`-> bytes`, or a typed value)'
                            % _where(source_name, node))
    return (_sol_type(node, source_name),)


def sol_param_name(py_name):
    """prompt_ids -> promptIds; names that would collide with the binding or Solidity get a
    trailing underscore."""
    parts = [p for p in py_name.split('_') if p]
    if not parts:
        return 'arg_'
    name = parts[0] + ''.join(p[0].upper() + p[1:] for p in parts[1:])
    if not re.match(r'^[A-Za-z][0-9A-Za-z]*$', name):
        raise GkPythonError('cannot turn the parameter name %r into a Solidity identifier'
                            % py_name)
    return name + '_' if name in SOL_RESERVED or re.match(r'^(u?int|bytes)\d+$', name) else name


def analyze(source_text, source_name):
    """-> None for a raw script, else {'params': [(py, sol name, sol type)], 'returns':
    None | (sol types…)}. Raises GkPythonError on floats or a main() gk cannot bind."""
    try:
        tree = ast.parse(source_text, filename=source_name)
    except SyntaxError as e:
        raise GkPythonError('%s:%s: %s' % (source_name, e.lineno, e.msg))
    reject_floats(tree, source_name)

    mains = [n for n in tree.body
             if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == 'main']
    if not mains:
        return None
    if len(mains) > 1:
        raise GkPythonError('%s: main() is defined twice' % _where(source_name, mains[1]))
    fn = mains[0]
    if isinstance(fn, ast.AsyncFunctionDef):
        raise GkPythonError('%s: main() cannot be async' % _where(source_name, fn))
    a = fn.args
    if a.vararg or a.kwarg or a.kwonlyargs or a.defaults or a.kw_defaults:
        raise GkPythonError('%s: main() takes plain positional parameters only (no *args, '
                            '**kwargs, keyword-only parameters or defaults)'
                            % _where(source_name, fn))
    params = []
    for arg in a.posonlyargs + a.args:
        if arg.annotation is None:
            raise GkPythonError('%s: main() parameter `%s` has no type hint — the Solidity '
                                'binding is generated from them'
                                % (_where(source_name, arg), arg.arg))
        params.append((arg.arg, sol_param_name(arg.arg), _sol_type(arg.annotation, source_name)))
    sol_names = [p[1] for p in params]
    if len(set(sol_names)) != len(sol_names):
        raise GkPythonError('%s: two main() parameters map to one Solidity name (%s)'
                            % (_where(source_name, fn), ', '.join(sol_names)))
    if fn.returns is None:
        raise GkPythonError('%s: main() has no return type hint (`-> bytes`, or a typed value)'
                            % _where(source_name, fn))
    return {'params': params, 'returns': _return_types(fn.returns, source_name)}


def check_stem(stem, typed):
    if typed and (not stem.isidentifier() or stem in RESERVED_STEMS):
        raise GkPythonError(
            'a typed guest is imported by its file name: %r is not a usable module name '
            '(an identifier, and none of %s)' % (stem + '.py', ', '.join(sorted(RESERVED_STEMS))))
    if not re.match(r'^[0-9A-Za-z_.-]+$', stem):
        raise GkPythonError('guest file name %r: letters, digits, _ . - only' % (stem + '.py'))


def render_entry(stem, sig):
    returns = sig['returns']
    return ('# gk_entry.py — generated by `gk build` from %s.py, do not edit\n'
            'import gk_runtime\n'
            'from %s import main\n'
            '\n'
            'gk_runtime.run(main, %r, %r)\n'
            % (stem, stem, tuple(p[2] for p in sig['params']), returns))


# --- the Solidity binding ---------------------------------------------------------------


def _memory(sol_type):
    return sol_type + (' memory' if sol_type not in ('uint256', 'bool') else '')


def _signature(params, returns):
    """`function call(...) internal view returns (...) {` the way forge fmt lays it out."""
    args = ', '.join(params)
    one = '    function call(%s) internal view returns (%s) {' % (args, returns)
    if len(one) <= SOL_LINE:
        return one
    head = '    function call(%s)' % args
    if len(head) <= SOL_LINE:
        if len('        returns (%s)' % returns) > SOL_LINE:
            returns = '\n%s\n        ' % ',\n'.join('            ' + r for r in returns.split(', '))
        return '%s\n        internal\n        view\n        returns (%s)\n    {' % (head, returns)
    return ('    function call(\n%s\n    ) internal view returns (%s) {'
            % (',\n'.join('        ' + p for p in params), returns))


def _exec_call(indent, prefix, payload, tail):
    """`<prefix>GkVm.exec(...)<tail>`, on one line when it fits, else one argument per line."""
    pad = ' ' * indent
    one = '%s%sGkVm.exec(gkvm, PROGRAM_HASH, artifactRoot, %s)' % (pad, prefix, payload)
    # measured against forge fmt 1.5.1: a statement's `;` may overhang the line, a `,` may not
    if len(one) + (tail == ',') <= SOL_LINE:
        return one + tail
    args = '%s    gkvm, PROGRAM_HASH, artifactRoot, %s' % (pad, payload)
    if len(args) > SOL_LINE:
        args = '%s    gkvm,\n%s    PROGRAM_HASH,\n%s    artifactRoot,\n%s    %s' % (
            pad, pad, pad, pad, payload)
    return '%s%sGkVm.exec(\n%s\n%s)%s' % (pad, prefix, args, pad, tail)


def _exec_statement(payload, decode_types, brace_own_line):
    """The body of `call`, the way forge fmt lays it out. decode_types None = return the
    raw output; brace_own_line = the signature wrapped its attributes and left `{` on a line
    of its own. Layouts beyond these (an abi.encode(...) or a type tuple that alone
    overflows the line) still compile; they are just not fmt-clean.

    All of it measured against forge fmt 1.5.1 (the fmt test holds both sides of every
    boundary), none of it read from its source."""
    exec_ = 'GkVm.exec(gkvm, PROGRAM_HASH, artifactRoot, %s)' % payload
    expr = exec_ if decode_types is None else 'abi.decode(%s, %s)' % (exec_, decode_types)
    if len('        return ' + expr) <= SOL_LINE:
        return '        return %s;\n' % expr
    # under a `{` of its own, the expression moves whole under `return` before it breaks
    # inside (three columns gained) — here the `;` may NOT overhang. Under
    # `) internal view … {` it never moves.
    if brace_own_line and len('            ' + expr + ';') <= SOL_LINE:
        return '        return\n            %s;\n' % expr
    if decode_types is None:
        return _exec_call(8, 'return ', payload, ';') + '\n'
    args = '            %s, %s' % (exec_, decode_types)
    if len(args) <= SOL_LINE:
        return '        return abi.decode(\n%s\n        );\n' % args
    return ('        return abi.decode(\n%s\n            %s\n        );\n'
            % (_exec_call(12, '', payload, ','), decode_types))


def render_binding(name, program_hash, source_rel, import_path, sig):
    params = ['address gkvm', 'bytes32 artifactRoot']
    params += ['%s %s' % (_memory(t), n) for _, n, t in sig['params']]
    returns = sig['returns']
    if sig['params']:
        payload = 'abi.encode(%s)' % ', '.join(n for _, n, _ in sig['params'])
    else:
        payload = 'new bytes(0)'
    # No locals: every parameter and return value already owns a stack slot for the whole
    # call, and solc's legacy codegen reaches 16 deep — a `payload` / `result` local each
    # costs one of them (6 params + 5 returns compiled only in this shape).
    if returns is None:
        ret_decl, decode_types = 'bytes memory', None
    else:
        ret_decl = ', '.join(_memory(t) for t in returns)
        decode_types = '(%s)' % ', '.join(returns)
    signature = _signature(params, ret_decl)
    body = _exec_statement(payload, decode_types, signature.endswith('\n    {'))
    py_sig = 'main(%s) -> %s' % (
        ', '.join(p for p, _, _ in sig['params']),
        'bytes (raw output)' if returns is None else '(%s), ABI-encoded by the guest' % ', '.join(returns))
    return ('// SPDX-License-Identifier: AGPL-3.0-only\n'
            '// %(name)s.sol — generated by `gk build` from %(source)s, do not edit\n'
            'pragma solidity ^0.8.4;\n'
            '\n'
            'import {GkVm} from "%(import_path)s";\n'
            '\n'
            '/// @dev %(py_sig)s\n'
            'library %(name)s {\n'
            '    bytes32 constant PROGRAM_HASH = %(hash)s;\n'
            '\n'
            '%(signature)s\n'
            '%(body)s'
            '    }\n'
            '}\n' % {'name': name, 'source': source_rel, 'import_path': import_path,
                     'py_sig': py_sig, 'hash': program_hash,
                     'signature': signature, 'body': body})


# --- upstream MicroPython: fetch, pin ----------------------------------------------------


def _git(args, cwd=None):
    proc = subprocess.run(['git'] + args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise GkPythonError('git %s failed (exit %d):\n%s' % (
            ' '.join(args), proc.returncode, proc.stderr.decode('utf-8', 'replace').strip()))
    return proc.stdout.decode('utf-8', 'replace').strip()


def check_pin(mpy_src):
    """Exactly the pinned MicroPython, unmodified — anything else is a different interpreter
    and so a different programHash (untracked build outputs, e.g. mpy-cross/build, are fine)."""
    lib = os.path.join(mpy_src, 'lib', 'micropython-lib')
    if _git(['-C', mpy_src, 'rev-parse', 'HEAD']) != MPY_COMMIT:
        raise GkPythonError('%s is not MicroPython %s (%s)' % (mpy_src, MPY_TAG, MPY_COMMIT))
    if not os.path.exists(os.path.join(lib, '.git')) or \
            _git(['-C', lib, 'rev-parse', 'HEAD']) != MPY_LIB_COMMIT:
        raise GkPythonError('%s is not at %s' % (lib, MPY_LIB_COMMIT))
    if _git(['-C', mpy_src, 'status', '--porcelain', '--untracked-files=no']):
        raise GkPythonError('%s has local modifications' % mpy_src)


def resolve_mpy_src(mpy_src, root, log=print):
    """--mpy-src, else GK_MPY_SRC, else <root>/cache/gkvm/micropython/src — cloned there at
    the pin on first use (network). Whatever it is, it must pass check_pin."""
    mpy_src = mpy_src or os.environ.get('GK_MPY_SRC')
    if not mpy_src:
        mpy_src = os.path.join(root, 'cache', 'gkvm', 'micropython', 'src')
        if not os.path.isdir(os.path.join(mpy_src, '.git')):
            if not shutil.which('git'):
                raise GkPythonError('git is not on PATH (needed to fetch MicroPython %s)' % MPY_TAG)
            log('  fetching  MicroPython %s -> %s' % (MPY_TAG, os.path.relpath(mpy_src)))
            os.makedirs(os.path.dirname(mpy_src), exist_ok=True)
            _git(['clone', '--depth', '1', '--branch', MPY_TAG, MPY_REPO, mpy_src])
        _git(['-C', mpy_src, 'submodule', 'update', '--init', '--depth', '1',
              'lib/micropython-lib'])
    elif not os.path.isdir(mpy_src):
        raise GkPythonError('no MicroPython checkout at %s' % mpy_src)
    mpy_src = os.path.abspath(mpy_src)
    check_pin(mpy_src)
    return mpy_src


def resolve_port(port=None):
    port = port or os.environ.get('GK_MPY_PORT') or BUNDLED_PORT
    missing = [f for f in PORT_FILES if not os.path.isfile(os.path.join(port, f))]
    if missing:
        raise GkPythonError('MicroPython gkvm port not found at %s (missing %s)'
                            % (port, ', '.join(missing)))
    return os.path.abspath(port)


# --- stage + compile ---------------------------------------------------------------------


def empty_dir(stage_dir):
    """Clear a stage dir IN PLACE rather than rmtree + recreate: Docker Desktop's file sharing
    caches the bind-mounted directory by inode, and a directory recreated at the same path
    seconds after a build shows up empty inside the next container ("crt/crt0.S: No such
    file") — seen on a second `gk init` of the same project."""
    if os.path.isdir(stage_dir):
        for entry in os.listdir(stage_dir):
            path = os.path.join(stage_dir, entry)
            shutil.rmtree(path) if os.path.isdir(path) and not os.path.islink(path) else os.remove(path)
    else:
        os.makedirs(stage_dir)


def stage(source, sig, crt, crt_files, port, stage_dir):
    """Lay out gas-analyzer's guest dir: crt/, link.ld, micropython/ (the port) with the
    scripts under micropython/guest/. Returns (GUEST_PY, GUEST_PY_EXTRA), port-relative."""
    empty_dir(stage_dir)
    guest_dir = os.path.join(stage_dir, 'micropython', 'guest')
    os.makedirs(os.path.join(stage_dir, 'crt'))
    os.makedirs(guest_dir)
    for f in crt_files:
        shutil.copyfile(os.path.join(crt, f), os.path.join(stage_dir, f))
    for f in PORT_FILES:
        shutil.copyfile(os.path.join(port, f), os.path.join(stage_dir, 'micropython', f))
    base = os.path.basename(source)
    shutil.copyfile(source, os.path.join(guest_dir, base))
    if sig is None:
        return 'guest/' + base, []
    shutil.copyfile(RUNTIME, os.path.join(guest_dir, 'gk_runtime.py'))
    with open(os.path.join(guest_dir, ENTRY_STEM + '.py'), 'w') as f:
        f.write(render_entry(os.path.splitext(base)[0], sig))
    return 'guest/%s.py' % ENTRY_STEM, ['guest/' + base, 'guest/gk_runtime.py']


def make_args(guest_py, extra, heap_bytes=None, stack_bytes=None):
    args = ['GUEST_PY=' + guest_py]
    if extra:
        args.append('GUEST_PY_EXTRA=' + ' '.join(extra))
    if heap_bytes is not None:
        args.append('GK_MPY_HEAP_BYTES=%d' % heap_bytes)
    if stack_bytes is not None:
        args.append('GK_MPY_STACK_BYTES=%d' % stack_bytes)
    return args


def built_elf(stage_dir, guest_py):
    name = os.path.splitext(os.path.basename(guest_py))[0]
    return os.path.join(stage_dir, 'build', 'micropython', name, name + '-py.elf')


def _run(cmd, cwd=None):
    proc = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        tail = proc.stdout.decode('utf-8', 'replace').strip().splitlines()[-40:]
        raise GkPythonError('%s failed (exit %d):\n%s' % (cmd[0], proc.returncode, '\n'.join(tail)))
    return proc.stdout.decode('utf-8', 'replace')


def compile_native(stage_dir, mpy_src, args, cc):
    """UNTESTED on a real host toolchain (needs riscv64-unknown-elf-gcc + picolibc headers);
    the ELF may also differ from the docker leg's, whose source paths are fixed."""
    _run(['make', '-f', 'port.mk', 'MPY_SRC=' + mpy_src] + args,
         cwd=os.path.join(stage_dir, 'micropython'))
    return _run([cc, '--version']).splitlines()[0].strip()


def compile_docker(stage_dir, mpy_src, args, cc):
    # gas-analyzer's `make docker` leg, mount for mount: /guest is the staged guest dir,
    # /mpy the pinned upstream (mpy-cross, a host tool, is built inside it once).
    quoted = ' '.join("'%s'" % a for a in args)
    script = (
        'set -e; apt-get update -qq >/dev/null; apt-get install -y -qq %s >/dev/null; '
        '%s --version | head -n1 > /guest/cc.version; rc=0; '
        'make -f port.mk MPY_SRC=/mpy %s > /guest/make.log 2>&1 || rc=$?; '
        'chown -R %d:%d /guest /mpy/mpy-cross/build 2>/dev/null || true; '
        '[ $rc -eq 0 ] || tail -n 40 /guest/make.log; exit $rc'
        % (DOCKER_PACKAGES, cc, quoted, os.getuid(), os.getgid()))
    _run(['docker', 'run', '--rm', '-v', '%s:/guest' % os.path.abspath(stage_dir),
          '-v', '%s:/mpy' % mpy_src, '-w', '/guest/micropython', DOCKER_IMAGE,
          'bash', '-c', script])
    with open(os.path.join(stage_dir, 'cc.version')) as f:
        return f.read().strip()
