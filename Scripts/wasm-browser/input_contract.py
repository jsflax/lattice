"""Fail closed until a real exact corrected build artifact has been sealed."""
import hashlib,json,re
SHA=re.compile(r'^[0-9a-f]{64}$')
COMMIT=re.compile(r'^[0-9a-f]{40}$')
def validate_config(config, inputs=None):
    if config.get('artifactInputReady') is not True:
        raise ValueError('Corrected artifact has not been built, authenticated and sealed')
    if config.get('executedArms') != ['B'] or set(config.get('assets',{})) != {'B'}:
        raise ValueError('Candidate-only source identity required')
    for field in ['jsCommit','jsTree','coreB','coreBTree']:
        if not COMMIT.fullmatch(config.get(field,'')):raise ValueError('Missing exact source: '+field)
    if not isinstance(config.get('artifactID'),int) or not isinstance(config.get('wasmCI'),int) or not SHA.fullmatch(config.get('artifactSHA256') or ''):
        raise ValueError('Missing actual artifact receipt')
    for kind in ['js','wasm']:
        value=config['assets']['B'].get(kind)
        if not isinstance(value,dict) or value.get('zipMember')!='B-lattice.'+kind or not SHA.fullmatch(value.get('sha256') or '') or not isinstance(value.get('bytes'),int) or not 0<value['bytes']<=4*1024**2:
            raise ValueError('Missing bounded actual asset: '+kind)
    historical=config['historicalBaseline']
    if historical.get('executedInThisRun') is not False or historical.get('baselineQualified') is not False or historical.get('fullABCompatibility') is not False:
        raise ValueError('Historical failed baseline must remain separately unqualified')
    if inputs is not None:
        if inputs.get('artifactInputReady') is not True:raise ValueError('CI artifact input is not sealed')
        for left,right in [('artifactID','artifactID'),('artifactRunID','wasmCI'),('artifactSHA256','artifactSHA256'),('jsCommit','jsCommit'),('jsTree','jsTree'),('coreCommit','coreB'),('coreTree','coreBTree')]:
            if inputs.get(left)!=config.get(right):raise ValueError('Input/config identity mismatch: '+left)
        for field in ['runtimePacketSealSHA256','builderRunnerSHA256','builderConfigSHA256']:
            if not SHA.fullmatch(inputs.get(field) or ''):raise ValueError('Missing provenance: '+field)
        if not COMMIT.fullmatch(inputs.get('artifactRunHeadSHA') or '') or not isinstance(inputs.get('artifactBytes'),int) or not 0<inputs['artifactBytes']<8*1024**2:
            raise ValueError('Missing bounded actual archive provenance')

def verify_artifact(archive, config, inputs):
    def read(name):
        info=archive.getinfo(name)
        if info.file_size>2*1024**2:raise ValueError('Artifact JSON exceeds bound: '+name)
        return json.loads(archive.read(info))
    result=read('PARTIAL-RESULT.json')
    if str(result['runID'])!=str(inputs['artifactRunID']) or result['workflowCommit']!=inputs['artifactRunHeadSHA'] or result['runnerSHA256']!=inputs['builderRunnerSHA256'] or result['configSHA256']!=inputs['builderConfigSHA256']:
        raise ValueError('Builder source/run provenance mismatch')
    if result.get('fullABCompatibility') is not False or result.get('baselineRerun') is not False:
        raise ValueError('Builder scope mismatch')
    if result.get('evidenceErrors') != [] or result.get('receivedSignals') != []:
        raise ValueError('Builder finalization or interruption evidence is incomplete')
    arm=read('B-PARTIAL-RESULT.json')
    if result.get('arms') != {'B':arm}:
        raise ValueError('Top-level candidate arm differs from retained arm receipt')
    if not arm.get('buildArtifactsReady') or not arm.get('finalSourceVerified') or arm.get('evidenceErrors'):
        raise ValueError('Candidate build/source gate incomplete')
    for label,commit,tree in [('js',config['jsCommit'],config['jsTree']),('core',config['coreB'],config['coreBTree'])]:
        before=read('B-'+label+'-initial-source.json');after=read('B-'+label+'-final-source.json')
        if before!=after or before['commit']!=commit or before['tree']!=tree:
            raise ValueError('Build input changed or wrong source: '+label)
    js=read('B-js-initial-source.json');core=read('B-core-initial-source.json')
    proof=read('B-compiler-input-proof.json')
    if proof['jsBinding']['sha256']!=js['files']['wasm/bindings.cpp']['sha256']:
        raise ValueError('Actual JS binding compiler input mismatch')
    if not proof['files'] or any(core['files'][name]['sha256']!=value for name,value in proof['files'].items()):
        raise ValueError('Actual Core compiler input mismatch')
    for label in ['B-wasm-build','B-typescript-build']:
        command=read(label+'.json')
        if not command.get('success') or command.get('exitCode')!=0 or command.get('evidenceErrors') or not command.get('cleanup',{}).get('groupGone'):
            raise ValueError('Build command unqualified: '+label)
    for kind in ['js','wasm']:
        expected=config['assets']['B'][kind];produced=arm['artifacts']['lattice.'+kind]
        if produced!=expected:raise ValueError('Produced asset receipt differs: '+kind)
        info=archive.getinfo(expected['zipMember'])
        if info.file_size!=expected['bytes'] or hashlib.sha256(archive.read(info)).hexdigest()!=expected['sha256']:
            raise ValueError('Actual produced bytes differ: '+kind)
    # Node skips remain unqualified. Only build/source/asset proof is consumed.
    return {'buildArtifactsReady':True,'jsCommit':js['commit'],'coreCommit':core['commit'],
            'nodeAllNamedCasesPassed':arm['nodeAllNamedCasesPassed'],'nodeTestCounts':arm.get('nodeTestCounts'),
            'nodeNonPassing':arm.get('nodeNonPassing'),'fullABCompatibility':False}
