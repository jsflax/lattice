"""One fresh actual SDK graph. Reuses GuardedRunner; no retry or old compiled output."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import time
import guarded_runner as guard
import build_proof
import runtime_oracles
import sdk_test_oracles
import source_checks

P=Path(__file__).resolve().parent
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def require(ok, message):
    if not ok: raise ValueError(message)

NATIVE_BUILD_SYSTEM_WARNING = b"warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system."

def runtime_output_directory(output, expected):
    """Match the complete combined bytes; never infer a path from partial output."""
    path = expected.encode('utf-8')
    require(output.removesuffix(b'\n') in (path, NATIVE_BUILD_SYSTEM_WARNING + b'\n' + path),
            'unbound native runtime bin directory')
    return expected

def source_packet(expected, *, no_runtime=False, prelaunch=False):
    require(re.fullmatch(r'[0-9a-f]{64}',expected or '') and H(P/'SOURCE-READY.json')==expected,'reviewed source seal required')
    value=json.loads((P/'SOURCE-READY.json').read_text())
    required={'qualify.py','source_checks.py','sdk_test_oracles.py','runtime_oracles.py','build_proof.py',
              'guarded_runner.py','CONFIG.json','COMMANDS.json','EXPECTED-TESTS.json','SDK-SOURCE-MANIFEST.json',
              'process_custody.py','detached_owner.py','CORE-SOURCE-MANIFEST.json','EXTERNAL-INPUTS.json','Package.resolved.original','overlay/Package.swift',
              'overlay/Qualification/OwnedPageQualificationRuntime/main.swift'}
    required |= {'overlay/Qualification/DurablePageRuntimeFixture/'+x for x in ['runtime_fixture.cpp','runtime_fixture.hpp','edge_fixture.hpp','module.modulemap']}
    require(required<=set(value['files']),'runtime input omitted from seal')
    for name,digest in value['files'].items():
        path=P/name;require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(P) and H(path)==digest,'sealed input drift: '+name)
    source_checks.verify(require_no_runtime=no_runtime, require_no_owner=prelaunch)
    return json.loads((P/'CONFIG.json').read_text())

def clean(receipts,label,wanted):
    value=json.loads((receipts/(label+'.json')).read_text());cleanup=value['cleanup']
    require(value['argv']==wanted['argv'] and value['cwd']==wanted['cwd'] and value['timeoutSeconds']==wanted['timeoutSeconds'],'command identity changed: '+label)
    require(value['success'] and value['started'] and value['exitCode']==0 and not value.get('stopReason')
        and not value['primaryError'] and not value['evidenceErrors'] and not value['receivedSignals']
        and cleanup['groupGone'] and cleanup['leaderReaped'] and cleanup['ownedDescendantsGone'] and not cleanup.get('errors') and not cleanup.get('signals'),'unclean command: '+label)
    require(H(receipts/(label+'.log'))==value['logSHA256'],'changed command log: '+label)
    return {'label':label,'receiptSHA256':H(receipts/(label+'.json')),'logSHA256':value['logSHA256']}

def files_at(root, expected, *, edit=None, mutable_lock=False):
    require(root.is_dir() and not root.is_symlink() and root.resolve()==root,'unsafe source root')
    found={};links={}
    for directory,dirs,names in os.walk(root,followlinks=False):
        here=Path(directory)
        if here==root: dirs[:]=[x for x in dirs if x not in ('.git','.swiftpm')]
        for name in [*dirs,*names]:
            path=here/name;rel=str(path.relative_to(root))
            if here==root and name in ('.git','.swiftpm'):continue
            if path.is_symlink():
                links[rel]=str(path.resolve(strict=True))
                if name in dirs:dirs.remove(name)
            elif path.is_file():found[rel]=H(path)
    require(links==({} if edit is None else {'Packages/LatticeCore':str(edit)}),'unexpected source link')
    wanted=dict(expected)
    if mutable_lock:found.pop('Package.resolved',None);wanted.pop('Package.resolved',None)
    require(found==wanted,'complete source manifest drift: '+str(root))
    require(not (root/'.swiftpm').is_symlink(),'root SwiftPM bookkeeping link')

def uniform(proof):
    def definitions(args,name):
        values=[]
        for i,arg in enumerate(args):
            if arg.startswith('-U'+name) or (arg=='-U' and i+1<len(args) and args[i+1].startswith(name)):raise ValueError('opposing undefine')
            if arg.startswith('-D'+name):values.append(arg[2:])
            if arg=='-D' and i+1<len(args) and args[i+1].startswith(name):values.append(args[i+1])
        require(values and all(x==name+'=1' for x in values),'uniform native/importer macro missing or opposing: '+name)
    for source,item in proof['nativeObjects'].items():
        if source.endswith('.c'):continue  # sqlite-vec C has no Swift owner ABI.
        for name in ('LATTICE_HAS_FRT','LATTICE_EXPERIMENTAL_OWNED_READ'):definitions(item['expandedArguments'],name)
    for module in ('Lattice','LatticeTests','OwnedPageQualificationRuntime'):
        args=proof['swiftModules'][module]['argv'];importer=[args[i+1] for i,x in enumerate(args[:-1]) if x=='-Xcc']
        require('-cxx-interoperability-mode=default' in args,'actual C++ interop missing: '+module)
        for name in ('LATTICE_HAS_FRT','LATTICE_EXPERIMENTAL_OWNED_READ'):definitions(importer,name)
        swift=[x for i,x in enumerate(args) if i==0 or args[i-1]!='-Xcc']
        require('-DLATTICE_EXPERIMENTAL_OWNED_READ' in swift or any(swift[i:i+2]==['-D','LATTICE_EXPERIMENTAL_OWNED_READ'] for i in range(len(swift)-1)),'Swift feature missing: '+module)
    return {'nativeOwnerABI':'FRT1','nativeFeature':1,'importerFeature':1,'actualSwiftModules':['Lattice','LatticeTests','OwnedPageQualificationRuntime']}

def final_evidence(result, *, sources, products, observed, receipts, runner, now=time.monotonic):
    """Independent final checks: an expected command failure cannot short-circuit custody."""
    result['finalChecks'] = []
    result['commandAudit'] = []
    def check(label, action):
        try:
            detail = action()
            result['finalChecks'].append({'check': label, 'success': True, 'detail': detail})
        except BaseException as error:
            detail = guard.error_record(error)
            result['evidenceErrors'].append({'check': label, 'error': detail})
            result['finalChecks'].append({'check': label, 'success': False, 'error': detail})
    check('sourceCustody', sources)
    check('productCustody', products)
    for label, wanted in observed.items():
        check('command:' + label, lambda label=label, wanted=wanted:
              result['commandAudit'].append(clean(receipts, label, wanted)))
    def resources():
        sample = runner.measure(receipts / 'RESULT.json')
        result['finalResources'] = sample
        require(runner.violation(sample) is None, 'final resource refusal')
    check('resources', resources)
    def deadline():
        sampled = now()
        result['finalDeadline'] = {'sampledMonotonic': sampled, 'overallDeadline': runner.overall_deadline,
                                   'withinDeadline': sampled <= runner.overall_deadline}
        require(sampled <= runner.overall_deadline, 'final absolute deadline refusal')
    check('deadline', deadline)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--reviewed-sdk-owned-page-qualification',action='store_true',required=True);parser.add_argument('--source-ready-sha256',required=True);args=parser.parse_args()
    require(platform.system()=='Darwin' and platform.machine()=='arm64' and __debug__,'arm64 macOS, nonoptimized Python required')
    config=source_packet(args.source_ready_sha256,no_runtime=True);root=Path(config['runtimeRoot'])
    owner=guard.detached_owner.Control()
    require(owner.owner is not None and owner.owner['description'].get('sourceReadySHA256')==args.source_ready_sha256
            and owner.owner['description'].get('runtimeRoot')==str(root),'authenticated detached owner required')
    owner.check('before-stage')
    require(root.is_relative_to(P.parents[2]) and not root.exists() and root.resolve()==root,'fresh exact owned runtime root required')
    root.mkdir();receipts=root/'receipts';receipts.mkdir()
    for name in ['tmp','scratch','cache','config','security','module-cache','test-logs','data/frt1']:(root/name).mkdir(parents=True)
    env={x:os.environ[x] for x in ('HOME','USER','LOGNAME') if x in os.environ}
    env.update(PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',LANG='en_US.UTF-8',LC_ALL='en_US.UTF-8',**config['ownedEnvironment'])
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    planned={x['label']:x for x in json.loads((P/'COMMANDS.json').read_text())};observed={};proof=None;proof_hash=None;staged=False;edited=False
    expected=json.loads((P/'EXPECTED-TESTS.json').read_text());sdk=root/'SDK';core=root/'Core'
    sdk_files=json.loads((P/'SDK-SOURCE-MANIFEST.json').read_text());core_files=json.loads((P/'CORE-SOURCE-MANIFEST.json').read_text())
    original_pins=guard.pins(P/'Package.resolved.original');derived=dict(sdk_files)
    for path in (P/'overlay').rglob('*'):
        if path.is_file():derived[str(path.relative_to(P/'overlay'))]=H(path)
    result={'success':False,'scope':config['scope'],'primaryError':None,'evidenceErrors':[],'sourceReadySHA256':args.source_ready_sha256,
            'SDKCommit':config['sdkCommit'],'SDKTree':config['sdkTree'],'privateCoreManifestSHA256':config['privateCoreSourceManifestSHA256'],
            'nativeFRT0OwnerQualified':False,'iOSQualified':False,'publicActivation':False,'performanceClaimed':False,
            'physicalCxxBackendAsyncAccepted':False,'oldCompiledOutputCredited':False,'cases':{}}
    limits=config['proposedLimits']
    with guard.Interrupts() as interrupts:
        runner=guard.GuardedRunner(root,receipts,env,interrupts,free_floor=limits['freeFloorBytes'],packet_ceiling=limits['packetCeilingBytes'],
            log_ceiling=limits['logCeilingBytes'],overall_seconds=limits['overallSeconds'],reserve=limits['reserveSeconds'])
        def run(label, command=None):
            command=planned[label] if command is None else command
            require(label not in observed,'one-shot command label');observed[label]=command
            log=runner.run(label,command['argv'],cwd=Path(command['cwd']),timeout=command['timeoutSeconds'],require_full_timeout=True)
            clean(receipts,label,command);return log
        def sources():
            source_packet(args.source_ready_sha256)
            if staged:
                files_at(sdk,derived,edit=core if edited else None,mutable_lock=edited)
                files_at(core,core_files)
                pins=guard.pins(sdk/'Package.resolved')
                require({k:v for k,v in pins.items() if k!='latticecore'}=={k:v for k,v in original_pins.items() if k!='latticecore'},'non-Core pins changed')
        def products():
            if proof:
                require(H(receipts/'COMPILER-PROOF.json')==proof_hash,'compiler proof changed')
                build_proof.verify_products(proof)
            return {'compilerProofAvailable': proof is not None, 'productsAuthenticated': proof is not None}
        def custody():
            sources();products()
        def graph(label,log):
            nodes=guard.graph_nodes(guard.read_graph(log));state=json.loads((root/'scratch/workspace-state.json').read_text())['object']['dependencies'];entries={x['packageRef']['identity']:x for x in state}
            require(len(state)==len(entries) and set(entries)==set(nodes)==set(original_pins),'exact34 graph identities required')
            rows=[]
            for identity,pin in sorted(original_pins.items()):
                node=nodes[identity];entry=entries[identity];path=Path(node['path']).resolve(strict=True)
                require(guard.url_key(entry['packageRef']['location'])==guard.url_key(pin['location']),'workspace URL mismatch')
                if identity=='latticecore':
                    require(path==core and entry['state']['name']=='edited' and entry['state'].get('path')==str(core) and entry['subpath']=='LatticeCore','only exact frozen Core edit allowed')
                    rows.append({'identity':identity,'path':str(path),'composedSourceManifestSHA256':H(P/'CORE-SOURCE-MANIFEST.json')});continue
                require(entry['state']['name']=='sourceControlCheckout' and entry['state']['checkoutState']==pin['state'],'version/revision mismatch')
                require(path==(root/'scratch/checkouts'/entry['subpath']).resolve() and path.is_relative_to(root/'scratch/checkouts'),'dependency outside owned checkouts')
                require(guard.url_key(node['url'])==guard.url_key(pin['location']),'graph URL mismatch')
                prefix=label+'-'+identity
                head=run(prefix+'-head',{'argv':['/usr/bin/git','rev-parse','HEAD'],'cwd':str(path),'timeoutSeconds':60}).read_text().strip()
                dirty=run(prefix+'-status',{'argv':['/usr/bin/git','status','--porcelain=v1','--untracked-files=all'],'cwd':str(path),'timeoutSeconds':60}).read_text()
                require(head==pin['state']['revision'] and not dirty,'actual dependency source mismatch')
                rows.append({'identity':identity,'path':str(path),'revision':head})
            guard.save_json(receipts/(label+'-proof.json'),rows)
        try:
            sample=runner.measure(receipts/'stage.log');require(runner.violation(sample) is None,'initial resource refusal')
            began=time.monotonic()
            for destination,origin,manifest in [(sdk,Path(config['sdkSource']),sdk_files),(core,Path(config['privateCoreSource']),core_files)]:
                destination.mkdir()
                for name,digest in manifest.items():
                    require(time.monotonic()-began<120,'source stage time bound')
                    source=origin/name;target=destination/name;require(H(source)==digest and not source.is_symlink(),'stage input drift')
                    target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target);require(H(target)==digest,'stage copy drift')
            for source in (P/'overlay').rglob('*'):
                if source.is_file():
                    target=sdk/source.relative_to(P/'overlay');target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
            staged=True;sources();guard.save_json(receipts/'STAGED-SOURCES.json',{'SDK':derived,'Core':core_files})
            guard.save_json(receipts/'INVOCATION.json',{'environment':env,'limits':limits,'commandPlanSHA256':H(P/'COMMANDS.json'),'sourceReadySHA256':args.source_ready_sha256})
            run('swift-version');help_log=run('test-help').read_text();require(all(x in help_log for x in ('--skip-build','--disable-xctest','--enable-swift-testing','--xunit-output','--list-tests')),'required real Swift Testing options absent')
            run('resolve-versioned');require(guard.pins(sdk/'Package.resolved')==original_pins,'original complete34lock changed during resolve')
            run('edit-private-core');edited=True;sources();graph('effective-graph-before',run('effective-graph-before'))
            runtime_output_directory(run('runtime-output-directory').read_bytes(),str(Path(planned['owning-edge-9']['argv'][0]).parent))
            build=run('debug-build-tests-and-runtime');sources()
            proof=build_proof.make(build,sdk,core,root/'scratch','Tests/LatticeTests/OwnedPageReadTests.swift',temporary=root/'tmp',map_receipts=receipts/'swift-output-maps')
            proof['uniformDefinitions']=uniform(proof)
            tools=config['toolFiles']
            for item in proof['nativeObjects'].values():
                require(H(Path(item['argv'][0]))==tools[config['clang']],'actual native compiler differs from pinned tool')
            for item in proof['swiftDriverJobs']:
                require(H(Path(item['compiler']))==tools[config['swiftc']],'actual Swift driver differs from pinned tool')
            for item in proof['swiftModules'].values():
                require(H(Path(item['argv'][0]))==tools[config['swiftc']],'actual Swift compiler differs from pinned tool')
            fixture=proof['nativeObjects'][str(sdk/'Qualification/DurablePageRuntimeFixture/runtime_fixture.cpp')]
            arguments=fixture['expandedArguments'];require(arguments.count('-MF')==1,'fixture dependency file required')
            depfile=Path(arguments[arguments.index('-MF')+1]).resolve(strict=True)
            require(depfile.is_relative_to(root/'scratch') and depfile.stat().st_size<1024*1024,'fixture dependency path/size')
            import shlex
            names=shlex.split(depfile.read_text().replace('\\\n',' ').split(':',1)[1]);dependencies={}
            allowed=[sdk,core,Path(config['macosSDK']).resolve(),Path(config['clang']).parent.parent.parent.resolve()]
            for name in names:
                path=(sdk/name).resolve(strict=True);require(any(path.is_relative_to(x) for x in allowed),'fixture compiler dependency outside bound roots')
                dependencies[str(path)]=H(path)
            require(str(sdk/'Qualification/DurablePageRuntimeFixture/runtime_fixture.cpp') in dependencies,'fixture dependency source absent')
            proof['fixtureDependencies']={'path':str(depfile),'sha256':H(depfile),'files':dependencies}
            build_proof.verify_products(proof)
            guard.save_json(receipts/'COMPILER-PROOF.json',proof);proof_hash=H(receipts/'COMPILER-PROOF.json')
            result['discovered']=sdk_test_oracles.discovery(run('discover-owned-page'),expected);custody()
            log=run('owned-page-26');result['cases']['fake26']=sdk_test_oracles.analyze(log,receipts/'owned-page-26.xml',expected);custody()
            linkage=run('runtime-system-linkage').read_text();require('\t/usr/lib/libsqlite3.dylib (' in linkage,'system SQLite link absent')
            runner.env=env|config['runtimeEnvironment'];log=run('owning-edge-9');runner.env=env
            records=runtime_oracles.analyze_runtime(log,{'expectedCases':config['originalCases9']})
            images=runtime_oracles.physical_postimages(root/'data/frt1',records);result['cases']['direct9']={'records':records,'physicalPostimages':images};custody()
            graph('effective-graph-after',run('effective-graph-after'));custody()
            require([x for x in observed if x in planned]==list(planned),'planned command order or inventory changed')
            result['success']=True
        except BaseException as error:result['primaryError']=guard.error_record(error)
        finally:
            with interrupts.hold():
                final_evidence(result,sources=sources,products=products,observed=observed,receipts=receipts,runner=runner)
                result.update(commands=runner.records,receivedSignals=interrupts.received,elapsedSeconds=time.monotonic()-runner.started,compilerProofSHA256=proof_hash)
                result['success']=result['success'] and not result['primaryError'] and not result['evidenceErrors'] and not interrupts.received
                guard.save_json(receipts/'RESULT.json',result)
    print(json.dumps({'success':result['success'],'primaryError':result['primaryError'],'result':str(receipts/'RESULT.json')}))
    return 0 if result['success'] else 1

if __name__=='__main__':raise SystemExit(main())
