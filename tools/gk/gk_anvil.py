"""`gk anvil` — a local node where the guest really runs (gk-anvil, UNBOUNDED_V3 Phase B).

Finds the gk-anvil binary ($GK_ANVIL, `gk-anvil` on PATH, ~/.gk/bin/gk-anvil — where
install-gk.sh puts it), installs every guest built in this project (`--guest` for each
cache/gkvm/build/*/guest.elf) and passes every other argument to anvil. Then `cast call`
and `forge script --rpc-url http://localhost:8545` reach a consumer whose GkVm.exec works —
on this node and on no real chain.
"""
import glob
import os
import shutil
import subprocess

import gk_build

INSTALL_HINT = 'curl -fsSL https://gaskiller.xyz/bash | sh'


def find_gk_anvil():
    for candidate in (os.environ.get('GK_ANVIL'), shutil.which('gk-anvil'),
                      os.path.join(os.environ.get('GK_HOME') or os.path.expanduser('~/.gk'),
                                   'bin', 'gk-anvil')):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.abspath(candidate)
    return None


def built_guests(root):
    return sorted(glob.glob(os.path.join(root, 'cache', 'gkvm', 'build', '*', 'guest.elf')))


def run(sdk_root, anvil_args, log=print):
    binary = find_gk_anvil()
    if not binary:
        raise gk_build.GkBuildError('gk-anvil not found. Install it:  %s' % INSTALL_HINT)
    root = gk_build.find_project(os.getcwd(), sdk_root) or sdk_root
    cmd = [binary]
    guests = built_guests(root)
    for elf in guests:
        cmd += ['--guest', elf]
    if not guests:
        log('  guests    none built yet (gk build <source> first) — the node starts without any')
    else:
        log('  guests    %s' % ', '.join(os.path.relpath(g, root) for g in guests))
    cmd += list(anvil_args)
    log('  running   %s' % ' '.join(os.path.relpath(c) if os.path.isabs(c) else c for c in cmd))
    return subprocess.call(cmd, cwd=root)
