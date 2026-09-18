import ast
import copy
import json
from pathlib import Path
import signal
import tempfile
import time
import unittest
from unittest.mock import patch
import analyze
import crash_reports

P = Path(__file__).resolve().parent


def row(code=0):
    return {'started': True, 'exitCode': code, 'success': code == 0,
            'cleanup': {'leaderReaped': True, 'groupGone': True, 'signals': [], 'errors': []},
            'receivedSignals': [], 'primaryError': None, 'evidenceErrors': [], 'stopReason': None}


class Acceptance(unittest.TestCase):
    trace = '*** Signal 11: Backtracing ***\nThread 0 crashed:\n3 0x123 latticeSDK46DiagnosticCrashControl() + 22\n'

    def test_expected_signal_and_named_stack(self):
        analyze.control(row(-signal.SIGSEGV), self.trace)

    def test_symbol_outside_stack_rejected(self):
        with self.assertRaises(AssertionError):
            analyze.control(row(-signal.SIGSEGV), 'Signal 11 Backtrace latticeSDK46DiagnosticCrashControl')

    def test_wrong_signal_rejected(self):
        with self.assertRaises(AssertionError): analyze.control(row(-signal.SIGABRT), self.trace)

    def test_cleanup_signal_rejected(self):
        data = row(-signal.SIGSEGV); data['cleanup']['signals'] = ['SIGTERM']
        with self.assertRaises(AssertionError): analyze.control(data, self.trace)

    def test_missing_group_rejected(self):
        data = row(-signal.SIGSEGV); data['cleanup']['groupGone'] = False
        with self.assertRaises(AssertionError): analyze.control(data, self.trace)

    def test_timeout_rejected(self):
        data = row(-signal.SIGSEGV); data['stopReason'] = 'command timeout'
        with self.assertRaises(AssertionError): analyze.control(data, self.trace)

    def test_interactive_rejected(self):
        with self.assertRaises(AssertionError): analyze.control(row(-signal.SIGSEGV), self.trace + 'Press enter')

    def test_framework_four(self):
        expected = json.loads((P / 'config.json').read_text())['focusedIdentifiers']
        xml = '<testsuites><testsuite>' + ''.join('<testcase classname="' + item.split('/')[0] + '" name="' + item.split('/')[1] + '"/>' for item in expected) + '</testsuite></testsuites>'
        analyze.discovery('\n'.join(expected), expected)
        self.assertEqual(analyze.focused(row(), xml, 'Test run with 4 tests in 2 suites passed', expected)['executed'], 4)
        for bad in [xml.replace('/>', '><skipped/></testcase>', 1), xml.replace(expected[0].split('/')[1], 'wrong()')]:
            with self.assertRaises(AssertionError): analyze.focused(row(), bad, 'Test run with 4 tests passed', expected)

    def test_extra_discovery_rejected(self):
        expected = json.loads((P / 'config.json').read_text())['focusedIdentifiers']
        with self.assertRaises(AssertionError): analyze.discovery('\n'.join(expected + expected[:1]), expected)

    def test_missing_full_summary_rejected(self):
        with self.assertRaises(AssertionError): analyze.full(row(), 'all tests started')

    def test_full_signal_rejected(self):
        with self.assertRaises(AssertionError): analyze.full(row(), 'Test run with 815 tests passed\nunexpected signal 11')

    def test_control_before_checkout_ast(self):
        tree = ast.parse((P / 'qualify.py').read_text())
        source = (P / 'qualify.py').read_text()
        self.assertLess(source.index("assert admission is not None"), source.index("runner.run(name + '-fetch'"))
        self.assertNotIn('--no-parallel', source)
        self.assertNotIn('--parallel', source)
        self.assertNotIn('sanitize', source)
        self.assertIn('timeout=1800, require_full_timeout=True', source)
        self.assertTrue(tree)


class Collector(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=P / 'check-tmp')
        self.root = Path(self.temp.name)
        bundle = self.root / 'scratch/arm64-apple-macosx/debug/LatticePackageTests.xctest/Contents/MacOS/LatticePackageTests'
        bundle.parent.mkdir(parents=True); bundle.write_bytes(b'not a binary')
        self.marker = str(bundle).encode(); self.reports = self.root / 'reports'; self.reports.mkdir()
        marker=self.marker
        class FakeIdentity:
            def candidate(self,data,scan_end):
                if marker not in data:raise ValueError('unowned synthetic report')
                return {'role':'sdk','descriptorId':'synthetic'}
        self.collector = crash_reports.Collector(self.root,self.root/'captured',time.time()-1,FakeIdentity(),[self.reports])

    def tearDown(self): self.temp.cleanup()

    def report(self, name, data=None):
        path = self.reports / ('swiftpm-testing-helper-' + name + '.ips')
        path.write_bytes(self.marker if data is None else data)
        return path

    def test_late_and_deduplicated(self):
        first = self.collector.scan('initial', wait_seconds=0)
        self.assertFalse(first['reportsFound'])
        self.report('one'); second = self.collector.scan('late', wait_seconds=0)
        self.assertEqual(len(second['files']), 1)
        self.report('copy'); third = self.collector.scan('last', wait_seconds=0)
        self.assertEqual(len(third['files']), 1)
        self.assertEqual(third['counters']['duplicateContents'], 1)
        self.assertFalse(first['reportsFound'])
        with self.assertRaises(ValueError): self.collector.scan('fourth', wait_seconds=0)

    def test_total_budget_not_reset_between_scans(self):
        size = len(self.marker)
        with patch.object(crash_reports, 'MAX_TOTAL', size + 2):
            self.report('one'); self.collector.scan('first', wait_seconds=0)
            self.report('two', self.marker + b'different')
            result = self.collector.scan('late', wait_seconds=0)
            self.assertEqual(result['bytes'], size)
            self.assertEqual(len(result['files']), 1)
            self.assertTrue(result['rejected'])

    def test_file_cap_shared(self):
        with patch.object(crash_reports, 'MAX_FILES', 1):
            self.report('one'); self.collector.scan('first', wait_seconds=0)
            self.report('two', self.marker + b'2')
            result = self.collector.scan('second', wait_seconds=0)
            self.assertEqual(len(result['files']), 1)

    def test_wrong_owned_bundle_rejected(self):
        self.report('other', b'/another/owner/LatticePackageTests')
        result = self.collector.scan('first', wait_seconds=0)
        self.assertFalse(result['reportsFound']); self.assertEqual(len(result['rejected']), 1)

    def test_symlink_rejected(self):
        self.report('target'); (self.reports / 'swiftpm-testing-helper-link.ips').symlink_to(self.reports / 'swiftpm-testing-helper-target.ips')
        result = self.collector.scan('first', wait_seconds=0)
        self.assertEqual(len(result['files']), 1)
        self.assertGreater(result['scans'][0]['directories'][str(self.reports)]['oldOrNonregular'], 0)

    def test_failed_output_stays_charged_and_stops(self):
        self.report('one')
        real_open = Path.open
        class Partial:
            def __init__(self, output): self.output = output
            def __enter__(self): return self
            def write(self, data):
                self.output.write(data[:3])
                raise OSError('injected write failure')
            def __exit__(self, *args): self.output.close()
        def failing_open(path, mode='r', *args, **kwargs):
            opened = real_open(path, mode, *args, **kwargs)
            return Partial(opened) if path.parent == self.collector.destination and mode == 'xb' else opened
        with patch.object(Path, 'open', failing_open):
            with self.assertRaises(RuntimeError): self.collector.scan('first', wait_seconds=0)
        value = self.collector.snapshot()
        self.assertTrue(value['custodyStopped'])
        self.assertEqual(value['bytes'], len(self.marker))
        self.assertEqual(len(value['files']), 1)
        self.assertEqual(value['files'][0]['status'], 'copy-not-completed')
        self.assertEqual((self.collector.destination / value['files'][0]['name']).stat().st_size, 3)
        with self.assertRaises(RuntimeError): self.collector.scan('late', wait_seconds=0)

    def test_final_copy_drift_rejected(self):
        self.report('one'); self.collector.scan('first', wait_seconds=0)
        item = self.collector.result['files'][0]
        (self.collector.destination / item['name']).write_bytes(b'changed')
        with self.assertRaises(AssertionError): self.collector.snapshot()

    def test_aggregate_read_attempt_cap(self):
        self.collector.result['counters']['eligibleReadAttempts'] = 64
        self.report('one')
        result = self.collector.scan('late', wait_seconds=0)
        self.assertTrue(result['inventoryTruncated'])
        self.assertEqual(result['files'], [])

    def test_missing_directory_observable(self):
        self.reports.rmdir()
        result = self.collector.scan('first', wait_seconds=0)
        self.assertEqual(result['scans'][0]['directories'][str(self.reports)]['missingPasses'], 1)

    def test_error_metadata_capped(self):
        for number in range(100): self.collector.record('errors', {'error': 'x' * 2000})
        self.assertEqual(len(self.collector.result['errors']), 64)
        self.assertEqual(self.collector.result['metadataOmitted']['errors'], 36)
        self.assertEqual(len(self.collector.result['errors'][0]['error']), 1024)

    def test_fifo_swap_nonblocking(self):
        import os
        target = self.report('one'); real_open = os.open
        def swap(path, flags, *args):
            if Path(path) == target:
                target.unlink(); os.mkfifo(target)
            return real_open(path, flags, *args)
        with patch.object(crash_reports.os, 'open', swap):
            result = self.collector.scan('first', wait_seconds=0)
        self.assertFalse(result['reportsFound']); self.assertTrue(result['errors'])


if __name__ == '__main__': unittest.main()
