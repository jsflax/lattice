"""Exact selected SDK consumer qualification; not release or performance acceptance."""
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

REFRESH = [
    'payloadFreeWakeRefreshesWithoutAnAuditEventAndCancellationStopsNewWakes()',
    'cachedCountRefreshesWithBeltDisabledAndNoExplicitListener()',
    'heldModelOnlyGetsFreshPropertyWithBeltDisabled()',
    'rejectedOrCancelledSwiftCallbackReleasesItsContext()',
]
COMBINE = [
    'resultsRecoveryUsesTheOrdinaryDeliveryQueueAndCancelFencesQueuedWake()',
    'cancellationDuringRegistrationCancelsReturnedTokens()',
]
FIELDS = [
    'extractor_plainPredicate()', 'extractor_quotedAndQualifiedIdentifiers()',
    'extractor_functionsOverColumnsAreReferenced()',
    'extractor_dualUseOperatorKeywordsAreBookedAsColumns()',
    'extractor_conservativeFallbacks()', 'extractor_shapeDependencyIncludesImplicitID()',
    'withFieldsHook_deliversPerTablePayloadInline()',
    'memberRowUnrelatedColumnUpdate_noShapeRebuild_fileDB()',
    'memberRowUnrelatedColumnUpdate_noShapeRebuild_memoryFamily()',
    'predicateColumnUpdate_rebuildsAtNextAccess()', 'sortColumnUpdate_rebuildsAtNextAccess()',
    'flagOff_unrelatedColumnUpdateInvalidates()',
    'syntheticFieldsPayload_skipsDisjointShapes_invalidatesIntersecting()',
    'recoverySignalRecapturesWarmShapesWithNoTableHistory(fieldAware:)',
    'longSoakEquivalence_flagOnVsFlagOff()',
]
SOURCES = {
    'RecoveryRefreshTests': 'Tests/LatticeTests/RecoveryRefreshTests.swift',
    'LiveResultsChangedFieldsTests': 'Tests/LatticeTests/LiveResultsChangedFieldsTests.swift',
}
PARAMETERIZED = FIELDS[-2]
MAX_REPORT_BYTES = 512 * 2**20  # Same existing command-log ceiling; no increase.


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def save(path, value):
    with Path(path).open('x') as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')


def expected(platform):
    if platform not in ('Darwin', 'Linux'):
        raise ValueError('unreviewed recovery qualification platform')
    groups = {'RecoveryRefreshTests': REFRESH + (COMBINE if platform == 'Darwin' else []),
              'LiveResultsChangedFieldsTests': FIELDS}
    return [f'LatticeTests.{suite}/{case}' for suite, cases in groups.items() for case in cases]


def source_inventory(sdk, platform):
    """Bind the fixed inventory to actual compiled source; do not invent tests from logs."""
    proof = {}
    for suite, relative in SOURCES.items():
        path = Path(sdk) / relative
        source = path.read_text()
        names = re.findall(r'@Test(?:\([^\n]*\))?\s+func\s+(\w+)\(', source)
        wanted = REFRESH + COMBINE if suite == 'RecoveryRefreshTests' else FIELDS
        if names != [name.split('(')[0] for name in wanted]:
            raise ValueError('selected source inventory changed: ' + suite)
        if suite == 'RecoveryRefreshTests':
            marker = '#if canImport(Combine)\n    @Test func ' + COMBINE[0]
            if source.count(marker) != 1 or source.rsplit('#if canImport(Combine)', 1)[1].count('@Test') != 2:
                raise ValueError('reviewed platform-conditional test boundary changed')
        elif '@Test(arguments: [true, false])\n    func ' + PARAMETERIZED.removesuffix(')') + ' Bool)' not in source:
            raise ValueError('reviewed Boolean argument coverage changed')
        proof[relative] = {'sha256': digest(path), 'declaredFunctions': names}
    return {'platform': platform, 'identifiers': expected(platform), 'sources': proof,
            'parameterizedArguments': [True, False]}


def discover(log, identities):
    selected = [line.strip() for line in log.splitlines()
                if re.match(r'^LatticeTests\.(?:RecoveryRefreshTests|LiveResultsChangedFieldsTests)/', line.strip())]
    if len(selected) != len(set(selected)) or set(selected) != set(identities):
        raise ValueError('actual discovery differs from exact selected test inventory')
    return selected


def selector(identities):
    # The suffix includes Swift Testing's source-location component. The older
    # strict end anchor selected zero tests on a retained Swift 6.3 run.
    return '^(?:' + '|'.join(re.escape(name) for name in identities) + r')(?:/|$)'


def framework(xml, log, identities):
    """Require XML plus affirmative function and Boolean argument events."""
    root = ET.fromstring(xml)
    if root.tag not in ('testsuites', 'testsuite'):
        raise ValueError('unexpected test XML root')
    if any(list(root.iter(tag)) for tag in ('failure', 'error', 'skipped')):
        raise ValueError('failure/error/skip in selected test XML')
    cases = list(root.iter('testcase'))
    actual = [case.get('classname', '') + '/' + case.get('name', '') for case in cases]
    if len(actual) != len(set(actual)) or set(actual) != set(identities):
        raise ValueError('selected XML case identities differ from discovery')
    for suite in root.iter('testsuite'):
        for key in ('failures', 'errors', 'skipped'):
            if key in suite.attrib and int(suite.attrib[key]) != 0:
                raise ValueError('nonzero selected XML suite status')
    plain = re.sub(r'\x1b\[[0-9;]*m', '', log)
    if re.search(r'\bskipped\b|unexpected signal|Exited with unexpected|recorded an issue|^[✘×]', plain, re.M):
        raise ValueError('nonpassing selected framework status')
    names = [name.split('/', 1)[1] for name in identities]
    starts = re.findall(r'^◇ Test (\w+\([^\n]*\)) started\.$', plain, re.M)
    passed_events = re.findall(r'^[✔✓] Test (\w+\([^\n]*\))([^\n]*) passed after [0-9.]+ seconds?\.$', plain, re.M)
    passed = [name for name, _ in passed_events]
    if sorted(starts) != sorted(names) or sorted(passed) != sorted(names):
        raise ValueError('missing, duplicate or unexpected affirmative function events')
    for name, suffix in passed_events:
        required = ' with 2 test cases' if name == PARAMETERIZED else ''
        if suffix != required:
            raise ValueError('aggregate case count must be exactly two only for the reviewed parameterized function')
    arguments = re.findall(r'^◇ Test case passing 1 argument fieldAware → (true|false) to '
                           + re.escape(PARAMETERIZED) + r' started\.$', plain, re.M)
    if sorted(arguments) != ['false', 'true']:
        raise ValueError('both reviewed Boolean argument cases must start exactly once')
    summaries = re.findall(r'^[✔✓] Test run with (\d+) tests(?: in (\d+) suites?)? passed after [0-9.]+ seconds?\.$', plain, re.M)
    if summaries != [(str(len(identities)), '2')]:
        raise ValueError('selected test summary does not match exact two-suite inventory')
    return {'passed': actual, 'functionCount': len(actual), 'parameterizedArguments': arguments,
            'suiteCount': 2, 'failures': [], 'skips': [],
            'scope': 'selected SDK consumer tests only; not full-suite, release, iOS or performance acceptance'}


def read_report(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_REPORT_BYTES:
        raise ValueError('test report is absent, indirect or exceeds existing log budget')
    return path.read_text()


def test_image(scratch):
    scratch = Path(scratch).resolve(strict=True)
    candidates = list(scratch.glob('*/debug/LatticePackageTests.xctest/Contents/MacOS/LatticePackageTests'))
    candidates += [path for path in scratch.glob('*/debug/LatticePackageTests.xctest') if path.is_file()]
    if len(candidates) != 1:
        raise ValueError('expected one freshly built SDK test image')
    image = candidates[0]
    if image.is_symlink() or not image.resolve(strict=True).is_relative_to(scratch):
        raise ValueError('SDK test image escaped scratch')
    return {'path': str(image.resolve()), 'bytes': image.stat().st_size, 'sha256': digest(image),
            'scope': 'fresh test-image custody; not a complete link-map proof'}


def qualify(runner, sdk, core, root, common, timeout):
    import platform
    root, sdk = Path(root), Path(sdk)
    inventory = source_inventory(sdk, platform.system())
    identities = inventory['identifiers']
    help_text = read_report(runner.receipts / 'test-help.log')
    for flag in ('--skip-build', '--filter', '--disable-xctest', '--enable-swift-testing', '--xunit-output'):
        if flag not in help_text:
            raise ValueError('required Swift Testing runner option absent: ' + flag)
    (root / 'tmp' / 'recovery-fixtures').mkdir(exist_ok=False)
    save(runner.receipts / 'recovery-refresh-source-inventory.json', inventory)
    image = test_image(root / 'scratch')
    save(runner.receipts / 'recovery-refresh-test-image.json', image)
    # Discovery may instantiate suites. Give each process its own owned log;
    # the logger never truncates a preceding discovery receipt.
    previous_log = runner.env['LATTICE_TEST_LOG_PATH']
    try:
        runner.env['LATTICE_TEST_LOG_PATH'] = str(root / 'test-logs/recovery-discovery.log')
        listing = runner.run('recovery-refresh-discovery', ['swift', 'test', *common,
                             '--force-resolved-versions', '--skip-build', 'list'], cwd=sdk, timeout=60)
        listed = discover(read_report(listing), identities)
        pattern = selector(identities)
        save(runner.receipts / 'recovery-refresh-discovery-proof.json',
             {'identifiers': listed, 'filter': pattern, 'logSHA256': digest(listing)})
        if test_image(root / 'scratch') != image or source_inventory(sdk, platform.system()) != inventory:
            raise ValueError('selected source/test image changed after discovery')
        runner.env['LATTICE_TEST_LOG_PATH'] = str(root / 'test-logs/recovery-tests.log')
        xml = runner.receipts / 'recovery-refresh.xml'
        log = runner.run('recovery-refresh-tests', ['swift', 'test', *common,
                         '--force-resolved-versions', '--skip-build', '--disable-xctest',
                         '--enable-swift-testing', '--filter', pattern, '--xunit-output', str(xml)],
                         cwd=sdk, timeout=timeout, require_full_timeout=True)
        actual = framework(read_report(xml), read_report(log), identities)
        if test_image(root / 'scratch') != image or source_inventory(sdk, platform.system()) != inventory:
            raise ValueError('selected source/test image changed during execution')
        save(runner.receipts / 'recovery-refresh-qualification.json',
             {'scope': actual['scope'], 'tests': actual, 'testImage': image,
              'xmlSHA256': digest(xml), 'logSHA256': digest(log),
              'commandReceiptSHA256': digest(runner.receipts / 'recovery-refresh-tests.json'),
              'primaryResult': 'GuardedRunner must independently prove clean exit and owned process-group cleanup',
              'releaseGraphAccepted': False, 'fullSuiteAccepted': False, 'performanceAccepted': False})
    finally:
        runner.env['LATTICE_TEST_LOG_PATH'] = previous_log
