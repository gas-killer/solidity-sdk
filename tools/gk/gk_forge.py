"""`gk forge` — the transparent forge prehook for gkvm projects (UNBOUNDED_V3 L3).

`gk init` installs a `forge` shim (tools/gk/forge-shim.sh) into $GK_HOME/bin — the
directory the gas-killer installer put on PATH ahead of foundry's own. From then on, in a
project that ran `gk init` (a guest/ dir + the gk-sdk/ remapping), every plain `forge …`
goes through here first:

  - guests whose recorded build no longer matches reality are rebuilt (guest.json's
    sourceHash / crtHash / portHash / runtimeHash against the bytes on disk — content
    hashes, not mtimes), so an edited guest/greet.py is fresh before the tests run;
  - GK_RUN is resolved and exported, and test-running subcommands get the gkvm-ffi
    profile, so shim-backed tests execute instead of skipping;
  - exactly ONE `[gk]` line goes to stderr first — every wrapped forge run says so at the
    start, and stdout stays byte-identical to forge's own (`forge test --json` parses);
  - then the real forge is exec'd. It IS the forge process from here on: exit code,
    signals and terminal behavior are forge's.

Anywhere outside a gk project the shim execs the real forge untouched and prints nothing.
GK_FORGE_PLAIN=1 forces that untouched path everywhere. The prehook never runs inside the
sdk checkout itself (its own flows are make targets and `gk test`).
"""
import glob
import os
import shutil
import subprocess
import sys

import gk_build
import gk_python
from gk_keccak import hex32, keccak256

INSTALL_HINT = 'curl -fsSL https://gaskiller.xyz/bash | sh'

# Any executable named `forge` whose leading bytes carry this marker is a copy of our
# shim, never the real forge. The string literally appears in forge-shim.sh.
SHIM_MARKER = b'gk-forge-shim'

SHIM_TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'forge-shim.sh')

# Subcommands that run tests: these get FOUNDRY_PROFILE=gkvm-ffi (the only profile with
# ffi = true) so the shim-backed tests actually execute.
TEST_COMMANDS = {'test', 't', 'snapshot', 'coverage'}

# Subcommands that compile or execute project code: these get the stale-guest rebuild.
# `forge fmt`, `forge install`, `forge remappings`, … do not touch guest output and skip it.
REBUILD_COMMANDS = TEST_COMMANDS | {'build', 'b', 'compile', 'script', 'create'}


def gk_home_bin():
    return os.path.join(os.environ.get('GK_HOME') or os.path.expanduser('~/.gk'), 'bin')


def is_shim(path):
    try:
        with open(path, 'rb') as f:
            return SHIM_MARKER in f.read(4096)
    except OSError:
        return False


def find_real_forge(path=None):
    """First executable `forge` on PATH that is not a copy of our shim."""
    for d in (path if path is not None else os.environ.get('PATH', '')).split(os.pathsep):
        candidate = os.path.join(d or '.', 'forge')
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK) and not is_shim(candidate):
            return os.path.abspath(candidate)
    return None


def find_gk_run():
    """$GK_RUN, then `gk-run` on PATH, then ~/.gk/bin/gk-run — where install-gk.sh puts it."""
    for candidate in (os.environ.get('GK_RUN'), shutil.which('gk-run'),
                      os.path.join(gk_home_bin(), 'gk-run')):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.abspath(candidate)
    return None


def tier(gk_run):
    try:
        out = subprocess.run([gk_run, '--print-tier'], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=30)
        return out.stdout.decode().strip() or '?'
    except (OSError, subprocess.SubprocessError):
        return '?'


def _read(path):
    with open(path, 'rb') as f:
        return f.read()


def _hash_files(base, names):
    return hex32(keccak256(b''.join(_read(os.path.join(base, f)) for f in names)))


def guest_sources(root):
    """Top-level guest sources of a gk-init project (guest/*.c + guest/*.py; crt/ is not
    a guest)."""
    return sorted(p for ext in ('c', 'py')
                  for p in glob.glob(os.path.join(root, gk_build.PROJECT_CRT_DIR, '*.' + ext)))


def _load_info(build_dir):
    try:
        import json
        with open(os.path.join(build_dir, 'guest.json')) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def stale(root, source):
    """Why `source`'s recorded build is out of date, or None when it is fresh.

    Everything guest.json commits the programHash to is compared as content hashes:
    the source, the vendored crt, and for Python guests the port + typed runtime.
    """
    stem = os.path.splitext(os.path.basename(source))[0]
    build_dir = os.path.join(root, 'cache', 'gkvm', 'build', stem)
    info = _load_info(build_dir)
    if info is None:
        return 'never built'
    if not os.path.isfile(os.path.join(build_dir, 'guest.elf')):
        return 'guest.elf missing'
    if info.get('binding'):
        binding = os.path.join(root, gk_build.forge_dirs(root)[0], 'gen',
                               info['binding'] + '.sol')
        if not os.path.isfile(binding):
            return 'binding missing'
    if hex32(keccak256(_read(source))) != info.get('sourceHash'):
        return 'source changed'
    try:
        crt = gk_build.resolve_crt(None, root)
    except gk_build.GkBuildError:
        return None  # no crt to compare against; a real build would refuse loudly anyway
    if _hash_files(crt, gk_build.CRT_FILES) != info.get('crtHash'):
        return 'crt changed'
    if source.endswith('.py'):
        if _hash_files(gk_python.resolve_port(), gk_python.PORT_FILES) != info.get('portHash'):
            return 'micropython port changed'
        if 'runtimeHash' in info and hex32(keccak256(_read(gk_python.RUNTIME))) != \
                info['runtimeHash']:
            return 'typed runtime changed'
    return None


def _prior_make_args(root, source):
    """--heap-bytes / --stack-bytes of the previous build, so a rebuild keeps them."""
    stem = os.path.splitext(os.path.basename(source))[0]
    info = _load_info(os.path.join(root, 'cache', 'gkvm', 'build', stem)) or {}
    heap = stack = None
    for arg in info.get('makeArgs') or []:
        if arg.startswith('GK_MPY_HEAP_BYTES='):
            heap = int(arg.split('=', 1)[1])
        elif arg.startswith('GK_MPY_STACK_BYTES='):
            stack = int(arg.split('=', 1)[1])
    return heap, stack


def ensure_fresh(sdk_root, project, log=print, build=None):
    """Rebuild every stale guest of `project`; returns [(name, reason)] of what was rebuilt.

    Raises GkBuildError when a rebuild fails — the caller must NOT run forge then: it
    would test the stale binding the failed build was replacing.
    """
    build = build or gk_build.build  # late-bound: gk_build.build at call time
    rebuilt = []
    for source in guest_sources(project):
        reason = stale(project, source)
        if not reason:
            continue
        heap, stack = _prior_make_args(project, source) if source.endswith('.py') else (None, None)
        build(source, sdk_root, project=project, log=log, heap_bytes=heap, stack_bytes=stack)
        rebuilt.append((os.path.basename(source), reason))
    return rebuilt


def is_gk_project(project):
    return bool(project) and os.path.isdir(os.path.join(project, gk_build.PROJECT_CRT_DIR)) \
        and gk_build.sdk_remapping(project) is not None


def _banner(forge_args, gk_run, gk_tier, profile, rebuilt):
    cmd = next((a for a in forge_args if not a.startswith('-')), '') or 'forge'
    parts = []
    if gk_run:
        parts.append('gk-run %s tier' % gk_tier)
        if profile:
            parts.append('profile %s' % profile)
    else:
        parts.append('gk-run missing — guest tests will skip (install: %s)' % INSTALL_HINT)
    if rebuilt:
        parts.append('rebuilt ' + ', '.join('%s (%s)' % r for r in rebuilt))
    else:
        parts.append('guests fresh')
    return '[gk] forge %s wrapped by the gas-killer sdk · %s' % (cmd, ' · '.join(parts))


def run(sdk_root, forge_args, log=None, exec_fn=None):
    """The prehook: rebuild stale guests, export GK_RUN, one [gk] line, exec real forge.

    `log` writes the banner (default: stderr — stdout is forge's alone).
    `exec_fn(path, argv, env)` defaults to os.execve and never returns.
    """
    log = log or (lambda line: print(line, file=sys.stderr, flush=True))
    exec_fn = exec_fn or os.execve
    real = find_real_forge()
    if not real:
        raise gk_build.GkBuildError('forge is not on PATH (only the gk shim is): '
                                    'https://getfoundry.sh')
    env = dict(os.environ)
    project = gk_build.find_project(os.getcwd(), sdk_root)
    if env.get('GK_FORGE_PLAIN') == '1' or env.get('GK_FORGE_WRAPPED') == '1' \
            or not is_gk_project(project):
        return exec_fn(real, [real] + list(forge_args), env)

    cmd = next((a for a in forge_args if not a.startswith('-')), '')
    rebuilt = []
    if cmd in REBUILD_COMMANDS:
        try:
            rebuilt = ensure_fresh(sdk_root, project, log=log)
        except gk_build.GkBuildError as e:
            log('[gk] guest rebuild failed — forge not run (it would test the stale '
                'binding): %s' % e)
            return 1
    gk_run = find_gk_run()
    profile = None
    if gk_run:
        env['GK_RUN'] = gk_run
        if cmd in TEST_COMMANDS:
            profile = env.get('FOUNDRY_PROFILE') or None
            if not profile:
                import gk_init
                env['FOUNDRY_PROFILE'] = profile = gk_init.FFI_PROFILE
    env['GK_FORGE_WRAPPED'] = '1'  # a forge a script spawns goes straight through
    log(_banner(forge_args, gk_run, tier(gk_run) if gk_run else '?', profile, rebuilt))
    return exec_fn(real, [real] + list(forge_args), env)


def install_shim(log=print):
    """Copy forge-shim.sh to $GK_HOME/bin/forge (the installer's PATH dir).

    Returns one of: installed | updated | kept | skipped (no $GK_HOME/bin — the
    installer has not run) | refused (a foreign `forge` sits there — never clobbered).
    """
    target_dir = gk_home_bin()
    target = os.path.join(target_dir, 'forge')
    if not os.path.isdir(target_dir):
        log('  forge     prehook not installed: %s does not exist — run the installer '
            'first (%s), then re-run gk init' % (target_dir, INSTALL_HINT))
        return 'skipped'
    shim = _read(SHIM_TEMPLATE)
    if os.path.exists(target):
        if not is_shim(target):
            log('  forge     %s exists and is not the gk shim — left alone' % target)
            return 'refused'
        if _read(target) == shim:
            status = 'kept'
        else:
            status = 'updated'
    else:
        status = 'installed'
    if status != 'kept':
        with open(target, 'wb') as f:
            f.write(shim)
    os.chmod(target, 0o755)
    log('  forge     prehook %s at %s — plain `forge test` now runs the guests' %
        (status, target))
    which = shutil.which('forge')
    if which and os.path.realpath(which) != os.path.realpath(target):
        log('            (PATH resolves forge to %s first; put %s before it for the '
            'prehook to apply)' % (which, target_dir))
    return status
