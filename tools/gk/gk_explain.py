"""`gk explain` — decode a gkvm failure into words (solidity-sdk#88).

Takes any form a failing guest reaches a developer in and says what happened:

  - the ABI-encoded revert of a gkvm typed error (`GkGuestTrap(uint32,bytes)`,
    `GkGuestOutOfCycles(uint64,uint64)`, …) — what the precompile, gk-anvil and
    GkVmFfiShim return and what a forge trace shows as returndata;
  - the line forge itself prints, pasted verbatim: `GkGuestTrap(3489660929, 0x5472…)`;
  - gk-run's one-hex-line stdout for a trap (4-byte big-endian code + raw data) or for
    out-of-cycles (8-byte used + 8-byte limit);
  - a bare trap code, decimal or hex.

The trap-code taxonomy lives in three files across two repos; this module is the one
place that knows all of it (kept in lockstep — the tests pin the constants):

    0xD0000001            micropython port   uncaught exception, data = traceback text
    0xE0000001..4         gk-guest-crt       input/artifact/manifest failures
    0xF0000001/2          host runner        memory cap / execution fault
    0xF0000100 | exit     host runner        bare nonzero exit() without gk_abort
    anything else         the guest itself   gk_abort(code, msg)

Decoding is read-only and consensus-free: nothing here touches what goes on the wire.
"""
import re

from gk_keccak import keccak256

# --- the gkvm typed errors (src/gkvm/GkVmErrors.sol; selectors recomputed, tests pin them)
ERROR_SIGS = [
    'GkVmUnavailable()',
    'GkGuestTrap(uint32,bytes)',
    'GkGuestOutOfCycles(uint64,uint64)',
    'GkVmInputOverflow()',
    'GkVmOutputOverflow()',
    'GkVmStaticOnly()',
]

# --- trap-code classes (sources named per row)
GK_MPY_TRAP_EXCEPTION = 0xD0000001    # guest-crt/micropython/gkport.h
GK_TRAP_INPUT_TOO_LARGE = 0xE0000001  # guest-crt/crt/gkvm.h
GK_TRAP_ARTIFACT_VERIFY = 0xE0000002
GK_TRAP_ARTIFACT_RANGE = 0xE0000003
GK_TRAP_MANIFEST_INVALID = 0xE0000004
GKVM_TRAP_CODE_MEM_CAP = 0xF0000001   # gas-analyzer crates/gkvm/src/runner.rs
GKVM_TRAP_CODE_EXEC_FAULT = 0xF0000002
GKVM_TRAP_CODE_BARE_EXIT = 0xF0000100  # low byte = the guest's exit code

_KNOWN_CODES = {
    GK_MPY_TRAP_EXCEPTION: (
        'GK_MPY_TRAP_EXCEPTION', 'the MicroPython port',
        'uncaught Python exception', 'the traceback text'),
    GK_TRAP_INPUT_TOO_LARGE: (
        'GK_TRAP_INPUT_TOO_LARGE', 'gk-guest-crt',
        "payload larger than the guest's input buffer", 'crt diagnostic'),
    GK_TRAP_ARTIFACT_VERIFY: (
        'GK_TRAP_ARTIFACT_VERIFY', 'gk-guest-crt',
        'artifact page failed Merkle verification against artifactRoot', 'crt diagnostic'),
    GK_TRAP_ARTIFACT_RANGE: (
        'GK_TRAP_ARTIFACT_RANGE', 'gk-guest-crt',
        'artifact read out of the bundle range', 'crt diagnostic'),
    GK_TRAP_MANIFEST_INVALID: (
        'GK_TRAP_MANIFEST_INVALID', 'gk-guest-crt',
        'malformed artifact manifest', 'crt diagnostic'),
    GKVM_TRAP_CODE_MEM_CAP: (
        'GKVM_TRAP_CODE_MEM_CAP', 'the host runner',
        'guest exceeded GKVM_MEM_BYTES_CAP', 'host diagnostic'),
    GKVM_TRAP_CODE_EXEC_FAULT: (
        'GKVM_TRAP_CODE_EXEC_FAULT', 'the host runner',
        'execution fault (illegal instruction, bad ELF semantics, …)', 'host diagnostic'),
}

GKVM_OK_TAG = 0x01


class GkExplainError(Exception):
    pass


def selector(sig):
    return keccak256(sig.encode())[:4]


def _selectors():
    return {selector(sig): sig for sig in ERROR_SIGS}


def classify(code):
    """(name, origin, meaning, data description) for a trap code."""
    if code in _KNOWN_CODES:
        return _KNOWN_CODES[code]
    if GKVM_TRAP_CODE_BARE_EXIT <= code <= GKVM_TRAP_CODE_BARE_EXIT | 0xFF:
        exit_code = code & 0xFF
        return ('GKVM_TRAP_CODE_BARE_EXIT | %d' % exit_code, 'the host runner',
                'guest exited with code %d without calling gk_abort' % exit_code, '(empty)')
    prefix = code >> 28
    if prefix == 0xD:
        return (None, 'the MicroPython port',
                'unassigned code in the 0xD… range the port reserves', 'port-defined')
    if prefix == 0xE:
        return (None, 'gk-guest-crt',
                'unassigned code in the 0xE… range the crt reserves', 'crt-defined')
    if prefix == 0xF:
        return (None, 'the host runner',
                'unassigned code in the 0xF… range the host reserves', 'host-defined')
    return (None, 'the guest itself',
            'guest-chosen abort code — grep the guest source for gk_abort(%s, …)' % hex(code),
            "the guest's abort message")


def _code_lines(code, data=None):
    name, origin, meaning, data_desc = classify(code)
    lines = ['  code   %s (%d)%s' % ('0x%08X' % code, code, ' — %s' % name if name else '')]
    lines.append('  from   %s: %s' % (origin, meaning))
    if data is None:
        return lines
    if not data:
        lines.append('  data   (empty)')
        return lines
    text = None
    try:
        decoded = data.decode('utf-8')
        if all(c.isprintable() or c in '\n\r\t' for c in decoded):
            text = decoded
    except UnicodeDecodeError:
        pass
    if text is not None:
        label = 'traceback' if code == GK_MPY_TRAP_EXCEPTION else 'text'
        lines.append('  data   %d bytes (%s) — %s:' % (len(data), data_desc, label))
        lines.extend('    ' + l for l in text.rstrip('\n').split('\n'))
    else:
        lines.append('  data   %d bytes (%s), not text: 0x%s' % (len(data), data_desc,
                                                                 data.hex()))
    return lines


def _u256(word):
    return int.from_bytes(word, 'big')


def _decode_abi(blob):
    """Explanation lines for an ABI-encoded gkvm typed error, or None when the selector
    is not one of ours."""
    sig = _selectors().get(bytes(blob[:4]))
    if sig is None:
        return None
    name = sig.split('(')[0]
    body = blob[4:]
    head = 'ABI-encoded %s revert (the precompile / gk-anvil / GkVmFfiShim shape)' % name
    if name == 'GkGuestTrap':
        if len(body) < 96:
            raise GkExplainError('GkGuestTrap blob too short for (uint32, bytes)')
        code = _u256(body[0:32])
        if code > 0xFFFFFFFF:
            raise GkExplainError('GkGuestTrap code word exceeds uint32: 0x%x' % code)
        offset = _u256(body[32:64])
        length = _u256(body[offset:offset + 32])
        data = bytes(body[offset + 32:offset + 32 + length])
        if len(data) != length:
            raise GkExplainError('GkGuestTrap data truncated: %d of %d bytes'
                                 % (len(data), length))
        return [head] + _code_lines(code, data)
    if name == 'GkGuestOutOfCycles':
        if len(body) < 64:
            raise GkExplainError('GkGuestOutOfCycles blob too short for (uint64, uint64)')
        return [head] + _out_of_cycles_lines(_u256(body[0:32]), _u256(body[32:64]))
    return [head, '  %s' % _NO_ARG_MEANINGS[name]]


_NO_ARG_MEANINGS = {
    'GkVmUnavailable': 'no gkvm precompile answered at the target address — raised by '
                       'GkVm.exec itself (empty account on a real chain, or the shim/env '
                       'is not wired)',
    'GkVmInputOverflow': 'the call payload exceeds GKVM_INPUT_BYTES_CAP (checked before '
                         'any execution)',
    'GkVmOutputOverflow': 'the guest wrote more than GKVM_OUTPUT_BYTES_CAP',
    'GkVmStaticOnly': 'the precompile was invoked outside a STATICCALL',
}


def _out_of_cycles_lines(used, limit):
    lines = ['  cycles %s used of %s allowed' % ('{:,}'.format(used), '{:,}'.format(limit))]
    lines.append('  from   the host runner: instruction budget exhausted (budget = call gas '
                 '× 4 cycles); the call consumes its full gas')
    if limit:
        lines.append('  hint   the budget was %s cycles = %s gas at the pinned 4 cyc/gas — '
                     'raise the call\'s gas above that'
                     % ('{:,}'.format(limit), '{:,}'.format(limit // 4)))
    return lines


_FORGE_LINE = re.compile(
    r'\b(GkVmUnavailable|GkGuestTrap|GkGuestOutOfCycles|GkVmInputOverflow|'
    r'GkVmOutputOverflow|GkVmStaticOnly)\s*\(([^)]*)\)')


def _decode_forge_text(text):
    """Explanation lines for a pasted forge-console line, or None."""
    m = _FORGE_LINE.search(text)
    if not m:
        return None
    name, raw_args = m.group(1), m.group(2).strip()
    args = [a.strip() for a in raw_args.split(',')] if raw_args else []
    head = 'forge-printed %s(...)' % name
    if name == 'GkGuestTrap':
        if len(args) != 2:
            raise GkExplainError('GkGuestTrap wants (code, data), got: %s' % raw_args)
        code = int(args[0], 0)
        data = bytes.fromhex(args[1][2:]) if args[1].startswith('0x') else args[1].encode()
        return [head] + _code_lines(code, data)
    if name == 'GkGuestOutOfCycles':
        if len(args) != 2:
            raise GkExplainError('GkGuestOutOfCycles wants (used, limit), got: %s' % raw_args)
        return [head] + _out_of_cycles_lines(int(args[0], 0), int(args[1], 0))
    return [head, '  %s' % _NO_ARG_MEANINGS[name]]


def _decode_hex_blob(blob):
    """Explanation lines for non-ABI hex: gk-run's stdout line, OK returndata, bare code."""
    if len(blob) >= 1 and blob[0] == GKVM_OK_TAG:
        return ['not an error: GKVM_OK_TAG-prefixed returndata (the guest halted cleanly)',
                '  output %d bytes: 0x%s' % (len(blob) - 1, blob[1:].hex())]
    if len(blob) == 4:
        return ['bare trap code'] + _code_lines(int.from_bytes(blob, 'big'))
    if len(blob) > 4:
        code = int.from_bytes(blob[:4], 'big')
        lines = []
        if classify(code)[0] is not None or code >> 28 in (0xD, 0xE, 0xF):
            lines += ["gk-run trap line (4-byte code + the guest's raw data)"]
            lines += _code_lines(code, bytes(blob[4:]))
        if len(blob) == 16:
            used, limit = int.from_bytes(blob[:8], 'big'), int.from_bytes(blob[8:], 'big')
            if used <= limit:
                alt = ['gk-run out-of-cycles line (8-byte used + 8-byte limit)']
                alt += _out_of_cycles_lines(used, limit)
                lines = lines + [''] + alt if lines else alt
        if lines:
            return lines
        raise GkExplainError(
            'unrecognized blob: not a gkvm error selector, not GKVM_OK_TAG returndata, and '
            '0x%08X is no known trap class. If this is raw guest output, it is not an error.'
            % code)
    raise GkExplainError('blob shorter than 4 bytes: 0x%s' % blob.hex())


def explain(text):
    """One human-readable, multi-line explanation for any gkvm failure shape."""
    text = text.strip()
    lines = _decode_forge_text(text)
    if lines is not None:
        return '\n'.join(lines)
    compact = re.sub(r'\s+', '', text)
    if re.fullmatch(r'\d+', compact):
        code = int(compact)
        if code > 0xFFFFFFFF:
            raise GkExplainError('%d does not fit a uint32 trap code' % code)
        return '\n'.join(['bare trap code'] + _code_lines(code))
    if re.fullmatch(r'(0[xX])?[0-9a-fA-F]+', compact):
        raw = compact[2:] if compact[:2].lower() == '0x' else compact
        if len(raw) % 2:
            raise GkExplainError('odd-length hex: %s' % text)
        blob = bytes.fromhex(raw)
        abi = _decode_abi(blob) if len(blob) >= 4 else None
        return '\n'.join(abi if abi is not None else _decode_hex_blob(blob))
    raise GkExplainError('cannot parse %r — pass a 0x… blob, a bare code, or the forge '
                         'line, e.g. gk explain "GkGuestTrap(3489660929, 0x…)"' % text)
