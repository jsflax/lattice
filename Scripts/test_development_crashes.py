"""Filesystem/fake-runner diagnostics checks; no Swift or native execution."""
import ast
import hashlib
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import development_crashes as crashes


class FullTestBacktraceTests(unittest.TestCase):
    def full_branch(self):
        source = Path(__file__).with_name('run-development.py').read_text()
        tree = ast.parse(source)
        branches = [node for node in ast.walk(tree) if isinstance(node, ast.If)
                    and isinstance(node.test, ast.Attribute)
                    and node.test.attr == 'recovery_refresh_qualification'
                    and any(isinstance(child, ast.With) for child in node.orelse)]
        self.assertEqual(len(branches), 1)
        return compile(ast.Module(body=branches[0].orelse, type_ignores=[]), str(__file__), 'exec')

    def invoke(self, platform_name, failure=None):
        original = {'SWIFT_BACKTRACE': 'enable=no', 'UNRELATED_SETTING': 'preserve'}
        calls, receipts = [], []
        runner = SimpleNamespace(env=original)

        def run(label, argv, **kwargs):
            calls.append((label, argv, kwargs, dict(runner.env)))
            if failure is not None:
                raise failure

        runner.run = run
        namespace = {'runner': runner, 'platform': SimpleNamespace(system=lambda: platform_name),
                     'save_json': lambda path, value: receipts.append((path, value)),
                     'receipts': Path('/synthetic/receipts'), 'sdk': Path('/synthetic/sdk'),
                     'common': ['--scratch-path', '/synthetic/scratch'],
                     'args': SimpleNamespace(test_timeout=1800)}
        before_environment = dict(os.environ)
        caught = None
        try:
            exec(self.full_branch(), namespace)
        except BaseException as error:
            caught = error
        self.assertIs(runner.env, original)
        self.assertEqual(original, {'SWIFT_BACKTRACE': 'enable=no', 'UNRELATED_SETTING': 'preserve'})
        self.assertEqual(dict(os.environ), before_environment)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:3], ('full-test', ['swift', 'test', '--scratch-path',
                         '/synthetic/scratch', '--force-resolved-versions', '--skip-build'],
                         {'cwd': Path('/synthetic/sdk'), 'timeout': 1800, 'require_full_timeout': True}))
        self.assertEqual(calls[0][3]['UNRELATED_SETTING'], 'preserve')
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0][0].name, 'full-test-backtrace.json')
        return calls[0][3], receipts[0][1], caught

    def test_mac_full_command_requests_bounded_noninteractive_trace_only_during_test(self):
        environment, receipt, caught = self.invoke('Darwin')
        self.assertIsNone(caught)
        self.assertTrue(receipt['requested'])
        options = dict(item.split('=', 1) for item in environment['SWIFT_BACKTRACE'].split(','))
        self.assertEqual(options['enable'], 'yes')
        self.assertEqual(options['interactive'], 'no')
        self.assertEqual(options['timeout'], '0s')
        self.assertEqual(options['threads'], 'crashed')
        self.assertEqual(options['limit'], '64')
        self.assertEqual(options['output-to'], 'stderr')
        self.assertFalse(receipt['captureGuaranteed'])

    def test_failed_command_preserves_first_exception_without_retry_and_restores_environment(self):
        first = RuntimeError('original native crash remains failure')
        _, _, caught = self.invoke('Darwin', first)
        self.assertIs(caught, first)

    def test_linux_full_command_keeps_original_environment(self):
        environment, receipt, caught = self.invoke('Linux')
        self.assertIsNone(caught)
        self.assertFalse(receipt['requested'])
        self.assertIsNone(receipt['setting'])
        self.assertEqual(environment['SWIFT_BACKTRACE'], 'enable=no')

    def test_no_prior_setting_is_not_added_to_original_mapping(self):
        original = {'UNRELATED_SETTING': 'preserve'}
        runner = SimpleNamespace(env=original)
        with crashes.full_test_backtrace(runner, 'Darwin') as receipt:
            self.assertFalse(receipt['priorSettingPresent'])
            self.assertIn('SWIFT_BACKTRACE', runner.env)
        self.assertIs(runner.env, original)
        self.assertNotIn('SWIFT_BACKTRACE', original)


class CrashReportCollectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bundle = self.root / 'scratch/arm64-apple-macosx/debug/LatticePackageTests.xctest/Contents/MacOS/LatticePackageTests'
        self.bundle.parent.mkdir(parents=True)
        self.bundle.write_bytes(b'fixture only, not executable')
        self.reports = self.root / 'reports'
        self.reports.mkdir()
        self.started = 1000

    def report(self, name='LatticePackageTests-current.ips', *, data=None, modified=1001):
        path = self.reports / name
        path.write_bytes(str(self.bundle).encode() if data is None else data)
        os.utime(path, (modified, modified))
        return path

    def collect(self, **kwargs):
        return crashes.collect(self.root, self.root / 'captured', self.started,
                               directories=[self.reports, self.root / 'missing'], wait_seconds=0, **kwargs)

    def test_absent_reports_distinguish_empty_and_missing_directories(self):
        result = self.collect()
        self.assertFalse(result['reportsFound'])
        self.assertEqual(result['errors'], [])
        self.assertEqual([row['lastStatus'] for row in result['scanSummary']['directories']], ['scanned', 'missing'])
        self.assertEqual(result['scanSummary']['passes'], 1)

    def test_current_exact_bundle_report_is_copied_with_hash(self):
        source = self.report('swiftpm-testing-helper-current.crash')
        data = source.read_bytes()
        result = self.collect()
        self.assertTrue(result['reportsFound'])
        self.assertEqual(len(result['files']), 1)
        item = result['files'][0]
        self.assertEqual((self.root / 'captured' / item['name']).read_bytes(), data)
        self.assertEqual(item['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(result['bytes'], len(data))

    def test_stale_and_unrelated_reports_are_observed_without_copying(self):
        self.report(modified=999)
        self.report('UnrelatedApplication-current.ips')
        result = self.collect()
        summary = result['scanSummary']['directories'][0]
        self.assertEqual(summary['entriesExamined'], 2)
        self.assertEqual(summary['matchingReportNames'], 1)
        self.assertEqual(summary['staleReports'], 1)
        self.assertFalse(result['reportsFound'])
        self.assertEqual(result['bytes'], 0)

    def test_wrong_bundle_cannot_be_captured_by_matching_report_name(self):
        self.report(data=b'/another/job/LatticePackageTests')
        result = self.collect()
        self.assertFalse(result['reportsFound'])
        self.assertEqual(result['rejected'][0]['reason'], 'exact test bundle absent')

    def test_symlink_and_fifo_are_not_followed_or_read(self):
        target = self.root / 'outside-report'
        target.write_bytes(str(self.bundle).encode())
        (self.reports / 'LatticePackageTests-link.ips').symlink_to(target)
        os.mkfifo(self.reports / 'LatticePackageTests-pipe.crash')
        result = self.collect()
        self.assertFalse(result['reportsFound'])
        self.assertEqual(result['scanSummary']['directories'][0]['nonRegularReports'], 2)

    def test_existing_byte_cap_refuses_oversized_report(self):
        path = self.report()
        with path.open('r+b') as output:
            output.truncate(crashes.MAX_FILE + 1)
        result = self.collect()
        self.assertFalse(result['reportsFound'])
        self.assertEqual(result['bytes'], 0)
        self.assertEqual(result['rejected'][0]['reason'], 'byte/file limit')

    def test_candidate_cap_is_preserved(self):
        for index in range(crashes.MAX_CANDIDATES + 2):
            self.report(f'LatticePackageTests-{index:03}.ips', data=b'wrong bundle')
        result = self.collect()
        self.assertTrue(result['inventoryTruncated'])
        self.assertEqual(len(result['rejected']), crashes.MAX_CANDIDATES)
        self.assertEqual(result['bytes'], 0)

    def test_report_appearing_within_existing_wait_is_collected_without_extending_wait(self):
        clock = [0.0]

        def sleep(seconds):
            clock[0] += seconds
            if not list(self.reports.iterdir()):
                self.report()

        with patch.object(crashes.time, 'monotonic', side_effect=lambda: clock[0]), \
                patch.object(crashes.time, 'sleep', side_effect=sleep):
            result = crashes.collect(self.root, self.root / 'captured', self.started,
                                     directories=[self.reports], wait_seconds=30)
        self.assertTrue(result['reportsFound'])
        self.assertEqual(clock[0], 3)
        self.assertEqual(result['scanSummary']['elapsedSeconds'], 3)
        self.assertEqual(len(result['files']), 1)


if __name__ == '__main__':
    unittest.main()
