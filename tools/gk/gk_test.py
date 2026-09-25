"""`gk test` — forge test with the guest really executing.

Resolves the gk-run sidecar ($GK_RUN, then `gk-run` on PATH, then ~/.gk/bin/gk-run — where
install-gk.sh puts it), selects the `gkvm-ffi` profile `gk init` appended to foundry.toml (the
only place `ffi = true` lives), and runs `forge test` in the project the cwd sits in with any
extra arguments passed through. Without a sidecar the shim-backed tests skip themselves and
plain `forge test` runs, so the command is always safe to run.
"""
import os
import shutil
import subprocess

import gk_build
import gk_init

INSTALL_HINT = 'curl -fsSL https://gaskiller.xyz/bash | sh'


def find_gk_run():
    for candidate in (os.environ.get('GK_RUN'), shutil.which('gk-run'),
                      os.path.join(os.environ.get('GK_HOME') or os.path.expanduser('~/.gk'),
                                   'bin', 'gk-run')):
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


def run(sdk_root, forge_args, log=print):
    if not shutil.which('forge'):
        raise gk_build.GkBuildError('forge is not on PATH (https://getfoundry.sh)')
    project = gk_build.find_project(os.getcwd(), sdk_root)
    env = dict(os.environ)
    gk_run = find_gk_run()
    if gk_run:
        env['GK_RUN'] = gk_run
        env['FOUNDRY_PROFILE'] = env.get('FOUNDRY_PROFILE') or gk_init.FFI_PROFILE
        log('  gk-run    %s (%s tier)' % (gk_run, tier(gk_run)))
        log('  profile   %s' % env['FOUNDRY_PROFILE'])
    else:
        log('  gk-run    not found: shim-backed tests will skip. Install it:  %s' % INSTALL_HINT)
    cmd = ['forge', 'test'] + list(forge_args)
    log('  running   %s   (in %s)' % (' '.join(cmd), os.path.relpath(project) or '.'))
    return subprocess.call(cmd, cwd=project, env=env)
