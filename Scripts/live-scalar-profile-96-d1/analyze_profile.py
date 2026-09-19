#!/usr/bin/env python3
"""Read-only JSON/byte audit of instrumented B; never a performance acceptance."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics

PHASES = {'read.total', 'read.cold_page_identity_anchor', 'read.live_scalars',
          'read.warm_hit', 'read.warm_live_scalars', 'update.total',
          'update.discovery_hydration_routing', 'update.set_and_atomic_increment'}
COUNTS = ('managedCalls', 'prepareCalls', 'bindNameCalls', 'stepCalls', 'extractCalls', 'finalizeCalls', 'rowReturns')
SPANS = ('prepareNS', 'bindNameNS', 'stepNS', 'extractNS', 'finalizeNS')
NUMERIC = ('wallNS', 'threadCPUBracketingNS', 'sqlStatements', *COUNTS, *SPANS)
CHECKSUMS = dict(readChecksum='f4d97904cd404449', beforeChecksum='ce49468f9d371fbf', afterChecksum='e6af078c85b4656c')
CALIBRATION = [False, True, True, False, True, False, False, True]
# Exact observed B statement inventory, common to all 105 samples per variant.
SQL = {variant: dict(zip(sorted(PHASES), counts)) for variant, counts in {
    'local': [8, 600, 608, 0, 600, 1, 17, 42],
    'attached': [2, 600, 602, 0, 600, 1, 22, 47],
}.items()}
REPORTER_SHA = 'aeb1d5994149d28badc6ddfa01d51c60ebed4ffb941f85d885d2d06c8669714f'

def need(ok, message):
    if not ok:
        raise ValueError(message)

def verify(sidecar, sample, *, enabled, calibration):
    need(sidecar['schema'] == 'lattice.live-scalar-profile/1', 'profile schema')
    for key, expected in [('instrumented', True), ('performanceTargetClaimed', False),
                          ('swiftConversionMeasured', False), ('bridgeSQLConstructionMeasured', False),
                          ('nativeCountersEnabled', enabled), ('calibration', calibration)]:
        need(sidecar[key] is expected, key)
    for key in ('variant', 'iteration', 'warmup'):
        need(sidecar[key] == sample[key], 'sample identity: ' + key)
    need(sidecar['variant'] in ('local', 'attached') and type(sidecar['iteration']) is int, 'sample identity types')
    need(type(sidecar['warmup']) is bool, 'warmup type')
    for key, expected in CHECKSUMS.items():
        need(sidecar[key] == sample[key] == expected, 'checksum: ' + key)
    need(sample['readRows'] == 100 and sample['updatedRows'] == 11, 'row counts')
    need(sample['coldOffsetFills'] == 1 and sample['coldKeysetFills'] == 0, 'cold fill')
    need(sample['coldAnchors'] in ((1,) if sample['variant'] == 'local' else (0, 1)), 'cold anchor')
    for key in ('OffsetFills', 'KeysetFills', 'Anchors'):
        need(sample['warm' + key] == sample['cold' + key], 'warm fill')
    need(set(sidecar['phases']) == set(sample['phases']) == PHASES, 'phase inventory')
    for name, row in sidecar['phases'].items():
        need(set(row) == set(NUMERIC), 'phase fields')
        need(all(type(row[key]) is int and 0 <= row[key] <= 2**64-1 for key in NUMERIC), 'numeric values')
        need(row['sqlStatements'] == SQL[sample['variant']][name], 'measured B SQL inventory changed')
        need(row['wallNS'] == sample['phases'][name]['elapsedNS'] and
             row['sqlStatements'] == sample['phases'][name]['sqlStatements'], 'phase join')
        need(sum(row[key] for key in SPANS) <= row['wallNS'], 'exclusive duration bound')
        if not enabled:
            need(all(row[key] == 0 for key in (*COUNTS, *SPANS)), 'disabled counters')
        if name in ('read.live_scalars', 'read.warm_live_scalars'):
            need(row['sqlStatements'] == 600, 'live scalar SQL')
            if enabled:
                need([row[key] for key in COUNTS] == [600, 600, 600, 1200, 600, 600, 600], 'native route counts')
        if name == 'read.warm_hit':
            need(row['sqlStatements'] == 0, 'warm SQL')
    for total, parts in [('read.total', ('read.cold_page_identity_anchor', 'read.live_scalars')),
                         ('update.total', ('update.discovery_hydration_routing', 'update.set_and_atomic_increment'))]:
        for key in ('wallNS', 'sqlStatements', *COUNTS, *SPANS):
            need(sidecar['phases'][total][key] >= sum(sidecar['phases'][p][key] for p in parts), 'nested accounting')
    return sidecar

def read(path):
    need(path.is_file() and not path.is_symlink() and path.stat().st_size <= 65_536, 'bounded regular sidecar/sample')
    return json.loads(path.read_text())

def analyze(root, reporter):
    need(hashlib.sha256(reporter.read_bytes()).hexdigest() == REPORTER_SHA, 'frozen reporter changed')
    spec = importlib.util.spec_from_file_location('frozen_profile_reporter', reporter)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    frozen = module.load_run(root / 'result.json')
    raw = json.loads((root / 'result.json').read_text())
    need(raw['manifest']['measuredSamples'] == 100 and raw['manifest']['warmupSamples'] == 5, 'exact sample policy')
    need(raw['manifest']['writeImplementation'] == module.SELECTED_BATCH_WRITES, 'selected write route')
    rows = []
    expected_paths = set()
    for sample in raw['samples']:
        path = root / sample['variant'] / ('profile-%04d.json' % sample['iteration'])
        expected_paths.add(path)
        need(read(path.with_name('sample-%04d.json' % sample['iteration'])) == sample, 'canonical sample file join')
        rows.append(verify(read(path), sample, enabled=True, calibration=False))
    need(set(root.glob('*/profile-*.json')) == expected_paths, 'missing/extra sidecar')
    calibration_summary = {}
    calibration_paths = set()
    for variant in ('local', 'attached'):
        calibration = []
        for index, enabled in enumerate(CALIBRATION):
            directory = root / variant / 'profile-calibration'
            path = directory / ('profile-%04d.json' % index)
            calibration_paths.add(path)
            sample = read(directory / ('sample-%04d.json' % index))
            need(sample['variant'] == variant and sample['iteration'] == index and sample['warmup'] is False, 'calibration order')
            calibration.append(verify(read(path), sample, enabled=enabled, calibration=True))
        calibration_summary[variant] = {}
        for phase in sorted(PHASES):
            values = {mode: [row['phases'][phase]['wallNS'] for row in calibration if row['nativeCountersEnabled'] is mode]
                      for mode in (False, True)}
            off, on = statistics.median(values[False]), statistics.median(values[True])
            calibration_summary[variant][phase] = dict(offWallNS=values[False], onWallNS=values[True],
                medianOffNS=off, medianOnNS=on, medianOnOverOff=on/off if off else None)
    need(set(root.glob('*/profile-calibration/profile-*.json')) == calibration_paths, 'calibration inventory')
    # Join each tail sample's own CPU/native spans. Do not add component p95s.
    tails = {}
    for variant in ('local', 'attached'):
        measured = [row for row in rows if row['variant'] == variant and not row['warmup']]
        tails[variant] = {}
        for phase in ('read.total', 'read.live_scalars', 'update.total'):
            ordered = sorted(measured, key=lambda row: (row['phases'][phase]['wallNS'], row['iteration']))
            tails[variant][phase] = [dict(iteration=row['iteration'], **row['phases'][phase]) for row in ordered[-6:]]
    return dict(schemaVersion=1, scope='diagnostic B only; instrumented, no performance acceptance',
                performanceTargetClaimed=False, physicalHostQualified=False, hostCausationClaimed=False,
                swiftConversionMeasured=False, canonicalSampleCount=len(rows), calibrationSampleCount=16,
                frozenResult=frozen, tailSamples=tails, calibration=calibration_summary,
                limits=['phase CPU brackets wall boundaries', 'native counters cover query_managed_cell only',
                        'counter-off retains diagnostic branches and phase clocks; this is not stock-build overhead',
                        'four samples per mode/variant describe local overhead variation; no significance claim',
                        'unattributed time includes routing/bridge/Swift/clock/bookkeeping; not conversion attribution'])

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--frozen-reporter', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(analyze(args.run.resolve(strict=True), args.frozen_reporter.resolve(strict=True)), indent=2, sort_keys=True))
