import copy
import unittest
from phase_summary import analyze, union_duration


def fixture():
    labels = ['claim', 'watermark_store', 'watermark_bound', 'floor_read',
              'begin', 'delete_audit', 'delete_sync', 'commit']
    records = [{'ordinal': i, 'phase': name, 'startNS': 100 + i * 10,
                'endNS': 105 + i * 10, 'finished': True, 'sqliteProfileNS': 0,
                'startedOnTickThread': True, 'endedOnTickThread': True,
                'unknownSQLFingerprint': '0', 'fingerprintBytes': 0, 'fingerprintTruncated': False}
               for i, name in enumerate(labels)]
    trace = {'kind': 'maintenancePhases', 'schema': 'retention.phases/2',
             'installStartedNS': 0, 'installReturnedNS': 1,
             'removeStartedNS': 1001, 'removeReturnedNS': 1200,
             'capacity': 256, 'activeCapacity': 32, 'recordCount': len(records),
             'records': records, 'statementCallbacks': 8, 'profileCallbacks': 8,
             'triggerCallbacks': 0, 'duplicateStarts': 0, 'droppedRecords': 0,
             'activeOverflow': 0, 'unmatchedProfiles': 0, 'missingSQL': 0}
    writes = [{'kind': 'write', 'index': i, 'startNS': 2000 + i * 2,
               'endNS': 2001 + i * 2} for i in range(1000)]
    writes[0].update(startNS=130, endNS=185)
    return {'success': True, 'events': [trace, {'kind': 'tickDone',
            'startNS': 10, 'endNS': 1000, 'instrumented': True}] + writes}


class PhaseSummaryTests(unittest.TestCase):
    def test_complete_trace_has_descriptive_bracket_and_writer_overlap(self):
        result = analyze(fixture())
        self.assertTrue(result['traceComplete'])
        self.assertTrue(result['phaseQualified'])
        self.assertEqual(result['observedStatementUnionNS'], 40)
        self.assertEqual(result['unattributedWithinTickNS'], 950)
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
        value['events'][0]['profileCallbacks'] -= 1
        result = analyze(value)
        self.assertFalse(result['traceComplete'])
        self.assertEqual(result['traceFailures']['unfinishedRecords'], 1)
        self.assertNotIn('delete_audit', result['phaseTotals'])

    def test_unknown_sql_class_remains_explicit_other(self):
        value = fixture(); trace = value['events'][0]
        trace['records'].append({'ordinal': 8, 'phase': 'other', 'startNS': 200,
                                 'endNS': 250, 'finished': True, 'sqliteProfileNS': 1000,
                                 'startedOnTickThread': True, 'endedOnTickThread': True,
                                 'unknownSQLFingerprint': '12', 'fingerprintBytes': 4, 'fingerprintTruncated': False})
        trace['recordCount'] += 1; trace['statementCallbacks'] += 1; trace['profileCallbacks'] += 1
        result = analyze(value)
        self.assertEqual(result['phaseTotals']['other']['inclusiveWallNS'], 50)
        self.assertEqual(result['phaseTotals']['other']['sqliteApproximateProfileNS'], 1000)
        self.assertTrue(result['traceComplete'])
        self.assertFalse(result['classificationComplete'])
        self.assertFalse(result['phaseQualified'])

    def test_malformed_phase_is_rejected(self):
        value = fixture(); value['events'][0]['records'][0]['phase'] = 'raw SQL text'
        with self.assertRaises(AssertionError): analyze(value)

    def test_backward_statement_is_rejected(self):
        value = fixture(); value['events'][0]['records'][0].update(startNS=100, endNS=99)
        with self.assertRaises(AssertionError): analyze(value)

    def add_record(self, value, phase, start, end, owner=False):
        trace = value['events'][0]
        row = copy.deepcopy(trace['records'][0])
        row.update(ordinal=len(trace['records']), phase=phase, startNS=start, endNS=end,
                   startedOnTickThread=owner, endedOnTickThread=owner)
        if phase == 'other':
            row.update(unknownSQLFingerprint='42', fingerprintBytes=512, fingerprintTruncated=True)
        trace['records'].append(row)
        trace['recordCount'] += 1; trace['statementCallbacks'] += 1; trace['profileCallbacks'] += 1
        return row

    def test_pre_post_and_straddling_connection_work_retained_without_inflating_tick(self):
        value = fixture()
        self.add_record(value, 'vector_catalog', 2, 9)
        self.add_record(value, 'vector_catalog', 1002, 1010)
        self.add_record(value, 'vector_catalog', 990, 1010)
        result = analyze(value)
        self.assertTrue(result['phaseQualified'])
        self.assertEqual(result['recordLocations']['before'], [8])
        self.assertEqual(result['recordLocations']['after'], [9])
        self.assertEqual(result['recordLocations']['straddling'], [10])
        self.assertEqual(result['phaseTotals']['vector_catalog']['inclusiveWallNS'], 10)
        self.assertEqual(result['phaseTotals']['vector_catalog']['fullStatementWallNS'], 20)
        self.assertEqual(result['observedStatementUnionNS'], 50)
        self.assertEqual(len(result['rawStatementRecords']), 11)
        self.assertNotIn('vector_catalog', result['tickThreadPhaseTotals'])

    def test_unknown_outside_window_still_blocks_qualification(self):
        value = fixture(); self.add_record(value, 'other', 2, 9)
        result = analyze(value)
        self.assertTrue(result['traceComplete'])
        self.assertFalse(result['classificationComplete'])
        self.assertFalse(result['phaseQualified'])
        self.assertEqual(result['unknownSQLRecords'][0]['fingerprintBytes'], 512)

    def test_foreign_transaction_cannot_substitute_for_maintenance(self):
        value = fixture(); value['events'][0]['records'][4].update(startedOnTickThread=False, endedOnTickThread=False)
        result = analyze(value)
        self.assertFalse(result['phaseQualified'])
        self.assertEqual(result['traceFailures']['expectedOne_begin'], 0)
        self.assertIsNone(result['transactionBracket'])

    def test_statement_cross_thread_profile_is_unqualified(self):
        value = fixture(); value['events'][0]['records'][0]['endedOnTickThread'] = False
        self.assertEqual(analyze(value)['traceFailures']['statementChangedThread'], 1)

    def test_record_outside_installation_is_retained_as_failure(self):
        value = fixture(); self.add_record(value, 'vector_catalog', 1201, 1210)
        result = analyze(value)
        self.assertFalse(result['phaseQualified'])
        self.assertEqual(result['traceFailures']['outsideInstallationWindow'], 1)
        self.assertEqual(result['recordLocations']['after'], [8])

    def test_historical_trace_does_not_gain_qualification(self):
        value = fixture(); value['events'][0]['schema'] = 'retention.phases/1'
        self.add_record(value, 'other', 2, 9)
        result = analyze(value)
        self.assertFalse(result['phaseQualified'])
        self.assertTrue(result['traceFailures']['legacyCaptureWindowAndThreadUnknown'])
        self.assertIsNone(result['captureWindow'])
        self.assertIsNone(result['tickThreadPhaseTotals'])
        self.assertEqual(result['recordLocations']['before'], [8])

    def test_lazy_migration_is_retained_in_tick_cost(self):
        value = fixture(); self.add_record(value, 'floor_migration', 300, 900, owner=True)
        result = analyze(value)
        self.assertTrue(result['phaseQualified'])
        self.assertEqual(result['tickThreadPhaseTotals']['floor_migration']['inclusiveWallNS'], 600)

    def test_callback_accounting_mismatch_is_unqualified(self):
        value = fixture(); value['events'][0]['statementCallbacks'] += 1
        self.assertTrue(analyze(value)['traceFailures']['callbackAccountingMismatch'])

    def test_malformed_window_and_fingerprint_are_rejected(self):
        value = fixture(); value['events'][0]['installReturnedNS'] = 20
        with self.assertRaises(AssertionError): analyze(value)
        value = fixture(); value['events'][0]['records'][0]['fingerprintBytes'] = 513
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
