"""Exact affected Swift suites; independent of the original one-case phase DATA."""
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

CASES = {
    'RelayCheckedMountedServerOpenTests': [
        'missingFileIsNotCreatedOrBootstrapped', 'missingParentIsNotCreatedBySelectedOpener',
        'fullLinkedExistingCatalogAndRowsSurviveRepeatedCheckedOpen',
        'incompleteDeclaredCatalogRefusesWithoutGenericSchemaRepair',
        'genuineRegistrationGuardDDLAllowsCheckedReopen',
        'firstHistoryStageAndLedgerDDLAllowReopenWithActualLineage',
        'memoryAndReadOnlyConfigurationsCannotBorrowExistingServerBranch',
        'storedPositiveVersionMismatchIsNotMigrated',
        'forgedCookieMarkersCannotHideActualChangedGeneratedSQL',
        'actualRolledBackDDLAndMarkersRemainEligibleForExistingRead',
        'genuineMountedSuccessorWaitsForActualForeignCutDestructionReturn',
    ],
    'RelayCurrentMountedCaptureTests': [
        'actualExecutingKeyDistinguishesSameWorkerAndDifferentPool',
        'finalCapturedTargetKeepsActualKeyAndCanEnqueueNextKey',
        'fullCatalogIncludesTheActualOptionalLinkedModel',
        'realNativeFullCatalogRefusesRootOnlyAndCapturesOnlyLinkedSelection',
        'actualMountedCutMustReleaseBeforeSuccessorAndKeepsLineage',
        'genuineIssuedPageRetainsBytesAfterParentCheckedClose',
    ],
    'RelayOrdinaryHistoryProducerTests': [
        'actualAuthenticatedTypedSelectionReachesHistoryIssuerAndWaitsForProgress',
        'finalPassiveProgressRetainsActualCutWithoutCanonicalReceiptACKOrSuccessor',
        'wrongActualStageProgressRefusesAndRetiresWithoutPruningOriginals',
        'explicitHistoryMountUsesActualLegacyTypedRegistrationAfterOriginalEffectRequest',
        'unknownAuthenticatedModelSelectorCannotFallBackToFullHistoryScope',
        'actualAuthenticatedHistoricalMountCapturesSelectedRowsWithoutInventingOldReceipt',
    ],
    'RelayOrdinaryLineageRelationTests': [
        'actualAuthenticatedPersonalMountBindsOldFullAndNewSelectedCutBeforeHeader',
        'actualAuthenticatedGroupMountPreservesSameLineageAndPreAdvanceFrontier',
        'defaultHistoryRequestDoesNotEmitRelationDespiteTypedRoleDeclaration',
        'explicitRelationRefusesMissingActualTypedRoleAndMismatchedGroupChannel',
        'freshAuthenticatedMountReportsNoPredecessorWithoutClaimingReceiverAbsence',
    ],
}
MAC_SQLITE = set(CASES['RelayCheckedMountedServerOpenTests'][7:10])
MAX_LOG = 512 * 2**20  # Original command-log ceiling.
MAX_XML = 16 * 2**20


def require(value):
    if not value:
        raise ValueError('checked_mounted_fix_qualification_refused')


def expected(system):
    require(system in ('Darwin', 'Linux'))
    return [f'LatticeTests.{suite}/{name}()' for suite, names in CASES.items()
            for name in names if system == 'Darwin' or name not in MAC_SQLITE]


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def source_inventory(sdk, system):
    identities = expected(system)
    sources = {}
    for suite, names in CASES.items():
        path = Path(sdk) / f'Tests/LatticeTests/SyncTests/{suite}.swift'
        text = path.read_text(encoding='utf-8')
        actual = re.findall(r'@Test\s+func\s+(\w+)\(', text)
        require(actual == names)
        require('struct ' + suite + ' {' in text)
        if suite == 'RelayCheckedMountedServerOpenTests':
            start = '#if canImport(SQLite3)\n    @Test func ' + names[7]
            require(text.count(start) == 1)
            conditional = text.split(start, 1)[1].split('#endif', 1)[0]
            require(re.findall(r'@Test\s+func\s+(\w+)\(', conditional) == names[8:10])
        sources[str(path.relative_to(sdk))] = {'sha256': digest(path), 'declarations': actual}
    require(len(identities) == (28 if system == 'Darwin' else 25))
    return {'platform': system, 'identifiers': identities, 'sources': sources,
            'sqliteConditionalFunctions': sorted(MAC_SQLITE), 'suiteCount': 4}


def read_report(path, maximum):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= maximum)
    raw = path.read_bytes()
    require(len(raw) <= maximum)
    return raw


def framework(xml, log, system):
    identities = expected(system)
    require(type(xml) is bytes and len(xml) <= MAX_XML)
    text = xml.decode('utf-8', errors='strict')
    require('\x00' not in text and '<!DOCTYPE' not in text.upper() and '<!ENTITY' not in text.upper())
    root = ET.fromstring(text)
    require(root.tag in ('testsuites', 'testsuite'))
    require(not any(list(root.iter(tag)) for tag in ('failure', 'error', 'skipped')))
    actual = [case.get('classname', '') + '/' + case.get('name', '') for case in root.iter('testcase')]
    require(len(actual) == len(set(actual)) and set(actual) == set(identities))
    for suite in root.iter('testsuite'):
        for field in ('failures', 'errors', 'skipped'):
            require(field not in suite.attrib or re.fullmatch(r'0+', suite.attrib[field]) is not None)
    require(type(log) is bytes and len(log) <= MAX_LOG)
    plain = re.sub(r'\x1b\[[0-9;]*m', '', log.decode('utf-8', errors='strict'))
    require(re.search(r'\bskipped\b|unexpected signal|Exited with unexpected|recorded an issue|^[✘×]', plain, re.M) is None)
    names = [identity.split('/', 1)[1] for identity in identities]
    starts = re.findall(r'^◇ Test (\w+\([^\n]*\)) started\.$', plain, re.M)
    passes = re.findall(r'^[✔✓] Test (\w+\([^\n]*\)) passed after [0-9]+\.[0-9]+ seconds?\.$', plain, re.M)
    require(sorted(starts) == sorted(names) and sorted(passes) == sorted(names))
    summaries = re.findall(r'^[✔✓] Test run with (\d+) tests in (\d+) suites passed after [0-9]+\.[0-9]+ seconds?\.$', plain, re.M)
    require(summaries == [(str(len(identities)), '4')])
    return {'identifiers': actual, 'testCount': len(actual), 'suiteCount': 4,
            'platform': system, 'failures': [], 'skips': [],
            'scope': 'exact four affected Swift suites only; no full-SDK, platform matrix beyond this runner, performance or release acceptance'}


def save(path, value):
    with Path(path).open('x') as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')


def qualify(runner, sdk, root, common, timeout):
    import platform
    import recovery_refresh_qualification as original
    sdk, root = Path(sdk), Path(root)
    system = platform.system()
    inventory = source_inventory(sdk, system)
    help_text = read_report(runner.receipts / 'test-help.log', MAX_LOG).decode('utf-8')
    for flag in ('--skip-build', '--filter', '--disable-xctest', '--enable-swift-testing', '--xunit-output'):
        require(flag in help_text)
    image = original.test_image(root / 'scratch')
    save(runner.receipts / 'checked-mounted-fix-source-inventory.json', inventory)
    save(runner.receipts / 'checked-mounted-fix-test-image.json', image)
    previous_log = runner.env['LATTICE_TEST_LOG_PATH']
    try:
        runner.env['LATTICE_TEST_LOG_PATH'] = str(root / 'test-logs/checked-mounted-fix.log')
        xml = runner.receipts / 'checked-mounted-fix.xml'
        pattern = '^(?:' + '|'.join(re.escape(name) for name in inventory['identifiers']) + r')(?:/|$)'
        log = runner.run('checked-mounted-fix-tests', ['swift', 'test', *common,
                         '--force-resolved-versions', '--skip-build', '--disable-xctest',
                         '--enable-swift-testing', '--filter', pattern, '--xunit-output', str(xml)],
                         cwd=sdk, timeout=timeout, require_full_timeout=True)
        actual = framework(read_report(xml, MAX_XML), read_report(log, MAX_LOG), system)
        require(original.test_image(root / 'scratch') == image and source_inventory(sdk, system) == inventory)
        save(runner.receipts / 'checked-mounted-fix-qualification.json',
             {'tests': actual, 'testImage': image, 'xmlSHA256': digest(xml), 'logSHA256': digest(log),
              'commandReceiptSHA256': digest(runner.receipts / 'checked-mounted-fix-tests.json'),
              'originalDiagnosticCommandSeparate': True, 'fullSDKAccepted': False,
              'performanceOrReleaseAccepted': False})
    finally:
        runner.env['LATTICE_TEST_LOG_PATH'] = previous_log
