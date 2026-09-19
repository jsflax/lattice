"""Pure file/fixture checks only. Never invokes Swift, native code or SQLite."""
import ast
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import unittest
from unittest.mock import patch

import recovery_refresh_qualification as q


def reports(identities):
    cases = ''.join('<testcase classname="' + identity.split('/')[0] + '" name="'
                    + identity.split('/')[1] + '"/>' for identity in identities)
    xml = '<testsuites><testsuite failures="0" errors="0" skipped="0">' + cases + '</testsuite></testsuites>'
    names = [identity.split('/')[1] for identity in identities]
    lines = ['◇ Test ' + name + ' started.' for name in names]
    lines += ['◇ Test case passing 1 argument fieldAware → ' + value + ' to ' + q.PARAMETERIZED + ' started.'
              for value in ('true', 'false')]
    lines += ['✔ Test ' + name + ' passed after 0.001 seconds.' for name in names]
    lines += ['✔ Test run with ' + str(len(names)) + ' tests in 2 suites passed after 0.1 seconds.']
    return xml, '\n'.join(lines)


class RecoveryQualification(unittest.TestCase):
    def setUp(self):
        # Agent test invocations must explicitly supply an owned temporary root.
        temporary = Path(os.environ['TMPDIR']).resolve(strict=True)
        self.assertIn('localdev', temporary.parts)
        self.temporary = tempfile.TemporaryDirectory(dir=temporary)
        self.root = Path(self.temporary.name)
        self.sdk = self.root / 'lattice'
        self.sdk.mkdir()
        original = Path(__file__).resolve().parent.parent
        for relative in q.SOURCES.values():
            target = self.sdk / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original / relative, target)

    def tearDown(self):
        self.temporary.cleanup()

    def test_actual_source_inventory_binds_platform_and_both_arguments(self):
        self.assertEqual(len(q.source_inventory(self.sdk, 'Darwin')['identifiers']), 21)
        self.assertEqual(len(q.source_inventory(self.sdk, 'Linux')['identifiers']), 19)
        with self.assertRaises(ValueError):
            q.source_inventory(self.sdk, 'Windows')
        path = self.sdk / q.SOURCES['LiveResultsChangedFieldsTests']
        path.write_text(path.read_text().replace('[true, false]', '[true]'))
        with self.assertRaisesRegex(ValueError, 'Boolean'):
            q.source_inventory(self.sdk, 'Linux')

    def test_changed_or_disabled_inventory_cannot_pass(self):
        path = self.sdk / q.SOURCES['RecoveryRefreshTests']
        path.write_text(path.read_text().replace('@Test func heldModelOnly', 'func heldModelOnly'))
        with self.assertRaisesRegex(ValueError, 'inventory'):
            q.source_inventory(self.sdk, 'Darwin')

    def test_discovery_rejects_missing_duplicate_or_added_selected_case(self):
        expected = q.expected('Linux')
        self.assertEqual(q.discover('\n'.join(expected + ['LatticeTests.Other/test()']), expected), expected)
        for actual in (expected[:-1], expected + expected[:1], expected + ['LatticeTests.RecoveryRefreshTests/newCase()']):
            with self.assertRaises(ValueError):
                q.discover('\n'.join(actual), expected)

    def test_selector_admits_source_suffix_but_not_other_suites_or_names(self):
        identities = q.expected('Darwin')
        selected = re.compile(q.selector(identities))
        for identity in identities:
            self.assertIsNotNone(selected.search(identity))
            self.assertIsNotNone(selected.search(identity + '/source.swift:1:2'))
        for identity in ('prefix' + identities[0], identities[0] + 'Extra',
                         identities[0].replace('RecoveryRefreshTests', 'OtherSuite')):
            self.assertIsNone(selected.search(identity))

    def test_both_platform_reports_require_every_positive_result(self):
        for platform in ('Darwin', 'Linux'):
            identities = q.expected(platform)
            xml, log = reports(identities)
            self.assertEqual(q.framework(xml, log, identities)['functionCount'], len(identities))
            with self.assertRaisesRegex(ValueError, 'affirmative'):
                q.framework(xml, log.replace('✔ Test ' + identities[0].split('/')[1], 'missing Test', 1), identities)

    def test_parameterized_test_needs_true_and_false_exactly_once(self):
        identities = q.expected('Linux')
        xml, log = reports(identities)
        for mutated in (log.replace('fieldAware → false', 'fieldAware → true'),
                        '\n'.join(line for line in log.splitlines() if 'fieldAware → false' not in line),
                        log + '\n' + next(line for line in log.splitlines() if 'fieldAware → false' in line)):
            with self.assertRaisesRegex(ValueError, 'Boolean'):
                q.framework(xml, mutated, identities)

    def test_xml_and_log_cannot_hide_failure_skip_duplicate_or_zero_tests(self):
        identities = q.expected('Linux')
        xml, log = reports(identities)
        for tag in ('failure', 'error', 'skipped'):
            with self.assertRaises(ValueError):
                q.framework(xml.replace('</testsuite>', '<' + tag + '/></testsuite>'), log, identities)
        for bad in ('<testsuites/>', xml.replace('failures="0"', 'failures="1"'),
                    xml.replace('</testsuite>', '<testcase classname="LatticeTests.RecoveryRefreshTests" name="'
                                + q.REFRESH[0] + '"/></testsuite>')):
            with self.assertRaises(ValueError):
                q.framework(bad, log, identities)
        for suffix in ('\n✘ Test recorded an issue.', '\nTest skipped', '\nExited with unexpected signal code 11'):
            with self.assertRaises(ValueError):
                q.framework(xml, log + suffix, identities)
        with self.assertRaises(ValueError):
            q.framework(xml, log.replace('19 tests', '0 tests'), identities)

    def test_image_requires_one_owned_regular_target_and_detects_changes(self):
        scratch = self.root / 'scratch'
        image = scratch / 'triple/debug/LatticePackageTests.xctest'
        image.parent.mkdir(parents=True)
        image.write_bytes(b'pure-file fixture image')
        first = q.test_image(scratch)
        image.write_bytes(b'changed pure-file fixture image')
        self.assertNotEqual(first, q.test_image(scratch))
        other = scratch / 'other/debug/LatticePackageTests.xctest'
        other.parent.mkdir(parents=True)
        other.write_bytes(b'another')
        with self.assertRaises(ValueError):
            q.test_image(scratch)
        other.unlink()
        outside = self.root / 'outside-image'
        outside.write_bytes(b'outside')
        image.unlink(); image.symlink_to(outside)
        with self.assertRaises(ValueError):
            q.test_image(scratch)

    def test_report_rejects_symlinks_and_byte_overflow(self):
        report = self.root / 'report'; report.write_text('abc')
        link = self.root / 'link'; link.symlink_to(report)
        with self.assertRaises(ValueError): q.read_report(link)
        with patch.object(q, 'MAX_REPORT_BYTES', 2):
            with self.assertRaises(ValueError): q.read_report(report)

    def fixture_runner(self, fail=False):
        root = self.root
        (root / 'tmp').mkdir()
        receipts = root / 'receipts'; receipts.mkdir()
        (root / 'test-logs').mkdir()
        (receipts / 'test-help.log').write_text('--skip-build --filter --disable-xctest --enable-swift-testing --xunit-output')
        image = root / 'scratch/triple/debug/LatticePackageTests.xctest'
        image.parent.mkdir(parents=True); image.write_bytes(b'pure fake image')
        class Runner:
            def __init__(self):
                self.receipts = receipts
                self.env = {'LATTICE_TEST_LOG_PATH': str(root / 'test-logs/native.log')}
                self.calls = []
            def run(self, label, argv, **kwargs):
                self.calls.append((label, argv, kwargs, self.env.copy()))
                log = receipts / (label + '.log')
                if label == 'recovery-refresh-discovery':
                    log.write_text('\n'.join(q.expected('Linux')))
                else:
                    if fail: raise RuntimeError('preserved original command failure')
                    xml, text = reports(q.expected('Linux'))
                    (receipts / 'recovery-refresh.xml').write_text(xml)
                    log.write_text(text)
                (receipts / (label + '.json')).write_text(json.dumps({'fakePureFixture': True}))
                return log
        return Runner()

    def test_qualification_uses_guarded_commands_and_original_timeout(self):
        runner = self.fixture_runner()
        with patch('platform.system', return_value='Linux'):
            q.qualify(runner, self.sdk, self.root / 'Core', self.root, ['--scratch-path', str(self.root / 'scratch')], 5400)
        self.assertEqual([call[0] for call in runner.calls], ['recovery-refresh-discovery', 'recovery-refresh-tests'])
        self.assertEqual(runner.calls[1][2]['timeout'], 5400)
        self.assertIs(runner.calls[1][2]['require_full_timeout'], True)
        self.assertIn('--skip-build', runner.calls[1][1])
        self.assertNotIn('-DLATTICE_SYNC_COMMIT_PROBE', runner.calls[1][1])
        self.assertEqual(runner.env['LATTICE_TEST_LOG_PATH'], str(self.root / 'test-logs/native.log'))
        result = json.loads((runner.receipts / 'recovery-refresh-qualification.json').read_text())
        self.assertFalse(result['fullSuiteAccepted']); self.assertFalse(result['releaseGraphAccepted'])

    def test_failed_command_does_not_create_acceptance_or_rerun(self):
        runner = self.fixture_runner(fail=True)
        with patch('platform.system', return_value='Linux'):
            with self.assertRaisesRegex(RuntimeError, 'preserved original'):
                q.qualify(runner, self.sdk, self.root / 'Core', self.root, [], 1800)
        self.assertEqual(len(runner.calls), 2)
        self.assertFalse((runner.receipts / 'recovery-refresh-qualification.json').exists())
        self.assertEqual(runner.env['LATTICE_TEST_LOG_PATH'], str(self.root / 'test-logs/native.log'))

    def test_runner_has_mutually_exclusive_modes_and_unchanged_full_command(self):
        source = (Path(__file__).parent / 'run-development.py').read_text()
        ast.parse(source)
        self.assertIn('qualification = parser.add_mutually_exclusive_group()', source)
        for mode in ('--sync-probe-qualification', '--recovery-refresh-qualification'):
            self.assertIn("qualification.add_argument('" + mode, source)
        self.assertIn("runner.run('full-test', ['swift', 'test', *common, '--force-resolved-versions', '--skip-build'], cwd=sdk,\n                           timeout=args.test_timeout, require_full_timeout=True)", source)


if __name__ == '__main__':
    unittest.main()
