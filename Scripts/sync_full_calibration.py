"""One full loaded/quiet control pair for qualification, never A/A2/B acceptance.

Only the enclosing exact-source runner launches native work. Its existing
GuardedRunner owns each process, timeout, resource limit and cleanup receipt.
"""
import hashlib
import json
import sync_measurement_logging
import os
from pathlib import Path
import platform
import re

import evaluate_sync
from sync_probe_qualification import FLAGS, check_native_summary

CASE = 'offeredLoadPublicVisibilityProfile'
FILTER = 'SyncPublicVisibilityTests/' + CASE
PROFILES = (('loaded', 8201), ('quiet-only', 41))
TIMEOUT = 300
PREFIX = 'LATTICE_SYNC_VISIBILITY_'
SCOPE = 'Full workload calibration/qualification only; no A/A2/B, performance, release or goal acceptance.'


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    with path.open('x') as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')


def failure(error):
    return {'type': type(error).__name__, 'message': str(error)[:2048]}


def clean_exit(command):
    """An ordinary failed assertion may permit the independent quiet control.

    A signal, timeout, resource refusal or missing cleanup proof does not.
    GuardedRunner separately rechecks remaining budget/resources before launch.
    """
    cleanup = command.get('cleanup', {})
    return (command.get('started') is True and type(command.get('exitCode')) is int
            and command['exitCode'] >= 0 and not command.get('stopReason')
            and not command.get('primaryError') and not command.get('evidenceErrors')
            and not command.get('receivedSignals') and cleanup.get('groupGone') is True
            and cleanup.get('leaderReaped') is True and not cleanup.get('signals')
            and not cleanup.get('errors'))


def require_flags(argv):
    for index in range(0, len(FLAGS), 2):
        pair = FLAGS[index:index + 2]
        if sum(argv[i:i + 2] == pair for i in range(len(argv) - 1)) != 1:
            raise ValueError('exactly one Swift/C/C++ probe flag pair is required: ' + pair[0])


def make_binding(root, sdk_inputs, core_inputs, graph, toolchain, build, native,
                 compiler_inputs, env, host):
    """Pure metadata derivation from inputs authenticated by the outer runner.

    Build identity excludes execution IDs, host name and owned-root spelling.
    The raw input receipt hashes are retained separately by prepare_binding.
    """
    for command in (build, native):
        if not command.get('success') or not clean_exit(command):
            raise ValueError('native probe and SDK build must have successful isolated exits')
        require_flags(command['argv'])
    if not toolchain.strip():
        raise ValueError('actual Swift toolchain output is missing')
    actual_graph = sorted([{'identity': row['identity'], 'revision': row['revision'],
                            'location': row['location']} for row in graph], key=lambda x: x['identity'])
    if (len(actual_graph) != 34 or len({row['identity'] for row in actual_graph}) != 34
            or [row['revision'] for row in actual_graph if row['identity'] == 'latticecore'] != [core_inputs['commit']]):
        raise ValueError('authenticated graph must contain the exact Core and all 33 other pins')
    relative_sources = {}
    for name, value in compiler_inputs['sourceFiles'].items():
        relative_sources[str(Path(name).relative_to(core_inputs['path']))] = value
    samples = compiler_inputs['samples']
    if not relative_sources or not samples:
        raise ValueError('actual SDK compiler inputs are missing')
    if any('-DLATTICE_SYNC_COMMIT_PROBE' not in sample['command'] for sample in samples):
        raise ValueError('actual Core compiler command lacks the probe define')
    normalize = lambda arg: arg.replace(str(root), '$OWNED_ROOT')
    configuration = {
        'sdk': {k: sdk_inputs[k] for k in ('commit', 'tree')},
        'core': {k: core_inputs[k] for k in ('commit', 'tree')},
        'graph': actual_graph, 'toolchain': toolchain.strip(),
        'platform': {'system': host['system'], 'machine': host['machine']},
        'sdkBuildArgv': [normalize(arg) for arg in build['argv']],
        'nativeProbeArgv': [normalize(arg) for arg in native['argv']],
        'actualCoreCompilerSources': relative_sources, 'probeFlags': FLAGS,
        'actualCoreCompilerCommands': [normalize(sample['command'])
                                       for sample in sorted(samples, key=lambda x: x['source'])],
    }
    for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'):
        if not re.fullmatch(r'[1-9][0-9]*', env.get(key, '')):
            raise ValueError('missing actual workflow execution identity: ' + key)
    for key in ('GITHUB_REPOSITORY', 'GITHUB_JOB', 'DEVELOPMENT_LEG'):
        if not re.fullmatch(r'[A-Za-z0-9_./-]+', env.get(key, '')):
            raise ValueError('missing actual workflow execution identity: ' + key)
    sync_measurement_logging.require_controls(env)
    logging = {'policy': sync_measurement_logging.POLICY,
               'nativeLevel': 'fixture sets off; start/end readback required',
               'nativeSink': 'fixture nil FILE setter selects stderr; no sink getter',
               'swiftLogging': 'LOG_LEVEL absent; pinned library defaults retained',
               'ordinaryDiagnosticControls': 'observer-worker=0;ack-path=0;sql-dump=absent'}
    group = ':'.join(['calibration'] + [env[key] for key in (
        'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB', 'DEVELOPMENT_LEG')])
    metadata = {'SDK_REVISION': sdk_inputs['commit'], 'CORE_REVISION': core_inputs['commit'],
                'BUILD_ID': 'sha256:' + fingerprint(configuration),
                'HOST_ID': 'sha256:' + fingerprint(host), 'RUN_GROUP': group,
                'LOGGING': sync_measurement_logging.POLICY}
    return {'scope': SCOPE, 'performanceAccepted': False, 'buildConfiguration': configuration,
            'hostFacts': host, 'loggingPolicy': logging, 'metadata': metadata}


def prepare_binding(runner, root, sdk_inputs, core_inputs):
    names = ['graph-before.json', 'swift-version.log', 'build-tests.json', 'native-probe.json',
             'native-probe-qualification.json', 'compiler-input-proof.json']
    read = lambda name: json.loads((runner.receipts / name).read_text())
    native = read('native-probe-qualification.json')
    check_native_summary(native['tests'])
    host = dict(platform.uname()._asdict(), cpuCount=os.cpu_count())
    binding = make_binding(root, sdk_inputs, core_inputs, read('graph-before.json'),
                           (runner.receipts / 'swift-version.log').read_text(),
                           read('build-tests.json'), read('native-probe.json'),
                           read('compiler-input-proof.json'), runner.env, host)
    binding['inputSHA256'] = {name: digest(runner.receipts / name) for name in names}
    save(runner.receipts / 'sync-full-calibration-binding.json', binding)
    return binding


def profile_plan(root, binding, original_env):
    plans = []
    for order, (profile, count) in enumerate(PROFILES, start=1):
        directory = root / ('visibility-full-' + profile)
        if directory.exists() or directory.is_symlink():
            raise ValueError('full profile needs an unused evidence directory: ' + str(directory))
        metadata = dict(binding['metadata'], RUN_ORDER=f'{order}:{profile}')
        env = {key: value for key, value in original_env.items() if not key.startswith(PREFIX)}
        env = sync_measurement_logging.apply_environment(env)
        env.update({PREFIX + key: value for key, value in metadata.items()})
        env.update({PREFIX + 'PERF': '1', PREFIX + 'PROFILE': profile,
                    PREFIX + 'RUN_DIR': str(directory)})
        plans.append({'profile': profile, 'expectedCount': count, 'directory': directory,
                      'metadata': metadata, 'env': env, 'label': 'sync-full-' + profile})
    return plans


def analyze_profile(data, profile, metadata):
    analysis = evaluate_sync.analyze(data)
    expected = dict(evaluate_sync.FULL, writerCount=0 if profile == 'quiet-only' else 8)
    count = dict(PROFILES)[profile]
    violations = []
    contract_matches = (analysis['mode'] == 'full' and analysis['clock'] == evaluate_sync.NATIVE_CLOCK
                        and analysis['profile'] == profile and analysis['effectiveParameters'] == expected
                        and analysis['receiptCount'] == count and analysis['expectedReceiptCount'] == count)
    metadata_matches = all(analysis['metadata'].get(key) == value for key, value in metadata.items())
    if not analysis['validCompleteRun'] or not contract_matches:
        violations.append('full profile did not prove every unchanged expected operation with native origins')
    logging_matches = sync_measurement_logging.metadata_valid(analysis['metadata'])
    if not logging_matches:
        violations.append('measurement logging setup/readback attestation missing or contradictory')
    if not metadata_matches:
        violations.append('declared metadata differs from inspected graph/build/host/run/logging binding')
    return {'analysis': analysis, 'violations': violations, 'qualified': not violations,
            'evidenceUsable': contract_matches and metadata_matches and logging_matches,
            'scope': SCOPE, 'performanceAccepted': False, 'experimentAccepted': False}


def inspect_full_log(path):
    """One exact terminal result, including a retained ordinary assertion failure.

    A start/issue/summary line alone is not test completion evidence. Keep the
    affirmative-only qualification rule in check_full_log and inspect_profile.
    """
    executed = []
    with path.open() as lines:
        for line in lines:
            plain = re.sub(r'\x1b\[[0-9;]*m', '', line).strip()
            passed = re.fullmatch(r'[✔✓] Test (\w+)\(\) passed after [0-9.]+ seconds?\.', plain)
            failed = re.fullmatch(r'[✘✗] Test (\w+)\(\) failed after [0-9.]+ seconds? with [1-9][0-9]* issues?\.', plain)
            if passed or failed:
                executed.append({'case': (passed or failed).group(1), 'outcome': 'passed' if passed else 'failed'})
                if len(executed) > 1:
                    raise ValueError('full process ran multiple terminal test cases')
    if len(executed) != 1 or executed[0]['case'] != CASE:
        raise ValueError('full process lacks its one exact terminal test completion')
    return executed[0]


def check_full_log(path):
    terminal = inspect_full_log(path)
    if terminal['outcome'] != 'passed':
        raise ValueError('full process lacks its one exact affirmative test completion')
    return [terminal['case']]


def inspect_profile(runner, plan):
    """Retain missing, invalid and incomplete evidence before returning failure."""
    label = plan['label']
    report = {'scope': SCOPE, 'profile': plan['profile'], 'expectedCount': plan['expectedCount'],
              'expectedMetadata': plan['metadata'], 'performanceAccepted': False,
              'experimentAccepted': False, 'qualified': False, 'evidenceUsable': False, 'errors': []}
    command = None
    terminal_usable = receipts_usable = False
    try:
        path = runner.receipts / (label + '.json')
        command = json.loads(path.read_text())
        report['commandSHA256'] = digest(path)
        report['processExit'] = command.get('cleanup')
        report['commandSuccess'] = command.get('success')
        if not command.get('success') or not clean_exit(command):
            raise ValueError('full profile command or isolated exit failed')
    except Exception as error:
        report['errors'].append({'phase': 'command', **failure(error)})
    try:
        terminal = inspect_full_log(runner.receipts / (label + '.log'))
        report['testInventory'] = terminal
        exit_code = command.get('exitCode') if command else None
        terminal_usable = (type(exit_code) is int and
                           ((terminal['outcome'] == 'passed' and exit_code == 0) or
                            (terminal['outcome'] == 'failed' and exit_code > 0)))
        if not terminal_usable:
            raise ValueError('terminal test result contradicts or lacks process exit')
        if terminal['outcome'] != 'passed':
            raise ValueError('full profile has a retained failed test completion')
        report['affirmativeCases'] = [terminal['case']]
    except Exception as error:
        report['errors'].append({'phase': 'test inventory', **failure(error)})
    try:
        data, report['inputSHA256'] = evaluate_sync.read_json(plan['directory'] / 'receipts.json')
        result = analyze_profile(data, plan['profile'], plan['metadata'])
        report['receipts'] = result
        receipts_usable = result['evidenceUsable']
        if not result['qualified']:
            raise ValueError('; '.join(result['violations']))
    except Exception as error:
        report['errors'].append({'phase': 'receipts', **failure(error)})
    report['evidenceUsable'] = terminal_usable and receipts_usable
    report['qualified'] = not report['errors']
    save(runner.receipts / (label + '-qualification.json'), report)
    return report, command


def run(runner, sdk, root, common, sdk_inputs, core_inputs):
    binding = prepare_binding(runner, root, sdk_inputs, core_inputs)
    plans = profile_plan(root, binding, runner.env)
    summary = {'scope': SCOPE, 'performanceAccepted': False, 'experimentAccepted': False,
               'bindingSHA256': digest(runner.receipts / 'sync-full-calibration-binding.json'),
               'qualified': False, 'firstFailure': None, 'profiles': []}
    primary = None
    previous_clean = True
    original_env = runner.env
    try:
        for plan in plans:
            if not previous_clean or runner.interrupts.received:
                summary['profiles'].append({'profile': plan['profile'], 'expectedCount': plan['expectedCount'],
                    'started': False, 'qualified': False, 'reason': 'prior process/evidence was not usable or runner interrupted'})
                break
            try:
                # Calls are synchronous. Restore the original environment even
                # on interruption; no subsequent graph/evidence command inherits
                # PERF=1 or a full-profile output path.
                runner.env = plan['env']
                runner.run(plan['label'], ['swift', 'test', *common, *FLAGS, '--force-resolved-versions',
                           '--skip-build', '--filter', FILTER], cwd=sdk,
                           timeout=TIMEOUT, require_full_timeout=True)
            except BaseException as error:
                if primary is None:
                    primary = error
                    summary['firstFailure'] = failure(error)
            finally:
                runner.env = original_env
            try:
                report, command = inspect_profile(runner, plan)
                previous_clean = command is not None and clean_exit(command) and report['evidenceUsable']
                summary['profiles'].append({'profile': plan['profile'], 'expectedCount': plan['expectedCount'],
                    'started': command.get('started') if command else False, 'qualified': report['qualified'],
                    'reportSHA256': digest(runner.receipts / (plan['label'] + '-qualification.json'))})
                if not report['qualified'] and primary is None:
                    primary = ValueError('full calibration failed: ' + plan['profile'])
                    summary['firstFailure'] = failure(primary)
            except BaseException as error:
                previous_clean = False
                if primary is None:
                    primary = error
                    summary['firstFailure'] = failure(error)
                summary['profiles'].append({'profile': plan['profile'], 'expectedCount': plan['expectedCount'],
                    'qualified': False, 'evidenceError': failure(error)})
        summary['qualified'] = primary is None and len(summary['profiles']) == 2 and all(p['qualified'] for p in summary['profiles'])
    finally:
        runner.env = original_env
        try:
            save(runner.receipts / 'sync-full-calibration.json', summary)
        except BaseException:
            if primary is None:
                raise
            # The original failure remains primary if final evidence also fails.
            print('FULL_CALIBRATION_RECEIPT_WRITE_FAILED', json.dumps(summary), flush=True)
    if primary is not None:
        raise primary
    if not summary['qualified']:
        raise ValueError('full calibration incomplete; both profiles are required')
