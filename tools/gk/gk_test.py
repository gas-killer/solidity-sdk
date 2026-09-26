"""`gk test` — forge test with the guest really executing.

Resolves the gk-run sidecar ($GK_RUN, then `gk-run` on PATH, then ~/.gk/bin/gk-run — where
install-gk.sh puts it), selects the `gkvm-ffi` profile `gk init` appended to foundry.toml (the
only place `ffi = true` lives), rebuilds any guest whose recorded build no longer matches its
source (see gk_forge.stale), and runs `forge test` in the project the cwd sits in with any
extra arguments passed through. Without a sidecar the shim-backed tests skip themselves and
plain `forge test` runs, so the command is always safe to run.

Once `gk init` has installed the forge prehook, plain `forge test` does all of this by
itself; `gk test` stays as the explicit spelling (and the one that works without the shim).
"""
import os
import shutil
import subprocess

import gk_build
import gk_forge
import gk_init

INSTALL_HINT = gk_forge.INSTALL_HINT

# kept as aliases: the resolution order is one piece of code, in gk_forge
find_gk_run = gk_forge.find_gk_run
tier = gk_forge.tier


def run(sdk_root, forge_args, log=print):
    if not shutil.which('forge'):
        raise gk_build.GkBuildError('forge is not on PATH (https://getfoundry.sh)')
    project = gk_build.find_project(os.getcwd(), sdk_root)
    env = dict(os.environ)
    if gk_forge.is_gk_project(project):
        for name, reason in gk_forge.ensure_fresh(sdk_root, project, log=log):
            log('  rebuilt   %s (%s)' % (name, reason))
    gk_run = find_gk_run()
    if gk_run:
        env['GK_RUN'] = gk_run
        env['FOUNDRY_PROFILE'] = env.get('FOUNDRY_PROFILE') or gk_init.FFI_PROFILE
        log('  gk-run    %s (%s tier)' % (gk_run, tier(gk_run)))
        log('  profile   %s' % env['FOUNDRY_PROFILE'])
    else:
        log('  gk-run    not found: shim-backed tests will skip. Install it:  %s' % INSTALL_HINT)
    env['GK_FORGE_WRAPPED'] = '1'  # the prehook work is done here; the forge shim passes through
    cmd = ['forge', 'test'] + list(forge_args)
    log('  running   %s   (in %s)' % (' '.join(cmd),
                                      os.path.relpath(project) if project else '.'))
    return subprocess.call(cmd, cwd=project, env=env)
