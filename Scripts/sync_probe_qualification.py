"""Explicit instrumentation qualification. Never ordinary/performance acceptance."""
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

FLAGS = ['-Xcxx', '-DLATTICE_SYNC_COMMIT_PROBE', '-Xcc', '-DLATTICE_SYNC_COMMIT_PROBE',
         '-Xswiftc', '-DLATTICE_SYNC_COMMIT_PROBE']
NATIVE_CASES = {
    'AnotherPhysicalOwnerOnSameThreadCannotFillTheReceipt',
    'AnotherThreadCannotFillFinishOrAdmitTheOwnerScope',
    'BookkeepingAfterARecordedWriteDoesNotCreateAnotherSample',
    'ExactConnectionAndMainSchemaAreRequiredAtRecordBoundary',
    'ExactWriteIsInvisibleBeforeCommitAndRecordedBeforeInvalidation',
    'FailedBeginCannotAdmitASampleAndNextAttemptCanCommit',
    'NoOpCommitDoesNotBecomeAnInsertSample',
    'QueuedOldObserverCannotMoveOrRelabelTheNativeTimestamp',
    'RealDeferredConstraintCommitFailureHasNoPostcommitRecord',
    'RollbackDisarmsBeforeAnUnrelatedLaterCommit',
    'SamePathReentrantSuccessorCannotRearmOrReplaceTheOrigin',
    'SwiftBridgeAdapterUsesTheSameClockAndOwner',
    'UnsupportedClosedAndUnownedTransactionsAreRefused',
    'WrongFinishCannotStealScopeAndFinishCannotBeReused',
    'EnrolledGeneratedWriteAndSuccessorPreserveProducerProvenance',
    'ActualProtectedClaimAndDetachedCallbackCannotReplaceConsumedOrigin',
    'PrivateInstallCannotArmAndRollbackDoesNotContaminatePublicSuccessor',
}
SDK_CASES = {'smallPublicVisibilityQualification',
             'lateReadCannotRepairDeadlineOrCompleteAnotherIdentity',
             'duplicateCallbacksCannotInflateCoverageAndDiagnosticsStayBounded',
             'changedValueOrMalformedObservationCannotPassAfterValidCoverage'}
SMOKE = dict(writerCount=2, opsPerWriter=3, payloadBytes=2048, cadenceNS=40_000_000,
             staggerNS=5_000_000, warmupPerWriter=1, quietWarmupOps=1, quietOps=1,
             quietCadenceNS=1_000_000_000, drainNS=20_000_000_000, driverWorkers=2)


def expected_tests(source):
    names = re.findall(r'TEST_F\(SyncCommitProbe,\s*(\w+)\)', source)
    if len(names) != len(NATIVE_CASES) or set(names) != NATIVE_CASES:
        raise ValueError('reviewed probe source must contain exactly the seventeen named tests')
    return set(names)


def check_native_xml(xml, expected):
    report = ET.fromstring(xml)
    cases = report.findall('.//testcase')
    names = [case.get('name') for case in cases]
    if expected != NATIVE_CASES or len(cases) != len(NATIVE_CASES) or set(names) != expected:
        raise ValueError('actual native test identities do not equal reviewed probe inventory')
    for case in cases:
        if case.get('classname') != 'SyncCommitProbe' or case.get('status') != 'run' or case.get('result') != 'completed':
            raise ValueError('probe case did not execute to completion')
        if case.findall('failure') or case.findall('skipped') or case.findall('error'):
            raise ValueError('native probe failure/skip/error retained in XML')
    return {'count': len(cases), 'names': sorted(names), 'allExecutedWithoutFailure': True}


def check_native_summary(summary):
    names = summary.get('names', [])
    if (type(summary.get('count')) is not int or summary['count'] != len(NATIVE_CASES)
            or summary.get('allExecutedWithoutFailure') is not True
            or not isinstance(names, list) or len(names) != len(NATIVE_CASES)
            or any(not isinstance(name, str) for name in names) or set(names) != NATIVE_CASES):
        raise ValueError('all seventeen exact native probe results are required before full calibration')


def qualify_native(runner, core, root, compiler_input_proof):
    # Core vendors GoogleTest and declares no package dependencies. Its source
    # and tracked postimages are already authenticated by the enclosing runner.
    base = root / 'native-probe'
    base.mkdir(exist_ok=False)
    for directory in ('scratch', 'cache', 'config', 'security'):
        (base / directory).mkdir()
    common = ['--package-path', str(core), '--scratch-path', str(base / 'scratch'),
              '--cache-path', str(base / 'cache'), '--config-path', str(base / 'config'),
              '--security-path', str(base / 'security'), '--disable-sandbox', '--disable-experimental-prebuilts']
    xml = runner.receipts / 'native-probe.xml'
    inventory = expected_tests((core / 'Tests/LatticeCoreTests/SyncCommitProbeTests.cpp').read_text())
    log = runner.run('native-probe', ['swift', 'run', *common, *FLAGS, '-j', '2', '-v',
                     'LatticeCoreTests', '--gtest_filter=SyncCommitProbe.*', '--gtest_output=xml:' + str(xml)],
                     cwd=core, timeout=5400)
    proof = compiler_input_proof(log, core)
    for sample in proof['samples']:
        if '-DLATTICE_SYNC_COMMIT_PROBE' not in sample['command']:
            raise ValueError('native compiler input lacks required macro')
    # Every actual fixture name must be present. A zero-test process exit0 fails.
    result = check_native_xml(xml.read_text(), inventory)
    with (runner.receipts / 'native-probe-qualification.json').open('x') as output:
        json.dump({'scope': 'native probe only; not full Core suite', 'tests': result,
                   'compilerInputs': proof, 'flags': FLAGS}, output, indent=2)


def qualify_public_receipts(root, receipts):
    # Import the reviewed offline evaluator from this same exact SDK source.
    import evaluate_sync
    data, digest = evaluate_sync.read_json(root / 'visibility-smoke/receipts.json')
    result = evaluate_sync.analyze(data)
    with (receipts / 'public-visibility-qualification.json').open('x') as output:
        json.dump({'inputSHA256': digest, 'analysis': result,
                   'processBoundary': 'test command exited; not proof every transport/cache owner was destroyed before process exit'}, output, indent=2)
    if (not result['validCompleteRun'] or result['clock'] != evaluate_sync.NATIVE_CLOCK
            or result['mode'] != 'smoke' or result['profile'] != 'loaded'
            or result['effectiveParameters'] != SMOKE or result['receiptCount'] != 10):
        raise ValueError('public visibility fixture did not prove all ten exact operations with native origins')


def check_sdk_log(log):
    # Swift Testing's positive per-case terminal events, not process exit0 or
    # a suite count. Missing/skipped/renamed cases fail closed. Keep original
    # complete output so a toolchain reporter change is diagnosable.
    plain = re.sub(r'\x1b\[[0-9;]*m', '', log)
    executed = re.findall(r'^[✔✓] Test (\w+)\(\) passed after [0-9.]+ seconds?\.$', plain, re.MULTILINE)
    for name in SDK_CASES:
        if executed.count(name) != 1:
            raise ValueError('missing or duplicate affirmative SDK test result: ' + name)
    return {'expectedCases': sorted(SDK_CASES), 'affirmativePassedCases': executed,
            'scope': 'four selected fixture cases; opt-in full profile remains disabled'}


def qualify_sdk_log(log, receipts):
    result = check_sdk_log(Path(log).read_text())
    with (receipts / 'sdk-probe-test-inventory.json').open('x') as output:
        json.dump(result, output, indent=2)
