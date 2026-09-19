"""Narrow diagnostic bindings; original complete-source and command checks reused."""
from pathlib import Path
import json
import re
import frozen_binding as frozen
import guarded_runner as guard

require, digest, complete_sources, command_check = frozen.require, frozen.digest, frozen.complete_sources, frozen.command_check
HEX64 = frozen.HEX64
SDK = '96a5bf0256f81691a92d98cb8fe24b54e00de811'
CORE = 'd1e06f4b74ffc76410a9e59f062117c160e191b6'

def manifest(packet, side, kind='profile'):
    return json.loads((packet/'manifests'/(side+'-'+kind+'.json')).read_text())

def packet_check(packet, expected):
    require(HEX64.fullmatch(expected or '') and digest(packet/'PACKET-SEAL.json')==expected,'exact reviewed packet seal required')
    seal=json.loads((packet/'PACKET-SEAL.json').read_text())
    required={'run-profile.py','profile_binding.py','profile_proof.py','guarded_runner.py','build_proof.py','frozen_binding.py',
              'CONFIG.json','SDK.patch','Core.patch','analyze_profile.py','perf_refinement_report.py',
              'manifests/sdk-base.json','manifests/core-base.json','manifests/sdk-profile.json','manifests/core-profile.json'}
    require(required<=set(seal['files']),'required packet input absent')
    for name,expected_hash in seal['files'].items():
        p=packet/name
        require(p.is_file() and not p.is_symlink() and p.resolve().is_relative_to(packet.resolve()),'unsafe packet input')
        require(digest(p)==expected_hash,'packet input changed: '+name)
    return seal

def prerequisites(packet, config):
    evidence=packet/'evidence'
    for name,sha in config['prerequisites'].items():require(digest(evidence/name)==sha,'historical prerequisite drift: '+name)
    load=lambda n:json.loads((evidence/n).read_text())
    sdk,core=load('sdk-parent.json'),load('core-parent.json')
    require(sdk['accepted'] is True and sdk['sdkCommit']==SDK and sdk['coreCommit']==CORE
            and sdk['sdkTree']==config['candidateSDKTree'] and sdk['coreTree']==config['candidateCoreTree'], 'exact SDK96 full gate absent')
    require(sdk['run']==35428388263 and sdk['runAttempt']==1,'SDK historical run identity changed')
    for side,field in [('macos','parentMacOSAssessmentSHA256'),('linux','parentLinuxAssessmentSHA256')]:
        child=load('sdk-'+side+'.json')
        require(sdk[field]==digest(evidence/('sdk-'+side+'.json')) and child['sdkCommit']==SDK and child['coreCommit']==CORE,
                'SDK platform receipt join')
        require(child['acceptedMacOSDevelopmentLeg' if side=='macos' else 'acceptedLinuxDevelopmentLeg'] is True,'SDK platform not accepted')
    require(core['accepted'] is True and core['candidate']==CORE and core['tree']==config['candidateCoreTree']
            and core['failureCount']==core['skipCount']==0,'exact Core d1 full gate absent')
    for filename,field in [('core-native.json','nativeAssessmentSHA256'),('core-cabi.json','capiAssessmentSHA256')]:
        child=load(filename)
        require(core[field]==digest(evidence/filename) and child['accepted'] is True
                and child['candidate']==CORE and child['tree']==config['candidateCoreTree'],'Core platform receipt join')
    parent,peer=load('profile-parent-review.json'),load('profile-peer-review.json')
    source=load('profile-source-ready.json');source_hash=digest(evidence/'profile-source-ready.json')
    require(source_hash==config['profileSourceReadySHA256'] and parent['sourceReadySHA256']==source_hash
            and peer['sourceReadySHA256']==source_hash and parent['sourceAccepted'] is True
            and peer['sourceReviewed'] is True and not peer['blockingSourceFindings'],'profile source reviews absent')
    for label,side in [('SDK','sdk'),('Core','core')]:
        effective,base=manifest(packet,side),manifest(packet,side,'base')
        require(effective['commit']==base['commit']==config['candidate'+label]
                and effective['tree']==base['tree']==config['candidate'+label+'Tree'],'base manifest identity')
        require(effective['patchSHA256']==digest(packet/(label+'.patch'))==source['inputs'][label+'.patch'],'reviewed patch identity')
        expected={**base['files'],**effective['diagnosticOverlay']}
        require(effective['files']==expected,'only sealed overlay may differ from base')
        reviewed={Path(k).as_posix():v for k,v in source['postimages'].items()}
        for name,row in effective['diagnosticOverlay'].items():
            matches=[sha for path,sha in reviewed.items() if path.endswith('/'+name)]
            require(matches==[row['sha256']],'postimage not source-reviewed: '+name)
    return {'sdk':digest(evidence/'sdk-parent.json'),'core':digest(evidence/'core-parent.json'), 'profileSource':source_hash,
            'historicalOnly':True,'newProfileBuildOrRuntimeCredit':False}

def config_check(config, packet):
    require(config['candidateSDK']==SDK and config['candidateCore']==CORE,'base graph changed')
    require(config['scope']=='diagnostic-profile-B-only' and config['performanceTargetClaimed'] is False
            and config['physicalHostQualified'] is False,'diagnostic scope changed')
    fixed={'measuredSamples':100,'warmups':5,'canonicalSamples':210,'calibrationSamples':16,'settlingSeconds':60,
           'freeFloorBytes':12*2**30,'packetCeilingBytes':30*2**30,'logCeilingBytes':512*2**20,
           'overallSeconds':18000,'finalizationReserveSeconds':600,'buildTimeoutSeconds':5400,'measurementTimeoutSeconds':1200}
    require(all(config[k]==v for k,v in fixed.items()) and config['variants']==['local','attached'],'frozen counts/limits changed')
    for name,sha in config['reuse'].items():require(digest(packet/name)==sha,'reused helper changed: '+name)
    require(set(config['allowedSDKChanges'])=={'Tests/CLatticeTestSQLite/shim.h','Tests/LatticeTests/PerfRefinementBenchmarks.swift'},'SDK overlay scope')
    require(set(config['allowedCoreChanges'])=={'Sources/LatticeCore/src/db.cpp','Sources/LatticeCore/src/perf_live_profile.hpp',
                                             'Sources/LatticeCore/include/lattice/perf_live_profile.h'},'Core overlay scope')
    return prerequisites(packet,config)

def admission_check(path, expected_hash, config, seal):
    require(HEX64.fullmatch(expected_hash or '') and digest(path)==expected_hash,'admission hash changed')
    require(path.is_file() and not path.is_symlink() and path.stat().st_size<=32768,'bounded real admission file required')
    value=json.loads(path.read_text())
    require(value.get('scope')==config['scope'] and value.get('approved') is True and value.get('runOnce') is True,'diagnostic owner admission missing')
    require(value.get('packetSealSHA256')==seal and value.get('sdkCommit')==SDK and value.get('coreCommit')==CORE
            and value.get('profileSourceReadySHA256')==config['profileSourceReadySHA256'],'admission source/seal mismatch')
    require(value.get('sdkPrerequisiteSHA256')==config['prerequisites']['sdk-parent.json']
            and value.get('corePrerequisiteSHA256')==config['prerequisites']['core-parent.json'],'admission prerequisite mismatch')
    require(value.get('physicalHostQualified') is False and value.get('performanceTargetClaimed') is False,'nonqualifying scope required')
    require(isinstance(value.get('ownerAllocation'),str) and 1<=len(value['ownerAllocation'])<=4096,'explicit owner allocation reference required')
    return value


def verify_graph(runner, label, graph, original, core, core_sha, scratch, expected_core):
    # Exact original guard.verify_graph logic; sole delta is allowing the three
    # Core diagnostic edits only when the complete postimage inventory matches.
    nodes = guard.graph_nodes(graph)
    if set(nodes) != set(original):
        raise ValueError('effective graph identities do not equal all committed lock identities')
    state = json.loads((scratch / 'workspace-state.json').read_text())
    entries = state['object']['dependencies']
    dependencies = {entry['packageRef']['identity']: entry for entry in entries}
    if len(dependencies) != len(entries) or set(dependencies) != set(original):
        raise ValueError('workspace state identities do not equal committed lock identities')
    rows = []
    for identity in sorted(original):
        pin, node, entry = original[identity], nodes[identity], dependencies[identity]
        path = Path(node['path']).resolve(strict=True)
        if identity == 'latticecore':
            if path != core.resolve() or entry['state']['name'] != 'edited':
                raise ValueError('Core is not the sole explicit edited checkout')
            expected_revision = core_sha
        else:
            if entry['state']['name'] != 'sourceControlCheckout':
                raise ValueError('unexpected edited/local dependency: ' + identity)
            if entry['state']['checkoutState'] != pin['state']:
                raise ValueError('workspace revision/version differs from committed pin: ' + identity)
            expected_path = (scratch / 'checkouts' / entry['subpath']).resolve(strict=True)
            if not expected_path.is_relative_to((scratch / 'checkouts').resolve()) or path != expected_path:
                raise ValueError('dependency graph uses an unexpected checkout path: ' + identity)
            if guard.url_key(node['url']) != guard.url_key(pin['location']):
                raise ValueError('dependency graph URL differs from committed pin: ' + identity)
            expected_revision = pin['state']['revision']
        if guard.url_key(entry['packageRef']['location']) != guard.url_key(pin['location']):
            raise ValueError('workspace source location differs from committed pin: ' + identity)
        head = runner.run(label + '-' + identity + '-head', ['git', 'rev-parse', 'HEAD'], cwd=path, timeout=60).read_text().strip()
        dirty = runner.run(label + '-' + identity + '-status', ['git', 'status', '--porcelain=v1', '--untracked-files=all'], cwd=path, timeout=60).read_text()
        if head != expected_revision or (dirty and identity != 'latticecore'):
            raise ValueError('effective checkout revision/source mismatch: ' + identity)
        if identity == 'latticecore':complete_sources(core, expected_core)
        rows.append({'identity': identity, 'path': str(path), 'revision': head,
                     'location': pin['location'], 'workspaceState': entry['state']})
    guard.save_json(runner.receipts / (label + '.json'), rows)
    return rows


def final_evidence(result, operations, records, receipts, runner, monotonic):
    """Independent attempts: one failed command cannot skip resources/deadline."""
    def attempt(name, action):
        try:result.setdefault('finalChecks',{})[name]=action()
        except BaseException as error:
            result['evidenceErrors'].append({'operation':name,**guard.error_record(error)})
    for name,action in operations:attempt(name,action)
    for record in list(records):attempt('command-'+record['label'],lambda record=record:command_check(receipts,record['label']))
    def resources():
        value=runner.measure(receipts/'RESULT.json');result['finalResources']=value
        require(not runner.violation(value),'final resource guard')
        return value
    attempt('resources',resources)
    attempt('absolute-deadline',lambda:require(monotonic()<=runner.overall_deadline,'absolute deadline exceeded'))


def retain_compiler_inputs(proof, supplement, destination):
    """Retain small actual stable lists/maps/response files for artifact audit."""
    require(not destination.exists(),'compiler input retention must be fresh')
    wanted=dict(proof['nativeResponseFiles'])
    wanted.update(supplement['responseFiles'])
    for item in proof['swiftModules'].values():wanted[item['outputMap']]=item['outputMapSHA256']
    for link in proof['linkGraph'].values():
        for item in link['lists']:wanted[item['path']]=item['SHA256']
    require(len(wanted)<=512,'compiler input-copy count cap')
    destination.mkdir(exist_ok=False)
    rows={}
    for index,(name,sha) in enumerate(sorted(wanted.items())):
        path=Path(name)
        require(path.is_file() and not path.is_symlink() and path.stat().st_size<=4*2**20,'bounded regular compiler input required')
        require(digest(path)==sha,'compiler input changed before retention')
        retained=destination/(str(index).zfill(4)+'-'+path.name)
        with retained.open('xb') as output:output.write(path.read_bytes())
        require(digest(retained)==sha,'compiler input changed during retention')
        rows[name]={'retained':str(retained),'sha256':sha}
    return rows

def verify_retained_inputs(rows):
    for name,row in rows.items():
        require(digest(Path(name))==row['sha256']==digest(Path(row['retained'])),'retained compiler input drift')
    return {'retainedCompilerInputs':len(rows)}
