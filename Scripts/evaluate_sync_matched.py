"""All-origin matched capture grammar; never changes calibration receipts.

Late actual public SQL reads may measure baseline latency, but never repair the
original deadline. Missing origins/reads never become censored samples or a
successful subset. Candidate B must still pass ordinary timely calibration.
"""
import argparse
import json
from pathlib import Path

import evaluate_sync as original

POLICY = 'deadline60s-tail120s-all-origins.v1'
TAIL_NS = 120_000_000_000
DEADLINE_ERROR = 'matched measured public visibility deadline'
DEADLINE_ISSUES = {
    'run recorded errors', 'producer declared incomplete',
    'write, timeout or exact-value failure',
    'missing offer/write/public-visibility timestamp',
    'late public read cannot replace deadline success',
}


def analyze(data):
    timely = original.analyze(data)
    failures = []
    def issue(message):
        if message not in failures:
            failures.append(message)
    deadline = data.get('deadlineNS')
    capture_end = data.get('captureDeadlineNS')
    if (data.get('capturePolicy') != POLICY or data['metadata'].get('CAPTURE_POLICY') != POLICY
            or type(deadline) is not int or type(capture_end) is not int
            or capture_end != deadline + TAIL_NS):
        issue('missing or different actual fixed capture policy/deadline')
    if not timely['headlineProfile'] or data['mode'] != 'full':
        issue('matched capture requires unchanged full workload and native clock')
    for name in timely['issueCounts']:
        if name not in DEADLINE_ISSUES:
            issue('original validation failure: ' + name)
    failed_deadline = data.get('deadlineFailureRecorded')
    if type(failed_deadline) is not bool:
        issue('missing actual original deadline result')
    elif failed_deadline:
        if data['errors'] != [DEADLINE_ERROR] or data['complete'] is not False:
            issue('deadline failure is not the sole retained error/incomplete reason')
    elif data['errors'] or not timely['validCompleteRun']:
        issue('declared timely result contradicts original validation')
    if data.get('captureComplete') is not True:
        issue('producer did not capture the whole expected population')
    if set(data['effectiveParameters']) != set(original.FULL):
        issue('workload parameter grammar differs')
    if timely['receiptCount'] != timely['expectedReceiptCount']:
        issue('missing logical operation receipts')
    groups = {'hot': [], 'quiet': []}
    late_count = 0
    epoch = data.get('measurementEpochNS')
    for row in data['receipts']:
        first, late = row.get('firstExactReadNS'), row.get('lateExactReadNS')
        # Preserve both original fields. A second timestamp or absent timestamp
        # is not a replacement, imputation or acceptable censoring boundary.
        if (first is None) == (late is None):
            issue('every expected operation requires exactly one actual first public read')
            continue
        visible = first if first is not None else late
        if type(visible) is not int or not data['startedNS'] <= visible <= data['finishedNS']:
            issue('actual public timestamp outside run')
            continue
        for name in ('scheduledNS', 'offeredNS', 'writeStartNS', 'writeReturnNS', 'probeArmedNS', 'postcommitNS'):
            if type(row.get(name)) is not int:
                issue('missing actual offered/native origin timestamp')
        if any(type(row.get(name)) is not int for name in
               ('scheduledNS', 'offeredNS', 'writeStartNS', 'writeReturnNS', 'probeArmedNS', 'postcommitNS')):
            continue
        if not (row['scheduledNS'] <= row['offeredNS'] <= row['writeStartNS']
                <= row['probeArmedNS'] <= row['postcommitNS'] <= row['writeReturnNS']
                and row['postcommitNS'] <= visible):
            issue('invalid actual native commit/public read order')
        if (row.get('writeError') is not None or row.get('valueMatch') is not True
                or row['valueMismatchCount'] != 0
                or row.get('observedID') != row['id']
                or row.get('readerStoreID') != f"clients/{row['stream']}-watcher.sqlite"):
            issue('write/value/public primary-key reader failed')
        if row['phase'] == 'warmup':
            if late is not None or row['timedOut'] or epoch is None or visible > epoch:
                issue('warmup was not timely before measurement')
        else:
            if first is not None:
                if row['timedOut'] or visible > row['observationDeadlineNS']:
                    issue('timely receipt contradicts original deadline')
            else:
                late_count += 1
                if (not row['timedOut'] or not failed_deadline
                        or type(capture_end) is not int or visible > capture_end):
                    issue('late capture does not preserve original failure/fixed tail')
                # A read timestamp obtained before recorder.freeze can be
                # delivered to its lock after freeze. Preserve that actual
                # timestamp and frozen/timedOut fact, never recategorize it as
                # original timely success or assume late capture means late SQL.
            groups[row['stream']].append((row, visible))
    if bool(late_count) != bool(failed_deadline):
        issue('deadline result disagrees with actual late population')
    streams = {}
    p = data['effectiveParameters']
    for stream, pairs in groups.items():
        expected = p['writerCount'] * p['opsPerWriter'] if stream == 'hot' else p['quietOps']
        if len(pairs) != expected:
            issue('whole measured stream population is incomplete')
        metrics = {}
        for metric, field in (('scheduledToVisible', 'scheduledNS'), ('writeStartToVisible', 'writeStartNS'),
                              ('postcommitToVisible', 'postcommitNS'), ('writeReturnToVisible', 'writeReturnNS')):
            metrics[metric] = original.distribution([(visible - row[field]) / 1e6 for row, visible in pairs])
        metrics['offerLateness'] = original.distribution([(row['offeredNS'] - row['scheduledNS']) / 1e6 for row, _ in pairs])
        span = (p['opsPerWriter'] * p['cadenceNS'] + (p['writerCount'] - 1) * p['staggerNS']
                if stream == 'hot' and p['writerCount'] else p['quietOps'] * p['quietCadenceNS'])
        end = max([epoch + span] + [visible for _, visible in pairs]) if epoch is not None else None
        duration = (end - epoch) / 1e9 if end is not None else None
        streams[stream] = {'expected': expected, 'receiptCount': len(pairs), 'completed': len(pairs),
            'offered': sum(row.get('offeredNS') is not None for row, _ in pairs),
            'timedOut': sum(row['timedOut'] for row, _ in pairs), 'metrics': metrics,
            'throughputWindowSeconds': duration,
            'completedOperationsPerSecond': len(pairs) / duration if duration and pairs else None}
    result = dict(timely)
    result.update(streams=streams, eligibleForNumericalComparison=not failures,
                  measurementPopulationComplete=not failures, capturePolicy=POLICY,
                  captureFailures=failures, actualLateMeasuredReads=late_count,
                  timelyCalibration=timely,
                  latencyPopulation='every expected measured operation, actual first timely OR late exact public SQL read; missing is ineligible, never a censored or successful subset',
                  throughputEstimator='all expected exact captured identities / max(nominal offer span, actual last public read minus epoch)',
                  scope=original.DISCLAIMER)
    return result


def compare(groups, *, profile='loaded'):
    if len(groups) != 5:
        raise ValueError('exactly five fresh matched groups required per platform')
    failures, experiment_ids, leg_ids = [], set(), set()
    for ordinal, group in enumerate(groups, 1):
        if set(group) != {'A', 'A2', 'B'}:
            raise ValueError('each group requires exactly A/A2/B')
        for label, run in group.items():
            m = run['metadata']
            experiment_ids.add(m.get('EXPERIMENT_ID'))
            if m.get('LEG') != label or not m.get('LEG_ID') or m.get('LEG_ID') in leg_ids:
                failures.append(f'group {ordinal} {label}: missing/reused/wrong preissued leg')
            leg_ids.add(m.get('LEG_ID'))
            if run.get('capturePolicy') != POLICY or not run.get('measurementPopulationComplete'):
                failures.append(f'group {ordinal} {label}: incomplete/different full capture population')
        if not group['B']['timelyCalibration']['validCompleteRun']:
            failures.append(f'group {ordinal} B: original timely calibration failed')
        if len({r['metadata'].get('PROFILE_ORDER') for r in group.values()}) != 1:
            failures.append(f'group {ordinal}: profile sequence differs across legs')
    if len(experiment_ids) != 1 or None in experiment_ids or len(leg_ids) != 15:
        failures.append('one actual experiment and fifteen distinct leg IDs required')
    if failures:
        return {'eligible': False, 'failures': failures, 'numericalGatesPass': False,
                'scope': original.DISCLAIMER}
    # Original ratios/thresholds use the independently validated FULL population.
    # No raw receipt is rewritten and original timely verdict remains attached.
    result = original.compare(groups, profile=profile)
    result.update(capturePolicy=POLICY, candidateTimelyRequired=True,
                  baselineDeadlineFailuresRetained=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('run', 'compare', 'compare-quiet'))
    parser.add_argument('input', type=Path)
    args = parser.parse_args()
    data, sha = original.read_json(args.input)
    if args.mode == 'run':
        result = analyze(data)
        result['inputSHA256'] = sha
    else:
        groups = []
        for group in data['groups']:
            members = {}
            for label, name in group.items():
                raw, raw_sha = original.read_json(args.input.parent / name)
                members[label] = analyze(raw)
                members[label]['inputSHA256'] = raw_sha
            groups.append(members)
        result = compare(groups, profile='quiet-only' if args.mode == 'compare-quiet' else 'loaded')
        result.update(runs=groups, manifestSHA256=sha)
    print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
    return 0 if result.get('numericalGatesPass', result.get('measurementPopulationComplete', False)) else 1


if __name__ == '__main__':
    raise SystemExit(main())
