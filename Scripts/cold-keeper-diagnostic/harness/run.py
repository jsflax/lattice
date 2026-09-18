"""Existing GuardedRunner orchestration, with no new process supervisor."""
import argparse, json, os, platform, sys, time
from pathlib import Path
from guarded_runner import GuardedRunner, Interrupts, error_record
from prepare import P, SHA, TREE, digest, save, verify_inputs, verify_source, facts
from build import verify_build
from summary import parse, summarize
HERE = P/'harness'; FREE = int(12.5*2**30); CAP = 512*2**20
def clean(path):
    r = json.loads(path.read_text())
    assert r['success'] and r['started'] and r['exitCode'] == 0 and not r['evidenceErrors']
    assert not r['receivedSignals'] and not r['stopReason']
    assert r['cleanup']['groupGone'] and r['cleanup']['leaderReaped']
    assert not r['cleanup'].get('signals') and not r['cleanup'].get('errors')
    return r
def main():
    ap = argparse.ArgumentParser(); ap.add_argument('stage',choices=['prepare','configure','build-off','build-on','run'])
    ap.add_argument('--repo',type=Path); args = ap.parse_args()
    admission=json.loads((P/'SOURCE-READY.json').read_text())
    assert admission['executionAdmitted'] is True and admission['inputsSHA256']==digest(P/'INPUTS.json')
    root = Path(os.environ['TASK_ROOT']).resolve(strict=True)
    assert P == root/'packet' and '/localdev/' in str(root) and platform.system() == 'Darwin'
    receipts = P/'receipts'; receipts.mkdir(exist_ok=True); env = os.environ.copy()
    for key,name in [('TMPDIR','tmp'),('TMP','tmp'),('TEMP','tmp'),('CLANG_MODULE_CACHE_PATH','module-cache'),
                     ('CMAKE_USER_HOME','cmake-home'),('XDG_CACHE_HOME','xdg-cache')]:
        path = P/name; path.mkdir(exist_ok=True); env[key] = str(path)
    env.update(PYTHONDONTWRITEBYTECODE='1', CMAKE_BUILD_PARALLEL_LEVEL='1', LATTICE_LOG_LEVEL='0')
    overall = 1355 if args.stage.startswith('build-') else (335 if args.stage=='run' else 600)
    result = {'stage': args.stage, 'success': False, 'source': SHA, 'tree': TREE}
    with Interrupts() as interrupts:
        runner = GuardedRunner(root,receipts,env,interrupts,free_floor=FREE,packet_ceiling=CAP,
            log_ceiling=65536 if args.stage=='run' else 64*2**20,overall_seconds=overall,reserve=35)
        try:
            input_hash = verify_inputs(); manifest_hash = digest(P/'SOURCE-MANIFEST.json')
            if args.stage == 'prepare':
                assert args.repo
                runner.run('prepare-001',[sys.executable,str(HERE/'prepare.py'),'--repo',str(args.repo)],cwd=P,timeout=120,require_full_timeout=True)
            else:
                verify_source(); clean(receipts/'prepare-001.json')
                if args.stage == 'configure':
                    toolchain = {'platform':platform.platform(), 'architecture':platform.machine()}
                    for name,command in [('cc',['xcrun','--find','clang']),('cxx',['xcrun','--find','clang++']),
                        ('ar',['xcrun','--find','ar']),('otool',['xcrun','--find','otool']),('sdk',['xcrun','--sdk','macosx','--show-sdk-path'])]:
                        log=runner.run('tool-'+name,command,cwd=P,timeout=15,require_full_timeout=True)
                        toolchain[name]=log.read_text().strip();assert Path(toolchain[name]).exists()
                    sdk=Path(toolchain['sdk']);toolchain['sqliteInclude']=str(sdk/'usr/include');toolchain['sqliteLibrary']=str(sdk/'usr/lib/libsqlite3.tbd')
                    toolchain['files']={name:facts(Path(toolchain[name])) for name in ['cc','cxx','ar','otool','sqliteLibrary']}
                    toolchain['sqliteHeader']=facts(sdk/'usr/include/sqlite3.h')
                    for label,command in [('compiler-version',[toolchain['cxx'],'--version']),('cmake-version',['cmake','--version']),('os-version',['sw_vers'])]:
                        runner.run(label,command,cwd=P,timeout=15,require_full_timeout=True)
                    save(P/'TOOLCHAIN.json',toolchain)
                    for arm in ['off','on']:
                        build=P/('build-'+arm);assert not build.exists()
                        command=['cmake','-S',str(HERE),'-B',str(build),'-G','Unix Makefiles','-DCMAKE_BUILD_TYPE=Release',
                            '-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -g0','-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -g0',
                            '-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF','-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF',
                            '-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF','-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
                            '-DLATTICE_CORE_SOURCE='+str(P/'source'),'-DLATTICE_COLD_KEEPER_TIMING='+arm.upper(),
                            '-DCMAKE_C_COMPILER='+toolchain['cc'],'-DCMAKE_CXX_COMPILER='+toolchain['cxx'],
                            '-DCMAKE_OSX_SYSROOT='+toolchain['sdk'],'-DSQLite3_INCLUDE_DIR='+toolchain['sqliteInclude'],
                            '-DSQLite3_LIBRARY='+toolchain['sqliteLibrary']]
                        runner.run('configure-'+arm,command,cwd=P,timeout=120,require_full_timeout=True)
                elif args.stage.startswith('build-'):
                    arm=args.stage.split('-')[1]; clean(receipts/('configure-'+arm+'.json'))
                    runner.run('compile-'+arm,[sys.executable,str(HERE/'build.py'),arm],cwd=P,timeout=1200,require_full_timeout=True)
                    proof_hash=digest(P/('BUILD-PROOF-'+arm+'.json'));verify_build(arm,proof_hash);result['buildProofSHA256']=proof_hash
                else:
                    accepted={}
                    for arm in ['off','on']:
                        clean(receipts/('compile-'+arm+'.json'))
                        stage=json.loads((receipts/('RESULT-build-'+arm+'.json')).read_text());assert stage['success']
                        accepted[arm]=stage['buildProofSHA256'];verify_build(arm,accepted[arm])
                    fixtures=P/'fixtures';fixtures.mkdir(exist_ok=False);samples=[]
                    # Authentication is outside this shared180s window. Every
                    # child still requires its full unchanged30s admission.
                    runner.work_deadline=min(runner.work_deadline,time.monotonic()+180)
                    for number,arm in enumerate(['off','on']*3,1):
                        label=f'sample-{number:03}-{arm}';path=fixtures/(label+'.sqlite')
                        log=runner.run(label,[str(P/('build-'+arm)/'ColdKeeperProbe'),str(path)],cwd=P,timeout=30,require_full_timeout=True)
                        record=clean(receipts/(label+'.json'));data=parse(log.read_text(),arm)
                        files={}
                        for suffix in ['','-wal','-shm']:
                            f=Path(str(path)+suffix)
                            if f.exists():assert f.is_file()and not f.is_symlink();files[suffix]=facts(f)
                        assert '' in files
                        sample={'label':label,'arm':arm,'data':data,'closedFiles':files,'guardSHA256':digest(receipts/(label+'.json')),'logSHA256':digest(log)}
                        save(receipts/(label+'-validated.json'),sample);samples.append(sample)
                        # All values and closed/group-absence custody passed;
                        # only this successful owned fixture is removed.
                        for suffix,fact in files.items():
                            f=Path(str(path)+suffix);assert facts(f)==fact;f.unlink()
                    analysis=summarize(samples)
                    for arm in ['off','on']:verify_build(arm,accepted[arm])
                    save(P/'ANALYSIS.json',analysis);result['analysisSHA256']=digest(P/'ANALYSIS.json')
                    result['buildProofs']=accepted
            assert verify_inputs()==input_hash and digest(P/'SOURCE-MANIFEST.json')==manifest_hash
            verify_source()
            for command in runner.records:clean(receipts/(command['label']+'.json'))
            sample=runner.measure(receipts/('RESULT-'+args.stage+'.json'))
            assert not runner.violation(sample) and time.monotonic()<runner.overall_deadline
            result.update(success=True,inputsSHA256=input_hash,sourceManifestSHA256=manifest_hash,final=sample)
        except BaseException as error:
            result['error']=error_record(error);raise
        finally:
            result['commands']=runner.records
            save(receipts/('RESULT-'+args.stage+'.json'),result)
if __name__=='__main__':main()
