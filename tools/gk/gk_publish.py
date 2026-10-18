"""`gk publish` — put a built guest where operators fetch it by hash.

Publishing is availability, not trust. A consumer names its program on-chain
(`IGkVmConsumer.programHash()`, or the generated bindings' `PROGRAM_HASH()` constant), and an
operator serving one of its tasks fetches the ELF from the mirrors its fleet knows and
verifies `keccak256(elf) == programHash` before installing it — so a mirror can be anyone's
bucket and nothing it serves is believed. What this command does is make the bytes reachable
under the one name operators derive from the chain:

    <mirror base>/<programHash hex, lowercase, no 0x>.elf

Targets (`--to`, repeatable — every target gets the same object):

    <dir> | file://<dir>       copy into a directory (atomic: temp file in the dir + rename,
                               mode 0644 so a web server can serve it); created when missing
    s3://bucket[/prefix]       `aws s3 cp`. --endpoint <url> (or $GK_PUBLISH_S3_ENDPOINT) adds
                               --endpoint-url: an S3-compatible store such as Quilibrium
                               QStorage (https://qstorage.quilibrium.com) is targeted this
                               way. --public adds --acl public-read.
    gs://bucket[/prefix]       `gcloud storage cp`; --public adds --predefined-acl=publicRead

Anything else — an https:// URL included — is refused: a mirror is WRITTEN through one of the
above and READ over https. The MIRROR_BASE this command prints is the https (or path) prefix
an operator puts in the fleet's mirror list; the ELF is fetched on the first task that names
its hash, so adding a program needs no fleet config change once a known mirror serves it.

The pure parts (`parse_target`, `object_name`, `mirror_base`, `upload_command`) are plain
functions, and `publish` takes the command runner as a parameter, so the whole thing is
testable without aws, gcloud or a network.
"""
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

from gk_keccak import hex32, keccak256

ELF_NAME = 'guest.elf'
ENDPOINT_ENV = 'GK_PUBLISH_S3_ENDPOINT'
S3_PUBLIC_HOST = 'https://%s.s3.amazonaws.com'
GS_PUBLIC_HOST = 'https://storage.googleapis.com'

# kind -> (binary, how to get it) for the bucket targets
TOOLS = {
    's3': ('aws', 'the AWS CLI (https://aws.amazon.com/cli/) — any S3-compatible store speaks '
                  'to it through --endpoint'),
    'gs': ('gcloud', 'the Google Cloud CLI (https://cloud.google.com/sdk/docs/install)'),
}


class GkPublishError(Exception):
    pass


def resolve_elf(elf_or_dir):
    """guest.elf, or the `gk build` dir holding one -> absolute ELF path."""
    path = elf_or_dir
    if os.path.isdir(path):
        path = os.path.join(path, ELF_NAME)
    if not os.path.isfile(path):
        raise GkPublishError('%s: no such ELF (give guest.elf, or the `gk build` dir that holds '
                             'one: cache/gkvm/build/<name>)' % elf_or_dir)
    return os.path.abspath(path)


def program_hash_of(elf_path):
    with open(elf_path, 'rb') as f:
        return hex32(keccak256(f.read()))


def normalize_hash(text):
    """'0x…' or bare hex -> lowercase 0x-prefixed 32-byte hex; anything else is refused."""
    text = str(text).strip()
    h = text[2:] if text[:2].lower() == '0x' else text
    if len(h) != 64 or any(c not in '0123456789abcdefABCDEF' for c in h):
        raise GkPublishError('%r is not a 32-byte hex hash' % text)
    return '0x' + h.lower()


def object_name(program_hash_hex):
    """The hash-addressed object name operators fetch: <hex64>.elf — lowercase, no 0x."""
    return normalize_hash(program_hash_hex)[2:] + '.elf'


def parse_target(target):
    """-> (kind, bucket_or_dir, prefix). kind is 'dir' | 's3' | 'gs'; bucket_or_dir is the
    bucket name, or the directory's absolute path; prefix has no leading or trailing slash
    and is '' when absent (always '' for a directory)."""
    target = str(target).strip()
    for kind in ('s3', 'gs'):
        scheme = kind + '://'
        if target.lower().startswith(scheme):
            bucket, _, prefix = target[len(scheme):].partition('/')
            if not bucket:
                raise GkPublishError('%s: no bucket name' % target)
            return kind, bucket, prefix.strip('/')
    if target.lower().startswith('file://'):
        path = target[len('file://'):]
        if not path:
            raise GkPublishError('%s: no directory' % target)
        return 'dir', os.path.abspath(path), ''
    if '://' in target:
        raise GkPublishError(
            '%s: not a publish target. A mirror is WRITTEN through a directory, '
            's3://bucket[/prefix] or gs://bucket[/prefix] and READ over https — the https URL is '
            'the MIRROR_BASE this '
            'command prints, not something it writes to. An S3-compatible store (Quilibrium '
            'QStorage, MinIO, …) is `--to s3://<bucket> --endpoint <its url>`' % target)
    if not target:
        raise GkPublishError('empty publish target')
    return 'dir', os.path.abspath(target), ''


def object_url(target, name):
    """Where the object lands, in the target's own spelling: s3://…, gs://…, or a path."""
    kind, where, prefix = parse_target(target)
    if kind == 'dir':
        return os.path.join(where, name)
    return '%s://%s/%s' % (kind, where, prefix + '/' + name if prefix else name)


def mirror_base(target, endpoint=None):
    """What an operator puts in the fleet's mirror list: the prefix `<hex64>.elf` is fetched
    under. s3 is path-style through an endpoint (`<endpoint>/<bucket>[/<prefix>]`), else
    virtual-hosted on AWS; gs is the public storage.googleapis.com host; a directory is its
    absolute path."""
    kind, where, prefix = parse_target(target)
    if kind == 'dir':
        return where
    suffix = '/' + prefix if prefix else ''
    if kind == 's3':
        if endpoint:
            return endpoint.rstrip('/') + '/' + where + suffix
        return S3_PUBLIC_HOST % where + suffix
    return GS_PUBLIC_HOST + '/' + where + suffix


def upload_command(target, elf_path, name, public=False, endpoint=None):
    """argv that uploads `elf_path` as `name` under `target`; None for a directory target
    (that one is a plain atomic copy, no command — see `publish`). `endpoint` is for s3://
    only and ignored elsewhere; `public` is ignored for a directory."""
    kind = parse_target(target)[0]
    dest = object_url(target, name)
    if kind == 's3':
        argv = ['aws', 's3', 'cp', elf_path, dest]
        if endpoint:
            argv += ['--endpoint-url', endpoint]
        if public:
            argv += ['--acl', 'public-read']
        return argv
    if kind == 'gs':
        argv = ['gcloud', 'storage', 'cp', elf_path, dest]
        if public:
            argv.append('--predefined-acl=publicRead')
        return argv
    return None


def copy_atomic(src, dest_dir, name):
    """<dest_dir>/<name> appears complete or not at all: written to a temp file in the same
    directory, then os.replace'd over the name. 0644, so a web server serves it."""
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, name)
    fd, tmp = tempfile.mkstemp(prefix='.%s.' % name, dir=dest_dir)
    try:
        with os.fdopen(fd, 'wb') as out, open(src, 'rb') as inp:
            shutil.copyfileobj(inp, out)
        os.chmod(tmp, 0o644)
        os.replace(tmp, dest)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return dest


def publish(elf_or_dir, targets, program_hash=None, public=False, endpoint=None, dry_run=False,
            log=print, run=subprocess.run):
    """Publish one ELF to every target. Returns the facts it printed:
    PROGRAM_HASH (0x…), OBJECT (<hex64>.elf), ELF (absolute path), DRY_RUN, and per target —
    in `targets` order — PUBLISHED (the object's url or path), MIRROR_BASE, COMMANDS (the argv
    run, None for a directory copy). `run(argv)` must return something with `.returncode`;
    with --dry-run it is never called and nothing is created."""
    if not targets:
        raise GkPublishError('publish wants at least one --to <dir | s3://bucket[/prefix] | '
                             'gs://bucket[/prefix]> — where operators will fetch the ELF from')
    elf = resolve_elf(elf_or_dir)
    actual = program_hash_of(elf)
    if program_hash is not None:
        wanted = normalize_hash(program_hash)
        if wanted != actual:
            raise GkPublishError(
                '%s hashes to %s, not the %s you passed: that PROGRAM_HASH is from a different '
                'build — re-run `gk build` and publish the ELF the binding was generated from'
                % (elf, actual, wanted))
    # parse every target before the first write: a bad second target writes nothing
    plans = [(t,) + parse_target(t) for t in targets]
    endpoint = endpoint or os.environ.get(ENDPOINT_ENV) or None
    name = object_name(actual)
    facts = {'PROGRAM_HASH': actual, 'OBJECT': name, 'ELF': elf, 'DRY_RUN': bool(dry_run),
             'PUBLISHED': [], 'MIRROR_BASE': [], 'COMMANDS': []}
    log('PROGRAM_HASH=%s' % actual)
    for target, kind, where, _prefix in plans:
        dest = object_url(target, name)
        argv = upload_command(target, elf, name, public=public, endpoint=endpoint)
        base = mirror_base(target, endpoint)
        if dry_run:
            log('would copy %s -> %s' % (elf, dest) if argv is None
                else 'would run: %s' % shlex.join(argv))
        elif argv is None:
            copy_atomic(elf, where, name)
        else:
            sys.stdout.flush()  # the tool inherits stdout: keep our lines ahead of its own
            try:
                proc = run(argv)
            except FileNotFoundError:
                binary, how = TOOLS[kind]
                raise GkPublishError('%s not found on PATH — install %s' % (binary, how))
            if proc.returncode != 0:
                raise GkPublishError('`%s` exited %d' % (shlex.join(argv), proc.returncode))
        facts['PUBLISHED'].append(dest)
        facts['MIRROR_BASE'].append(base)
        facts['COMMANDS'].append(argv)
        log('%s=%s' % ('WOULD_PUBLISH' if dry_run else 'PUBLISHED', dest))
        log('MIRROR_BASE=%s' % base)
    fetch = '%s/%s' % (facts['MIRROR_BASE'][0], name)
    others = '' if len(plans) == 1 else ' (any MIRROR_BASE above serves it)'
    if dry_run:
        log('dry run: nothing written. Without --dry-run, operators fetch %s on the first task '
            'that names this hash — no fleet config change%s' % (fetch, others))
    else:
        log('next: operators fetch %s on the first task that names this hash — no fleet config '
            'change%s' % (fetch, others))
    return facts
