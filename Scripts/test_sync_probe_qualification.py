"""Synthetic runner receipt checks, not native test execution."""
import unittest
import sync_probe_qualification as q


class NativeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.names = set(q.NATIVE_CASES)
        self.first, self.second = sorted(self.names)[:2]
        self.xml = '<testsuites><testsuite>' + ''.join(
            f'<testcase name="{name}" classname="SyncCommitProbe" status="run" result="completed"/>'
            for name in sorted(self.names)) + '</testsuite></testsuites>'

    def test_all_exact_cases_required(self):
        self.assertEqual(q.check_native_xml(self.xml, self.names)['count'], 14)
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

    def test_every_baseline_identity_is_required_not_only_the_count(self):
        source = '\n'.join(f'TEST_F(SyncCommitProbe, {name}) {{}}' for name in sorted(self.names))
        for name in sorted(self.names):
            with self.subTest(name=name):
                with self.assertRaises(ValueError): q.expected_tests(source.replace(name, 'UnreviewedCase'))
                with self.assertRaises(ValueError): q.check_native_xml(self.xml.replace(name, 'UnreviewedCase'), self.names)

    def test_summary_requires_original_fourteen_and_rejects_current_seventeen(self):
        summary = q.check_native_xml(self.xml, self.names)
        q.check_native_summary(summary)
        current_only = ['EnrolledGeneratedWriteAndSuccessorPreserveProducerProvenance',
                        'ActualProtectedClaimAndDetachedCallbackCannotReplaceConsumedOrigin',
                        'PrivateInstallCannotArmAndRollbackDoesNotContaminatePublicSuccessor']
        for changes in ({'count': 17, 'names': sorted(self.names) + current_only},
                        {'count': 14, 'names': [self.first] * 14},
                        {'names': sorted(self.names)[:-1] + ['UnreviewedCase']},
                        {'allExecutedWithoutFailure': False}, {'count': '14'}, {'names': []}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                q.check_native_summary(dict(summary, **changes))
        current_source = '\n'.join(f'TEST_F(SyncCommitProbe, {name}) {{}}' for name in sorted(self.names) + current_only)
        with self.assertRaises(ValueError): q.expected_tests(current_source)
        current_xml = self.xml.replace('</testsuite>', ''.join(
            f'<testcase name="{name}" classname="SyncCommitProbe" status="run" result="completed"/>'
            for name in current_only) + '</testsuite>')
        with self.assertRaises(ValueError): q.check_native_xml(current_xml, self.names)

    def test_sdk_inventory_requires_each_real_positive_completion(self):
        log = '\n'.join(f'✔ Test {name}() passed after 0.001 seconds.' for name in sorted(q.SDK_CASES))
        self.assertEqual(set(q.check_sdk_log(log)['affirmativePassedCases']), q.SDK_CASES)
        with self.assertRaises(ValueError): q.check_sdk_log('Test run passed after 0.1 seconds.')
        with self.assertRaises(ValueError): q.check_sdk_log(log.replace('passed after', 'skipped after', 1))
        with self.assertRaises(ValueError): q.check_sdk_log(log + '\n' + log.splitlines()[0])


if __name__ == '__main__': unittest.main()
