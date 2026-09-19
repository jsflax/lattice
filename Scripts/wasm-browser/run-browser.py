#!/usr/bin/env python3
"""Isolated corrected-candidate Chromium WASM qualification; never connects to an existing browser/server."""
import argparse,hashlib,importlib.util,json,os,shutil,signal,subprocess,sys,tarfile,time,zipfile
from pathlib import Path
P=Path(__file__).resolve().parent
from input_contract import validate_config, verify_artifact

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--js-source',type=Path,required=True)
    parser.add_argument('--wasm-artifact',type=Path,required=True)
    args=parser.parse_args()
    if sys.platform!='linux':raise ValueError('This preparation requires Linux /proc process-identity proof')
    config=json.loads((P/'config.json').read_text())
    inputs=json.loads((P/'ci-inputs.json').read_text());validate_config(config,inputs)
    historical=P/config['historicalBaseline']['receipt']
    if hashlib.sha256(historical.read_bytes()).hexdigest()!=config['historicalBaseline']['receiptSHA256']:raise ValueError('Historical baseline receipt changed')
    if hashlib.sha256((P/'package-lock.json').read_bytes()).hexdigest()!=config['playwrightLockSHA256']:raise ValueError('Playwright lock bytes changed')
    if hashlib.sha256((P/'guarded_runner.py').read_bytes()).hexdigest()!=config['supervisorSHA256']:
        raise ValueError('Supervisor bytes changed')
    spec=importlib.util.spec_from_file_location('guarded_runner',P/'guarded_runner.py'); guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)
    root=args.root.resolve(); localdev=(Path.home()/'localdev').resolve()
    if not root.is_relative_to(localdev) or root==localdev or root.exists(): raise ValueError('A new owned ~/localdev child is required')
    root.mkdir(parents=True)
    receipts=root/'receipts';receipts.mkdir()
    for folder in ['tmp','npm-cache','browser-cache','tooling','xdg-cache','xdg-config','xdg-data']: (root/folder).mkdir()
    env=os.environ.copy();env.update(TMPDIR=str(root/'tmp'),TMP=str(root/'tmp'),TEMP=str(root/'tmp'),
        npm_config_cache=str(root/'npm-cache'),PLAYWRIGHT_BROWSERS_PATH=str(root/'browser-cache'),
        XDG_CACHE_HOME=str(root/'xdg-cache'),XDG_CONFIG_HOME=str(root/'xdg-config'),XDG_DATA_HOME=str(root/'xdg-data'),
        PYTHONDONTWRITEBYTECODE='1',PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD='1')
    result={'schemaVersion':1,'success':False,'browserCompatibility':False,'remoteSyncQualified':False,
        'fullBrowserMatrixQualified':False,'releaseGraphAccepted':False,'browserCandidateQualified':False,'fullABCompatibility':False,'baselineQualified':False,'baselineRerun':False,'historicalBaseline':config['historicalBaseline'],'scope':'corrected candidate only; historical baseline remains failed','errors':[],'detachedGroupCleanup':[],'config':config}
    def process_identity(pid):
        try:
            raw=Path('/proc',str(pid),'stat').read_text()
            fields=raw[raw.rfind(')')+2:].split()
            return {'pid':pid,'processGroup':int(fields[2]),'session':int(fields[3]),'startTicks':fields[19]}
        except (FileNotFoundError,ProcessLookupError):return None
    def ownership_matches(row):
        for recorded in row.get('identities',[]):
            if not isinstance(recorded.get('pid'),int):continue
            current=process_identity(recorded['pid'])
            if current==recorded and current['processGroup']==row['pid'] and current['session']==row['pid']:return True
        return False
    primary=None;input_manifest={};qualification_manifest={}
    shutil.copyfile(historical,receipts/historical.name)
    with guard.Interrupts() as interrupts:
        runner=guard.GuardedRunner(root,receipts,env,interrupts,free_floor=config['freeFloorBytes'],
            packet_ceiling=config['packetCeilingBytes'],log_ceiling=128*1024*1024,
            overall_seconds=config['overallSeconds'],reserve=60,signal_grace=45)
        def command(name,argv,cwd=root,timeout=120,**kw):return runner.run(name,argv,cwd=cwd,timeout=timeout,**kw)
        try:
            source=args.js_source.resolve(strict=True); artifact=args.wasm_artifact.resolve(strict=True)
            if guard.digest(artifact)!=config['artifactSHA256']:raise ValueError('Archived WASM CI artifact mismatch')
            with zipfile.ZipFile(artifact) as archive:result['buildProvenance']=verify_artifact(archive,config,inputs)
            head=command('source-head',['git','rev-parse','HEAD'],source).read_text().strip()
            status=command('source-status',['git','status','--porcelain=v1','--untracked-files=all'],source).read_text()
            if head!=config['jsCommit'] or status:raise ValueError('Read-only JS source must match clean exact commit')
            if command('source-tree',['git','rev-parse','HEAD^{tree}'],source).read_text().strip()!=config['jsTree']:raise ValueError('Candidate JS tree mismatch')
            for name,expected in config['jsSourceHashes'].items():
                if guard.digest(source/name)!=expected:raise ValueError('Source inventory mismatch: '+name)
            archive=root/'original-js.tar'
            command('source-archive',['git','archive','--format=tar','--output',str(archive),config['jsCommit']],source)
            input_manifest={}
            for arm in ['B']:
                target=root/arm;target.mkdir()
                with tarfile.open(archive) as tar:
                    members=tar.getmembers()
                    if sum(m.size for m in members)>32*1024*1024:raise ValueError('Source archive ceiling')
                    for member in members:
                        name=Path(member.name)
                        if name.is_absolute() or '..' in name.parts or not (member.isdir() or member.isfile()):raise ValueError('Unsafe source archive member')
                    tar.extractall(target,members=members,filter='data')
                input_manifest[arm]={str(f.relative_to(target)):guard.digest(f) for f in sorted(target.rglob('*')) if f.is_file()}
                (target/'wasm/build').mkdir(parents=True,exist_ok=True)
                with zipfile.ZipFile(artifact) as z:
                    for ext in ['js','wasm']:
                        expected=config['assets'][arm][ext];info=z.getinfo(expected['zipMember'])
                        if info.file_size!=expected['bytes'] or info.file_size>4*1024*1024:raise ValueError('WASM artifact entry size mismatch')
                        raw=z.read(info)
                        if hashlib.sha256(raw).hexdigest()!=expected['sha256']:raise ValueError('WASM artifact entry digest mismatch')
                        (target/'wasm/build'/('lattice.'+ext)).write_bytes(raw)
                fixture=target/'test/qualification';fixture.mkdir()
                for name in ['fixture.html','fixture.ts']:shutil.copyfile(P/name,fixture/name)
                qualification_manifest[arm]={'test/qualification/'+name:guard.digest(P/name) for name in ['fixture.html','fixture.ts']}
                # Published JS1.1 does not contain the earlier audit6 fixtures.
                # Preserve them as an explicit qualification-only overlay;
                # never attribute their bytes to the published source tree.
                for name,expected in config['regressionFixtureHashes'].items():
                    supplied=P/'audit-fixtures'/name
                    destination=target/'test/browser'/name
                    if destination.exists() or guard.digest(supplied)!=expected:raise ValueError('Audit regression overlay differs or overwrites published source')
                    shutil.copyfile(supplied,destination)
                    qualification_manifest[arm]['test/browser/'+name]=expected
            guard.save_json(receipts/'ORIGINAL-SOURCE-MANIFEST.json',input_manifest)
            guard.save_json(receipts/'QUALIFICATION-OVERLAY-MANIFEST.json',qualification_manifest)
            for name in ['package.json','package-lock.json','driver.mjs']:shutil.copyfile(P/name,root/'tooling'/name)
            shutil.copyfile(P/'config.json',root/'config.json')
            node=command('node-version',['node','--version']).read_text().strip()
            npm=command('npm-version',['npm','--version']).read_text().strip()
            if node!='v'+config['nodeVersion']:raise ValueError('Exact Node '+config['nodeVersion']+' required')
            result.update(node=node,npm=npm,playwrightLockSHA256=guard.digest(P/'package-lock.json'),artifactSHA256=guard.digest(artifact))
            command('tooling-ci',['npm','ci','--ignore-scripts','--no-audit','--no-fund','--fetch-retries=0','--fetch-timeout=15000'],root/'tooling',timeout=180)
            # Preserve JS's own complete lock and dependency graph, without upgrades.
            command('source-ci',['npm','ci','--no-audit','--no-fund','--fetch-retries=0','--fetch-timeout=15000'],root/'B',timeout=240)
            command('install-owned-chromium',['node',str(root/'tooling/node_modules/playwright/cli.js'),'install','chromium'],root/'tooling',timeout=240)
            # A whole separate process owns Vite and the new browser, never attaches to other surfaces.
            command('browser-driver',['node',str(root/'tooling/driver.mjs'),str(root),str(root/'config.json')],root/'tooling',timeout=720,require_full_timeout=True)
            browser=json.loads((receipts/'BROWSER-RESULT.json').read_text())
            if not browser['success']:raise ValueError('Browser report failed or incomplete')
            for arm in ['B']:
                for name,expected in input_manifest[arm].items():
                    if guard.digest(root/arm/name)!=expected:raise ValueError('Original source changed: '+arm+'/'+name)
            if command('source-final-head',['git','rev-parse','HEAD'],source).read_text().strip()!=head:raise ValueError('Read-only original checkout changed')
            if command('source-final-status',['git','status','--porcelain=v1','--untracked-files=all'],source).read_text()!=status:raise ValueError('Read-only original source dirtied')
            result.update(success=True,browserCandidateQualified=True,localChromiumCasesQualified=True)
        except BaseException as error:
            primary=error;result['errors'].append(guard.error_record(error))
        finally:
            with interrupts.hold():
                # Preserve source custody even when runtime assertions fail.
                try:
                    if set(input_manifest) != {'B'}:raise ValueError('Candidate source manifest incomplete')
                    for name,expected in input_manifest['B'].items():
                        if guard.digest(root/'B'/name)!=expected:raise ValueError('Candidate source changed: '+name)
                    result['stagedSourceVerifiedAtExit']=True
                    if set(qualification_manifest)!= {'B'} or len(qualification_manifest['B'])!=4:raise ValueError('Qualification-only overlay manifest incomplete')
                    for name,expected in qualification_manifest['B'].items():
                        if guard.digest(root/'B'/name)!=expected:raise ValueError('Qualification-only fixture changed: '+name)
                    result['qualificationOverlayVerifiedAtExit']=True
                except BaseException as error:result['errors'].append(guard.error_record(error))
                # Playwright can create a detached browser session. Its audited
                # spawn registry is the authority; never signal a guessed/foreign group.
                owned_file=receipts/'owned-spawns.json'
                try:
                    if owned_file.exists():
                        entries=json.loads(owned_file.read_text())
                        if not isinstance(entries,list) or len(entries)>64:raise ValueError('Invalid owned spawn inventory')
                        cleanup_until=time.monotonic()+30
                        for row in entries:
                            if not row.get('detached'):continue
                            pid=row.get('pid')
                            if not isinstance(pid,int) or pid<=1 or pid in (os.getpid(),os.getpgrp()):raise ValueError('Invalid owned detached group')
                            proof={'pgid':pid,'signals':[],'groupGone':False,'errors':[]}
                            if row.get('groupGone') is True:
                                # Permanent absence was witnessed before PID reuse is possible.
                                proof.update(groupGone=True,proof='driver-observed-group-gone')
                                result['detachedGroupCleanup'].append(proof);continue
                            for number in [signal.SIGTERM,signal.SIGKILL]:
                                alive,error,method=guard.GuardedRunner.group_state(pid)
                                if error:proof['errors'].append(error)
                                if alive is False:break
                                if time.monotonic()>=cleanup_until:proof['errors'].append({'message':'Global detached cleanup budget exhausted'});break
                                if not ownership_matches(row):
                                    proof['errors'].append({'message':'No retained member birth identity authenticates this group; refused signal'});break
                                try:os.killpg(pid,number);proof['signals'].append(signal.Signals(number).name)
                                except ProcessLookupError:pass
                                except OSError as error:proof['errors'].append(guard.error_record(error))
                                until=min(time.monotonic()+5,cleanup_until)
                                while time.monotonic()<until:
                                    alive,error,method=guard.GuardedRunner.group_state(pid)
                                    if alive is False:break
                                    time.sleep(0.1)
                            alive,error,method=guard.GuardedRunner.group_state(pid)
                            proof.update(groupGone=alive is False,proof=method)
                            if error:proof['errors'].append(error)
                            result['detachedGroupCleanup'].append(proof)
                            if not proof['groupGone']:raise ValueError('Missing browser group absence proof')
                    elif any(record['label']=='browser-driver' for record in runner.records):
                        raise ValueError('Browser driver started without an owned spawn inventory')
                except BaseException as error:result['errors'].append(guard.error_record(error))
                try:
                    result['finalResources']=runner.measure(receipts/'RESULT.json')
                    if runner.violation(result['finalResources']):raise ValueError('Final resource guard failed')
                except BaseException as error:result['errors'].append(guard.error_record(error))
                if time.monotonic()-runner.started>config['overallSeconds']:result['errors'].append({'message':'Overall deadline exceeded during cleanup'})
                result.update(commands=runner.records,signals=interrupts.received,elapsedSeconds=time.monotonic()-runner.started)
                result['success']=result['success'] and not result['errors'] and not interrupts.received and all(c['success'] for c in runner.records)
                result['browserCompatibility']=False
                result['localChromiumCasesQualified']=result['success']
                result['browserCandidateQualified']=result['success']
                guard.save_json(receipts/'RESULT.json',result)
    if not result['success']:
        if primary:raise primary
        raise RuntimeError('Browser qualification incomplete')

if __name__=='__main__':main()
