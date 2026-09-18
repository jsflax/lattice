"""Describe one bounded trace; temporal overlap is not lock-wait causality."""
from collections import Counter

PHASES = {
    'other', 'epoch_read', 'claim', 'watermark_max', 'watermark_store',
    'watermark_bound', 'floor_schema', 'floor_migration', 'floor_read',
    'vector_catalog', 'local_audit_head', 'watermark_cleanup', 'cursor_read',
    'disabled_read', 'receipt_schema', 'begin', 'disable_sync', 'delete_audit',
    'delete_sync', 'delete_receipts', 'restore_sync', 'commit', 'rollback',
    'release_claim',
}
COUNTERS = ['statementCallbacks', 'profileCallbacks', 'triggerCallbacks',
            'duplicateStarts', 'droppedRecords', 'activeOverflow',
            'unmatchedProfiles', 'missingSQL']


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


def location(row, tick):
    if not row['finished']:
        return 'unfinished'
    if tick['startNS'] <= row['startNS'] <= row['endNS'] <= tick['endNS']:
        return 'within'
    if row['endNS'] <= tick['startNS']:
        return 'before'
    if row['startNS'] >= tick['endNS']:
        return 'after'
    return 'straddling'


def analyze(sample):
    events = sample['events']
    traces = [x for x in events if x['kind'] == 'maintenancePhases']
    ticks = [x for x in events if x['kind'] == 'tickDone']
    writes = [x for x in events if x['kind'] == 'write']
    assert sample['success'] and len(traces) == len(ticks) == 1
    assert len(writes) == 1000 and [x['index'] for x in writes] == list(range(1000))
    trace, tick = traces[0], ticks[0]
    assert trace['schema'] in {'retention.phases/1', 'retention.phases/2'}
    v2 = trace['schema'] == 'retention.phases/2'
    assert trace['capacity'] == 256 and trace['activeCapacity'] == 32
    records = trace['records']
    assert trace['recordCount'] == len(records) <= 256
    assert [x['ordinal'] for x in records] == list(range(len(records)))
    assert tick['instrumented'] is True and tick['endNS'] >= tick['startNS']
    assert all(type(trace[k]) is int and trace[k] >= 0 for k in COUNTERS)
    failures = {k: trace[k] for k in COUNTERS[3:] if trace[k]}
    window = None
    if v2:
        window = {key: trace[key] for key in ['installStartedNS', 'installReturnedNS',
                                            'removeStartedNS', 'removeReturnedNS']}
        assert all(type(x) is int and x >= 0 for x in window.values())
        assert (window['installStartedNS'] <= window['installReturnedNS'] <= tick['startNS']
                <= tick['endNS'] <= window['removeStartedNS'] <= window['removeReturnedNS'])
    else:
        # Historical input remains usable as failed evidence, never retroactively
        # qualified. Its outside-tick records and missing thread attribution stay visible.
        failures['legacyCaptureWindowAndThreadUnknown'] = True
    for row in records:
        assert row['phase'] in PHASES and type(row['startNS']) is int and row['startNS'] >= 0
        assert isinstance(row['finished'], bool) and row['sqliteProfileNS'] >= 0
        if row['finished']:
            assert row['startNS'] <= row['endNS']
        else:
            assert row['endNS'] == 0
        if v2:
            assert type(row['startedOnTickThread']) is bool and type(row['endedOnTickThread']) is bool
            assert type(row['fingerprintBytes']) is int and 0 <= row['fingerprintBytes'] <= 512
            assert type(row['fingerprintTruncated']) is bool
            assert isinstance(row['unknownSQLFingerprint'], str) and row['unknownSQLFingerprint'].isdigit()
            assert 0 <= int(row['unknownSQLFingerprint']) <= 2**64 - 1
            if row['phase'] != 'other':
                assert row['unknownSQLFingerprint'] == '0' and row['fingerprintBytes'] == 0
                assert not row['fingerprintTruncated']
            if row['fingerprintTruncated']:
                assert row['fingerprintBytes'] == 512
            if not (window['installStartedNS'] <= row['startNS'] <= window['removeReturnedNS']
                    and (not row['finished'] or row['endNS'] <= window['removeReturnedNS'])):
                failures['outsideInstallationWindow'] = failures.get('outsideInstallationWindow', 0) + 1
            if row['finished'] and row['startedOnTickThread'] != row['endedOnTickThread']:
                failures['statementChangedThread'] = failures.get('statementChangedThread', 0) + 1
    completed = [x for x in records if x['finished']]
    if len(completed) != len(records):
        failures['unfinishedRecords'] = len(records) - len(completed)
    if (trace['profileCallbacks'] != len(completed) + trace['unmatchedProfiles']
            or trace['statementCallbacks'] != len(records) + sum(trace[k] for k in
                ['triggerCallbacks', 'duplicateStarts', 'droppedRecords', 'activeOverflow', 'missingSQL'])):
        failures['callbackAccountingMismatch'] = True
    locations = {name: [x['ordinal'] for x in records if location(x, tick) == name]
                 for name in ['before', 'within', 'after', 'straddling', 'unfinished']}
    intersecting = [x for x in completed if location(x, tick) in {'within', 'straddling'}]
    # A foreign thread may use this same serialized connection between tick SQL
    # calls. Its work is retained but cannot stand in for the tick's required phases.
    owned = [x for x in intersecting if x.get('startedOnTickThread') is True] if v2 else intersecting
    counts = Counter(x['phase'] for x in owned)
    for name in ['claim', 'watermark_store', 'watermark_bound', 'floor_read', 'begin', 'delete_audit', 'delete_sync', 'commit']:
        if counts[name] != 1:
            failures['expectedOne_' + name] = counts[name]
    if counts['rollback'] or counts['release_claim']:
        failures['rollbackOrReleasedClaim'] = counts['rollback'] + counts['release_claim']
    bracket = None
    if counts['begin'] == counts['commit'] == 1:
        begin = next(x for x in owned if x['phase'] == 'begin')
        commit = next(x for x in owned if x['phase'] == 'commit')
        if (location(begin, tick) == location(commit, tick) == 'within'
                and begin['endNS'] <= commit['startNS']):
            bracket = {
                'beginStatementStartNS': begin['startNS'], 'beginProfileEndNS': begin['endNS'],
                'commitStatementStartNS': commit['startNS'], 'commitProfileEndNS': commit['endNS'],
                'beginExecutionNS': begin['endNS'] - begin['startNS'],
                'beginStartThroughCommitEndNS': commit['endNS'] - begin['startNS'],
                'beginEndThroughCommitEndNS': commit['endNS'] - begin['endNS'],
                'threadAttribution': 'tick' if v2 else 'unknown',
                'meaning': 'Observed explicit transaction bracket. PROFILE does not report statement result; fixture validation checks committed outcome. Neither bracket identifies exact write-lock acquisition or release.',
            }
        else:
            failures['transactionOrderOrWindow'] = True
    def totals(rows):
        grouped = {}
        for name in sorted({x['phase'] for x in rows}):
            selected = [x for x in rows if x['phase'] == name]
            grouped[name] = {'count': len(selected),
                'inclusiveWallNS': sum(overlap(x['startNS'], x['endNS'], tick['startNS'], tick['endNS']) for x in selected),
                'fullStatementWallNS': sum(x['endNS'] - x['startNS'] for x in selected),
                'sqliteApproximateProfileNS': sum(x['sqliteProfileNS'] for x in selected)}
        return grouped
    longest = []
    for write in sorted(writes, key=lambda x: (x['endNS'] - x['startNS']), reverse=True)[:10]:
        assert write['endNS'] >= write['startNS']
        intersections = []
        for row in intersecting:
            left, right = max(row['startNS'], tick['startNS']), min(row['endNS'], tick['endNS'])
            duration = overlap(write['startNS'], write['endNS'], left, right)
            if duration:
                intersections.append({'ordinal': row['ordinal'], 'phase': row['phase'], 'overlapNS': duration,
                                      'startedOnTickThread': row.get('startedOnTickThread')})
        longest.append({'index': write['index'], 'startNS': write['startNS'], 'endNS': write['endNS'],
                        'durationNS': write['endNS'] - write['startNS'],
                        'statementOverlaps': intersections,
                        'transactionBracketOverlapNS': overlap(write['startNS'], write['endNS'], bracket['beginStatementStartNS'], bracket['commitProfileEndNS']) if bracket else None})
    tick_ns = tick['endNS'] - tick['startNS']
    covered = union_duration([(max(x['startNS'], tick['startNS']), min(x['endNS'], tick['endNS'])) for x in intersecting])
    capture_complete = not failures
    unknown = [x for x in records if x['phase'] == 'other']
    return {
        'scope': 'one instrumented B sample; descriptive attribution only; no performance acceptance',
        'traceComplete': capture_complete, 'classificationComplete': not unknown,
        'phaseQualified': capture_complete and not unknown, 'traceFailures': failures,
        'captureWindow': window, 'recordLocations': locations,
        'unknownSQLRecords': [{k: x[k] for k in ['ordinal', 'startNS', 'endNS', 'finished',
            'unknownSQLFingerprint', 'fingerprintBytes', 'fingerprintTruncated'] if k in x} for x in unknown],
        'tickNS': tick_ns, 'observedStatementUnionNS': covered,
        'unattributedWithinTickNS': tick_ns - covered,
        'phaseTotals': totals(intersecting), 'transactionBracket': bracket,
        'tickThreadPhaseTotals': totals(owned) if v2 else None,
        'otherThreadPhaseTotals': totals([x for x in intersecting if not x['startedOnTickThread']]) if v2 else None,
        'longestWrites': longest, 'rawStatementRecords': records,
        'traceCounts': {k: trace[k] for k in COUNTERS},
        'limitations': [
            'Tracing perturbs execution. Do not append this sample to the uninstrumented five-triplet timing result.',
            'SQLITE_TRACE_STMT begins at execution, after prepare and native connection-lock acquisition. Those earlier waits remain in the unattributed interval.',
            'SQLite PROFILE duration is approximate and is not a statement success code or a lock-wait duration.',
            'Phase wall durations and overlaps are clipped to the tick. Full statement spans and pre/post/straddling records are retained; nested intervals use a union to avoid double counting.',
            'Writer/maintenance timestamps share the same Linux host monotonic clock; no cross-host comparison is permitted.',
            'Temporal overlap does not prove a specific writer waited on a specific SQLite lock.',
            'This connection includes background notifier metadata reads. Other connections are not traced; thread labels distinguish tick work without disabling background work.',
            'Trigger callbacks are counted without per-trigger records; dropped/unmatched records make attribution incomplete, not idle.',
            'Every unclassified SQL record, including pre/post tick, remains other and prevents qualification. A bounded noncryptographic fingerprint is not SQL identity proof.',
            'Historical v1 traces lack installation boundaries and thread labels and remain unqualified, even when their within-tick intervals can be described.',
        ],
    }
