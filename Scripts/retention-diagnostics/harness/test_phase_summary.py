import copy
import unittest
from phase_summary import analyze, union_duration


def fixture():
    labels = ['claim', 'watermark_store', 'watermark_bound', 'floor_read',
              'begin', 'delete_audit', 'delete_sync', 'commit']
    records = [{'ordinal': i, 'phase': name, 'startNS': 100 + i * 10,
                'endNS': 105 + i * 10, 'finished': True, 'sqliteProfileNS': 0}
               for i, name in enumerate(labels)]
    trace = {'kind': 'maintenancePhases', 'schema': 'retention.phases/1',
             'capacity': 256, 'activeCapacity': 32, 'recordCount': len(records),
             'records': records, 'statementCallbacks': 8, 'profileCallbacks': 8,
             'triggerCallbacks': 0, 'duplicateStarts': 0, 'droppedRecords': 0,
             'activeOverflow': 0, 'unmatchedProfiles': 0, 'missingSQL': 0}
    writes = [{'kind': 'write', 'index': i, 'startNS': 2000 + i * 2,
               'endNS': 2001 + i * 2} for i in range(1000)]
    writes[0].update(startNS=130, endNS=185)
    return {'success': True, 'events': [trace, {'kind': 'tickDone',
            'startNS': 0, 'endNS': 1000, 'instrumented': True}] + writes}


class PhaseSummaryTests(unittest.TestCase):
    def test_complete_trace_has_descriptive_bracket_and_writer_overlap(self):
        result = analyze(fixture())
        self.assertTrue(result['traceComplete'])
        self.assertTrue(result['phaseQualified'])
        self.assertEqual(result['observedStatementUnionNS'], 40)
        self.assertEqual(result['unattributedWithinTickNS'], 960)
        self.assertEqual(result['transactionBracket']['beginStartThroughCommitEndNS'], 35)
        self.assertEqual(result['longestWrites'][0]['transactionBracketOverlapNS'], 35)
        self.assertEqual(len(result['longestWrites']), 10)

    def test_nested_intervals_are_unioned_without_double_counting(self):
        self.assertEqual(union_duration([(10, 90), (20, 30), (80, 100), (110, 120)]), 100)

    def test_each_overflow_or_missing_counter_fails_attribution(self):
        for key in ['droppedRecords', 'activeOverflow', 'unmatchedProfiles', 'missingSQL', 'duplicateStarts']:
            with self.subTest(key=key):
                value = fixture(); value['events'][0][key] = 1
                result = analyze(value)
                self.assertFalse(result['traceComplete'])
                self.assertEqual(result['traceFailures'][key], 1)

    def test_unfinished_statement_is_unknown_not_zero_cost(self):
        value = fixture(); value['events'][0]['records'][5].update(finished=False, endNS=0)
        result = analyze(value)
        self.assertFalse(result['traceComplete'])
        self.assertEqual(result['traceFailures']['unfinishedRecords'], 1)
        self.assertNotIn('delete_audit', result['phaseTotals'])

    def test_unknown_sql_class_remains_explicit_other(self):
        value = fixture(); trace = value['events'][0]
        trace['records'].append({'ordinal': 8, 'phase': 'other', 'startNS': 200,
                                 'endNS': 250, 'finished': True, 'sqliteProfileNS': 1000})
        trace['recordCount'] += 1
        result = analyze(value)
        self.assertEqual(result['phaseTotals']['other']['inclusiveWallNS'], 50)
        self.assertEqual(result['phaseTotals']['other']['sqliteApproximateProfileNS'], 1000)
        self.assertTrue(result['traceComplete'])
        self.assertFalse(result['classificationComplete'])
        self.assertFalse(result['phaseQualified'])

    def test_malformed_phase_is_rejected(self):
        value = fixture(); value['events'][0]['records'][0]['phase'] = 'raw SQL text'
        with self.assertRaises(AssertionError): analyze(value)

    def test_backward_or_outside_tick_statement_is_rejected(self):
        for start, end in [(100, 99), (1001, 1002)]:
            value = fixture(); value['events'][0]['records'][0].update(startNS=start, endNS=end)
            with self.assertRaises(AssertionError): analyze(value)

    def test_incomplete_foreground_workload_is_rejected(self):
        value = fixture(); value['events'].pop()
        with self.assertRaises(AssertionError): analyze(value)

    def test_duplicate_trace_or_changed_cap_is_rejected(self):
        value = fixture(); value['events'].append(copy.deepcopy(value['events'][0]))
        with self.assertRaises(AssertionError): analyze(value)
        value = fixture(); value['events'][0]['capacity'] = 257
        with self.assertRaises(AssertionError): analyze(value)

    def test_unexpected_rollback_is_preserved_and_unqualified(self):
        value = fixture(); value['events'][0]['records'][-1]['phase'] = 'rollback'
        result = analyze(value)
        self.assertFalse(result['traceComplete'])
        self.assertIsNone(result['transactionBracket'])
        self.assertEqual(result['traceFailures']['rollbackOrReleasedClaim'], 1)


if __name__ == '__main__':
    unittest.main()
