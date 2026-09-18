"""Small source-identical selector preflight using the existing owned command guard."""
from pathlib import Path
import collections
import json
import re
import shutil
import xml.etree.ElementTree as ET
import guarded_runner as guard

FILES = ('Package.swift', 'Tests/FilterProbeTests/FilterProbeTests.swift')
IDENTITIES = (
    ('chosen', 'FilterProbeTests.FilterProbeSuite/selected()', 11),
    ('same_suite_distractor', 'FilterProbeTests.FilterProbeSuite/selectedExtra()', 15),
    ('other_suite_distractor', 'FilterProbeTests.OtherFilterProbeSuite/selected()', 22),
)
OLD_FILTER = r'^FilterProbeTests\.FilterProbeSuite/selected\(\)$'
FILTER = r'^FilterProbeTests\.FilterProbeSuite/selected\(\)(?:/|$)'
LIMIT = 1024 * 1024


def validate_source(packet):
    fixture = packet / 'selector-fixture'
    entries = list(fixture.rglob('*'))
    assert not any(x.is_symlink() for x in entries)
    assert {str(x.relative_to(fixture)) for x in entries if x.is_file()} == set(FILES)
    origin = json.loads((packet / 'selector-origin-SOURCE-READY.json').read_text())
    for name in FILES:
        original = origin['files']['package/' + name]
        path = packet / 'selector-fixture' / name
        assert path.is_file() and not path.is_symlink()
        assert path.stat().st_size == original['bytes'] and guard.digest(path) == original['sha256']
    assert origin['files']['package/Package.swift']['sha256'] == 'db7b9dd4fc3c1631db34ff20b656c6ac1b49b05de3ac15ade251a58e8c17d6fa'
    assert origin['files']['package/Tests/FilterProbeTests/FilterProbeTests.swift']['sha256'] == '91da3f7380da441d0c71986a0e843c7d0799f0bb8e98ee9c1d33a73fa6b5ed69'


def discover(text):
    actual = [line.strip() for line in text.splitlines() if line.strip().startswith('FilterProbeTests.')]
    assert sorted(actual) == sorted(x[1] for x in IDENTITIES) and len(actual) == 3
    assert 'FILTER_PROBE_BODY' not in text and not re.search(r'^[◇✔✘] Test ', text, re.M)
    return actual


def framework(xml, log, mode):
    assert mode in ('baseline', 'old-anchor-zero', 'selected')
    root = ET.fromstring(xml)
    assert root.tag in ('testsuite', 'testsuites')
    assert not any(list(root.iter(tag)) for tag in ('skipped', 'failure', 'error'))
    cases = list(root.iter('testcase'))
    actual = [x.attrib['classname'] + '/' + x.attrib['name'] for x in cases]
    wanted = list(IDENTITIES) if mode == 'baseline' else ([] if mode == 'old-anchor-zero' else [IDENTITIES[0]])
    assert sorted(actual) == sorted(x[1] for x in wanted) and len(actual) == len(set(actual))
    suites = list(root.iter('testsuite'))
    assert len(suites) == 1 and int(suites[0].attrib['tests']) == len(wanted)
    for node in [root, *suites]:
        for name in ('failures', 'errors', 'skipped'):
            assert int(node.attrib.get(name, '0')) == 0
    assert not re.search(r'recorded an issue|unexpected signal|Exited with unexpected|^✘|^➜.*skipped', log, re.M)
    body_lines = [line for line in log.splitlines() if 'FILTER_PROBE_BODY' in line]
    bodies = []
    for line in body_lines:
        parts = line.split('\t'); assert len(parts) == 3 and parts[0] == 'FILTER_PROBE_BODY'
        bodies.append(parts[1:])
    assert len(bodies) == len(wanted) and collections.Counter(x[0] for x in bodies) == collections.Counter(x[0] for x in wanted)
    for label, identity, line in wanted:
        observed = next(value for name, value in bodies if name == label)
        assert observed in (identity, identity + '/FilterProbeTests.swift:%d:6' % line)
    starts = re.findall(r'^◇ Test ([A-Za-z0-9_]+\(\)) started\.$', log, re.M)
    passes = re.findall(r'^✔ Test ([A-Za-z0-9_]+\(\)) passed after [0-9.]+ seconds\.$', log, re.M)
    names = collections.Counter(x[1].split('/')[1] for x in wanted)
    assert collections.Counter(starts) == collections.Counter(passes) == names
    summaries = re.findall(r'^✔ Test run with (\d+) tests?(?: in (\d+) suites?)? passed after [0-9.]+ seconds\.$', log, re.M)
    if mode == 'old-anchor-zero':
        assert summaries in ([], [('0', '')], [('0', '0')])
        assert log.count('warning: No matching test cases were run') == 1 or len(summaries) == 1
        assert not re.search(r'^◇ (?:Test|Suite) .* started\.$|^✔ Suite ', '\n'.join(line for line in log.splitlines() if line != '◇ Test run started.'), re.M)
    else:
        assert summaries == [(str(len(wanted)), '2' if mode == 'baseline' else '1')]
        assert 'No matching test cases were run' not in log
    return {'cases': actual, 'bodies': bodies, 'reportedTests': len(wanted),
        'reportedSuites': 2 if mode == 'baseline' else (0 if not wanted else 1),
        'zeroObservationOnly': mode == 'old-anchor-zero', 'selectedTestQualified': mode == 'selected'}


def bounded_text(path):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size <= LIMIT
    return path.read_text()


def verify(state):
    for name, digest in state['files'].items():
        path = Path(name)
        assert path.is_file() and not path.is_symlink() and guard.digest(path) == digest, 'selector evidence drift: ' + name


def run(packet, root, receipts, runner, command, config, version_log):
    validate_source(packet)
    version = bounded_text(version_log)
    assert re.search(r'^(?:swift-driver version: [0-9]+(?:\.[0-9]+)* )?Apple Swift version 6\.3\.3(?:\s|$)', version, re.M), 'selector preflight requires actual hosted Swift 6.3.3'
    home = root / 'selector-probe'; home.mkdir()
    for name in ('tmp', 'scratch', 'cache', 'config', 'security', 'module-cache'):
        (home / name).mkdir()
    package = home / 'package'; package.mkdir()
    for name in FILES:
        destination = package / name; destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(packet / 'selector-fixture' / name, destination)
    state = {'files': {str(package / n): guard.digest(packet / 'selector-fixture' / n) for n in FILES}}
    state['files'][str(version_log)] = guard.digest(version_log)
    common = ['--package-path', str(package), '--scratch-path', str(home / 'scratch'),
        '--cache-path', str(home / 'cache'), '--config-path', str(home / 'config'),
        '--security-path', str(home / 'security'), '--disable-sandbox', '--disable-experimental-prebuilts']
    previous_env = runner.env
    runner.env = dict(previous_env, TMPDIR=str(home / 'tmp'), TMP=str(home / 'tmp'), TEMP=str(home / 'tmp'),
        CLANG_MODULE_CACHE_PATH=str(home / 'module-cache'), SWIFT_MODULECACHE_PATH=str(home / 'module-cache'),
        SWIFTPM_MODULECACHE_OVERRIDE=str(home / 'module-cache'))
    try:
        build = command('selector-build-tests', [config['swift'], 'build', *common, '--build-tests', '-j', str(config['j'])], package, timeout=60)
        state['files'][str(build)] = guard.digest(build)
        inventory = sorted((home / 'scratch').glob('**/*.xctest/Contents/MacOS/*'))
        guard.save_json(receipts / 'SELECTOR-BINARY-CANDIDATES.json', {'paths': [str(x) for x in inventory]})
        candidates = [path for path in inventory if path.is_file()]
        assert len(candidates) == 1, 'expected one tiny fixture test image'
        binary = candidates[0]
        assert binary.name in ('FilterProbeTests', 'FilterProbePackageTests') and binary.is_file() and not binary.is_symlink()
        assert binary.resolve().is_relative_to(home / 'scratch') and 0 < binary.stat().st_size <= 64 * 1024 * 1024
        state['files'][str(binary)] = guard.digest(binary)
        # Anchor source and freshly built image before any discovery or body executes.
        guard.save_json(receipts / 'SELECTOR-INPUTS.json', state)
        state['files'][str(receipts / 'SELECTOR-INPUTS.json')] = guard.digest(receipts / 'SELECTOR-INPUTS.json')
        test = [config['swift'], 'test', *common, '--skip-build', '--disable-xctest', '--enable-swift-testing']
        verify(state)
        discovery = command('selector-discovery', [*test, '--list-tests'], package, timeout=15)
        discovered = discover(bounded_text(discovery)); state['files'][str(discovery)] = guard.digest(discovery)
        results = {}
        for mode, pattern in [('baseline', None), ('old-anchor-zero', OLD_FILTER), ('selected', FILTER)]:
            verify(state)
            xml = receipts / ('selector-' + mode + '.xml')
            argv = [*test, *([] if pattern is None else ['--filter', pattern]), '--xunit-output', str(xml)]
            log = command('selector-' + mode, argv, package, timeout=15)
            result = framework(bounded_text(xml), bounded_text(log), mode)
            results[mode] = result
            state['files'].update({str(xml): guard.digest(xml), str(log): guard.digest(log)})
            guard.save_json(receipts / ('selector-' + mode + '-classification.json'), result)
            state['files'][str(receipts / ('selector-' + mode + '-classification.json'))] = guard.digest(receipts / ('selector-' + mode + '-classification.json'))
            verify(state)
        chosen = [x for x in results['baseline']['bodies'] if x[0] == 'chosen']
        assert results['selected']['bodies'] == chosen
        result = {'success': True, 'swift633SelectorQualified': True, 'legacyChecksQualified': False,
            'sourceIdenticalToProbe001': True, 'discovered': discovered, 'arms': results,
            'oldFilter': OLD_FILTER, 'runtimeFilter': FILTER, 'custody': state,
            'limits': ['Tiny selector mechanism only; no SDK or four-case qualification.',
                'Fresh image hash anchored after its build and before tests; no full compiler-object provenance claimed.']}
        guard.save_json(receipts / 'SELECTOR-PROBE.json', result)
        return state
    finally:
        runner.env = previous_env
