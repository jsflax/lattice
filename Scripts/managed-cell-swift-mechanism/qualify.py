#!/usr/bin/env python3
"""One diagnostic Swift benchmark image; reuses the existing process/build guards."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import sys
import time

PACKET = Path(__file__).resolve().parent
FEATURES = ('LATTICE_MANAGED_CELL_STATEMENT_REUSE', 'LATTICE_MANAGED_CELL_SWIFT_MECHANISM')
FLAGS = [item for name in FEATURES for item in ('-Xcxx', '-D' + name)]
FLAGS += [item for name in FEATURES for item in ('-Xswiftc', '-Xcc', '-Xswiftc', '-D' + name)]
FLAGS += ['-Xswiftc', '-DLATTICE_MANAGED_CELL_SWIFT_MECHANISM']

def require(ok, message):
    if not ok: raise ValueError(message)

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def packet_check(expected):
    seal_path = PACKET / 'PACKET-SEAL.json'
    require(sha(seal_path) == expected, 'reviewed seal changed')
    seal = json.loads(seal_path.read_text())
    required = {'qualify.py','guarded_runner.py','build_proof.py','mechanism.py','perf_refinement_report.py',
                'config.json','BASE-SOURCE-MANIFEST.json','SOURCE-MANIFEST.json','PROTOTYPE-APPLICABLE.patch',
                'DIAGNOSTIC-CORE.patch','DIAGNOSTIC-SDK.patch','FROZEN-BENCHMARK.swift'}
    require(required <= set(seal['files']), 'runtime input omitted from seal')
    for name, digest in seal['files'].items():
        path = PACKET / name
        require(not path.is_symlink() and path.is_file() and path.resolve().is_relative_to(PACKET) and sha(path) == digest,
                'sealed input drift: ' + name)
    return seal

def sources(repository, expected, *, edited_core=None):
    require(repository.is_dir() and not repository.is_symlink() and repository.resolve(strict=True)==repository,
            'source root is not an owned real directory: '+str(repository))
    files=[];links={}
    # Never descend through directory links, including the declared SwiftPM edit.
    for directory, dirs, names in os.walk(repository, followlinks=False):
        dirs[:]=[name for name in dirs if name!='.git']
        for name in [*dirs,*names]:
            path=Path(directory)/name
            if name=='.git':continue
            relative=str(path.relative_to(repository))
            if path.is_symlink():
                links[relative]=os.readlink(path)
                if name in dirs:dirs.remove(name)
            elif path.is_file() and path.relative_to(repository).parts[0]!='.swiftpm':
                files.append(path)
    allowed={}
    if edited_core is not None:
        require(repository.name=='SDK' and edited_core==repository.parent/'Core'
                and edited_core.is_dir() and not edited_core.is_symlink()
                and edited_core.resolve(strict=True)==edited_core,
                'edit target is not the exact owned sibling Core directory')
        name='Packages/LatticeCore';link=repository/name
        require(name not in expected and not any(x.startswith(name+'/') for x in expected),
                'edit link overlaps authenticated SDK source')
        require(links.get(name)==str(edited_core) and link.resolve(strict=True)==edited_core,
                'expected SwiftPM edit link mismatch: '+json.dumps({'path':name,'readlink':links.get(name),'expected':str(edited_core),'observedLinks':links},sort_keys=True))
        allowed[name]=str(edited_core)
    rejected={name:target for name,target in links.items() if allowed.get(name)!=target}
    require(not rejected,'source symlinks rejected: '+json.dumps(rejected,sort_keys=True))
    found={str(path.relative_to(repository)):sha(path) for path in files}
    require(found==expected,'complete source inventory/hash drift: '+str(repository))
    return links

def uniform_flags(proof, log, scratch, expand):
    for item in proof['nativeObjects'].values():
        args = item['expandedArguments']
        for name in FEATURES:
            require('-D'+name in args and not any(a.startswith(('-U'+name, '-D'+name+'=')) for a in args), 'C++ opt-in mismatch')
    importer = {}
    for line in log.read_text().splitlines():
        try: args = shlex.split(line)
        except ValueError: continue
        if args and args[0] == 'builtin-SwiftDriver' and len(args) > 2 and args[1] == '--': args = args[2:]
        if not args or Path(args[0]).name != 'swiftc' or '-module-name' not in args or '-output-file-map' not in args: continue
        if '-cxx-interoperability-mode=default' not in args: continue
        module = args[args.index('-module-name')+1]
        args, responses = expand(args, scratch)
        for name in FEATURES:
            require(any(args[i:i+2] == ['-Xcc','-D'+name] for i in range(len(args)-1)), 'Clang importer opt-in missing: '+module)
            require(not any(a.startswith(('-U'+name, '-D'+name+'=')) for a in args), 'importer opt-in conflicting')
        require(any(a == '-DLATTICE_MANAGED_CELL_SWIFT_MECHANISM' and (i == 0 or args[i-1] != '-Xcc') for i,a in enumerate(args)) or any(args[i:i+2] == ['-D','LATTICE_MANAGED_CELL_SWIFT_MECHANISM'] and (i == 0 or args[i-1] != '-Xcc') for i in range(len(args)-1)), 'Swift diagnostic condition absent')
        importer.setdefault(module, []).append({'argv':args,'responseFiles':responses,
            'scope':'actual Swift compiler-driver action with forwarded Clang importer flags; direct frontend child not independently captured'})
    require({'Lattice','LatticeTests'} <= set(importer), 'actual Swift compiler-driver evidence missing')
    return importer

def clear_acceptance(result):
    result.update(success=False, mechanismQualified=False, experimentCompleted=False)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--seal-sha256',required=True)
    parser.add_argument('--swift',type=Path,required=True)
    args=parser.parse_args();packet_check(args.seal_sha256)
    import guarded_runner as guard
    import build_proof
    import mechanism
    import perf_refinement_report as report
    config=json.loads((PACKET/'config.json').read_text())
    base=json.loads((PACKET/'BASE-SOURCE-MANIFEST.json').read_text())
    expected=json.loads((PACKET/'SOURCE-MANIFEST.json').read_text())
    root=args.root.resolve(strict=True);allowed=(Path.home()/'localdev').resolve(strict=True)
    require(root.is_relative_to(allowed) and root!=allowed and not any(x.name!='tmp' for x in root.iterdir()), 'new owned localdev root required')
    require(platform.system()=='Darwin' and args.swift.is_absolute() and args.swift.is_file(), 'macOS with explicit Swift required')
    for name in ('receipts','scratch','cache','config','security','module-cache','runs','test-logs'):(root/name).mkdir()
    (root/'tmp').mkdir(exist_ok=True)
    sdk=root/'SDK';core=root/'Core';scratch=root/'scratch';receipts=root/'receipts'
    env=os.environ.copy();env.update(PYTHONDONTWRITEBYTECODE='1',TMPDIR=str(root/'tmp'),TMP=str(root/'tmp'),TEMP=str(root/'tmp'),
        CLANG_MODULE_CACHE_PATH=str(root/'module-cache'),SWIFT_MODULECACHE_PATH=str(root/'module-cache'),SWIFTPM_MODULECACHE_OVERRIDE=str(root/'module-cache'),
        LATTICE_TEST_LOG_PATH=str(root/'test-logs/native.log'),LATTICE_PERF_REFINEMENT='0')
    for name in ('LATTICE_ACK_PATH_DIAGNOSTICS','LATTICE_OBSERVER_WORKER_DIAGNOSTICS','LATTICE_PERF_SELECTED_BATCH'):env.pop(name,None)
    result={'schemaVersion':1,'success':False,'mechanismQualified':False,'experimentCompleted':False,'performanceTargetClaimed':False,
            'releaseQualified':False,'transparentEnablementAccepted':False,'primaryError':None,'evidenceErrors':[],
            'packetSealSHA256':args.seal_sha256,'config':config}
    proof=None;proof_hash=None;original_pins=None;pending=None;graph_done=False;source_checks=0
    with guard.Interrupts() as interrupts:
        runner=guard.GuardedRunner(root,receipts,env,interrupts,free_floor=config['freeFloorBytes'],packet_ceiling=config['packetCeilingBytes'],
            log_ceiling=config['logCeilingBytes'],overall_seconds=config['overallSeconds'],reserve=config['reserveSeconds'])
        def command(label,argv,cwd=root,timeout=60):
            return runner.run(label,[str(x) for x in argv],cwd=cwd,timeout=timeout,require_full_timeout=True)
        common=['--package-path',str(sdk),'--scratch-path',str(scratch),'--cache-path',str(root/'cache'),'--config-path',str(root/'config'),
                '--security-path',str(root/'security'),'--disable-sandbox','--disable-experimental-prebuilts']
        def full_receipts():
            items=[]
            for summary in runner.records:
                label=summary['label'];path=receipts/(label+'.json');record=json.loads(path.read_text());cleanup=record['cleanup']
                require(record['success'] and record['started'] and record['exitCode']==0 and not record.get('stopReason') and not record['primaryError']
                    and not record['evidenceErrors'] and not record['receivedSignals'] and cleanup['groupGone'] and cleanup['leaderReaped']
                    and not cleanup.get('errors') and not cleanup.get('signals'), 'command/cleanup failure: '+label)
                require(sha(receipts/(label+'.log'))==record['logSHA256'],'command log drift: '+label)
                items.append({'label':label,'receiptSHA256':sha(path),'logSHA256':record['logSHA256']})
            return items
        def graph(label):
            log=command(label+'-graph',[args.swift,'package',*common,'show-dependencies','--format','json'],sdk,120)
            nodes=guard.graph_nodes(guard.read_graph(log));state=json.loads((scratch/'workspace-state.json').read_text())
            entries=state['object']['dependencies'];deps={x['packageRef']['identity']:x for x in entries}
            require(len(entries)==len(deps) and set(nodes)==set(deps)==set(original_pins),'graph identity inventory')
            for identity,pin in original_pins.items():
                node=nodes[identity];entry=deps[identity];path=Path(node['path']).resolve(strict=True)
                require(guard.url_key(entry['packageRef']['location'])==guard.url_key(pin['location']),'workspace URL')
                if identity=='latticecore':
                    require(path==core and entry['state']['name']=='edited' and entry['state'].get('path')==str(core)
                            and entry['subpath']=='LatticeCore','Core edit is not exact owned source');revision=config['core']
                else:
                    require(entry['state']['name']=='sourceControlCheckout' and entry['state']['checkoutState']==pin['state'],'dependency checkout state')
                    require(path==(scratch/'checkouts'/entry['subpath']).resolve() and path.is_relative_to(scratch/'checkouts'),'dependency path')
                    require(guard.url_key(node['url'])==guard.url_key(pin['location']),'dependency URL');revision=pin['state']['revision']
                    dirty=command(label+'-'+identity+'-status',['git','status','--porcelain=v1','--untracked-files=all'],path).read_text()
                    require(not dirty,'dependency source dirty')
                require(command(label+'-'+identity+'-head',['git','rev-parse','HEAD'],path).read_text().strip()==revision,'dependency revision')
            current=guard.pins(sdk/'Package.resolved')
            require({k:v for k,v in current.items() if k!='latticecore'}=={k:v for k,v in original_pins.items() if k!='latticecore'},'non-Core lock drift')
            return {'nodes':nodes,'workspaceSHA256':sha(scratch/'workspace-state.json'),'lockSHA256':sha(sdk/'Package.resolved')}
        def verify_sources():
            nonlocal source_checks
            # Editing Core can remove its lock entry; preserve and compare actual
            # generated lock separately while authenticating every other SDK byte.
            sdk_expected=dict(expected['SDK']);sdk_expected['Package.resolved']=sha(sdk/'Package.resolved')
            sdk_links=sources(sdk,sdk_expected,edited_core=core if graph_done else None);sources(core,expected['Core'])
            guard.save_json(receipts/('SOURCE-CHECK-%03d.json'%source_checks),{'SDKEditLinks':sdk_links,'graphAuthenticated':graph_done})
            source_checks+=1
        try:
            for label,destination,sha_key,url_key,tree_key in [('SDK',sdk,'sdk','sdkURL','sdkTree'),('Core',core,'core','coreURL','coreTree')]:
                command(label+'-init',['git','init',destination])
                command(label+'-fetch',['git','fetch','--depth=1',config[url_key],config[sha_key]],destination,120)
                command(label+'-checkout',['git','checkout','--detach',config[sha_key]],destination)
                identity=command(label+'-identity',['git','show','--no-patch','--format=%H %T','HEAD'],destination).read_text().strip()
                require(identity==config[sha_key]+' '+config[tree_key],'source commit/tree');sources(destination,base[label])
            original_pins=guard.pins(sdk/'Package.resolved');require(len(original_pins)==34,'full SDK lock inventory')
            guard.save_json(receipts/'ORIGINAL-PINS.json',original_pins)
            for destination,patch in [(core,'PROTOTYPE-APPLICABLE.patch'),(core,'DIAGNOSTIC-CORE.patch'),(sdk,'DIAGNOSTIC-SDK.patch')]:
                command(patch+'-check',['git','apply','--check',PACKET/patch],destination)
                command(patch+'-apply',['git','apply',PACKET/patch],destination)
            verify_sources()
            command('swift-version',[args.swift,'--version']);command('sdk-version',['xcrun','--sdk','macosx','--show-sdk-version'])
            command('resolve',[args.swift,'package',*common,'--force-resolved-versions','resolve'],sdk,config['resolveSeconds'])
            require(guard.pins(sdk/'Package.resolved')==original_pins,'resolved published lock changed')
            command('edit-Core',[args.swift,'package',*common,'edit','LatticeCore','--path',core],sdk,120)
            initial_graph=graph('before');graph_done=True;guard.save_json(receipts/'GRAPH-BEFORE.json',initial_graph);verify_sources()
            build=command('release-build-optout',[args.swift,'test',*common,'-c','release','--force-resolved-versions','--filter',config['testFilter'],'-j','2','-v',*FLAGS],sdk,config['buildSeconds'])
            proof=build_proof.make(build,sdk,core,scratch,config['testPath'],temporary=root/'tmp',map_receipts=receipts/'swift-output-maps')
            proof['uniformSwiftDriverFlags']=uniform_flags(proof,build,scratch,build_proof.native_arguments)
            proof_path=receipts/'BUILD-PROOF.json';guard.save_json(proof_path,proof);proof_hash=sha(proof_path);result['compilerProofSHA256']=proof_hash
            verify_sources();build_proof.verify(proof);packet_check(args.seal_sha256)
            command('settle',[sys.executable,'-c','import time; time.sleep(60)'],timeout=90)
            run=root/'runs/mechanism'
            runner.env.update(LATTICE_PERF_REFINEMENT='1',LATTICE_PERF_RUN_DIR=str(run),LATTICE_PERF_SOURCE_REVISION='git:'+config['sdk']+';overlay:'+sha(PACKET/'DIAGNOSTIC-SDK.patch'),
                LATTICE_PERF_CORE_REVISION='git:'+config['core']+';prototype:'+sha(PACKET/'PROTOTYPE.patch')+';diagnostic:'+sha(PACKET/'DIAGNOSTIC-CORE.patch'),
                LATTICE_PERF_BUILD_IDENTITY='sha256:'+proof_hash,LATTICE_PERF_HOST_ID='diagnostic-allocation:'+root.name,
                LATTICE_PERF_SAMPLES='100',LATTICE_PERF_WARMUPS='5',LATTICE_PERF_VARIANTS='local,attached')
            command('mechanism-run',[args.swift,'test',*common,'-c','release','--force-resolved-versions','--skip-build','--filter',config['testFilter'],*FLAGS],sdk,config['runSeconds'])
            report.load_run(run/'result.json',expected_variants=('local','attached'))
            pending=mechanism.load(run);guard.save_json(receipts/'OBSERVED-MECHANISM.json',pending)
            result['observedMechanismSHA256']=sha(receipts/'OBSERVED-MECHANISM.json')
            result['originalResultSHA256']=sha(run/'result.json')
            result['sidecarHashes']={str(x.relative_to(run)):sha(x) for x in sorted(run.glob('*/mechanism-*.json'))}
        except BaseException as error:
            result['primaryError']=guard.error_record(error);clear_acceptance(result)
        finally:
            with interrupts.hold():
                try:
                    packet_check(args.seal_sha256)
                    if graph_done:
                        final_graph=graph('after');guard.save_json(receipts/'GRAPH-AFTER.json',final_graph)
                        require(final_graph==initial_graph,'effective graph/lock drift');verify_sources()
                    if proof is not None:
                        require(proof_hash is not None and sha(receipts/'BUILD-PROOF.json')==proof_hash,'proof drift');build_proof.verify(proof)
                        for records in proof['uniformSwiftDriverFlags'].values():
                            for record in records:
                                for name,digest in record['responseFiles'].items():require(sha(Path(name))==digest,'Swift response drift')
                    result['commands']=full_receipts();require(not interrupts.received,'interrupted')
                    if pending is not None:
                        require(sha(receipts/'OBSERVED-MECHANISM.json')==result['observedMechanismSHA256'],'mechanism evidence drift')
                        require(sha(root/'runs/mechanism/result.json')==result['originalResultSHA256'],'original result drift')
                        for name,digest in result['sidecarHashes'].items():require(sha(root/'runs/mechanism'/name)==digest,'sidecar drift')
                    sample=runner.measure(receipts/'RESULT.json');result['finalResource']=sample
                    require(not runner.violation(sample) and time.monotonic()<runner.overall_deadline,'final budget')
                    if not result['primaryError'] and pending is not None:
                        result.update(success=True,mechanismQualified=True,experimentCompleted=True,cleanExpectedSignatures=pending['cleanExpectedSignatures'])
                except BaseException as error:
                    result['evidenceErrors'].append(guard.error_record(error));clear_acceptance(result)
                result['receivedSignals']=list(interrupts.received);result['elapsedSeconds']=time.monotonic()-runner.started
                guard.save_json(receipts/'RESULT.json',result)
                require(time.monotonic()<runner.overall_deadline,'deadline passed during result write; outer failure is authoritative')
    return 0 if result['success'] else 1

if __name__=='__main__':sys.exit(main())
