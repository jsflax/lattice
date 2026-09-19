#!/usr/bin/env python3
"""One same-allocation Linux control/candidate diagnostic; never retries an arm."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import sys
import time

PAIR_SECONDS = 300 * 60
RESERVE_SECONDS = 600
COMMAND_SECONDS = 5400
ARMS = (
    ('A-core205', 'binding-A.json', '559c496d7997677d06cc6d1f7a7a87abc440c210'),
    ('B-core206', 'binding-B.json', 'db6bf8b97d7af22db4c1224f17bbdea80a43cc57'),
)


def write_once(path, data):
    with path.open('x') as output:
        json.dump(data, output, indent=2, sort_keys=True)
        output.write('\n')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def can_continue(result, receipts):
    """A failed assertion is observable; an unowned/live child is not safe to follow."""
    if not isinstance(result, dict) or result.get('receivedSignals') != []:
        return False
    commands = result.get('commands')
    if not isinstance(commands, list) or not commands:
        return False
    labels = set()
    for summary in commands:
        if not isinstance(summary, dict):
            return False
        label = summary.get('label')
        if not isinstance(label, str) or not re.fullmatch(r'[a-z0-9-]+', label) or label in labels:
            return False
        labels.add(label)
        try:
            command = json.loads((receipts / (label + '.json')).read_text())
        except (OSError, ValueError):
            return False
        if (not isinstance(command, dict)
                or command.get('success') is not summary.get('success')
                or command.get('receivedSignals') != []
                or not isinstance(command.get('started'), bool)):
            return False
        if command['started']:
            cleanup = command.get('cleanup', {})
            if (not isinstance(cleanup, dict)
                    or cleanup.get('groupGone') is not True
                    or cleanup.get('leaderReaped') is not True
                    or cleanup.get('errors') or cleanup.get('signals')):
                return False
    return True


def run_pair(root, packet, runner_main, *, clock=time.monotonic):
    started = clock()
    overall = started + PAIR_SECONDS
    work = overall - RESERVE_SECONDS
    receipts = root / 'pair-receipts'
    receipts.mkdir(exist_ok=False)
    boot = Path('/proc/sys/kernel/random/boot_id')
    clock_info = time.get_clock_info('monotonic')
    identity = {'runnerOS': platform.platform(), 'machine': platform.machine(),
                'cpuCount': os.cpu_count(), 'node': platform.node(),
                'bootIDHash': digest(boot) if boot.is_file() else None,
                'runID': os.environ.get('GITHUB_RUN_ID'),
                'attempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
                'workflowCommit': os.environ.get('GITHUB_SHA'),
                'monotonicClock': {'implementation': clock_info.implementation,
                                   'resolutionSeconds': clock_info.resolution,
                                   'monotonic': clock_info.monotonic,
                                   'adjustable': clock_info.adjustable}}
    result = {'schema': 1, 'scope': 'same-allocation full parallel Linux diagnostic',
              'identity': identity, 'order': [a[0] for a in ARMS], 'arms': [],
              'pairOverallSeconds': PAIR_SECONDS, 'finalizationReserveSeconds': RESERVE_SECONDS,
              'startedMonotonic': started, 'pairWorkDeadline': work,
              'pairOverallDeadline': overall, 'originalFailurePreserved': True,
              'allArmsSucceeded': False, 'candidateRuntimeSucceeded': False,
              'releaseAccepted': False, 'performanceAccepted': False,
              'stopReason': None}
    write_once(receipts / 'ADMISSION.json', result)
    for arm, binding_name, expected_core in ARMS:
        binding_path = packet / binding_name
        binding = json.loads(binding_path.read_text())
        if binding.get('coreCommit') != expected_core:
            result['stopReason'] = 'unexpected exact Core binding for ' + arm
            break
        if work - clock() < COMMAND_SECONDS:
            result['stopReason'] = 'cannot admit unchanged 5400-second command before ' + arm
            break
        arm_root = root / arm
        arm_root.mkdir(exist_ok=False)
        (arm_root / 'tmp').mkdir()
        argv = [str(packet / 'run-diagnostic.py'), '--root', str(arm_root),
                '--binding', str(binding_path), '--test-timeout', str(COMMAND_SECONDS),
                '--aggregate-root', str(root), '--pair-work-deadline', repr(work),
                '--pair-overall-deadline', repr(overall)]
        old_argv = sys.argv
        error = None
        try:
            sys.argv = argv
            runner_main()
        except Exception as caught:
            error = {'type': type(caught).__name__, 'message': str(caught)}
        finally:
            sys.argv = old_argv
        result_path = arm_root / 'receipts/RESULT.json'
        evidence = None
        evidence_hash = None
        evidence_error = None
        try:
            raw = result_path.read_bytes()
            evidence_hash = hashlib.sha256(raw).hexdigest()
            evidence = json.loads(raw)
            if not isinstance(evidence, dict):
                raise ValueError('arm RESULT must be an object')
        except (OSError, ValueError) as caught:
            evidence = None
            evidence_error = {'type': type(caught).__name__, 'message': str(caught)}
        entry = {'arm': arm, 'coreCommit': expected_core,
                 'bindingSHA256': digest(binding_path), 'argv': argv,
                 'raisedError': error, 'result': evidence,
                 'resultSHA256': evidence_hash, 'resultReadError': evidence_error}
        entry['ownershipEvidenceAccepted'] = can_continue(evidence, arm_root / 'receipts')
        result['arms'].append(entry)
        write_once(receipts / (arm + '.json'), entry)
        if not entry['ownershipEvidenceAccepted']:
            result['stopReason'] = 'missing evidence, interruption, or unclean owned process after ' + arm
            break
    result['allArmsSucceeded'] = (len(result['arms']) == 2
                                and all(isinstance(a['result'], dict)
                                        and a['result'].get('success') is True
                                        and a['raisedError'] is None for a in result['arms'])
                                and result['stopReason'] is None)
    result['candidateRuntimeSucceeded'] = any(
        a['arm'] == 'B-core206' and isinstance(a['result'], dict)
        and a['result'].get('success') is True and a['raisedError'] is None
        and a['ownershipEvidenceAccepted'] is True
        for a in result['arms'])
    result['elapsedSeconds'] = clock() - started
    if clock() > overall:
        result['stopReason'] = result['stopReason'] or 'pair overall deadline exceeded'
        result['allArmsSucceeded'] = False
    write_once(receipts / 'RESULT.json', result)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    allowed = (Path.home() / 'localdev').resolve(strict=True)
    if root == allowed or not root.is_relative_to(allowed):
        raise ValueError('pair root must be a child of ~/localdev')
    if platform.system() != 'Linux':
        raise ValueError('this finite diagnostic is Linux-only')
    if any((root / name).exists() for name in ['pair-receipts', *[a[0] for a in ARMS]]):
        raise ValueError('pair roots and evidence must be fresh; no arm retry')
    packet = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location('core206_diagnostic', packet / 'run-diagnostic.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    result = run_pair(root, packet, module.main)
    print(json.dumps({'allArmsSucceeded': result['allArmsSucceeded'],
                      'candidateRuntimeSucceeded': result['candidateRuntimeSucceeded'],
                      'stopReason': result['stopReason'], 'releaseAccepted': False}))
    if not result['allArmsSucceeded']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
