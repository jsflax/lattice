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


if __name__ == '__main__': unittest.main()
