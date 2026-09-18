#!/usr/bin/env python3
"""Strict source/build-input proof plus descriptive, same-source sample summary."""
import argparse, json, math, shlex
from pathlib import Path
from prepare import SHA, TREE, PACKET, digest, verify_harness

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
    expected.add(str((PACKET/'harness/floor-race/probe.cpp').resolve()))
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
    binaries={}; shared_archives=None
    for target, unit, mapname in [
        ('RetentionForegroundProbe','probe.cpp','probe.map'),
        ('RetentionFloorRaceProbe','floor-race/probe.cpp','floor-race.map')]:
        link=shlex.split((directory/('CMakeFiles/'+target+'.dir/link.txt')).read_text())
        archives={(directory/x).resolve() for x in link if x.endswith('.a')}
        required={directory/'core/libLatticeCore.a',directory/'core/libSqliteVec.a'}
        assert archives==required,'unexpected prebuilt or missing Core archive'
        direct_objects={(directory/x).resolve() for x in link if x.endswith('.o')}
        assert direct_objects=={directory/('CMakeFiles/'+target+'.dir/'+unit+'.o')}
        linkmap=directory/mapname; assert linkmap.is_file() and linkmap.stat().st_size>0
        assert 'libLatticeCore.a' in linkmap.read_text(), 'Core archive absent from map'
        binary=directory/target; assert binary.is_file()
        archive_hashes={str(p):digest(p) for p in sorted(archives)}
        assert shared_archives is None or shared_archives==archive_hashes
        shared_archives=archive_hashes
        binaries[target]={'path':str(binary),'sha256':digest(binary),'linkArgv':link,
                          'mapPath':str(linkmap),'mapSHA256':digest(linkmap)}
    foreground=binaries['RetentionForegroundProbe']
    save(PACKET/'BUILD-PROOF.json',{'source':SHA,'tree':TREE,'uniformO3':True,
        'objects':objects,'linkArgv':foreground['linkArgv'],'archives':shared_archives,
        'binarySHA256':foreground['sha256'],'mapSHA256':foreground['mapSHA256'],
        'binaries':binaries,
        'platformSQLite':'intentional dynamic/runtime dependency; each native identity records actual image/sourceid/options'})

def verify_build():
    proof=json.loads((PACKET/'BUILD-PROOF.json').read_text())
    assert proof['source']==SHA and proof['tree']==TREE and proof['uniformO3']
    for name in ['RetentionForegroundProbe','RetentionFloorRaceProbe']:
        facts=proof['binaries'][name]
        assert Path(facts['path'])==PACKET/'build'/name
        assert digest(Path(facts['path']))==facts['sha256']
        assert digest(Path(facts['mapPath']))==facts['mapSHA256']
    for path, expected in proof['archives'].items(): assert digest(Path(path))==expected
    for facts in proof['objects']: assert digest(Path(facts['object']))==facts['objectSHA256']
    return proof

def percentile(values, fraction):
    values=sorted(values); assert values
    return values[max(0,math.ceil(len(values)*fraction)-1)]

def summarize():
    from phase_summary import analyze
    verify_harness()
    verify_source()
    schedule=json.loads((PACKET/'RUN-SCHEDULE.json').read_text())
    assert schedule==[{'label':'phases-B-001','mode':'paired','arm':'B','instrumented':True}]
    receipt=PACKET/'receipts/phases-B-001-sample.json'
    sample=json.loads(receipt.read_text())
    assert not sample['error'] and not sample['cleanupErrors']
    assert all(x['reaped'] and x['exitCode']==0 for x in sample['cleanup'].values())
    for label in ['seed-001','phases-B-001']:
        guard=json.loads((PACKET/'receipts'/(label+'.json')).read_text())
        assert guard['success'] and guard['cleanup']['groupGone'] and guard['cleanup']['leaderReaped']
    analysis=analyze(sample)
    analysis.update(source=SHA,tree=TREE,buildProofSHA256=digest(PACKET/'BUILD-PROOF.json'),
        harnessSHA256=digest(PACKET/'HARNESS-SOURCE.json'),sampleSHA256=digest(receipt),
        uninstrumentedTimingRun=35365051287,numericSLO=None)
    save(PACKET/'ANALYSIS.json',analysis)
    assert analysis['phaseQualified'], 'bounded trace incomplete or SQL unclassified; preserved analysis cannot attribute unknown intervals'

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('stage',choices=['build','summarize'])
    args=parser.parse_args(); build() if args.stage=='build' else summarize()
