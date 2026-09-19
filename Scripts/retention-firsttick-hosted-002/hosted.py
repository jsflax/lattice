#!/usr/bin/env python3
"""Bootstrap/fetch/finalize only; native stages invoke harness/run.py directly."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys

P = Path(__file__).resolve().parent
sys.path.insert(0,str(P/'harness'))
import hosted_guard as guard
from guarded_runner import Interrupts

def facts(path): return {'bytes':path.stat().st_size,'sha256':guard.digest(path)}

def initialize():
    root,binding = guard.context()
    guard.require(P == root/'packet','exact installed packet required')
    guard.require({p.name for p in root.iterdir()} == {'packet','tools','tmp','BOOTSTRAP.json','ADMISSION.json'},
                  'fresh bootstrap root required')
    guard.require(not any((root/'tmp').iterdir()) and not (root/'tmp').is_symlink(),'fresh tmp required')
    require_preservation()
    for arm in ['baseline','bounded']:
        target = root/arm; target.mkdir()
        shutil.copytree(P/'harness',target/'harness')
        for name in ['SOURCE-CONFIG.json','SOURCE-MANIFEST.json']:
            shutil.copy2(P/'sources'/arm/name,target/name)
        source = guard.read(target/'SOURCE-CONFIG.json')
        harness = {str(p.relative_to(target/'harness')):facts(p)
                   for p in (target/'harness').rglob('*') if p.is_file()}
        guard.save(target/'HARNESS-SOURCE.json',dict(source,files=harness))
        guard.verify_arm(root,arm)
    (root/'objects').mkdir(); (root/'control').mkdir()
    sample = {'freeBytes':shutil.disk_usage(root).free,'aggregateBytes':guard.allocated(root),
              'armBytes':{a:guard.allocated(root/a) for a in ['baseline','bounded']}}
    guard.require(guard.limits(sample) is None,'initial resource refusal')
    guard.require(guard.time.monotonic() < binding['deadline']-guard.RESERVE,'bootstrap deadline')
    guard.save(root/'INITIALIZED.json',{'binding':binding,'resources':sample,'success':True})

def require_preservation():
    record = guard.read(P/'PRESERVATION.json')
    for name,fact in record['unchangedProtocolFiles'].items():
        guard.require(facts(P/'harness'/name) == fact,'reviewed protocol changed: '+name)
    guard.require(guard.digest(P/'evidence/PARENT-SOURCE-REVIEW.json') ==
                  guard.read(P/'CONFIG.json')['protocolParentReviewSHA256'],'parent protocol review changed')

def runner_for(stage, interrupts, seconds):
    root = stage.root; control = root/'control'
    receipts = control/stage.name; receipts.mkdir()
    env = os.environ.copy()
    for key,name in [('TMPDIR','tmp'),('TMP','tmp'),('TEMP','tmp'),('XDG_CACHE_HOME','cache')]:
        path=control/name;path.mkdir(exist_ok=True);env[key]=str(path)
    env['PYTHONDONTWRITEBYTECODE']='1'
    return guard.AggregateRunner(control,receipts,env,interrupts,free_floor=guard.FREE_BYTES,
        packet_ceiling=guard.PACKET_BYTES,log_ceiling=guard.LOG_BYTES,overall_seconds=seconds,reserve=30)

def toolchain():
    with guard.Stage('toolchain') as stage, Interrupts() as interrupts:
        runner = runner_for(stage,interrupts,300)
        runner.run('apt-update',['sudo','apt-get','update'],cwd=stage.root,timeout=120)
        runner.run('apt-install',['sudo','apt-get','install','-y','clang-18','cmake','make','libsqlite3-dev'],
                   cwd=stage.root,timeout=120)
        files = [Path('/usr/bin/clang-18'),Path('/usr/bin/clang++-18'),Path('/usr/include/sqlite3.h'),
                 Path('/usr/lib/x86_64-linux-gnu/libsqlite3.so')]
        guard.save(stage.root/'TOOLCHAIN-INPUTS.json',
                   {str(p):dict(facts(p),resolved=str(p.resolve(strict=True))) for p in files})

def fetch(arm):
    with guard.Stage(arm+'-fetch') as stage, Interrupts() as interrupts:
        runner = runner_for(stage,interrupts,150)
        source = guard.read(P/'sources'/arm/'SOURCE-CONFIG.json')
        repo = stage.root/'objects'/arm
        guard.require(not repo.exists(),'fresh object repository required')
        runner.run('init',['git','init',str(repo)],cwd=stage.root,timeout=15)
        runner.run('fetch',['git','fetch','--depth=1','https://github.com/jsflax/LatticeCore.git',source['source']],
                   cwd=repo,timeout=90)
        log = runner.run('identity',['git','show','-s','--format=%H %T',source['source']],cwd=repo,timeout=15)
        guard.require(log.read_text().strip() == source['source']+' '+source['tree'],'remote commit/tree mismatch')
        guard.save(stage.root/arm/'REMOTE-SOURCE.json',dict(source,identityLogSHA256=guard.digest(log)))

def finalize():
    with guard.Stage('finalize') as stage:
        results={}
        for arm in ['baseline','bounded']:
            packet=stage.root/arm; value=guard.read(packet/'RESULT.json')
            source=guard.read(packet/'SOURCE-CONFIG.json')
            guard.require(value['source']==source['source'] and value['tree']==source['tree'] and
                          value['sourceMode']==arm and value['protocolVersion']==2 and
                          value['masterFilesUnchanged'] is True,'source result identity')
            for name,key in [('ANALYSIS.json','analysisSHA256'),('BUILD-PROOF.json','buildProofSHA256'),
                             ('receipts/summary-001.json','summaryGuardSHA256')]:
                guard.require(guard.digest(packet/name)==value[key],'final result evidence drift')
            results[arm]={'resultSHA256':guard.digest(packet/'RESULT.json'),'analysisSHA256':value['analysisSHA256'],
                          'source':source['source'],'tree':source['tree']}
        # Collection is not performance acceptance; native records remain per arm.
        guard.save(stage.root/'COMPARISON-INPUTS.json',{'protocolVersion':2,'sources':results,
            'fixedSourceOrder':['baseline','bounded'],'performanceAccepted':False,
            'automaticWorkerPacingMeasured':False,'interpretation':'Parent assessment required; preserve A/A noise and source-order limits.'})

def main():
    parser=argparse.ArgumentParser();parser.add_argument('stage',choices=['init','toolchain','baseline-fetch','bounded-fetch','finalize'])
    stage=parser.parse_args().stage
    if stage=='init':initialize()
    elif stage=='toolchain':toolchain()
    elif stage=='finalize':finalize()
    else:fetch(stage.removesuffix('-fetch'))

if __name__=='__main__':main()
