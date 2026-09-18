"""Describe one bounded trace; temporal overlap is not lock-wait causality."""
from collections import Counter

PHASES = {
    'other', 'epoch_read', 'claim', 'watermark_max', 'watermark_store',
    'watermark_bound', 'floor_schema', 'floor_read', 'watermark_cleanup',
    'cursor_read', 'disabled_read', 'receipt_schema', 'begin', 'disable_sync',
    'delete_audit', 'delete_sync', 'delete_receipts', 'restore_sync', 'commit',
    'rollback', 'release_claim',
}


def overlap(a, b, c, d):
    return max(0, min(b, d) - max(a, c))


def union_duration(intervals):
    end = None
    total = 0
    for left, right in sorted(intervals):
        assert right >= left
        total += right - max(left, end if end is not None else left) if end is None or right > end else 0
        end = max(end if end is not None else right, right)
    return total


def analyze(sample):
    events = sample['events']
    traces = [x for x in events if x['kind'] == 'maintenancePhases']
    ticks = [x for x in events if x['kind'] == 'tickDone']
    writes = [x for x in events if x['kind'] == 'write']
    assert sample['success'] and len(traces) == len(ticks) == 1
    assert len(writes) == 1000 and [x['index'] for x in writes] == list(range(1000))
    trace, tick = traces[0], ticks[0]
    assert trace['schema'] == 'retention.phases/1'
    assert trace['capacity'] == 256 and trace['activeCapacity'] == 32
    records = trace['records']
    assert trace['recordCount'] == len(records) <= 256
    assert [x['ordinal'] for x in records] == list(range(len(records)))
    assert tick['instrumented'] is True and tick['endNS'] >= tick['startNS']
    for row in records:
        assert row['phase'] in PHASES and tick['startNS'] <= row['startNS'] <= tick['endNS']
        assert isinstance(row['finished'], bool) and row['sqliteProfileNS'] >= 0
        if row['finished']:
            assert row['startNS'] <= row['endNS'] <= tick['endNS']
        else:
            assert row['endNS'] == 0
    completed = [x for x in records if x['finished']]
    failures = {k: trace[k] for k in ['droppedRecords', 'activeOverflow', 'unmatchedProfiles', 'missingSQL', 'duplicateStarts'] if trace[k]}
    if len(completed) != len(records):
        failures['unfinishedRecords'] = len(records) - len(completed)
    counts = Counter(x['phase'] for x in completed)
    for name in ['claim', 'watermark_store', 'watermark_bound', 'floor_read', 'begin', 'delete_audit', 'delete_sync', 'commit']:
        if counts[name] != 1:
            failures['expectedOne_' + name] = counts[name]
    if counts['rollback'] or counts['release_claim']:
        failures['rollbackOrReleasedClaim'] = counts['rollback'] + counts['release_claim']
    bracket = None
    if counts['begin'] == counts['commit'] == 1:
        begin = next(x for x in completed if x['phase'] == 'begin')
        commit = next(x for x in completed if x['phase'] == 'commit')
        if begin['endNS'] <= commit['startNS']:
            bracket = {
                'beginStatementStartNS': begin['startNS'], 'beginProfileEndNS': begin['endNS'],
                'commitStatementStartNS': commit['startNS'], 'commitProfileEndNS': commit['endNS'],
                'beginExecutionNS': begin['endNS'] - begin['startNS'],
                'beginStartThroughCommitEndNS': commit['endNS'] - begin['startNS'],
                'beginEndThroughCommitEndNS': commit['endNS'] - begin['endNS'],
                'meaning': 'Observed explicit transaction bracket. PROFILE does not report statement result; fixture validation checks committed outcome. Neither bracket identifies exact write-lock acquisition or release.',
            }
        else:
            failures['transactionOrder'] = True
    grouped = {}
    for name in sorted(counts):
        rows = [x for x in completed if x['phase'] == name]
        grouped[name] = {'count': len(rows),
                         'inclusiveWallNS': sum(x['endNS'] - x['startNS'] for x in rows),
                         'sqliteApproximateProfileNS': sum(x['sqliteProfileNS'] for x in rows)}
    longest = []
    for write in sorted(writes, key=lambda x: (x['endNS'] - x['startNS']), reverse=True)[:10]:
        assert write['endNS'] >= write['startNS']
        intersections = []
        for row in completed:
            duration = overlap(write['startNS'], write['endNS'], row['startNS'], row['endNS'])
            if duration:
                intersections.append({'ordinal': row['ordinal'], 'phase': row['phase'], 'overlapNS': duration})
        longest.append({'index': write['index'], 'startNS': write['startNS'], 'endNS': write['endNS'],
                        'durationNS': write['endNS'] - write['startNS'],
                        'statementOverlaps': intersections,
                        'transactionBracketOverlapNS': overlap(write['startNS'], write['endNS'], bracket['beginStatementStartNS'], bracket['commitProfileEndNS']) if bracket else None})
    tick_ns = tick['endNS'] - tick['startNS']
    covered = union_duration([(x['startNS'], x['endNS']) for x in completed])
    capture_complete = not failures
    classification_complete = not counts['other']
    return {
        'scope': 'one instrumented B sample; descriptive attribution only; no performance acceptance',
        'traceComplete': capture_complete, 'classificationComplete': classification_complete,
        'phaseQualified': capture_complete and classification_complete, 'traceFailures': failures,
        'tickNS': tick_ns, 'observedStatementUnionNS': covered,
        'unattributedWithinTickNS': tick_ns - covered,
        'phaseTotals': grouped, 'transactionBracket': bracket,
        'longestWrites': longest,
        'rawStatementRecords': records,
        'traceCounts': {k: trace[k] for k in ['statementCallbacks', 'profileCallbacks', 'triggerCallbacks', 'duplicateStarts', 'droppedRecords', 'activeOverflow', 'unmatchedProfiles', 'missingSQL']},
        'limitations': [
            'Tracing perturbs execution. Do not append this sample to the uninstrumented five-triplet timing result.',
            'SQLITE_TRACE_STMT begins at execution, after prepare and native connection-lock acquisition. Those earlier waits remain in the unattributed interval.',
            'SQLite PROFILE duration is approximate and is not a statement success code or a lock-wait duration.',
            'Phase durations are inclusive; nested statements may overlap. Statement union avoids double counting.',
            'Writer/maintenance timestamps share the same Linux host monotonic clock; no cross-host comparison is permitted.',
            'Temporal overlap does not prove a specific writer waited on a specific SQLite lock.',
            'Only this maintenance connection is traced. Notifier/read connections and foreground SQL internals are not traced.',
            'Trigger callbacks are counted without per-trigger records; dropped/unmatched records make attribution incomplete, not idle.',
            'Unclassified SQL remains other and prevents phase qualification; ordinary time outside statement callbacks stays explicitly unattributed.',
        ],
    }
