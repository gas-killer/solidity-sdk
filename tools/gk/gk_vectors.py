"""`gk vectors` — run a guest under the `gk-run` sidecar, record golden vectors.

The native-guest counterpart of convert.py's reference.py -> vectors.json step:
the deterministic runner is the reference, its answers are written to
`test/fixtures/<name>_vectors.json` (json.dump indent=1, 0x-hex byte strings),
and forge tests read them back with `vm.readFile`/`parseJson` under the existing
`fs_permissions` grant on ./test/fixtures.

Each vector records gk-run's whole observable result, not just the happy path:
exit code (0 ok / 10 trap / 11 out of cycles / 12, 13 caps), the one hex line
on stdout (answer, or the typed-failure frame), and the instruction count —
cycles are consensus data (gas = ceil(cycles / 4)), so they are golden too.
Environment-class exits (2, 3) are never recorded: they describe this machine,
not the guest.
"""
import json
import os
import subprocess

from gk_keccak import hex32, keccak256

OUTCOMES = {0: 'ok', 10: 'trap', 11: 'out-of-cycles', 12: 'input-overflow', 13: 'output-overflow'}

# Above this many payload bytes the hex no longer fits one argv string
# (MAX_ARG_STRLEN 131072); such inputs go to gk-run as `--input @file`.
ARGV_INPUT_BYTES = 32768

ZERO32 = '0x' + '00' * 32


class GkVectorsError(Exception):
    pass


def parse_hex(value, what):
    raw = value[2:] if value.startswith(('0x', '0X')) else value
    try:
        return bytes.fromhex(raw)
    except ValueError:
        raise GkVectorsError('%s must be hex, got %r' % (what, value))


def resolve_gk_run(gk_run):
    gk_run = gk_run or os.environ.get('GK_RUN')
    if not gk_run:
        raise GkVectorsError('gk-run not given: pass --gk-run or set GK_RUN')
    if not os.path.isfile(gk_run):
        raise GkVectorsError('gk-run not found at %s' % gk_run)
    return gk_run


def run_one(gk_run, elf_path, program_hash, payload, cycle_limit=None, artifact=None,
            scratch=None):
    """One gk-run invocation -> one vector dict."""
    if len(payload) > ARGV_INPUT_BYTES:
        if scratch is None:
            raise GkVectorsError('payload of %d bytes needs a scratch dir' % len(payload))
        os.makedirs(scratch, exist_ok=True)
        path = os.path.join(scratch, 'input-%s.bin' % keccak256(payload).hex())
        with open(path, 'wb') as f:
            f.write(payload)
        input_arg = '@' + path
    else:
        input_arg = '0x' + payload.hex()

    cmd = [gk_run, '--program', elf_path, '--program-hash', program_hash, '--input', input_arg]
    if cycle_limit is not None:
        cmd += ['--cycle-limit', str(cycle_limit)]
    if artifact:
        cmd += ['--artifact', ','.join(artifact['blobs']), '--artifact-root', artifact['root']]
        if artifact.get('schedule'):
            cmd += ['--schedule', artifact['schedule']]

    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stderr = proc.stderr.decode('utf-8', 'replace')
    if proc.returncode not in OUTCOMES:
        raise GkVectorsError('gk-run exit %d (environment/usage class — not a vector):\n%s'
                             % (proc.returncode, stderr.strip()))

    report = None
    for line in stderr.splitlines():
        if line.startswith('{'):
            report = json.loads(line)
    if report is None:
        raise GkVectorsError('gk-run printed no JSON report on stderr:\n%s' % stderr.strip())

    stdout = proc.stdout.decode('ascii').strip()
    vector = {
        'input': '0x' + payload.hex(),
        'exit': proc.returncode,
        'outcome': OUTCOMES[proc.returncode],
        'stdout': stdout or '0x',
        'cycles': report['cycles'],
        'gasUsed': report['gas_used'],
    }
    if cycle_limit is not None:
        vector['cycleLimit'] = cycle_limit
    return vector


def vectors(elf_path, inputs, gk_run=None, name=None, out=None, sdk_root='.', cycle_limit=None,
            artifact=None, log=print):
    """Run every input; write and return the vectors document."""
    gk_run = resolve_gk_run(gk_run)
    if not os.path.isfile(elf_path):
        raise GkVectorsError('no such guest ELF: %s (run `gk build` first)' % elf_path)
    if not inputs:
        raise GkVectorsError('at least one --input is required (use 0x for an empty payload)')
    with open(elf_path, 'rb') as f:
        program_hash = hex32(keccak256(f.read()))
    name = name or os.path.splitext(os.path.basename(elf_path))[0]
    scratch = os.path.join(sdk_root, 'cache', 'gkvm')

    doc = {
        'name': name,
        'programHash': program_hash,
        'artifactRoot': artifact['root'] if artifact else ZERO32,
        'vectors': [run_one(gk_run, elf_path, program_hash, parse_hex(i, '--input'),
                            cycle_limit=cycle_limit, artifact=artifact, scratch=scratch)
                    for i in inputs],
    }
    if artifact and artifact.get('schedule'):
        doc['schedule'] = artifact['schedule']

    out = out or os.path.join(sdk_root, 'test', 'fixtures', '%s_vectors.json' % name)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w') as f:
        json.dump(doc, f, indent=1)
        f.write('\n')
    log('  program   %s' % program_hash)
    for v in doc['vectors']:
        log('  vector    %-15s cycles=%-12d %s -> %s' % (
            v['outcome'], v['cycles'], _clip(v['input']), _clip(v['stdout'])))
    log('  emitted   %s' % os.path.relpath(out))
    return doc


def _clip(hexstr, width=34):
    return hexstr if len(hexstr) <= width else hexstr[:width - 1] + '…'
