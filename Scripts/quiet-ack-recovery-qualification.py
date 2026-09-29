#!/usr/bin/env python3
"""Hosted-only quiet ACK-loss B gate, separate from A and all release gates.

Imports the immutable reviewed host/runner/trust/cleanup helpers without changing
any shared global. Raw logs, keys and stores remain private on disposable hosts.
"""
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

sys.dont_write_bytecode = True
COMMON_SHA256 = 'b42640b54096278976c9997fec1353745f0cb7337c9599583d3fe476f9e56b66'
CASE_NAMES = ('oneDroppedACKRecoversOnLiveConnectionWithoutAppActivity',)
# Fixed fixture contract; receipt strings outside these labels are refused.
PHASES = frozenset(['environment', 'deadline', 'metadata', 'drop', 'connections', 'sourceImage', 'sourceCounters', 'sourceCoverage', 'receiverImage', 'originals', 'receiverSettlement', 'sqliteOpen', 'sqlitePrepare', 'sqliteStep', 'sqliteType', 'sqliteBound', 'sqliteSchema', 'sqliteCleanup', 'fixtureCleanup', 'receipt', 'completed'])
EXPECTED_FACTS = {
    'receiverCount': 2, 'channelsPerReceiver': 2, 'sharedRowsPerReceiver': 6,
    'preservedSharedOriginals': 6, 'localOnlyRowsPreserved': 2, 'appWriteCount': 1,
    'ackDropCount': 1, 'physicalConnections': 4, 'sameConnectionsLive': True,
    'noReconnectObserved': True, 'noSyncErrorsObserved': True,
    'sourceHeadDelta': 2, 'sourceReceiptDelta': 1, 'sourceOriginDelta': 1,
    'sourceCoverageDelta': 2, 'receiverSettledClaims': 2, 'installedChannels': 4,
    'cohortsOpen': 2, 'rawSnapshotsBeforePublicInspection': True,
}
FAILURE_PHASES = {}


def load_common():
    path = Path(__file__).resolve().with_name('connected-recovery-qualification.py')
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise RuntimeError('shared-wrapper-source')
    if hashlib.sha256(path.read_bytes()).hexdigest() != COMMON_SHA256:
        raise RuntimeError('shared-wrapper-source')
    spec = importlib.util.spec_from_file_location('quiet_ack_shared_host_helpers', path)
    if spec is None or spec.loader is None:
        raise RuntimeError('shared-wrapper-loader')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COMMON = load_common()
require = COMMON.require
read_file, read_json, write_json = COMMON.read_file, COMMON.read_json, COMMON.write_json
load_helpers, child_environment, Commands = COMMON.load_helpers, COMMON.child_environment, COMMON.Commands
material, trust_install, cleanup_all = COMMON.material, COMMON.trust_install, COMMON.cleanup_all
public_commands = COMMON.public_commands
SHA, HEX256 = COMMON.SHA, COMMON.HEX256
OVERALL_SECONDS, CLEANUP_SECONDS = COMMON.OVERALL_SECONDS, COMMON.CLEANUP_SECONDS
TEST_SECONDS, BUILD_SECONDS = COMMON.TEST_SECONDS, COMMON.BUILD_SECONDS


def host_root(value):
    require(os.environ.get('LATTICE_QUIET_ACK_HOSTED_GATE') == '1')
    return COMMON.host_root(value)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def case_receipt(root):
    path = root / 'receipts/quiet-ack-recovery-case.json'
    value = json.loads(read_file(path, 16384), object_pairs_hook=unique_object)
    require(type(value) is dict and set(value) == {'version', 'cases'}
            and type(value['version']) is int and value['version'] == 1
            and type(value['cases']) is list and len(value['cases']) == 1)
    case = value['cases'][0]
    require(type(case) is dict and set(case) == {'name', 'passed', 'phase', 'scalarFacts'}
            and case['name'] == CASE_NAMES[0] and type(case['passed']) is bool
            and type(case['phase']) is str and case['phase'] in PHASES)
    facts = case['scalarFacts']
    require(type(facts) is dict and set(facts) <= set(EXPECTED_FACTS) | {'quietMilliseconds'})
    for key, observed in facts.items():
        kind = int if key == 'quietMilliseconds' else type(EXPECTED_FACTS[key])
        require(type(observed) is kind)
        if kind is int:
            minimum = -1000000 if not case['passed'] and key.endswith('Delta') else 0
            require(minimum <= observed <= 1000000)
    if case['passed']:
        require(case['phase'] == 'completed'
                and set(facts) == set(EXPECTED_FACTS) | {'quietMilliseconds'}
                and all(facts[k] == v for k, v in EXPECTED_FACTS.items())
                and 45000 <= facts['quietMilliseconds'] < 120000)
    else:
        require(case['phase'] != 'completed')
    # Reconstruct only the reviewed scalar fields; no strings from raw errors,
    # records, authority, credentials, paths or original identities are exported.
    return {'version': 1, 'cases': [{'name': CASE_NAMES[0], 'passed': case['passed'],
             'phase': case['phase'], 'scalarFacts': {k: facts[k] for k in sorted(facts)}}]}


def publish_case_observation(root):
    output = root / 'public-evidence/quiet-ack-recovery-case.json'
    if output.exists() or not (root / 'receipts/quiet-ack-recovery-case.json').exists():
        return
    write_json(output, case_receipt(root))


def validate_cases(root, log):
    raw = read_file(log, 128 * 1024 * 1024).decode(errors='replace')
    raw = re.sub(r'\x1b\[[0-9;]*m', '', raw)
    require(not re.search(r'(?im)^.*(?:[✘↷⊘]|Test .* skipped|Test run .* failed)', raw))
    passed = re.findall(r'(?m)^\s*✔ Test ([A-Za-z0-9_]+)\(\) passed after [^\n]+$', raw)
    require(passed == list(CASE_NAMES))
    require(len(re.findall(r'(?m)^\s*✔ Test run with 1 test(?: in 1 suite)? passed after [^\n]+$', raw)) == 1)
    receipt = case_receipt(root)
    require(receipt['cases'][0]['passed'] is True)
    return receipt


def case_outcomes(root):
    """Observation only; cannot promote an exit, timeout, skip or missing case.

    Read only the closed first test log with actual group/leader retirement
    proof. A killed wrapper lacking that proof reports unobserved, never copies
    a still-written raw log into artifacts. Max1 case/16 locations/16 codes.
    """
    cases = {name: {'name': name, 'outcome': 'unobserved', 'started': False,
                    'failureLocations': [], 'failurePhaseCodes': []} for name in CASE_NAMES}
    result = {'version': 1, 'evidenceOnly': True, 'observation': 'not-started',
              'cases': list(cases.values()), 'processExitCode': None, 'processRetired': False}
    records = list((root / 'private/commands').glob('*-connected-tests.json'))
    logs = list((root / 'private/commands').glob('*-connected-tests.log'))
    if len(records) != 1 or len(logs) != 1 or records[0].stem != logs[0].stem:
        result['observation'] = 'unobserved-process-proof' if records or logs else 'not-started'
        return result
    record = read_json(records[0], 1024 * 1024)
    require(type(record['started']) is bool and (record['exitCode'] is None or type(record['exitCode']) is int))
    result['processExitCode'] = record['exitCode']
    result['processRetired'] = (record['cleanup']['groupGone'] is True and record['cleanup']['leaderReaped'] is True)
    if not result['processRetired']:
        result['observation'] = 'unobserved-process-proof'
        return result
    if not record['started']:
        result['observation'] = 'command-not-started'
        return result
    if logs[0].is_symlink() or not logs[0].is_file() or logs[0].stat().st_size > 128 * 1024 * 1024:
        result['observation'] = 'unobserved-log-bound'
        return result
    result['observation'] = 'closed-first-log'
    result['testLogSHA256'] = hashlib.sha256(read_file(logs[0], 128 * 1024 * 1024)).hexdigest()
    raw = read_file(logs[0], 128 * 1024 * 1024).decode(errors='replace')
    raw = re.sub(r'\x1b\[[0-9;]*m', '', raw)
    for line in raw.splitlines():
        # No unbounded log line, error description, payload or user data is
        # copied out. These regex captures only choose fixed scalar values.
        if len(line) > 16384:
            continue
        event = re.fullmatch(r'\s*([✔✘◇↷⊘]) Test ([A-Za-z0-9_]+)\(\) (.*)', line)
        if not event or event.group(2) not in cases:
            continue
        mark, name, detail = event.groups()
        case = cases[name]
        if mark == '◇' and detail == 'started.':
            case['started'] = True
        if mark == '✔' and detail.startswith('passed after ') and case['outcome'] == 'unobserved':
            case['outcome'] = 'passed'
        if mark in ('↷', '⊘') and detail.startswith('skipped') and case['outcome'] != 'failed':
            case['outcome'] = 'skipped'
        if mark == '✘' and (detail.startswith('failed after ') or detail.startswith('recorded an issue')):
            case['outcome'] = 'failed'
            location = re.search(r'(?:^|[/ ])(PublicAutomaticRecoveryIntegrationTests\.swift):([1-9][0-9]{0,5}):([1-9][0-9]{0,4}):', detail)
            if location:
                value = {'file': 'PublicAutomaticRecoveryIntegrationTests.swift',
                         'line': int(location.group(2)), 'column': int(location.group(3))}
                if value not in case['failureLocations'] and len(case['failureLocations']) < 16:
                    case['failureLocations'].append(value)
            for literal, code in FAILURE_PHASES.items():
                if 'deadline("' + literal + '")' in detail and code not in case['failurePhaseCodes'] and len(case['failurePhaseCodes']) < 16:
                    case['failurePhaseCodes'].append(code)
            for literal in ('environment', 'metadata', 'receipt', 'unexpectedOriginal'):
                if re.search(r'Caught error: ' + literal + r'\s*$', detail):
                    code = {'environment': 'fixture-environment', 'metadata': 'fixture-metadata',
                            'receipt': 'fixture-receipt', 'unexpectedOriginal': 'original-oracle'}[literal]
                    if code not in case['failurePhaseCodes'] and len(case['failurePhaseCodes']) < 16:
                        case['failurePhaseCodes'].append(code)
    return result


def source_and_tests(commands, helper, root, sdk_sha, core_sha, core_tree, openssl, result):
    sdk, core = root / 'lattice', root / 'LatticeCore'
    result['stage'] = 'exact-source-graph'
    initial_sdk = commands.guarded(helper.authenticate_repository, 'sdk-initial', sdk, sdk_sha, initial=True)
    config = read_json(sdk / 'Scripts/development-core.json')
    require(config['coreCommit'] == core_sha and config['coreTree'] == core_tree)
    original = helper.pins(sdk / 'Package.resolved')
    require(len(original) == 34 and 'latticecore' in original)
    require(not core.exists())
    commands.run('swift-version', ['swift', '--version'])
    commands.run('core-init', ['git', '-c', 'core.hooksPath=/dev/null', 'init', core])
    commands.run('core-fetch', ['git', '-c', 'core.hooksPath=/dev/null', 'fetch', '--depth=1',
                               'https://github.com/jsflax/LatticeCore.git', core_sha], cwd=core, timeout=600)
    commands.run('core-checkout', ['git', '-c', 'core.hooksPath=/dev/null', 'checkout', '--detach', core_sha], cwd=core)
    initial_core = commands.guarded(helper.authenticate_repository, 'core-initial', core, core_sha, initial=True)
    require(initial_core['tree'] == core_tree)
    write_json(root / 'public-evidence/source-inputs.json', {
        'version': 1, 'stage': 'verified-inputs', 'sdkCommit': sdk_sha, 'sdkTree': initial_sdk['tree'],
        'coreCommit': core_sha, 'coreTree': core_tree, 'trackedSDKFiles': initial_sdk['files'],
        'trackedCoreFiles': initial_core['files'], 'resolvedPins': original})
    common = ['--package-path', str(sdk), '--scratch-path', str(root / 'scratch'), '--cache-path', str(root / 'cache'),
              '--config-path', str(root / 'config'), '--security-path', str(root / 'security'),
              '--disable-sandbox', '--disable-experimental-prebuilts']
    commands.run('resolve-versioned', ['swift', 'package', *common, '--force-resolved-versions', 'resolve'], cwd=sdk, timeout=900)
    require(helper.pins(sdk / 'Package.resolved') == original)
    commands.run('edit-core', ['swift', 'package', *common, 'edit', 'LatticeCore', '--path', core], cwd=sdk)
    graph = commands.run('effective-graph-before', ['swift', 'package', *common, 'show-dependencies', '--format', 'json'], cwd=sdk)
    before = commands.guarded(helper.verify_graph, 'graph-before', helper.read_graph(graph), original, core, core_sha, root / 'scratch')
    write_json(root / 'public-evidence/source-graph.json', {
        'version': 1, 'stage': 'verified-initial-effective-graph', 'sdkCommit': sdk_sha, 'coreCommit': core_sha,
        'effectiveRevisions': {x['identity']: x['revision'] for x in before}, 'completeIdentityCount': len(before)})
    result['stage'] = 'build'
    build = commands.run('build-tests', ['swift', 'build', *common, '--force-resolved-versions', '--build-tests', '-j', '2', '-v'],
                         cwd=sdk, timeout=BUILD_SECONDS)
    compiler = helper.compiler_input_proof(build, core)
    write_json(root / 'public-evidence/compiler-inputs.json', {
        'version': 1, 'stage': 'verified-actual-compiler-inputs', 'coreCommit': core_sha, 'coreTree': core_tree,
        'sourceFiles': {str(Path(k).relative_to(core)): v for k, v in compiler['sourceFiles'].items()},
        'proofSHA256': hashlib.sha256(json.dumps(compiler, sort_keys=True).encode()).hexdigest(),
        'buildLogSHA256': helper.digest(build)})
    result['stage'] = 'tls-material'
    tag, tls, version = material(commands, root, openssl)
    result['opensslVersion'] = version
    result['stage'] = 'trust-install'
    result['trustInstall'] = trust_install(commands, root, tag, tls)
    env = commands.runner.env
    env.update(LATTICE_CONNECTED_RECOVERY_GATE='1', LATTICE_QUIET_ACK_RECOVERY_GATE='1', LATTICE_CONNECTED_RECOVERY_RUN_DIR=str(root),
               LATTICE_CONNECTED_RECOVERY_CA_CERT=str(root / 'private/tls/ca.pem'),
               LATTICE_CONNECTED_RECOVERY_TLS_CERT=str(root / 'private/tls/matching.pem'),
               LATTICE_CONNECTED_RECOVERY_TLS_KEY=str(root / 'private/tls/matching.key'),
               LATTICE_CONNECTED_RECOVERY_WRONG_HOST_CERT=str(root / 'private/tls/wrong-host.pem'),
               LATTICE_CONNECTED_RECOVERY_WRONG_HOST_KEY=str(root / 'private/tls/wrong-host.key'),
               LATTICE_CONNECTED_RECOVERY_TLS_RECEIPT=str(root / 'receipts/tls-material.json'))
    result['stage'] = 'connected-tests'
    test = commands.run('connected-tests', ['swift', 'test', *common, '--force-resolved-versions', '--skip-build',
                                            '--filter', 'PublicQuietACKLossRecoveryTests'],
                        cwd=sdk, timeout=TEST_SECONDS, full=True)
    cases = validate_cases(root, test)
    result['stage'] = 'final-source-graph'
    graph = commands.run('effective-graph-after', ['swift', 'package', *common, 'show-dependencies', '--format', 'json'], cwd=sdk)
    after = commands.guarded(helper.verify_graph, 'graph-after', helper.read_graph(graph), original, core, core_sha, root / 'scratch')
    require(before == after)
    final_sdk = commands.guarded(helper.authenticate_repository, 'sdk-final', sdk, sdk_sha, allowed_changes=('Package.resolved',))
    final_core = commands.guarded(helper.authenticate_repository, 'core-final', core, core_sha)
    require(final_core == initial_core)
    require(final_sdk['files'] == {k: v for k, v in initial_sdk['files'].items() if k != 'Package.resolved'})
    final_pins = helper.pins(sdk / 'Package.resolved')
    require({k: v for k, v in final_pins.items() if k != 'latticecore'} == {k: v for k, v in original.items() if k != 'latticecore'})
    # Reconstruct, never copy arbitrary logs or directory trees to artifacts.
    write_json(root / 'public-evidence/tls-material.json', tls)
    write_json(root / 'public-evidence/quiet-ack-recovery-case.json', cases)
    write_json(root / 'public-evidence/source-bindings.json', {
        'version': 1, 'sdkCommit': sdk_sha, 'sdkTree': initial_sdk['tree'], 'coreCommit': core_sha, 'coreTree': core_tree,
        'trackedSDKFiles': initial_sdk['files'], 'trackedCoreFiles': initial_core['files'],
        'resolvedPins': original, 'effectiveRevisions': {x['identity']: x['revision'] for x in before},
        'compilerInputs': {str(Path(k).relative_to(core)): v for k, v in compiler['sourceFiles'].items()},
        'compilerInputProofSHA256': hashlib.sha256(json.dumps(compiler, sort_keys=True).encode()).hexdigest(),
        'testLogSHA256': helper.digest(test), 'testLogBytes': test.stat().st_size,
        'allOtherSourceAndPinsPreserved': True})
    result['oneCasePassed'] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--core-sha')
    parser.add_argument('--core-tree')
    parser.add_argument('--openssl', type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--cleanup-only', action='store_true')
    args = parser.parse_args()
    root = host_root(args.root)
    helper = load_helpers(root / 'lattice')
    if args.cleanup_only:
        logs = root / 'private/cleanup-always'
        logs.mkdir(mode=0o700, exist_ok=False)
        result = {'version': 1, 'success': False, 'stage': 'always-cleanup'}
        try:
            with helper.Interrupts() as interrupts:
                commands = Commands(helper, root, logs, child_environment(root), interrupts, CLEANUP_SECONDS)
                commands.runner.free_floor = 0
                commands.runner.packet_ceiling = 2**63 - 1
                with interrupts.hold():
                    result['cleanup'] = cleanup_all(commands, root)
            # A killed main process must never become passing solely because
            # cleanup succeeded. This mode reports cleanup; main result stands.
            result['success'] = result['cleanup']['success']
        except BaseException as error:
            result['errorClass'] = type(error).__name__
        if not (root / 'public-evidence/case-outcomes.json').exists():
            try:
                write_json(root / 'public-evidence/case-outcomes.json', case_outcomes(root))
            except BaseException as error:
                result['caseEvidenceErrorClass'] = type(error).__name__
                result['success'] = False
        try:
            publish_case_observation(root)
        except BaseException as error:
            result['receiptEvidenceErrorClass'] = type(error).__name__
            result['success'] = False
        write_json(root / 'public-evidence/always-cleanup.json', result)
        print('quiet ACK gate always-cleanup success', result['success'], flush=True)
        return 0 if result['success'] else 1
    require(SHA.fullmatch(os.environ.get('GITHUB_SHA', '')) and SHA.fullmatch(args.core_sha or '')
            and SHA.fullmatch(args.core_tree or '') and args.openssl is not None)
    require(args.openssl.is_absolute() and args.openssl.is_file())
    for name in ('private', 'receipts', 'public-evidence', 'module-cache', 'cache', 'config', 'security', 'scratch'):
        (root / name).mkdir(mode=0o700, exist_ok=False)
    (root / 'tmp').mkdir(mode=0o700, exist_ok=True)
    logs = root / 'private/commands'
    logs.mkdir(mode=0o700)
    result = {'version': 1, 'scope': 'B quiet ACK loss only', 'sdkCommit': os.environ['GITHUB_SHA'],
              'coreCommit': args.core_sha, 'coreTree': args.core_tree, 'platform': platform.system(),
              'integrationTimeoutSeconds': TEST_SECONDS, 'buildTimeoutSeconds': BUILD_SECONDS,
              'overallSeconds': OVERALL_SECONDS, 'cleanupReserveSeconds': CLEANUP_SECONDS,
              'success': False, 'oneCasePassed': False, 'stage': 'initialization',
              'fullSuiteAccepted': False, 'performanceAccepted': False, 'releaseAccepted': False}
    started = time.monotonic()
    with helper.Interrupts() as interrupts:
        commands = Commands(helper, root, logs, child_environment(root), interrupts, OVERALL_SECONDS - CLEANUP_SECONDS)
        try:
            source_and_tests(commands, helper, root, os.environ['GITHUB_SHA'], args.core_sha, args.core_tree, args.openssl, result)
        except BaseException as error:
            result['errorClass'] = type(error).__name__
        finally:
            with interrupts.hold():
                cleanup_logs = root / 'private/cleanup-final'
                cleanup_logs.mkdir(mode=0o700)
                # Independent bounded cleanup remains available after timeout,
                # low-space refusal or signal. No tests run in this allowance.
                cleanup_interrupts = helper.Interrupts()
                cleanup = Commands(helper, root, cleanup_logs, child_environment(root), cleanup_interrupts, CLEANUP_SECONDS)
                # The standard disk floor is a work-admission fence; removing
                # our trust/keys must still proceed under low disk space.
                cleanup.runner.free_floor = 0
                cleanup.runner.packet_ceiling = 2**63 - 1
                try:
                    result['cleanup'] = cleanup_all(cleanup, root)
                except BaseException as error:
                    result['cleanupErrorClass'] = type(error).__name__
                result['signalsReceived'] = list(interrupts.received)
                result['elapsedSeconds'] = time.monotonic() - started
                result['success'] = (result['oneCasePassed'] and not result.get('errorClass')
                    and not result.get('cleanupErrorClass') and not result['signalsReceived']
                    and result['cleanup']['success'])
                try:
                    write_json(root / 'public-evidence/case-outcomes.json', case_outcomes(root))
                except BaseException as error:
                    result['caseEvidenceErrorClass'] = type(error).__name__
                    result['success'] = False
                try:
                    write_json(root / 'public-evidence/commands.json', public_commands(logs))
                except BaseException as error:
                    result['evidenceErrorClass'] = type(error).__name__
                    result['success'] = False
                try:
                    publish_case_observation(root)
                except BaseException as error:
                    result['receiptEvidenceErrorClass'] = type(error).__name__
                    result['success'] = False
                write_json(root / 'public-evidence/result.json', result)
    print('quiet ACK gate success', result['success'], 'stage', result['stage'], flush=True)
    return 0 if result['success'] else 1

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as failure:
        print('quiet ACK gate early failure', type(failure).__name__, flush=True)
        sys.exit(1)
