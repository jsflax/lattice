"""Synthetic runner receipt checks, not native test execution."""
import unittest
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import sync_probe_qualification as q


class NativeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.names = set(q.NATIVE_CASES)
        self.first, self.second = sorted(self.names)[:2]
        self.xml = '<testsuites><testsuite>' + ''.join(
            f'<testcase name="{name}" classname="SyncCommitProbe" status="run" result="completed"/>'
            for name in sorted(self.names)) + '</testsuite></testsuites>'

    def test_all_exact_cases_required(self):
        self.assertEqual(q.check_native_xml(self.xml, self.names)['count'], 17)
        with self.assertRaises(ValueError): q.check_native_xml('<testsuites/>', self.names)
        with self.assertRaises(ValueError): q.check_native_xml(self.xml.replace(self.second + '"', self.first + '"'), self.names)

    def test_failure_skip_and_notrun_never_pass(self):
        for child in ('failure', 'skipped', 'error'):
            altered = self.xml.replace('/>', f'><{child}/></testcase>', 1)
            with self.assertRaises(ValueError): q.check_native_xml(altered, self.names)
        with self.assertRaises(ValueError):
            q.check_native_xml(self.xml.replace('status="run"', 'status="notrun"', 1), self.names)

    def test_wrong_suite_and_missing_identity_never_pass(self):
        with self.assertRaises(ValueError):
            q.check_native_xml(self.xml.replace('classname="SyncCommitProbe"', 'classname="AnotherSuite"', 1), self.names)
        with self.assertRaises(ValueError): q.check_native_xml(self.xml, self.names - {self.first})

    def test_source_inventory_is_exact_not_zero_or_duplicates(self):
        source = '\n'.join(f'TEST_F(SyncCommitProbe, {name}) {{}}' for name in sorted(self.names))
        self.assertEqual(q.expected_tests(source), self.names)
        with self.assertRaises(ValueError): q.expected_tests('')
        with self.assertRaises(ValueError): q.expected_tests(source + f'\nTEST_F(SyncCommitProbe, {self.first}) {{}}')

    def test_same_count_renamed_or_missing_composition_case_cannot_pass(self):
        source = '\n'.join(f'TEST_F(SyncCommitProbe, {name}) {{}}' for name in sorted(self.names))
        for name in ('EnrolledGeneratedWriteAndSuccessorPreserveProducerProvenance',
                     'ActualProtectedClaimAndDetachedCallbackCannotReplaceConsumedOrigin',
                     'PrivateInstallCannotArmAndRollbackDoesNotContaminatePublicSuccessor'):
            with self.subTest(name=name):
                with self.assertRaises(ValueError): q.expected_tests(source.replace(name, 'UnreviewedCase'))
                with self.assertRaises(ValueError): q.check_native_xml(self.xml.replace(name, 'UnreviewedCase'), self.names)

    def test_summary_requires_all_exact_results_and_rejects_old_fourteen(self):
        summary = q.check_native_xml(self.xml, self.names)
        q.check_native_summary(summary)
        for changes in ({'count': 14, 'names': sorted(self.names)[:14]},
                        {'count': 17, 'names': [self.first] * 17},
                        {'names': sorted(self.names)[:-1] + ['UnreviewedCase']},
                        {'allExecutedWithoutFailure': False}, {'count': '17'}, {'names': []}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                q.check_native_summary(dict(summary, **changes))

    def test_sdk_inventory_requires_each_real_positive_completion(self):
        log = '\n'.join(f'✔ Test {name}() passed after 0.001 seconds.' for name in sorted(q.SDK_CASES))
        self.assertEqual(set(q.check_sdk_log(log)['affirmativePassedCases']), q.SDK_CASES)
        with self.assertRaises(ValueError): q.check_sdk_log('Test run passed after 0.1 seconds.')
        with self.assertRaises(ValueError): q.check_sdk_log(log.replace('passed after', 'skipped after', 1))
        with self.assertRaises(ValueError): q.check_sdk_log(log + '\n' + log.splitlines()[0])


class CapacityBridgeReceiptTests(unittest.TestCase):
    """Synthetic XML/control flow only; no Swift/native command is executed."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.capacity-qualification-data-', dir=Path(__file__).resolve().parents[1])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ordinal = 0

    def xml(self, suite, names):
        return '<testsuites><testsuite>' + ''.join(
            f'<testcase name="{name}" classname="{suite}" status="run" result="completed"/>'
            for name in sorted(names)) + '</testsuite></testsuites>'

    def run_fake(self, *, capacity_source=True, capacity_xml=None, original_xml=None, capacity_error=None):
        self.ordinal += 1
        root = self.root / str(self.ordinal)
        core = root / 'Core'
        tests = core / 'Tests/LatticeCoreTests'
        tests.mkdir(parents=True)
        (tests / 'SyncCommitProbeTests.cpp').write_text('\n'.join(
            f'TEST_F(SyncCommitProbe, {name}) {{}}' for name in sorted(q.NATIVE_CASES)))
        if capacity_source is not None:
            (tests / 'OrdinaryExportCapacityBridgeTests.cpp').write_text(
                '\n'.join(f'TEST(OrdinaryExportCapacityBridge, {name}) {{}}' for name in sorted(q.CAPACITY_BRIDGE_CASES))
                if capacity_source is True else capacity_source)
        receipts = root / 'receipts'
        receipts.mkdir()
        env = {'KEEP': 'original'}
        runner = SimpleNamespace(receipts=receipts, env=env)
        calls = []
        def run(label, argv, *, cwd, timeout):
            calls.append({'label': label, 'argv': list(argv), 'cwd': cwd, 'timeout': timeout, 'env': runner.env})
            log = receipts / (label + '.log')
            log.write_text('retained synthetic command output\n')
            if label == 'native-capacity-bridge' and capacity_error is not None:
                raise capacity_error
            xml_path = Path(next(value.split('=', 1)[1].removeprefix('xml:') for value in argv if value.startswith('--gtest_output=')))
            xml_path.write_text((original_xml if original_xml is not None else self.xml('SyncCommitProbe', q.NATIVE_CASES))
                if label == 'native-probe' else (capacity_xml if capacity_xml is not None else self.xml('OrdinaryExportCapacityBridge', q.CAPACITY_BRIDGE_CASES)))
            return log
        runner.run = run
        proof = {'samples': [{'command': 'clang -DLATTICE_SYNC_COMMIT_PROBE -c fixture.cpp'}]}
        try:
            q.qualify_native(runner, core, root, lambda log, actual_core: proof)
        except Exception as error:
            caught = error
        else:
            caught = None
        self.assertIs(runner.env, env)
        return root, calls, caught

    def test_source_requires_exact_two_named_cases(self):
        source = '\n'.join(f'TEST(OrdinaryExportCapacityBridge, {name}) {{}}' for name in sorted(q.CAPACITY_BRIDGE_CASES))
        self.assertEqual(q.expected_capacity_bridge_tests(source), q.CAPACITY_BRIDGE_CASES)
        for bad in ('', source.replace(sorted(q.CAPACITY_BRIDGE_CASES)[0], 'WrongCase'), source + source):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                q.expected_capacity_bridge_tests(bad)

    def test_xml_requires_exact_suite_names_execution_and_no_failure(self):
        xml = self.xml('OrdinaryExportCapacityBridge', q.CAPACITY_BRIDGE_CASES)
        self.assertEqual(q.check_capacity_bridge_xml(xml, q.CAPACITY_BRIDGE_CASES)['count'], 2)
        first, second = sorted(q.CAPACITY_BRIDGE_CASES)
        bad = ['<testsuites/>', xml.replace(second, first), xml.replace(first, 'WrongCase'),
               xml.replace('classname="OrdinaryExportCapacityBridge"', 'classname="Other"', 1),
               xml.replace('status="run"', 'status="notrun"', 1), xml.replace('result="completed"', 'result="suppressed"', 1)]
        bad += [xml.replace('/>', f'><{name}/></testcase>', 1) for name in ('failure', 'skipped', 'error')]
        for value in bad:
            with self.subTest(xml=value), self.assertRaises(ValueError):
                q.check_capacity_bridge_xml(value, q.CAPACITY_BRIDGE_CASES)
        with self.assertRaises(ValueError):
            q.check_capacity_bridge_xml(xml, {first})

    def test_separate_execution_preserves_original_seventeen_and_all_runner_arguments(self):
        root, calls, caught = self.run_fake()
        self.assertIsNone(caught)
        self.assertEqual([call['label'] for call in calls], ['native-probe', 'native-capacity-bridge'])
        self.assertEqual(calls[0]['argv'][:-2], calls[1]['argv'][:-2])
        for call in calls:
            self.assertEqual(call['timeout'], 5400)
            self.assertEqual(call['cwd'], root / 'Core')
            self.assertIs(call['env'], calls[0]['env'])
        self.assertEqual(calls[1]['argv'][-2], '--gtest_filter=OrdinaryExportCapacityBridge.*')
        self.assertEqual(calls[1]['argv'][-1], '--gtest_output=xml:' + str(root / 'receipts/native-capacity-bridge.xml'))
        original = json.loads((root / 'receipts/native-probe-qualification.json').read_text())
        capacity = json.loads((root / 'receipts/native-capacity-bridge-qualification.json').read_text())
        self.assertEqual(original['tests']['count'], 17)
        self.assertEqual(set(original['tests']['names']), q.NATIVE_CASES)
        self.assertEqual(capacity['tests']['count'], 2)
        self.assertEqual(set(capacity['tests']['names']), q.CAPACITY_BRIDGE_CASES)
        self.assertTrue((root / 'receipts/native-probe.xml').is_file())

    def test_missing_or_wrong_capacity_source_fails_instead_of_skipping(self):
        for source in (None, ''):
            with self.subTest(source=source):
                root, calls, caught = self.run_fake(capacity_source=source)
                self.assertIsNotNone(caught)
                self.assertEqual(len(calls), 1)
                self.assertTrue((root / 'receipts/native-probe-qualification.json').is_file())
                self.assertFalse((root / 'receipts/native-capacity-bridge-qualification.json').exists())

    def test_real_runner_failure_propagates_and_keeps_original_probe_evidence(self):
        first = RuntimeError('synthetic capacity command first failure')
        root, calls, caught = self.run_fake(capacity_error=first)
        self.assertIs(caught, first)
        self.assertEqual(len(calls), 2)
        self.assertTrue((root / 'receipts/native-probe-qualification.json').is_file())
        self.assertTrue((root / 'receipts/native-capacity-bridge.log').is_file())
        self.assertFalse((root / 'receipts/native-capacity-bridge-qualification.json').exists())

    def test_zero_or_failed_capacity_xml_cannot_qualify(self):
        xml = self.xml('OrdinaryExportCapacityBridge', q.CAPACITY_BRIDGE_CASES)
        for bad in ('<testsuites/>', xml.replace('/>', '><failure/></testcase>', 1)):
            with self.subTest(xml=bad):
                root, calls, caught = self.run_fake(capacity_xml=bad)
                self.assertIsInstance(caught, ValueError)
                self.assertEqual(len(calls), 2)
                self.assertTrue((root / 'receipts/native-probe-qualification.json').is_file())
                self.assertEqual((root / 'receipts/native-capacity-bridge.xml').read_text(), bad)
                self.assertFalse((root / 'receipts/native-capacity-bridge-qualification.json').exists())

    def test_original_probe_failure_never_runs_capacity(self):
        root, calls, caught = self.run_fake(original_xml='<testsuites/>')
        self.assertIsInstance(caught, ValueError)
        self.assertEqual(len(calls), 1)
        self.assertFalse((root / 'receipts/native-capacity-bridge.xml').exists())


if __name__ == '__main__': unittest.main()
