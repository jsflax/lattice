#!/usr/bin/env python3
"""Strict source/build-input proof plus descriptive, same-source sample summary."""
import argparse, json, math, shlex
from pathlib import Path
from prepare import SHA, TREE, SOURCE_MODE, PACKET, digest, verify_harness

def save(path, value):
    with path.open('x') as stream:
        json.dump(value,stream,indent=2,sort_keys=True); stream.write('\n')

def verify_source():
    manifest=json.loads((PACKET/'PREPARED.json').read_text())
    assert manifest['source']==SHA and manifest['tree']==TREE
    root=PACKET/'source'
    actual={str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() or p.is_symlink()}
    assert actual==set(manifest['sourceFiles']), 'source inventory changed'
    assert not any(p.is_symlink() for p in root.rglob('*')), 'source symlink introduced'
    for name, value in manifest['sourceFiles'].items():
        path=PACKET/'source'/name
        assert path.stat().st_size==value['bytes'] and digest(path)==value['sha256'],name
    return manifest

def build():
    verify_harness()
    verify_source()
    directory=PACKET/'build'; core=PACKET/'source'
    commands=json.loads((directory/'compile_commands.json').read_text())
    measured=[]; objects=[]
    # Source may contain extra non-CMake platform helpers. Exact required target
    # units come from the frozen CMake list, not an invented glob expectation.
    cmake=(core/'CMakeLists.txt').read_text()
    block=cmake.split('add_library(LatticeCore STATIC',1)[1].split(')',1)[0]
    expected={str((core/line.strip()).resolve()) for line in block.splitlines() if line.strip()}
    expected.add(str((core/'Sources/SqliteVec/src/sqlite-vec.c').resolve()))
    expected.add(str((PACKET/'harness/probe.cpp').resolve()))
    for entry in commands:
        source=str((Path(entry['directory'])/entry['file']).resolve())
        if source not in expected: continue
        words=entry.get('arguments') or shlex.split(entry['command'])
        assert '-O3' in words and '-g0' in words and '-DNDEBUG' in words,source
        assert all(not x.startswith('-O') or x=='-O3' for x in words),source
        assert '-flto' not in words, 'no unreviewed LTO mode'
        assert '-o' in words and '-c' in words
        obj=(Path(entry['directory'])/words[words.index('-o')+1]).resolve()
        assert obj.is_relative_to(directory) and obj.is_file(),obj
        assert source not in measured,'duplicate measured TU'
        measured.append(source); objects.append({'source':source,'object':str(obj),
                                                'objectSHA256':digest(obj),'argv':words})
    assert set(measured)==expected,'missing uniformly optimized target unit'
    link=shlex.split((directory/'CMakeFiles/RetentionForegroundProbe.dir/link.txt').read_text())
    archives={(directory/x).resolve() for x in link if x.endswith('.a')}
    required={directory/'core/libLatticeCore.a',directory/'core/libSqliteVec.a'}
    assert archives==required,'unexpected prebuilt or missing Core archive'
    direct_objects={(directory/x).resolve() for x in link if x.endswith('.o')}
    assert direct_objects=={directory/'CMakeFiles/RetentionForegroundProbe.dir/probe.cpp.o'}
    linkmap=directory/'probe.map'; assert linkmap.is_file() and linkmap.stat().st_size>0
    assert 'libLatticeCore.a' in linkmap.read_text(), 'Core archive absent from map'
    binary=directory/'RetentionForegroundProbe'; assert binary.is_file()
    save(PACKET/'BUILD-PROOF.json',{'source':SHA,'tree':TREE,'uniformO3':True,
        'objects':objects,'linkArgv':link,'archives':{str(p):digest(p) for p in sorted(archives)},
        'binarySHA256':digest(binary),'mapSHA256':digest(linkmap),
        'platformSQLite':'intentional dynamic/runtime dependency; each native identity records actual image/sourceid/options'})

def percentile(values, fraction):
    values=sorted(values); assert values
    return values[max(0,math.ceil(len(values)*fraction)-1)]

def drain_summary(data):
    """Validate the versioned protocol independently of the process driver."""
    assert data['protocolVersion'] == 2 and data['sourceMode'] in {'baseline','bounded'}
    assert data['arm'] in {'A1','A2','B'}
    events = data['events']
    def one(kind):
        values = [x for x in events if x['kind'] == kind]
        assert len(values) == 1, kind
        return values[0]
    writes = [x for x in events if x['kind'] == 'write']
    assert len(writes) == 1000 and [x['index'] for x in writes] == list(range(1000))
    assert all(x['endNS'] >= x['startNS'] for x in writes)
    tick, first, done = one('tickDone'), one('firstTickResidual'), one('drainDone')
    assert tick['instrumented'] is False
    continuations = [x for x in events if x['kind'] == 'continuationTick']
    expected = ([7952,5904,3856,1808,0]
                if data['arm'] == 'B' and data['sourceMode'] == 'bounded'
                else [0 if data['arm'] == 'B' else 10000])
    residuals = [first] + continuations
    assert [x['oldRows'] for x in residuals] == expected
    assert [x['firstOldID'] for x in residuals] == [0 if n == 0 else 10001-n for n in expected]
    assert [x['call'] for x in continuations] == list(range(2,len(expected)+1))
    assert done['calls'] == len(expected) and done['oldRows'] == expected[-1]
    assert done['automaticSchedulerMeasured'] is False and done['firstEntryNS'] == tick['startNS']
    # Parent acknowledgements and child observations are independently retained.
    assert events.index(one('writerDone')) < events.index(one('writerReapedBeforeDrain')) < events.index(first)
    assert max(x['endNS'] for x in writes) <= first['observedNS']
    assert tick['startNS'] <= tick['endNS'] <= first['observedNS'] <= done['continuationStartNS'] <= done['endNS']
    previous = done['continuationStartNS']
    for x in continuations:
        assert previous <= x['startNS'] <= x['endNS'] <= x['observedNS'] <= done['endNS']
        previous = x['observedNS']
    overlaps = [x for x in writes if x['startNS'] < tick['endNS'] and x['endNS'] > tick['startNS']]
    if data['arm'] == 'B': assert overlaps, 'no first-tick foreground overlap'
    durations = [x['endNS']-x['startNS'] for x in writes]
    continuation_times = [x['endNS']-x['startNS'] for x in continuations]
    windows = {}
    # Use only the supervisor's clock for its file samples. C++ steady_clock
    # has no portable epoch identity with Python's monotonic clock. These are
    # observed envelopes including pipe/receipt latency, not native brackets.
    writer_start = one('writerStartSignaled')['supervisorNS']
    writer_done = one('writerDone')['supervisorNS']
    drain_signal = one('writerReapedBeforeDrain')['supervisorNS']
    drain_done = done['supervisorNS']
    assert writer_start <= writer_done <= drain_signal <= drain_done
    for label, low, high in [('foregroundEnvelope',writer_start,writer_done),
                             ('continuationEnvelope',drain_signal,drain_done),
                             ('totalEnvelope',writer_start,drain_done)]:
        rows = [x for x in data['fileSizeSamples'] if low <= x['supervisorNS'] <= high]
        windows[label] = {}
        for suffix in ['main','-wal','-shm']:
            values = [x['bytes'][suffix] for x in rows if x['bytes'][suffix] is not None]
            windows[label][suffix] = {'samples':len(values),'maxBytes':max(values) if values else None,
                                      'firstBytes':values[0] if values else None,
                                      'lastBytes':values[-1] if values else None,
                                      'sampledPeakGrowthBytes':max(values)-values[0] if values else None}
    return {'firstTickNS':tick['endNS']-tick['startNS'],
            'firstTickOldRows':first['oldRows'],'continuationTickNS':continuation_times,
            'manualCalls':done['calls'],'sumPublicCallNS':tick['endNS']-tick['startNS']+sum(continuation_times),
            'firstEntryToFinalObservationNS':done['endNS']-tick['startNS'],
            'writerP99NS':percentile(durations,.99),
            'largestWrites':sorted(writes,key=lambda x:x['endNS']-x['startNS'],reverse=True)[:10],
            'residualOldRows':expected,'fileWindows':windows,
            'fileWindowClock':'supervisor monotonic; envelopes include signal/pipe/receipt overhead',
            'automaticSchedulerMeasured':False}

def summarize():
    verify_harness()
    verify_source()
    schedule=json.loads((PACKET/'RUN-SCHEDULE.json').read_text())
    summaries=[]
    for row in schedule:
        receipt=PACKET/'receipts'/(row['label']+'-sample.json')
        data=json.loads(receipt.read_text()); assert data['success'] and not data['error']
        guard=json.loads((PACKET/'receipts'/(row['label']+'.json')).read_text())
        assert guard['success'] and guard['cleanup']['groupGone'] and guard['cleanup']['leaderReaped']
        assert all(x['reaped'] and x['exitCode']==0 for x in data['cleanup'].values())
        events=data['events']; item={**row,'receiptSHA256':digest(receipt)}
        assert data['sourceMode'] == SOURCE_MODE
        item.update(drain_summary(data))
        samples=[x['bytes']['-wal'] for x in data['fileSizeSamples'] if x['bytes']['-wal'] is not None]
        item['sampledWALMaxBytes']=max(samples) if samples else None
        work_samples=[x['bytes']['-wal'] for x in data['fileSizeSamples']
                      if x['phase']=='work' and x['bytes']['-wal'] is not None]
        item['workPhaseSampledWALMaxBytes']=max(work_samples) if work_samples else None
        if row['mode']!='claim':
            writes=[x['endNS']-x['startNS'] for x in events if x['kind']=='write']; assert len(writes)==1000
            tick=[x for x in events if x['kind']=='tickDone']; assert len(tick)==1
            item.update(writerP50NS=percentile(writes,.50),writerP95NS=percentile(writes,.95),
                        writerMaxNS=max(writes),tickNS=tick[0]['endNS']-tick[0]['startNS'])
            overlap=[x['endNS']-x['startNS'] for x in events if x['kind']=='write' and
                     x['startNS']<tick[0]['endNS'] and x['endNS']>tick[0]['startNS']]
            item['tickOverlappingWriteDurationsNS']=overlap
            item['logicalCloseNS']={x['role']:x['logicalCloseNS'] for x in events if 'logicalCloseNS' in x}
        summaries.append(item)
    pairs=[]
    for triplet in range(5):
        arms={x['arm']:x for x in summaries if x.get('triplet')==triplet and not x.get('warmup') and x['mode']=='paired'}
        assert set(arms)=={'A1','A2','B'}
        pairs.append({'triplet':triplet,'writerP95AASpreadNS':abs(arms['A1']['writerP95NS']-arms['A2']['writerP95NS']),
                      'writerP95BMinusAMeanNS':arms['B']['writerP95NS']-(arms['A1']['writerP95NS']+arms['A2']['writerP95NS'])/2,
                      'writerMaxAASpreadNS':abs(arms['A1']['writerMaxNS']-arms['A2']['writerMaxNS']),
                      'writerMaxBMinusAMeanNS':arms['B']['writerMaxNS']-(arms['A1']['writerMaxNS']+arms['A2']['writerMaxNS'])/2,
                      'tickBMinusAMeanNS':arms['B']['tickNS']-(arms['A1']['tickNS']+arms['A2']['tickNS'])/2})
    prerequisites={}
    for label in ['seed-001','correctness-001']:
        record=json.loads((PACKET/'receipts'/(label+'.json')).read_text())
        assert record['success'] and record['cleanup']['groupGone'] and record['cleanup']['leaderReaped']
        prerequisites[label]={'guardSHA256':digest(PACKET/'receipts'/(label+'.json')),
                              'logSHA256':digest(PACKET/'receipts'/(label+'.log'))}
    save(PACKET/'ANALYSIS.json',{'status':'sample analysis; final summary process cleanup not yet attested',
        'prerequisites':prerequisites,'buildProofSHA256':digest(PACKET/'BUILD-PROOF.json'),
        'harnessSHA256':digest(PACKET/'HARNESS-SOURCE.json'),
        'source':SHA,'tree':TREE,'sourceMode':SOURCE_MODE,'protocolVersion':2,
        'runs':summaries,'pairedEffects':pairs,'numericSLO':None,
        'caveats':['Same source, recent/expired claim contrast; no code-speedup inference.',
                   '5ms sampled main/WAL/SHM maxima are lower bounds; absent samples remain null, not zero.',
                   'Manual continuation calls do not measure the production 100ms scheduler.',
                   'First-entry to convergence includes the deliberate wait for foreground completion.',
                   'Logical close timing is not destructor or maintenance-thread join timing.',
                   'Floor-registration race, final memory invalidation, shutdown join, traced transaction duration and streaming amplification remain separate qualification gates.']})

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('stage',choices=['build','summarize'])
    args=parser.parse_args(); build() if args.stage=='build' else summarize()
