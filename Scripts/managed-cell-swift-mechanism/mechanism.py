"""Finite Swift read100 sidecar joins; no native activity and no timing claims."""
import json
from pathlib import Path

PHASES = ('read.live_scalars', 'read.warm_live_scalars')
COUNTERS = ('thread_statements', 'hits', 'prepares', 'retired', 'reset_failures')
NUMBERS = COUNTERS + ('idle', 'retained_bytes', 'active', 'suspensions')
FLAGS = ('read_ok', 'pool_present', 'raw_escaped', 'closed', 'disabled')

def require(ok, message):
    if not ok:
        raise ValueError(message)

def phase_record(record, sample):
    name = record['phase']
    require(name in PHASES, 'unknown phase')
    require(type(record['actualRows']) is int and record['actualRows'] == sample['readRows'] == 100, 'row count')
    require(type(record['actualFieldsPerRow']) is int and record['actualFieldsPerRow'] == 6, 'field count')
    require(type(record['sqlStatements']) is int and record['sqlStatements'] == sample['phases'][name]['sqlStatements'] == 600, 'SQL count')
    for endpoint in ('before', 'after'):
        value = record[endpoint]
        require(set(value) == set(NUMBERS + FLAGS), 'snapshot inventory')
        require(all(type(value[x]) is int and 0 <= value[x] < 2**64 for x in NUMBERS), 'counter type/range')
        require(all(type(value[x]) is bool for x in FLAGS), 'flag type')
        require(value['read_ok'] and value['pool_present'], 'snapshot unavailable')
        require(not any(value[x] for x in ('raw_escaped', 'closed', 'disabled')), 'pool disabled or escaped')
        require(value['active'] == value['suspensions'] == 0, 'nonquiescent endpoint')
        require(value['idle'] <= 16 and value['retained_bytes'] <= 256 * 1024, 'pool bound')
    delta = {key: record['after'][key] - record['before'][key] for key in COUNTERS}
    require(all(value >= 0 for value in delta.values()), 'counter regression')
    require(delta['thread_statements'] == 600, 'thread execution join')
    require(delta['hits'] + delta['prepares'] == 600, 'aggregate admission join')
    require(delta['reset_failures'] == 0, 'reset failure')
    require(0 < delta['hits'] <= 600, 'no observed reuse')
    expected = 0 if name == PHASES[1] else (6 if sample['variant'] == 'local' else 12)
    return {'phase': name, 'delta': delta, 'expectedCleanPrepares': expected,
            'cleanSignature': delta['prepares'] == expected and delta['retired'] == 0,
            'before': record['before'], 'after': record['after']}

def validate(data, sidecars):
    require(data.get('complete') is True, 'original run incomplete')
    manifest = data['manifest']
    require(manifest['variants'] == ['local', 'attached'], 'variant inventory/order')
    require(manifest['measuredSamples'] == 100 and manifest['warmupSamples'] == 5, 'sample policy')
    samples = data['samples']
    require(len(samples) == len(sidecars) == 210, 'sidecar/sample count')
    expected = [(v, i) for v in ('local', 'attached') for i in range(105)]
    require([(s['variant'], s['iteration']) for s in samples] == expected, 'sample order/duplicate')
    require(set(sidecars) == set(expected), 'sidecar identities')
    joined = []
    for sample in samples:
        key = (sample['variant'], sample['iteration']); item = sidecars[key]
        require(item['schema'] == 'lattice.swift-managed-cell-mechanism/1', 'sidecar schema')
        require((item['variant'], item['iteration']) == key, 'sidecar identity')
        require(type(item['warmup']) is bool and item['warmup'] == sample['warmup'] == (key[1] < 5), 'warmup join')
        require(item['readChecksum'] == sample['readChecksum'], 'value checksum join')
        require([p['phase'] for p in item['phases']] == list(PHASES), 'phase inventory/order')
        joined.append({'variant': key[0], 'iteration': key[1], 'warmup': item['warmup'],
                       'readChecksum': item['readChecksum'],
                       'phases': [phase_record(p, sample) for p in item['phases']]})
    return {'schemaVersion': 1, 'observedMechanismAccepted': True, 'phaseCount': 420,
            'scalarExecutions': 252000, 'cleanExpectedSignatures': all(p['cleanSignature'] for s in joined for p in s['phases']),
            'perConnectionCounters': True, 'requiresExclusiveFixtureManagedCellProducer': True,
            'performanceTargetClaimed': False, 'releaseQualified': False, 'samples': joined}

def load(run):
    run = Path(run)
    files = list(run.glob('*/mechanism-*.json'))
    require(len(files) == 210 and all(p.is_file() and not p.is_symlink() for p in files), 'sidecar file inventory')
    require(sum(p.stat().st_size for p in files) <= 2**20 and all(p.stat().st_size <= 4096 for p in files), 'sidecar byte bound')
    sidecars = {}
    for path in files:
        require(path.parent.name in ('local', 'attached'), 'unknown variant directory')
        item = json.loads(path.read_text()); key = (item['variant'], item['iteration'])
        require(path == run / key[0] / ('mechanism-%04d.json' % key[1]) and key not in sidecars, 'sidecar path/duplicate')
        sidecars[key] = item
    return validate(json.loads((run / 'result.json').read_text()), sidecars)
