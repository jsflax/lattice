#!/usr/bin/env python3
"""One held diagnostic B run. Existing guard supervises every launched command."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import time
import guarded_runner as guard
import build_proof
import profile_proof
import profile_binding as binding
import analyze_profile

PACKET=Path(__file__).resolve().parent

def compiler_custody(proof, supplement, context, receipts):
    """Recheck available base evidence even when supplement construction failed."""
    if proof is None:
        return {'baseBuildAvailable': False, 'profileBuildAvailable': False}
    build_proof.verify(proof)
    proof_hash = context.get('proofHash')
    binding.require(proof_hash is not None, 'compiler proof receipt unavailable')
    binding.require(guard.digest(receipts/'COMPILER-PROOF.json') == proof_hash, 'compiler proof drift')
    value = {'baseBuildAvailable': True, 'profileBuildAvailable': False,
             'binarySHA256': guard.digest(Path(proof['binary'])), 'compilerProofSHA256': proof_hash}
    if supplement is None:
        value['profileSupplementAvailable'] = False
        return value
    profile_proof.verify(supplement)
    value['profileSupplementAvailable'] = True
    if context.get('retainedInputs') is not None:
        binding.verify_retained_inputs(context['retainedInputs'])
        binding.require(guard.digest(receipts/'RETAINED-COMPILER-INPUTS.json') == context['retainedInputsHash'],
                        'compiler input receipt drift')
    profile_hash = context.get('profileProofHash')
    binding.require(profile_hash is not None, 'profile proof receipt unavailable')
    binding.require(guard.digest(receipts/'PROFILE-PROOF.json') == profile_hash, 'profile proof drift')
    value.update(profileBuildAvailable=True, profileProofSHA256=profile_hash)
    return value


class StrictRunner(guard.GuardedRunner):
    def run(self,label,*args,**kwargs):
        log=super().run(label,*args,**kwargs)
        binding.command_check(self.receipts,label)
        return log

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--seal-sha256',required=True)
    parser.add_argument('--admission-json',type=Path,required=True)
    parser.add_argument('--admission-sha256',required=True)
    args=parser.parse_args()
    config=json.loads((PACKET/'CONFIG.json').read_text())
    binding.packet_check(PACKET,args.seal_sha256)
    prerequisites=binding.config_check(config,PACKET)
    admission=binding.admission_check(args.admission_json,args.admission_sha256,config,args.seal_sha256)
    root=args.root.resolve(strict=True);allowed=(Path.home()/'localdev').resolve(strict=True)
    binding.require(root.is_relative_to(allowed) and root!=allowed and not args.root.is_symlink(),'owned localdev root required')
    binding.require(platform.system()=='Darwin' and guard.SHA.fullmatch(os.environ.get('GITHUB_SHA','')),'exact hosted macOS workflow identity required')
    binding.require({p.name for p in root.iterdir()}<={'tools','tmp','ADMISSION.json'},'one-shot root contains prior outputs')
    tmp=root/'tmp'
    binding.require(tmp.is_dir() and not tmp.is_symlink() and not any(tmp.iterdir()),'fresh owned temporary directory required')
    receipts=root/'receipts';receipts.mkdir(exist_ok=False)
    for name in ('runs','test-logs'): (root/name).mkdir(exist_ok=False)
    guard.save_json(receipts/'ROOT-ADMISSION.json',admission)
    shutil.copyfile(args.admission_json,receipts/'ROOT-ADMISSION.original.json')
    guard.save_json(receipts/'HISTORICAL-PREREQUISITES.json',prerequisites)
    env=os.environ.copy()
    env.update(PYTHONDONTWRITEBYTECODE='1',TMPDIR=str(tmp),TMP=str(tmp),TEMP=str(tmp),
               LATTICE_TEST_LOG_PATH=str(root/'test-logs/native.log'),LATTICE_PERF_REFINEMENT='0')
    for name in ('LATTICE_ACK_PATH_DIAGNOSTICS','LATTICE_OBSERVER_WORKER_DIAGNOSTICS',
                 'LATTICE_PERF_VARIANTS','LATTICE_PERF_SELECTED_BATCH','LATTICE_PERF_LIVE_PROFILE',*binding.frozen.FORBIDDEN,
                 'CFLAGS','CXXFLAGS','CPPFLAGS','SWIFTFLAGS','OTHER_SWIFT_FLAGS','SWIFT_EXEC','SWIFT_EXEC_MANIFEST',
                 'SDKROOT','DYLD_INSERT_LIBRARIES'):
        env.pop(name,None)
    env['LATTICE_PERF_VARIANTS']='local,attached'
    result={'schemaVersion':1,'scope':config['scope'],'success':False,'primaryError':None,'evidenceErrors':[],
            'performanceTargetClaimed':False,'physicalHostQualified':False,'hostCausationClaimed':False,
            'swiftConversionMeasured':False,'canonicalSamplesExpected':210,'calibrationSamplesExpected':16,
            'candidateSDK':config['candidateSDK'],'candidateCore':config['candidateCore'],
            'workflowCommit':env['GITHUB_SHA'],'packetSealSHA256':args.seal_sha256,
            'rootAdmissionSHA256':args.admission_sha256,'historicalPrerequisites':prerequisites,'currentPhase':'setup'}
    primary=None;context={};proof=None;supplement=None
    with guard.Interrupts() as interrupts:
        runner=StrictRunner(root,receipts,env,interrupts,free_floor=config['freeFloorBytes'],
            packet_ceiling=config['packetCeilingBytes'],log_ceiling=config['logCeilingBytes'],
            overall_seconds=config['overallSeconds'],reserve=config['finalizationReserveSeconds'])
        def command(label,argv,cwd,**kwargs):return runner.run(label,argv,cwd=cwd,**kwargs)
        def fetch(label,url,sha,destination):
            binding.require(not destination.exists(),'source destination already exists')
            command(label+'-init',['git','init',str(destination)],root)
            command(label+'-fetch',['git','fetch','--depth=1',url,sha],destination)
            command(label+'-checkout',['git','checkout','--detach',sha],destination)
            return guard.authenticate_repository(runner,label,destination,sha,initial=True)
        def common():
            home=context['home']
            return ['--package-path',str(context['sdk']),'--scratch-path',str(home/'scratch'),
                    '--cache-path',str(home/'cache'),'--config-path',str(home/'config'),
                    '--security-path',str(home/'security'),'--disable-sandbox','--disable-experimental-prebuilts']
        def sources():
            output={}
            for side,state in context.get('sourceStates',{}).items():
                source=context[side]
                output[side]=binding.complete_sources(source,binding.manifest(PACKET,side,state)['files'],
                    edited_core=context['core'] if side=='sdk' and context.get('coreEdited') else None,
                    mutable_lock=side=='sdk' and context.get('coreEdited',False))
            if context.get('pins'):
                current=guard.pins(context['sdk']/'Package.resolved');wanted=context['pins']
                binding.require(({k:v for k,v in current.items() if k!='latticecore'}==
                                 {k:v for k,v in wanted.items() if k!='latticecore'}) if context.get('coreEdited')
                                else current==wanted,'committed dependency pins changed')
            return {'checkedSources':output,'completeProfileSourceAvailable':context.get('overlaysApplied',False)}
        def graph(label):
            log=command(label+'-graph',['swift','package',*common(),'show-dependencies','--format','json'],context['sdk'])
            return binding.verify_graph(runner,label,guard.read_graph(log),context['pins'],context['core'],
                config['candidateCore'],context['home']/'scratch',binding.manifest(PACKET,'core')['files'])
        def custody():
            return compiler_custody(proof, supplement, context, receipts)
        def host(label):
            boot=command(label+'-boot',['sysctl','-n','kern.bootsessionuuid'],root,timeout=60).read_text().strip()
            value={'bootSession':boot,'hostname':platform.node(),'operatingSystem':platform.platform(),
                   'cpuCount':os.cpu_count(),'loadAverage':os.getloadavg(),'monotonic':time.monotonic(),
                   'physicalHostIdentityVerified':False,'identityScope':'one hosted VM allocation/boot only'}
            guard.save_json(receipts/(label+'-host.json'),value);return value
        try:
            home=root/'candidate';home.mkdir(exist_ok=False)
            for name in ('scratch','cache','config','security','module-cache'): (home/name).mkdir(exist_ok=False)
            context.update(home=home,sdk=home/'lattice',core=home/'LatticeCore',sourceStates={})
            runner.env=dict(env,CLANG_MODULE_CACHE_PATH=str(home/'module-cache'),SWIFT_MODULECACHE_PATH=str(home/'module-cache'),
                            SWIFTPM_MODULECACHE_OVERRIDE=str(home/'module-cache'))
            result['currentPhase']='authenticate-source-overlays'
            for side,label,url in [('sdk','SDK','https://github.com/jsflax/Lattice.git'),('core','Core','https://github.com/jsflax/LatticeCore.git')]:
                source=fetch('profile-'+side,url,config['candidate'+label],context[side])
                expected=binding.manifest(PACKET,side,'base')
                binding.require(source['tree']==config['candidate'+label+'Tree'] and source['files']==expected['files'],'pristine source mismatch')
                binding.complete_sources(context[side],expected['files'])
                context['sourceStates'][side]='base'
                command(side+'-patch-check',['git','apply','--check',str(PACKET/(label+'.patch'))],context[side],timeout=60)
                context['sourceStates'][side]='profile'
                command(side+'-patch-apply',['git','apply',str(PACKET/(label+'.patch'))],context[side],timeout=60)
                binding.complete_sources(context[side],binding.manifest(PACKET,side)['files'])
            context['overlaysApplied']=True
            context['pins']=guard.pins(context['sdk']/'Package.resolved')
            binding.require(len(context['pins'])==34,'full committed 34-pin inventory required')
            shutil.copyfile(context['sdk']/'Package.resolved',receipts/'Package.resolved.original')
            sources()
            version=command('swift-version',['swift','--version'],root)
            command('test-help',['swift','test','--help'],root)
            command('macos-sdk-version',['xcrun','--sdk','macosx','--show-sdk-version'],root)
            command('developer-path',['xcode-select','-p'],root)
            initial=host('initial')
            result['currentPhase']='resolve-exact-graph'
            command('profile-resolve',['swift','package',*common(),'--force-resolved-versions','resolve'],context['sdk'])
            binding.require(guard.pins(context['sdk']/'Package.resolved')==context['pins'],'versioned resolution changed committed lock')
            command('profile-edit-core',['swift','package',*common(),'edit','LatticeCore','--path',str(context['core'])],context['sdk'])
            context['coreEdited']=True
            graph('graph-before');sources()
            flags=['-Xswiftc','-DLATTICE_PERF_SELECTED_BATCH','-Xswiftc','-DLATTICE_PERF_LIVE_PROFILE',
                   '-Xcc','-DLATTICE_PERF_LIVE_PROFILE=1','-Xcc','-I'+str(context['core']/'Sources/LatticeCore/include')]
            result['currentPhase']='fresh-Release-profile-build'
            argv=['swift','test',*common(),'-c','release','--force-resolved-versions','--filter',
                  'PerfRefinementBenchmarks/releaseRead100AndUpdate11','-j','2','-v',*flags]
            build=command('profile-build-release-disabled-benchmark',argv,context['sdk'],
                          timeout=config['buildTimeoutSeconds'],require_full_timeout=True)
            proof=build_proof.make(build,context['sdk'],context['core'],home/'scratch',config['harnessPath'],
                                  temporary=tmp,map_receipts=receipts/'swift-output-maps')
            guard.save_json(receipts/'COMPILER-PROOF.json',proof)
            context['proofHash']=guard.digest(receipts/'COMPILER-PROOF.json')
            postimages={side:{name:value['sha256'] for name,value in binding.manifest(PACKET,side)['diagnosticOverlay'].items()}
                        for side in ('sdk','core')}
            supplement=profile_proof.make(proof,build,context['sdk'],context['core'],home/'scratch',postimages,receipts/'profile-dependencies')
            build_proof.verify(proof);profile_proof.verify(supplement);sources()
            context['retainedInputs']=binding.retain_compiler_inputs(proof,supplement,receipts/'compiler-input-copies')
            guard.save_json(receipts/'RETAINED-COMPILER-INPUTS.json',context['retainedInputs'])
            context['retainedInputsHash']=guard.digest(receipts/'RETAINED-COMPILER-INPUTS.json')
            guard.save_json(receipts/'PROFILE-PROOF.json',supplement)
            context['profileProofHash']=guard.digest(receipts/'PROFILE-PROOF.json')
            identity={'baseSDK':config['candidateSDK'],'baseCore':config['candidateCore'],
                'sdkPostimageManifestSHA256':guard.digest(PACKET/'manifests/sdk-profile.json'),
                'corePostimageManifestSHA256':guard.digest(PACKET/'manifests/core-profile.json'),
                'compilerProofSHA256':context['proofHash'],'profileProofSHA256':context['profileProofHash'],
                'retainedCompilerInputsSHA256':context['retainedInputsHash'],
                'binarySHA256':proof['binarySHA256'],'toolchainLogSHA256':guard.digest(version),'argv':argv,'configuration':'release',
                'instrumented':True,'performanceTargetClaimed':False}
            guard.save_json(receipts/'BUILD-IDENTITY.json',identity)
            result['buildIdentitySHA256']=guard.digest(receipts/'BUILD-IDENTITY.json')
            custody()
            result['currentPhase']='profile-B-measurement-and-calibration'
            command('B-profile-settle',[sys.executable,'-c','import time; time.sleep(60)'],root,timeout=90)
            observed=host('B-profile')
            binding.require(all(initial[k]==observed[k] for k in ('bootSession','hostname','operatingSystem','cpuCount')),'allocation continuity changed')
            sources();custody();binding.packet_check(PACKET,args.seal_sha256)
            run_dir=root/'runs/B-profile'
            runner.env.update(LATTICE_PERF_REFINEMENT='1',LATTICE_PERF_RUN_DIR=str(run_dir),
                LATTICE_PERF_SOURCE_REVISION='base-git:'+config['candidateSDK']+';profile-manifest:'+guard.digest(PACKET/'manifests/sdk-profile.json'),
                LATTICE_PERF_CORE_REVISION='base-git:'+config['candidateCore']+';profile-manifest:'+guard.digest(PACKET/'manifests/core-profile.json'),
                LATTICE_PERF_BUILD_IDENTITY='sha256:'+result['buildIdentitySHA256'],
                LATTICE_PERF_HOST_ID='unverified-physical:github-vm:'+':'.join(env.get(k,'') for k in ('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_JOB'))+':'+initial['bootSession'],
                LATTICE_PERF_SAMPLES='100',LATTICE_PERF_WARMUPS='5')
            command('B-profile-benchmark',['swift','test',*common(),'-c','release','--force-resolved-versions','--skip-build',
                '--filter','PerfRefinementBenchmarks/releaseRead100AndUpdate11',*flags],context['sdk'],
                timeout=config['measurementTimeoutSeconds'],require_full_timeout=True)
            analysis=analyze_profile.analyze(run_dir,PACKET/'perf_refinement_report.py')
            guard.save_json(receipts/'PROFILE-ANALYSIS.json',analysis)
            result['analysisSHA256']=guard.digest(receipts/'PROFILE-ANALYSIS.json')
            result['canonicalSamples']=analysis['canonicalSampleCount'];result['calibrationSamples']=analysis['calibrationSampleCount']
            graph('graph-after');sources();custody()
            result['success']=True;result['currentPhase']='finalization'
        except BaseException as error:
            primary=error;result['primaryError']=guard.error_record(error)
            result['stopPolicy']='first failure; no retry, correction, baseline fallback, count change or widened bound'
        finally:
            with interrupts.hold():
                binding.final_evidence(result,[
                    ('packet',lambda:binding.packet_check(PACKET,args.seal_sha256)),
                    ('admission',lambda:binding.admission_check(args.admission_json,args.admission_sha256,config,args.seal_sha256)),
                    ('prerequisites',lambda:binding.config_check(config,PACKET)),
                    ('source-custody',sources),('compiler-custody',custody)],runner.records,receipts,runner,time.monotonic)
                result.update(commands=runner.records,signals=interrupts.received,elapsedSeconds=time.monotonic()-runner.started)
                result['success']=(result['success'] and primary is None and not result['evidenceErrors'] and not interrupts.received
                                   and all(x['success'] for x in runner.records) and time.monotonic()<=runner.overall_deadline)
                try:guard.save_json(receipts/'RESULT.json',result)
                except BaseException as error:
                    result['success']=False
                    print('RESULT_WRITE_FAILED',json.dumps({'result':result,'error':guard.error_record(error)}),flush=True)
    if not result['success']:
        if primary is not None:raise primary
        raise RuntimeError('incomplete diagnostic profile; no accepted profile or performance claim')

if __name__=='__main__':main()
