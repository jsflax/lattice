#!/usr/bin/env python3
"""Explicit reviewed stages only. Authoring this driver is not run authorization."""
import argparse, json, os, shutil, sys
from pathlib import Path
from guarded_runner import Interrupts
from hosted_guard import AggregateRunner as GuardedRunner, Stage
from prepare import PACKET, SHA, TREE, SOURCE_MODE, digest, verify_harness
from supervise import bundle
from validate import verify_source, save

HERE=Path(__file__).resolve().parent
FREE=int(12.5*2**30); CAP=512*2**20; LOG=32*2**20

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('stage',choices=['prepare','build','run'])
    parser.add_argument('--core-source')
    parser.add_argument('--c-compiler'); parser.add_argument('--cxx-compiler')
    parser.add_argument('--sqlite-include'); parser.add_argument('--sqlite-library')
    parser.add_argument('--sdk')
    args=parser.parse_args()
    with Stage(PACKET.name+'-'+args.stage):
        run_stage(args)

def run_stage(args):
    verify_harness()
    assert '/localdev/' in str(PACKET)
    receipts=PACKET/'receipts'; receipts.mkdir(exist_ok=True)
    env=os.environ.copy()
    for key,name in [('TMPDIR','tmp'),('CLANG_MODULE_CACHE_PATH','module-cache'),
                     ('CMAKE_USER_HOME','cmake-home'),('XDG_CACHE_HOME','xdg-cache')]:
        path=PACKET/name; path.mkdir(exist_ok=True); env[key]=str(path)
    env['PYTHONDONTWRITEBYTECODE']='1'
    env['CMAKE_BUILD_PARALLEL_LEVEL']='1'
    # A fresh stage receipt is mandatory. There are no automatic retries or
    # fallback build paths; changed attempts need separately reviewed labels.
    with Interrupts() as interrupts:
        runner=GuardedRunner(PACKET,receipts,env,interrupts,free_floor=FREE,
            packet_ceiling=CAP,log_ceiling=LOG,overall_seconds=3600 if args.stage=='run' else 1500,reserve=30)
        if args.stage=='prepare':
            assert args.core_source
            runner.run('prepare-001',[sys.executable,str(HERE/'prepare.py'),'--core-source',args.core_source],cwd=PACKET,timeout=120)
            return
        verify_source()
        if args.stage=='build':
            assert args.c_compiler and args.cxx_compiler and args.sqlite_include and args.sqlite_library
            for value in [args.c_compiler,args.cxx_compiler,args.sqlite_library]: assert Path(value).is_file()
            assert Path(args.sqlite_include).is_dir()
            assert not (PACKET/'build').exists(), 'fresh build required'
            runner.run('c-version-001',[args.c_compiler,'--version'],cwd=PACKET,timeout=15)
            runner.run('cxx-version-001',[args.cxx_compiler,'--version'],cwd=PACKET,timeout=15)
            runner.run('cmake-version-001',['cmake','--version'],cwd=PACKET,timeout=15)
            command=['cmake','-S',str(HERE),'-B',str(PACKET/'build'),'-G','Unix Makefiles',
                '-DCMAKE_BUILD_TYPE=Release','-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -g0',
                '-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -g0','-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',
                '-DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON','-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF',
                '-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF',
                '-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF', '-DCMAKE_C_COMPILER='+args.c_compiler,
                '-DCMAKE_CXX_COMPILER='+args.cxx_compiler,'-DSQLite3_INCLUDE_DIR='+args.sqlite_include,
                '-DSQLite3_LIBRARY='+args.sqlite_library]
            if args.sdk: command.append('-DCMAKE_OSX_SYSROOT='+args.sdk)
            runner.run('configure-001',command,cwd=PACKET,timeout=120)
            runner.run('compile-001',['cmake','--build',str(PACKET/'build'),'--target','RetentionForegroundProbe','--parallel','1'],cwd=PACKET,timeout=1200)
            runner.run('build-proof-001',[sys.executable,str(HERE/'validate.py'),'build'],cwd=PACKET,timeout=30)
            return
        proof=json.loads((PACKET/'BUILD-PROOF.json').read_text())
        probe=PACKET/'build/RetentionForegroundProbe'
        assert proof['source']==SHA and proof['tree']==TREE and proof['uniformO3']
        assert digest(probe)==proof['binarySHA256']
        for label in ['prepare-001','configure-001','compile-001','build-proof-001']:
            record=json.loads((receipts/(label+'.json')).read_text())
            assert record['success'] and record['cleanup']['groupGone'] and record['cleanup']['leaderReaped']
        fixture=PACKET/'fixtures'; fixture.mkdir(exist_ok=False)
        master=fixture/'master.sqlite'
        runner.run('seed-001',[str(probe),'seed',str(master)],cwd=fixture,timeout=120)
        master_files=bundle(master)
        assert master_files['main'] and (not master_files['-wal'] or master_files['-wal']['bytes']==0)
        save(PACKET/'MASTER.json',master_files)
        correctness=fixture/'correctness'; correctness.mkdir()
        runner.run('correctness-001',[str(probe),'correctness',str(correctness/'source.sqlite'),str(correctness/'recipient.sqlite')],cwd=fixture,timeout=120)
        assert any(json.loads(line).get('kind')=='correctness' for line in (receipts/'correctness-001.log').read_text().splitlines())
        save(PACKET/'CORRECTNESS-FILES.json',{p.name:{'bytes':p.stat().st_size,'sha256':digest(p)} for p in correctness.iterdir()})
        shutil.rmtree(correctness)  # Only after successful guarded child cleanup.
        schedule=[]  # Old in-SQL claim barrier is deliberately excluded; native correctness is separate.
        for triplet in range(-1,5):
            order=['A1','A2','B'] if triplet%2==0 or triplet==-1 else ['B','A2','A1']
            for arm in order:
                schedule.append({'label':('warmup' if triplet==-1 else 'measured-'+str(triplet))+'-'+arm,
                                 'mode':'paired','arm':arm,'triplet':triplet,'warmup':triplet==-1})
        for arm in ['A1','B']: schedule.append({'label':'held-reader-'+arm,'mode':'held-reader','arm':arm})
        save(PACKET/'RUN-SCHEDULE.json',schedule)
        for item in schedule:
            label=item['label']; sample=fixture/label; receipt=receipts/(label+'-sample.json')
            assert bundle(master)==master_files
            runner.run(label,[sys.executable,str(HERE/'supervise.py'),'--probe',str(probe),
                '--master',str(master),'--sample',str(sample),'--receipt',str(receipt),
                '--mode',item['mode'],'--arm',item['arm'],'--source-mode',SOURCE_MODE],cwd=fixture,timeout=120)
            data=json.loads(receipt.read_text())
            assert data['success'] and not data['error'] and not data['cleanupErrors']
            assert all(x['reaped'] and x['exitCode']==0 for x in data['cleanup'].values())
            assert bundle(master)==master_files and data['masterFiles']==master_files
            for name, facts in data['closedSampleFiles'].items():
                assert (sample/name).stat().st_size==facts['bytes'] and digest(sample/name)==facts['sha256']
            shutil.rmtree(sample)  # Whole owned supervisor group already gone.
        assert digest(probe)==proof['binarySHA256'] and bundle(master)==master_files
        verify_harness()
        verify_source()
        runner.run('summary-001',[sys.executable,str(HERE/'validate.py'),'summarize'],cwd=PACKET,timeout=30)
        summary_guard=json.loads((receipts/'summary-001.json').read_text())
        assert summary_guard['success'] and summary_guard['cleanup']['groupGone'] and summary_guard['cleanup']['leaderReaped']
        save(PACKET/'RESULT.json',{'status':'versioned first-tick plus manual drain characterization collected','protocolVersion':2,'sourceMode':SOURCE_MODE,
            'source':SHA,'tree':TREE,'analysisSHA256':digest(PACKET/'ANALYSIS.json'),
            'summaryGuardSHA256':digest(receipts/'summary-001.json'),'buildProofSHA256':digest(PACKET/'BUILD-PROOF.json'),
            'masterFilesUnchanged':bundle(master)==master_files,'numericSLO':None,
            'productPerformanceAcceptance':'requires parent assessment of B effect against A/A noise; not inferred by this driver'})

if __name__=='__main__': main()
