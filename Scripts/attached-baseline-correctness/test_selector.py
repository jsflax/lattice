"""Pure selector/custody checks; no Swift, git, network, or SDK execution."""
from pathlib import Path
from copy import deepcopy
import ast
import json
import re
import tempfile
import unittest
import selector_probe as p
import qualify

P = Path(__file__).resolve().parent


def evidence(mode='baseline', plural=False):
    rows = list(p.IDENTITIES) if mode == 'baseline' else ([] if mode == 'old-anchor-zero' else [p.IDENTITIES[0]])
    xml = '<testsuites><testsuite name="TestResults" tests="%d" errors="0" failures="0" skipped="0">' % len(rows)
    log = []
    for label, identity, line in rows:
        suite, name = identity.split('/')
        xml += '<testcase classname="%s" name="%s"/>' % (suite, name)
        log += ['◇ Test %s started.' % name,
            'FILTER_PROBE_BODY\t%s\t%s/FilterProbeTests.swift:%d:6' % (label, identity, line),
            '✔ Test %s passed after 0.001 seconds.' % name]
    if rows:
        count = len(rows); suites = 2 if count == 3 else 1
        log += ['✔ Test run with %d test%s in %d suite%s passed after 0.001 seconds.' %
            (count, 's' if count != 1 or plural else '', suites, 's' if suites != 1 or plural else '')]
    else:
        log += ['warning: No matching test cases were run']
    return xml + '</testsuite></testsuites>', '\n'.join(log)


class Selector(unittest.TestCase):
    def test_three_zero_one_exact_and_singular_plural(self):
        for mode, n in [('baseline', 3), ('old-anchor-zero', 0), ('selected', 1)]:
            for plural in (False, True):
                result = p.framework(*evidence(mode, plural), mode)
                self.assertEqual(result['reportedTests'], n)
                self.assertEqual(result['selectedTestQualified'], mode == 'selected')
                self.assertEqual(result['zeroObservationOnly'], mode == 'old-anchor-zero')

    def test_zero_is_never_selected_qualification(self):
        with self.assertRaises(AssertionError):p.framework(*evidence('old-anchor-zero'), 'selected')
        with self.assertRaises(AssertionError):p.framework(*evidence('selected'), 'old-anchor-zero')

    def test_wrong_or_duplicate_body_identity_rejects(self):
        xml, log = evidence('selected')
        for bad in [log.replace('FilterProbeTests.FilterProbeSuite/', 'FilterProbeTests.OtherFilterProbeSuite/'),
                    log.replace(':11:6', ':12:6'), log.replace('\tchosen\t', '\tother_suite_distractor\t'),
                    log + '\nFILTER_PROBE_BODY\tchosen\t' + p.IDENTITIES[0][1],
                    log.replace('FILTER_PROBE_BODY\t', 'prefix FILTER_PROBE_BODY\t')]:
            with self.assertRaises(AssertionError):p.framework(xml, bad, 'selected')

    def test_wrong_extra_duplicate_xml_cases_reject(self):
        xml, log = evidence('selected')
        for bad in [xml.replace('FilterProbeTests.FilterProbeSuite', 'FilterProbeTests.OtherFilterProbeSuite'),
                    xml.replace('selected()', 'selectedExtra()'),
                    xml.replace('</testsuite>', '<testcase classname="FilterProbeTests.FilterProbeSuite" name="selected()"/></testsuite>')]:
            with self.assertRaises(AssertionError):p.framework(bad, log, 'selected')

    def test_fail_skip_issue_signal_reject(self):
        xml, log = evidence('selected')
        for element in ('<failure/>', '<error/>', '<skipped/>'):
            with self.assertRaises(AssertionError):p.framework(xml.replace('</testsuite>', element + '</testsuite>'), log, 'selected')
        for bad in ('\nrecorded an issue', '\nunexpected signal 11', '\n✘ Test x() failed', '\n➜ Test x() skipped.'):
            with self.assertRaises(AssertionError):p.framework(xml, log + bad, 'selected')

    def test_missing_or_inconsistent_terminal_counts_reject(self):
        xml, log = evidence('selected')
        for bad in [log.replace('◇ Test selected() started.', ''), log.replace('✔ Test selected() passed after 0.001 seconds.', ''),
                    log.replace('1 test in 1 suite', '2 tests in 1 suite'),
                    log + '\n✔ Test run with 1 test in 1 suite passed after 0.001 seconds.']:
            with self.assertRaises(AssertionError):p.framework(xml, bad, 'selected')
        with self.assertRaises(AssertionError):p.framework(xml.replace('tests="1"', 'tests="0"'), log, 'selected')

    def test_exact_discovery_three(self):
        text='\n'.join(x[1] for x in p.IDENTITIES)
        self.assertEqual(len(p.discover(text)), 3)
        for bad in (text.replace(p.IDENTITIES[0][1], ''), text+'\n'+p.IDENTITIES[0][1], text+'\nFilterProbeTests.Unknown/other()'):
            with self.assertRaises(AssertionError):p.discover(bad)

    def test_probe_source_is_exact_original001(self):
        p.validate_source(P)
        source=(P/'selector-fixture/Tests/FilterProbeTests/FilterProbeTests.swift').read_text()
        self.assertEqual(source.count('@Test func '), 3)
        self.assertIn('dependencies: []', (P/'selector-fixture/Package.swift').read_text())

    def test_undeclared_fixture_source_rejects(self):
        import shutil
        with tempfile.TemporaryDirectory() as tmp:
            packet=Path(tmp)
            shutil.copyfile(P/'selector-origin-SOURCE-READY.json', packet/'selector-origin-SOURCE-READY.json')
            shutil.copytree(P/'selector-fixture', packet/'selector-fixture')
            p.validate_source(packet)
            (packet/'selector-fixture/Tests/FilterProbeTests/extra.swift').write_text('unexpected')
            with self.assertRaises(AssertionError):p.validate_source(packet)

    def test_legacy_filter_changes_boundary_only_and_keeps_exact_names(self):
        value=json.loads((P/'legacy-expected-tests.json').read_text())
        regex=re.compile(value['filter'])
        for name in value['caseIdentifiers']:
            self.assertIsNotNone(regex.search(name))
            self.assertIsNotNone(regex.search(name+'/SomeFile.swift:12:4'))
            for other in ('Other'+name, name+'Extra', name.replace('()', '(argument:)'), name.replace('LatticeTests.', 'OtherTests.')):
                self.assertIsNone(regex.search(other))
            self.assertIsNone(regex.fullmatch(name+'/SomeFile.swift:12:4'))

    def test_input_drift_rejects(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'image';path.write_bytes(b'original')
            state={'files':{str(path):p.guard.digest(path)}};p.verify(state)
            path.write_bytes(b'changed')
            with self.assertRaises(AssertionError):p.verify(state)

    def test_real_probe_function_command_order_and_environment_restore(self):
        from types import SimpleNamespace
        observed = (P/'selector-observed-swift-version.log').read_text()
        self.assertEqual(p.guard.digest(P/'selector-observed-swift-version.log'),
            '5fa4b669e41b23b9ad0760253d062493487f93cf5d8ad8c44f0d4fd635137499')
        for fail, version_text in [(failure, text) for failure in (False, True)
                for text in ('Apple Swift version 6.3.3 (fixture)\n', observed)]:
            with self.subTest(fail=fail, version=version_text), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp).resolve(); receipts=root/'receipts';receipts.mkdir()
                version=receipts/'version.log';version.write_text(version_text)
                original={'KEEP':'exact'};runner=SimpleNamespace(env=original);calls=[]
                # Model real lowercase command receipts, with filesystem-independent casefold exclusion.
                original_save = p.guard.save_json
                def casefold_save(path, value):
                    if path.name.casefold() in {x.name.casefold() for x in path.parent.iterdir()}:
                        raise FileExistsError('casefold receipt collision: ' + path.name)
                    return original_save(path, value)
                def command(label, argv, cwd, timeout):
                    calls.append((label,argv,timeout)); log=receipts/(label+'.log')
                    p.guard.save_json(receipts/(label+'.json'), {'fakeCommandLabel':label, 'ownedCommandReceipt':True})
                    if label=='selector-build-tests':
                        binary=root/'selector-probe/scratch/arm64-apple-macosx/debug/FilterProbePackageTests.xctest/Contents/MacOS/FilterProbePackageTests'
                        binary.parent.mkdir(parents=True);binary.write_bytes(b'fake image for pure orchestration check')
                        binary.with_name(binary.name+'.dSYM').mkdir()
                        log.write_text('pure fake build\n')
                    elif label=='selector-discovery':log.write_text('\n'.join(x[1] for x in p.IDENTITIES))
                    else:
                        mode=label.removeprefix('selector-')
                        if fail and mode=='selected':raise RuntimeError('fake selected failure')
                        xml,text=evidence(mode);Path(argv[-1]).write_text(xml);log.write_text(text)
                    return log
                def run_probe():
                    from unittest.mock import patch
                    with patch.object(p.guard, 'save_json', casefold_save):
                        return p.run(P,root,receipts,runner,command,{'swift':'/owned/swift','j':2},version)
                if fail:
                    with self.assertRaisesRegex(RuntimeError,'fake selected failure'):
                        run_probe()
                else:
                    state=run_probe()
                    p.verify(state);self.assertTrue((receipts/'SELECTOR-PROBE.json').is_file())
                    inventory=json.loads((receipts/'SELECTOR-BINARY-CANDIDATES.json').read_text())['paths']
                    self.assertEqual(len(inventory),2);self.assertTrue(any(x.endswith('.dSYM') for x in inventory))
                    self.assertFalse(any(x.endswith('.dSYM') for x in state['files']))
                names = [x.name.casefold() for x in receipts.iterdir()]
                self.assertEqual(len(names), len(set(names)))
                for label, _, _ in calls:
                    self.assertEqual(json.loads((receipts/(label+'.json')).read_text()),
                        {'fakeCommandLabel':label, 'ownedCommandReceipt':True})
                for mode in ('baseline', 'old-anchor-zero') + (() if fail else ('selected',)):
                    command_receipt = receipts/('selector-'+mode+'.json')
                    classification = receipts/('selector-'+mode+'-classification.json')
                    self.assertNotEqual(command_receipt.name.casefold(), classification.name.casefold())
                    self.assertEqual(json.loads(classification.read_text()), p.framework(*evidence(mode), mode))
                    if not fail:
                        self.assertEqual(state['files'][str(classification)], p.guard.digest(classification))
                self.assertIs(runner.env, original)
                self.assertEqual([(x[0],x[2]) for x in calls],[('selector-build-tests',60),('selector-discovery',15),('selector-baseline',15),('selector-old-anchor-zero',15),('selector-selected',15)])
                self.assertEqual(calls[-2][1][calls[-2][1].index('--filter')+1],p.OLD_FILTER)
                self.assertEqual(calls[-1][1][calls[-1][1].index('--filter')+1],p.FILTER)

    def test_binary_inventory_retains_dsym_and_rejects_ambiguous_symlink_noimage(self):
        from types import SimpleNamespace
        for mode in ('two-files','symlink','no-image'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp).resolve();receipts=root/'receipts';receipts.mkdir()
                version=receipts/'version.log';version.write_text((P/'selector-observed-swift-version.log').read_text())
                runner=SimpleNamespace(env={'KEEP':'exact'});original=runner.env;calls=[]
                def command(label, argv, cwd, timeout):
                    calls.append(label);self.assertEqual(label,'selector-build-tests')
                    base=root/'selector-probe/scratch/arm64-apple-macosx/debug/FilterProbePackageTests.xctest/Contents/MacOS'
                    base.mkdir(parents=True);(base/'FilterProbePackageTests.dSYM').mkdir()
                    image=base/'FilterProbePackageTests'
                    if mode=='two-files':
                        image.write_bytes(b'one');(base/'FilterProbeTests').write_bytes(b'two')
                    elif mode=='symlink':
                        target=root/'selector-probe/scratch/real-image';target.write_bytes(b'target')
                        image.symlink_to(target)
                    log=receipts/(label+'.log');log.write_text('pure fake build\n');return log
                with self.assertRaises(AssertionError):p.run(P,root,receipts,runner,command,{'swift':'/owned/swift','j':2},version)
                self.assertEqual(calls,['selector-build-tests']);self.assertIs(runner.env,original)
                inventory=json.loads((receipts/'SELECTOR-BINARY-CANDIDATES.json').read_text())['paths']
                self.assertTrue(any(x.endswith('.dSYM') for x in inventory))
                self.assertEqual(len(inventory), {'two-files':3,'symlink':2,'no-image':1}[mode])
                self.assertFalse((receipts/'SELECTOR-PROBE.json').exists())

    def test_version_gate_rejects_wrong_version_or_malformed_prefix_before_commands(self):
        from types import SimpleNamespace
        observed = (P/'selector-observed-swift-version.log').read_text()
        for bad in (observed.replace('Swift version 6.3.3', 'Swift version 6.3.30'),
                    observed.replace('Swift version 6.3.3', 'Swift version 6.3.4'),
                    observed.replace('Swift version 6.3.3', 'Swift version 6.4'),
                    observed.replace('1.148.6', 'development'),
                    observed.replace('1.148.6', '1..6'),
                    observed.replace('swift-driver version: ', ''),
                    'unexpected prefix ' + observed,
                    'Apple Swift version 6.3.3-snapshot\n'):
            with self.subTest(version=bad), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp).resolve(); receipts=root/'receipts';receipts.mkdir()
                version=receipts/'version.log';version.write_text(bad)
                original={'KEEP':'exact'};runner=SimpleNamespace(env=original);calls=[]
                def command(*args, **kwargs):
                    calls.append((args,kwargs));self.fail('version rejection must precede all native commands')
                with self.assertRaisesRegex(AssertionError, 'requires actual hosted Swift 6.3.3'):
                    p.run(P,root,receipts,runner,command,{'swift':'/owned/swift','j':2},version)
                self.assertEqual(calls,[])
                self.assertFalse((root/'selector-probe').exists())
                self.assertIs(runner.env,original)

    def test_integration_order_budgets_and_finalization(self):
        source=(P/'qualify.py').read_text();ast.parse(source)
        self.assertLess(source.index('selector_state = selector_probe.run('), source.index("baseline_sources['sdk'] = pristine("))
        self.assertIn('selector_probe.verify(selector_state)',source)
        self.assertIn("selectorProbeAccepted=False",source)
        probe=(P/'selector_probe.py').read_text();ast.parse(probe)
        self.assertIn('runner.env = previous_env',probe)
        self.assertEqual(probe.count('timeout=60'),1)
        self.assertEqual(probe.count('timeout=15'),2) # one discovery + three loop arms
        self.assertIn('assert results[\'selected\'][\'bodies\'] == chosen',probe)
        value=json.loads((P/'config.json').read_text())
        self.assertEqual((value['buildSeconds'],value['testSeconds'],value['overallSeconds'],value['reserveSeconds']),(5400,180,18000,600))


if __name__ == '__main__':unittest.main()
