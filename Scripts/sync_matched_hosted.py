#!/usr/bin/env python3
"""Issue same-host phases; exec each original owner without a nested supervisor."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import sys
import time

BASELINE = 'c30f2f30e229dc917f4aa2583ce3c872b5abbecb'
BASELINE_CORE = 'a05fd480236430ab0d707ed0201d3edbef299de5'
PHASES = ('prepare-A', 'prepare-B', 'measure')
PHASE_SECONDS = 12600  # Existing owner includes its unchanged600s reserve.
ENVELOPE_SECONDS = 330 * 60
FINAL_RESERVE = 600
UPLOAD_BYTES = 2 * 2**30
UPLOAD_FILE_BYTES = 512 * 2**20
UPLOAD_FILES = 2048
SHA = re.compile(r'[0-9a-f]{40}')
SCOPE = 'Same-host matched measurement orchestration only; no release, recovery, goal or adoption acceptance.'


def save(path, value):
    with path.open('x') as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')


def read(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('missing original regular receipt: ' + str(path))
    return json.loads(path.read_text())


def identity(env):
    value = {key: env.get(key, '') for key in ('GITHUB_REPOSITORY', 'GITHUB_SHA',
        'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB', 'DEVELOPMENT_LEG')}
    if (env.get('GITHUB_ACTIONS') != 'true' or env.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
            or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', value['GITHUB_REPOSITORY'])
            or not SHA.fullmatch(value['GITHUB_SHA']) or value['GITHUB_SHA'] == BASELINE
            or any(not re.fullmatch(r'[1-9][0-9]*', value[key]) for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'))
            or not value['GITHUB_JOB'] or value['DEVELOPMENT_LEG'] not in ('linux', 'macos')):
        raise ValueError('actual workflow dispatch/run/attempt/job/leg identity required')
    return value


def profile_names():
    return [f'matched-{group}-{leg}-{profile}' for group in range(1, 6)
            for leg in ('A', 'A2', 'B') for profile in ('loaded', 'quiet-only')]


def roots(root, ident):
    allowed = (Path.home() / 'localdev').resolve(strict=True)
    expected = allowed / ('lattice-sync-matched-' + ident['GITHUB_RUN_ID'] + '-'
                          + ident['GITHUB_RUN_ATTEMPT'] + '-' + ident['DEVELOPMENT_LEG'])
    if root.is_symlink() or root.resolve(strict=True) != expected:
        raise ValueError('exact original workflow-owned localdev root required')
    values = {name: root / name for name in ('baseline', 'candidate')}
    for path in values.values():
        if path.is_symlink() or path.resolve(strict=True) != path:
            raise ValueError('prepared root cannot be an alias')
    return values


def pins(root, ident):
    result = {}
    for name, revision in (('baseline', BASELINE), ('candidate', ident['GITHUB_SHA'])):
        sdk = root / name / 'lattice'
        if sdk.is_symlink() or (sdk / '.git').is_symlink() or (sdk / '.git/HEAD').read_text().strip() != revision:
            raise ValueError('actual detached SDK original differs: ' + name)
        config = read(sdk / 'Scripts/development-core.json')
        if not SHA.fullmatch(config.get('coreCommit', '')) or not SHA.fullmatch(config.get('coreTree', '')):
            raise ValueError('exact committed Core pin/tree required')
        if name == 'baseline' and config['coreCommit'] != BASELINE_CORE:
            raise ValueError('baseline original Core changed')
        result[name] = {'sdkCommit': revision, 'coreCommit': config['coreCommit'], 'coreTree': config['coreTree']}
    return result


def command(root, ident, binding, phase):
    if phase == 'measure':
        return [sys.executable, str(root / 'candidate/lattice/Scripts/sync_matched_experiment.py'),
                '--root', str(root), '--baseline-root', str(root / 'baseline'),
                '--candidate-root', str(root / 'candidate')]
    name = 'baseline' if phase == 'prepare-A' else 'candidate'
    original = root / name
    return [sys.executable, str(original / 'lattice/Scripts/run-development.py'),
            '--root', str(original), '--sdk-sha', binding[name]['sdkCommit'],
            '--core-sha', binding[name]['coreCommit'], '--test-timeout',
            '5400' if ident['DEVELOPMENT_LEG'] == 'linux' else '1800', '--sync-matched-prepare']


def admit(start_ns, now_ns):
    if type(start_ns) is not int or start_ns <= 0 or now_ns < start_ns:
        raise ValueError('original monotonic envelope is invalid')
    remaining_ns = (ENVELOPE_SECONDS - FINAL_RESERVE) * 10**9 - (now_ns - start_ns)
    if remaining_ns < PHASE_SECONDS * 10**9:
        raise ValueError('hosted envelope cannot admit the full unchanged12600s phase; later work remains unattempted')
    return remaining_ns / 1e9


def context(root):
    ident = identity(os.environ)
    roots(root, ident)
    bootstrap = read(root / 'hosted-receipts/BOOTSTRAP.json')
    if (bootstrap['identity'] != ident or bootstrap['root'] != str(root)
            or bootstrap['host'] != dict(platform.uname()._asdict())
            or read(root / 'hosted-receipts/BOOTSTRAP-RESULT.json')['exitCode'] != 0):
        raise ValueError('actual same-host bootstrap did not finish')
    return ident, bootstrap, pins(root, ident)


def initialize(root):
    ident, bootstrap, binding = context(root)
    save(root / 'hosted-receipts/PLAN.json', {'scope': SCOPE, 'identity': ident,
        'bindings': binding, 'phases': list(PHASES), 'plannedProfiles': profile_names(),
        'profileDenominator': 30, 'baselineOriginal': str(root / 'baseline'),
        'candidateOriginal': str(root / 'candidate'), 'bootstrapMonotonicNS': bootstrap['monotonicNS'],
        'envelopeSeconds': ENVELOPE_SECONDS, 'finalizationReserveSeconds': FINAL_RESERVE,
        'originalPhaseOverallSeconds': PHASE_SECONDS, 'originalPhaseReserveSeconds': 600,
        'originalProfileChildSeconds': 300, 'originalTimelySeconds': 60, 'additionalCaptureSeconds': 120})


def execute(root, phase):
    ident, bootstrap, binding = context(root)
    receipts = root / 'hosted-receipts'
    plan = read(receipts / 'PLAN.json')
    if plan['identity'] != ident or plan['bindings'] != binding:
        raise ValueError('original issued graph binding changed')
    for prior in PHASES[:PHASES.index(phase)]:
        if read(receipts / (prior + '-RESULT.json'))['success'] is not True:
            raise ValueError('prior phase did not qualify')
    argv = command(root, ident, binding, phase)
    # Record even a refused admission. An exec attempt is not process/cleanup proof.
    issued = {'phase': phase, 'argv': argv, 'identity': ident, 'bindings': binding,
              'execAttempted': False, 'admissionError': None, 'monotonicNS': time.monotonic_ns()}
    try:
        issued['remainingWorkSeconds'] = admit(bootstrap['monotonicNS'], issued['monotonicNS'])
        issued['execAttempted'] = True
    except Exception as error:
        issued['admissionError'] = str(error)
    save(receipts / (phase + '-ISSUED.json'), issued)
    if issued['admissionError']:
        raise ValueError(issued['admissionError'])
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    # No new session or parent supervisor: the genuine original owner replaces us.
    os.execve(sys.executable, argv, env)


def complete(root, phase, exit_code):
    ident, _, binding = context(root)
    issued = read(root / 'hosted-receipts' / (phase + '-ISSUED.json'))
    result = {'phase': phase, 'exitCode': exit_code, 'success': False, 'error': None,
              'innerResult': None, 'innerResultSHA256': None}
    try:
        name = 'baseline' if phase == 'prepare-A' else 'candidate'
        path = root / ('matched-receipts/RESULT.json' if phase == 'measure' else name + '/receipts/RESULT.json')
        original = read(path)
        result.update(innerResult=str(path), innerResultSHA256=hashlib.sha256(path.read_bytes()).hexdigest())
        if issued['identity'] != ident or issued['bindings'] != binding or issued['execAttempted'] is not True or exit_code != 0:
            raise ValueError('original phase exec/admission/exit failed')
        if original.get('success') is not True or original.get('evidenceErrors') or original.get('receivedSignals'):
            raise ValueError('real original phase result refused')
        if phase == 'measure':
            if (original.get('numericalGatesPass') is not True or len(original.get('attemptedProfiles', [])) != 30
                    or set(original['attemptedProfiles']) != set(profile_names()) or original.get('unattempted') != []):
                raise ValueError('full original30-profile numerical denominator did not qualify')
        elif (original.get('syncMatchedPreparation') is not True
                or original.get('workflowCommit') != ident['GITHUB_SHA']
                or original.get('sdkCommit') != binding[name]['sdkCommit']
                or original.get('coreCommit') != binding[name]['coreCommit']):
            raise ValueError('real original preparation graph mismatch')
        result['success'] = True
    except Exception as error:
        result['error'] = str(error)
    save(root / 'hosted-receipts' / (phase + '-RESULT.json'), result)
    if not result['success']:
        raise ValueError(result['error'])


def retain(root):
    """Copy only bounded existing evidence, never stores/builds/caches."""
    destination = root / 'upload'
    destination.mkdir(exist_ok=False)
    selected = []
    for name in ('baseline', 'candidate'):
        for pattern in ('receipts/**/*', 'test-logs/**/*', 'visibility-smoke/receipts.json'):
            selected.extend((root / name).glob(pattern))
    for pattern in ('matched-receipts/**/*', 'captures/*/*/*/receipts.json', 'MATCHED-*.json'):
        selected.extend(root.glob(pattern))
    manifest = {'limitBytes': UPLOAD_BYTES, 'fileLimitBytes': UPLOAD_FILE_BYTES,
                'fileCountLimit': UPLOAD_FILES, 'stagedFiles': 0, 'copied': [], 'omitted': [], 'bytes': 0}
    for path in sorted(set(selected)):
        if path.is_dir() and not path.is_symlink():
            continue
        relative = str(path.relative_to(root))
        size = path.lstat().st_size
        aliases = any(parent.is_symlink() for parent in (path, *path.parents) if parent != root and parent.is_relative_to(root))
        if (aliases or not path.is_file() or path.suffix not in ('.json', '.jsonl', '.log', '.txt', '.ips', '.original', '.resolved', '.xml')
                or size > UPLOAD_FILE_BYTES
                or manifest['stagedFiles'] >= UPLOAD_FILES or manifest['bytes'] + size > UPLOAD_BYTES):
            manifest['omitted'].append({'path': relative, 'bytes': size, 'reason': 'bounded regular evidence refusal'})
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        copied = 0
        with path.open('rb') as source, target.open('xb') as output:
            manifest['stagedFiles'] += 1
            while copied < size:
                block = source.read(min(1024 * 1024, size - copied))
                if not block:
                    break
                output.write(block)
                digest.update(block)
                copied += len(block)
            changed = copied != size or bool(source.read(1))
        manifest['bytes'] += copied
        if changed:
            partial = target.with_name(target.name + '.partial-refused')
            target.rename(partial)
            manifest['omitted'].append({'path': relative, 'bytes': size, 'copiedBytes': copied,
                'partialPath': str(partial.relative_to(destination)), 'reason': 'source length changed during bounded evidence copy'})
        else:
            manifest['copied'].append({'path': relative, 'bytes': copied, 'sha256': digest.hexdigest()})
    return manifest


def finalize(root):
    roots(root, identity(os.environ))
    receipts = root / 'hosted-receipts'
    phases = {}
    errors = []

    def failed_read(label, error):
        errors.append({'receipt': label, 'type': type(error).__name__, 'message': str(error)})

    for phase in PHASES:
        path = receipts / (phase + '-RESULT.json')
        if path.exists():
            try:
                row = read(path)
                if not isinstance(row, dict) or type(row.get('success')) is not bool:
                    raise ValueError('original phase result shape is invalid')
                phases[phase] = row
            except Exception as error:
                failed_read(phase + '-RESULT.json', error)
                phases[phase] = {'success': False, 'state': 'malformed-outcome-unknown'}
        else:
            phases[phase] = {'success': False,
                'state': 'issued-outcome-unknown' if (receipts / (phase + '-ISSUED.json')).exists() else 'unattempted'}
    issued_path = receipts / 'measure-ISSUED.json'
    # None means unknown, including malformed issuance; it is never zero attempts.
    issued = False
    if issued_path.exists():
        try:
            original_issued = read(issued_path)
            if not isinstance(original_issued, dict) or type(original_issued.get('execAttempted')) is not bool:
                raise ValueError('original measurement issuance shape is invalid')
            issued = original_issued['execAttempted']
        except Exception as error:
            issued = None
            failed_read('measure-ISSUED.json', error)
    known_unattempted = (issued is False and phases['measure'].get('state') != 'malformed-outcome-unknown'
                         and (issued_path.exists() or phases['measure'].get('state') == 'unattempted'))
    progress = {'profileDenominator': 30, 'attemptedProfiles': [] if known_unattempted else None,
                'unattempted': profile_names() if known_unattempted else None}
    inner = root / 'matched-receipts/RESULT.json'
    measurement_complete = False
    if inner.exists():
        try:
            original = read(inner)
            attempted, unattempted = original['attemptedProfiles'], original['unattempted']
            if (not isinstance(attempted, list) or not isinstance(unattempted, list)
                    or len(attempted) + len(unattempted) != 30
                    or any(not isinstance(name, str) for name in attempted + unattempted)
                    or set(attempted + unattempted) != set(profile_names())):
                raise ValueError('original measurement progress is invalid')
            progress.update(attemptedProfiles=attempted, unattempted=unattempted,
                            originalResultSHA256=hashlib.sha256(inner.read_bytes()).hexdigest())
            measurement_complete = (original.get('success') is True and original.get('numericalGatesPass') is True
                                    and len(attempted) == 30 and not unattempted)
        except Exception as error:
            failed_read('matched-receipts/RESULT.json', error)
            progress.update(attemptedProfiles=None, unattempted=None)
    result = {'scope': SCOPE, 'success': False, 'phases': phases, 'progress': progress,
              'releaseOrGoalAccepted': False, 'retentionError': None, 'evidenceErrors': errors}
    try:
        manifest = retain(root)
        save(receipts / 'UPLOAD-MANIFEST.json', manifest)
        result['success'] = (all(row.get('success') is True for row in phases.values())
                             and measurement_complete and not errors and not manifest['omitted'])
        if manifest['omitted']:
            result['retentionError'] = 'bounded evidence omissions; original files remain in owned root'
    except Exception as error:
        result['retentionError'] = str(error)
    save(receipts / 'FINAL.json', result)
    if not result['success']:
        raise ValueError('hosted comparison incomplete/refused; actual failure and denominator retained')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('action', choices=('initialize', 'execute', 'complete', 'finalize'))
    parser.add_argument('--phase', choices=PHASES)
    parser.add_argument('--exit-code', type=int)
    args = parser.parse_args()
    if args.action in ('execute', 'complete') and args.phase is None:
        parser.error('--phase required')
    if args.action == 'complete' and args.exit_code is None:
        parser.error('actual --exit-code required')
    {'initialize': lambda: initialize(args.root), 'execute': lambda: execute(args.root, args.phase),
     'complete': lambda: complete(args.root, args.phase, args.exit_code),
     'finalize': lambda: finalize(args.root)}[args.action]()


if __name__ == '__main__':
    main()
