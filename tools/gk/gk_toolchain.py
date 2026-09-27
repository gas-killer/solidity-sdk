"""`gk toolchain` — the guest toolchain pinned like solc (solidity-sdk#92).

`programHash = keccak256(ELF)` commits to the crt + link.ld bytes, so "which crt built
this?" must be a declaration, not a directory-layout accident. The model is foundry's
`solc = "0.8.24"`:

  - the project declares a version in `gk.toml` at its root:

        [gkvm]
        toolchain = "v0.1.0"

    (its own file, not foundry.toml: forge prints "unknown config section" warnings for
    tables it does not know, and a pin should never add noise to every forge run)

  - the installed gk provides it from `$GK_HOME/toolchains/<version>/` (`~/.gk`, the
    install-gk.sh home), laid out like tools/gk/guest-crt: `crt/crt0.S`, `crt/gkvm.c`,
    `crt/gkvm.h`, `link.ld`;

  - `gk toolchain install <version>` fetches `gk-crt-<version>.tar.gz` + `SHA256SUMS`
    from the gas-analyzer releases (the same trust path install-gk.sh uses for gk-run),
    verifies, and installs — or takes `--from <dir|tarball>` for a local source (crt
    development, and until the release side of the bundle ships: gas-analyzer#197);

  - `gk build` on a pinned project REFUSES when the version is not installed and names
    the one command that fixes it — it never silently substitutes files lying around.

A global gk upgrade can therefore never move a project's programHash: changing the
toolchain is a one-line, reviewable `gk.toml` diff, and `guest.json` records both the
`toolchain` version and the byte-level `crtHash` for after-the-fact verification.
"""
import hashlib
import os
import re
import shutil
import tarfile
import tempfile
import urllib.request

PIN_FILE = 'gk.toml'

# Release-asset conventions (finalized with the release leg, gas-analyzer#197);
# --url overrides both while that lands.
ASSET_TEMPLATE = 'gk-crt-%s.tar.gz'
RELEASE_URL_TEMPLATE = ('https://github.com/gas-killer/gas-analyzer/releases/download/'
                        'gk-crt-%(version)s/%(asset)s')

_PIN_RE = re.compile(r'^\s*toolchain\s*=\s*"([^"\n]+)"\s*(?:#.*)?$')
_VERSION_RE = re.compile(r'^v[0-9A-Za-z][0-9A-Za-z_.-]*$')


class GkToolchainError(Exception):
    pass


def gk_home():
    return os.environ.get('GK_HOME') or os.path.expanduser('~/.gk')


def toolchains_dir():
    return os.path.join(gk_home(), 'toolchains')


def toolchain_path(version):
    return os.path.join(toolchains_dir(), version)


def check_version(version):
    if not _VERSION_RE.match(version or ''):
        raise GkToolchainError('toolchain version %r: expected v<something>, like v0.1.0'
                               % version)
    return version


def _crt_files():
    import gk_build
    return gk_build.CRT_FILES


def is_toolchain(path):
    return all(os.path.isfile(os.path.join(path, f)) for f in _crt_files())


def list_installed():
    """[(version, path)], newest-looking version first."""
    base = toolchains_dir()
    if not os.path.isdir(base):
        return []
    out = [(name, os.path.join(base, name)) for name in os.listdir(base)
           if is_toolchain(os.path.join(base, name))]
    return sorted(out, key=lambda item: _version_key(item[0]), reverse=True)


def _version_key(version):
    # v0.1.0 < v0.1.0-pre.2 is wrong for semver, but these are our own release names:
    # numeric-aware, stable, and never smarter than the release side's actual scheme.
    return [int(part) if part.isdigit() else part
            for part in re.split(r'[.-]', version.lstrip('v'))]


# --- the project pin ---------------------------------------------------------------


def read_pin(project):
    """The `toolchain = "v…"` of the project's gk.toml [gkvm] table, or None."""
    if not project:
        return None
    path = os.path.join(project, PIN_FILE)
    if not os.path.isfile(path):
        return None
    in_gkvm = False
    with open(path) as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith('['):
                in_gkvm = stripped == '[gkvm]'
            elif in_gkvm:
                match = _PIN_RE.match(line)
                if match:
                    return match.group(1)
    return None


def write_pin(project, version, log=print):
    """Create gk.toml, or add the [gkvm] pin to it; an existing pin is never rewritten."""
    existing = read_pin(project)
    if existing:
        return existing
    path = os.path.join(project, PIN_FILE)
    block = ('# gkvm guest toolchain — pinned like solc: programHash commits to these\n'
             '# bytes (solidity-sdk#92). Change it only as a deliberate, reviewed diff.\n'
             '[gkvm]\ntoolchain = "%s"\n' % check_version(version))
    old = ''
    if os.path.isfile(path):
        with open(path) as f:
            old = f.read()
        if old and not old.endswith('\n'):
            old += '\n'
        block = old + '\n' + block
    with open(path, 'w') as f:
        f.write(block)
    return version


def resolve_pin(project):
    """(version, toolchain path) for a pinned project — or (None, None) when pin-less.

    A pinned-but-missing toolchain is a hard, actionable refusal: substituting other
    crt bytes would silently move every programHash in the project.
    """
    version = read_pin(project)
    if not version:
        return None, None
    path = toolchain_path(version)
    if not is_toolchain(path):
        raise GkToolchainError(
            'gk.toml pins toolchain %s, which is not installed under %s — run: '
            'gk toolchain install %s' % (version, toolchains_dir(), version))
    return version, path


# --- install -----------------------------------------------------------------------


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _fetch(url, dst):
    try:
        with urllib.request.urlopen(url) as resp, open(dst, 'wb') as f:
            shutil.copyfileobj(resp, f)
    except (OSError, ValueError) as e:
        raise GkToolchainError('fetching %s: %s' % (url, e))


def _expected_sum(sums_path, asset_name):
    with open(sums_path) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[-1].lstrip('*') == asset_name:
                return parts[0].lower()
    raise GkToolchainError('SHA256SUMS has no entry for %s' % asset_name)


def _crt_root(tree):
    """The directory holding the crt layout: the tree itself, or its single subdir
    (tarballs often carry one top-level directory)."""
    if is_toolchain(tree):
        return tree
    entries = [e for e in os.listdir(tree) if not e.startswith('.')]
    if len(entries) == 1 and is_toolchain(os.path.join(tree, entries[0])):
        return os.path.join(tree, entries[0])
    raise GkToolchainError('not a gk toolchain layout (wanted %s)' % ', '.join(_crt_files()))


def _install_tree(src_root, version, log):
    dst = toolchain_path(version)
    if is_toolchain(dst):
        log('  kept      %s (already installed)' % dst)
        return dst
    os.makedirs(toolchains_dir(), exist_ok=True)
    staging = tempfile.mkdtemp(prefix='.%s.' % version, dir=toolchains_dir())
    try:
        for f in _crt_files():
            os.makedirs(os.path.dirname(os.path.join(staging, f)) or staging, exist_ok=True)
            shutil.copyfile(os.path.join(src_root, f), os.path.join(staging, f))
        os.rename(staging, dst)  # nothing half-installed is ever visible under the name
    except OSError:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    log('  installed %s' % dst)
    return dst


def install(version, from_path=None, url=None, log=print):
    """Install a toolchain version: from a local dir/tarball, or fetched + sha256-verified
    from the release assets (the install-gk.sh trust path). Returns the installed path."""
    check_version(version)
    if from_path:
        if os.path.isdir(from_path):
            return _install_tree(_crt_root(from_path), version, log)
        with tempfile.TemporaryDirectory() as tmp:
            _extract(from_path, tmp)
            return _install_tree(_crt_root(tmp), version, log)

    asset = ASSET_TEMPLATE % version
    base = url or RELEASE_URL_TEMPLATE % {'version': version, 'asset': asset}
    sums_url = base.rsplit('/', 1)[0] + '/SHA256SUMS'
    with tempfile.TemporaryDirectory() as tmp:
        tarball = os.path.join(tmp, asset)
        sums = os.path.join(tmp, 'SHA256SUMS')
        log('  fetching  %s' % base)
        _fetch(base, tarball)
        _fetch(sums_url, sums)
        expected = _expected_sum(sums, asset)
        actual = _sha256(tarball)
        if actual != expected:
            raise GkToolchainError('sha256 mismatch for %s: SHA256SUMS says %s, got %s — '
                                   'refusing to install' % (asset, expected, actual))
        log('  verified  sha256 %s' % actual)
        tree = os.path.join(tmp, 'tree')
        os.makedirs(tree)
        _extract(tarball, tree)
        return _install_tree(_crt_root(tree), version, log)


def _extract(tarball, dst):
    try:
        with tarfile.open(tarball) as tar:
            tar.extractall(dst, filter='data')  # no absolute paths, no links, no ..
    except (OSError, tarfile.TarError) as e:
        raise GkToolchainError('extracting %s: %s' % (tarball, e))


def cli_list(project, log=print):
    installed = list_installed()
    pin = read_pin(project)
    if not installed:
        log('no toolchains installed under %s' % toolchains_dir())
    for version, path in installed:
        marks = []
        if version == pin:
            marks.append('pinned by gk.toml')
        log('  %-16s %s%s' % (version, path, ('  (%s)' % ', '.join(marks)) if marks else ''))
    if pin and pin not in dict(installed):
        log('  %-16s NOT INSTALLED — gk.toml pins it; run: gk toolchain install %s'
            % (pin, pin))
    if not pin:
        log("  (this project has no gk.toml pin: builds use the sdk's bundled crt)")
    return 0
