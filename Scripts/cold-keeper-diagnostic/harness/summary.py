"""Strict bounded probe parsing and descriptive phase/perturbation accounting."""
import json, statistics

REQUIRED = [1, 2, 3, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]
PAIRS = {'acquisition': (1,16), 'eligibilityEviction': (1,2), 'poolSelection': (2,3),
         'constructor': (6,7), 'cacheClamp': (8,9), 'begin': (10,11), 'pin': (12,13),
         'publication': (14,15), 'page': (17,21), 'pageAdmission': (17,18),
         'actualPageQuery': (19,20), 'pageTail': (20,21)}
def parse(text, arm):
    assert arm in ['off','on'] and len(text.encode()) <= 65536
    rows = [json.loads(line) for line in text.splitlines() if line.strip()]
    assert len(rows) == 3 and set(rows[0]) == {'sqliteVersion','sqliteSourceId'}
    assert all(isinstance(v,str) and v for v in rows[0].values())
    out = {'runtime': rows[0], 'samples': []}
    for row, label in zip(rows[1:], ['cold','warm']):
        assert row['sample'] == label and row['cppScopeOnly'] is True and row['rows'] == 100
        assert type(row['sql']) is int and row['sql'] == (8 if label == 'cold' else 3)
        assert type(row['totalNs']) is int and row['totalNs'] > 0
        assert row['instrumented'] is (arm == 'on')
        expected_keys = {'sample','cppScopeOnly','rows','sql','totalNs','instrumented'}
        if arm == 'on': expected_keys.add('records')
        assert set(row) == expected_keys
        item = dict(row)
        if arm == 'on':
            records = row['records']; tags = REQUIRED.copy()
            if label == 'cold': tags[3:3] = [6,7,8,9]
            assert len(records) == len(tags) <= 24 and [r['tag'] for r in records] == tags
            prior = -1; by_tag = {}
            for record in records:
                assert set(record) == {'tag','offsetNs','fact'}
                assert type(record['offsetNs']) is int and record['offsetNs'] >= prior
                assert type(record['fact']) is int and record['fact'] >= 0
                prior = record['offsetNs']; by_tag[record['tag']] = record
            assert records[0]['offsetNs'] == 0
            assert by_tag[3]['fact'] == (0 if label == 'cold' else 1)
            assert by_tag[16]['fact'] == 1 and by_tag[21]['fact'] == 1
            assert all(r['fact'] == 0 for r in records if r['tag'] not in [3,16,21])
            intervals = {name: by_tag[end]['offsetNs']-by_tag[begin]['offsetNs']
                         for name,(begin,end) in PAIRS.items() if begin in by_tag and end in by_tag}
            residual = row['totalNs']-intervals['acquisition']-intervals['page']
            assert residual >= 0 and prior <= row['totalNs']
            item.update(intervalNs=intervals, outerResidualNs=residual,
                        acquisitionUnattributedNs=intervals['acquisition']-sum(intervals.get(k,0) for k in
                            ['eligibilityEviction','poolSelection','constructor','cacheClamp','begin','pin','publication']))
            assert item['acquisitionUnattributedNs'] >= 0
        out['samples'].append(item)
    return out
def summarize(samples):
    assert len(samples) == 6 and [x['arm'] for x in samples] == ['off','on']*3
    runtime = samples[0]['data']['runtime']; assert all(x['data']['runtime'] == runtime for x in samples)
    branches = {}
    for index,label in enumerate(['cold','warm']):
        selected = [x['data']['samples'][index] for x in samples]
        assert len({x['sql'] for x in selected}) == 1, 'ON/OFF SQL workload differs'
        off = [x['totalNs'] for x in selected[::2]]; on = [x['totalNs'] for x in selected[1::2]]
        branches[label] = {'sql': selected[0]['sql'], 'offNs': off, 'onNs': on,
            'pairedOnOverOff': [b/a for a,b in zip(off,on)],
            'offMinMedianMaxNs': [min(off),statistics.median(off),max(off)],
            'onMinMedianMaxNs': [min(on),statistics.median(on),max(on)],
            'phaseRecords': [x for x in selected if x['instrumented']]}
    return {'cppPhaseAttributionOnly': True, 'sampleProcesses': 6, 'runtime': runtime,
        'branches': branches, 'allRawSamples': samples, 'discardedOutliers': 0,
        'claims': 'Descriptive phase costs and timing perturbation only; three pairs do not establish a stable p95 or frozen Swift speedup.',
        'coldDefinition': 'First keeper on freshly opened owner; normal seeding and OS cache warmth retained.',
        'ambientLoad': 'Shared hosted runner; no isolated-host or thermal-control claim.'}
