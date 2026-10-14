"""Source-only grammar/unit declarations, NOT measured performance evidence.

These deterministic test receipts exercise rejection and population accounting.
They cannot qualify a compiler, native origin, relay, public read or experiment.
No test in this supplier has been executed.
"""
import copy
import unittest

import evaluate_sync
import evaluate_sync_matched as capture
import sync_matched_experiment as coordinator


def grammar_fixture(*, late=False):
    # Quiet full grammar keeps this unit declaration bounded (41 exact rows).
    # Numbers are fabricated contract inputs, never timed measurements.
    p = dict(evaluate_sync.FULL, writerCount=0)
    run = 'unit-grammar'
    epoch = 1_000_000_000
    deadline = epoch + 39 * p['quietCadenceNS'] + p['drainNS']
    records = []
    for phase, count in (('warmup', 1), ('measured', 40)):
        for sequence in range(count):
            scheduled = 10 if phase == 'warmup' else epoch + sequence * p['quietCadenceNS']
            visible = scheduled + 5
            is_late = late and phase == 'measured' and sequence == count - 1
            if is_late:
                visible = deadline + 1
            token = len(records) + 1
            identity = f'{run}/quiet/{phase}/0/{sequence}'
            records.append(dict(id=identity, token=token, runID=run, stream='quiet', phase=phase,
                writer=0, sequence=sequence, writerStoreID='clients/quiet-writer-0.sqlite',
                readerStoreID='clients/quiet-watcher.sqlite', observedID=identity,
                scheduledNS=scheduled, offeredNS=scheduled + 1, writeStartNS=scheduled + 2,
                probeArmedNS=scheduled + 3, postcommitNS=scheduled + 4, writeReturnNS=scheduled + 5,
                firstExactReadNS=None if is_late else visible, lateExactReadNS=visible if is_late else None,
                observationDeadlineNS=100 if phase == 'warmup' else deadline,
                armStatus=0, probeStatus=0, probeOperationID=token, probeAttemptID=1,
                probeOwnerID=1, probeConnectionID=2, probeThreadID=3, ignoredOwnerCommits=0,
                ignoredSchemaCommits=0, valueMatch=True, valueMismatchCount=0, duplicateCallbacks=0,
                timedOut=is_late, writeError=None))
    return dict(schema=evaluate_sync.SCHEMA, runID=run, mode='full', profile='quiet-only',
        clock=evaluate_sync.NATIVE_CLOCK, complete=not late,
        capturePolicy=capture.POLICY, captureDeadlineNS=deadline + capture.TAIL_NS,
        captureComplete=True, deadlineFailureRecorded=late,
        metadata={'CAPTURE_POLICY': capture.POLICY}, effectiveParameters=p, startedNS=1,
        measurementEpochNS=epoch, deadlineNS=deadline, finishedNS=deadline + capture.TAIL_NS + 1,
        errors=[capture.DEADLINE_ERROR] if late else [],
        counters={name: 0 for name in evaluate_sync.COUNTERS}, overhead={}, receipts=records)


class MatchedCoordinatorGrammar(unittest.TestCase):
    def test_five_groups_issue_fifteen_distinct_legs_before_children(self):
        groups = coordinator.schedule('unit-experiment')
        self.assertEqual(len(groups), 5)
        self.assertEqual(len({leg['legID'] for g in groups for leg in g['legs']}), 15)
        for g in groups:
            self.assertEqual([x['label'] for x in g['legs']][-1], 'B')
            self.assertEqual(set(x['label'] for x in g['legs'][:2]), {'A', 'A2'})
            self.assertEqual(set(g['profileOrder']), {'loaded', 'quiet-only'})
        self.assertEqual(groups, coordinator.schedule('unit-experiment'))
        self.assertNotEqual(groups[0]['profileOrder'], groups[1]['profileOrder'])

    def test_late_full_population_retains_original_failure_without_rewriting_input(self):
        raw = grammar_fixture(late=True)
        before = copy.deepcopy(raw)
        result = capture.analyze(raw)
        self.assertEqual(raw, before)
        self.assertTrue(result['measurementPopulationComplete'])
        self.assertFalse(result['timelyCalibration']['validCompleteRun'])
        self.assertEqual(result['actualLateMeasuredReads'], 1)
        self.assertEqual(result['streams']['quiet']['metrics']['postcommitToVisible']['count'], 40)
        self.assertEqual(result['streams']['quiet']['timedOut'], 1)

    def test_missing_failed_native_or_wrong_reader_never_forms_a_success_subset(self):
        for field, value in (('lateExactReadNS', None), ('probeStatus', 1),
                             ('readerStoreID', 'wrong-reader'), ('writeError', 'native error')):
            raw = grammar_fixture(late=True)
            raw['receipts'][-1][field] = value
            self.assertFalse(capture.analyze(raw)['measurementPopulationComplete'])

    def test_different_tail_or_extra_error_cannot_be_called_deadline_only(self):
        raw = grammar_fixture(late=True)
        raw['captureDeadlineNS'] += 1
        self.assertFalse(capture.analyze(raw)['measurementPopulationComplete'])
        raw = grammar_fixture(late=True)
        raw['errors'].append('observer error')
        self.assertFalse(capture.analyze(raw)['measurementPopulationComplete'])

    def test_candidate_timely_requirement_cannot_be_replaced_by_complete_tail(self):
        groups = []
        for ordinal in range(5):
            group = {}
            for label in ('A', 'A2', 'B'):
                result = capture.analyze(grammar_fixture(late=True))
                result['metadata'].update(EXPERIMENT_ID='unit', LEG_ID=f'unit/{ordinal}/{label}',
                                          LEG=label, PROFILE_ORDER='loaded,quiet-only')
                group[label] = result
            groups.append(group)
        result = capture.compare(groups, profile='quiet-only')
        self.assertFalse(result['eligible'])
        self.assertFalse(result['numericalGatesPass'])
        self.assertTrue(any('original timely calibration failed' in x for x in result['failures']))


if __name__ == '__main__':
    unittest.main()
