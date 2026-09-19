"""Review step: seal actual downloaded artifact evidence; no download, build or launch."""
import argparse,hashlib,json,zipfile,re
from pathlib import Path
from input_contract import validate_config,verify_artifact
from seal_runtime import seal
p=Path(__file__).parent
parser=argparse.ArgumentParser()
parser.add_argument('--metadata',type=Path,required=True)
parser.add_argument('--archive',type=Path,required=True)
parser.add_argument('--workflow-commit',required=True)
parser.add_argument('--run-id',type=int,required=True)
a=parser.parse_args()
if not re.fullmatch(r'[0-9a-f]{40}',a.workflow_commit):raise ValueError('Exact expected builder workflow commit is required')
metadata=json.loads(a.metadata.read_text());run=metadata.get('workflow_run',{})
if metadata.get('expired') is not False or run.get('id')!=a.run_id or run.get('head_sha')!=a.workflow_commit:
    raise ValueError('Artifact API receipt does not match the expected builder run/source')
if not 0<metadata['size_in_bytes']<8*1024**2 or a.archive.stat().st_size!=metadata['size_in_bytes']:
    raise ValueError('Artifact archive size mismatch or exceeds bound')
hash_=hashlib.sha256(a.archive.read_bytes()).hexdigest()
if metadata.get('digest')!='sha256:'+hash_:raise ValueError('Artifact archive digest mismatch')
config=json.loads((p/'config.json').read_text());inputs=json.loads((p/'ci-inputs.json').read_text())
if config.get('artifactInputReady') is True or (p/'ARTIFACT-BINDING.json').exists():raise ValueError('Artifact binding is one-shot; preserve an already sealed input')
with zipfile.ZipFile(a.archive)as z:
    info=z.getinfo('B-PARTIAL-RESULT.json')
    if info.file_size>2*1024**2:raise ValueError('Build receipt too large')
    candidate=json.loads(z.read(info))
    config.update(artifactInputReady=True,artifactID=metadata['id'],wasmCI=a.run_id,artifactSHA256=hash_,
                  assets={'B':{'js':candidate['artifacts']['lattice.js'],'wasm':candidate['artifacts']['lattice.wasm']}})
    inputs.update(artifactInputReady=True,artifactID=metadata['id'],artifactRunID=a.run_id,
                  artifactRunHeadSHA=a.workflow_commit,artifactBytes=metadata['size_in_bytes'],artifactSHA256=hash_)
    validate_config(config)
    proof=verify_artifact(z,config,inputs)
# Persist only after every new archive/source/compiler/asset assertion passed.
(p/'config.json').write_text(json.dumps(config,indent=2)+'\n')
(p/'ci-inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
runtime_seal=seal(p)
validate_config(config,json.loads((p/'ci-inputs.json').read_text()))
with (p/'ARTIFACT-BINDING.json').open('x')as output:
    json.dump({'metadataSHA256':hashlib.sha256(a.metadata.read_bytes()).hexdigest(),'archiveSHA256':hash_,
               'artifactID':metadata['id'],'runID':a.run_id,'workflowCommit':a.workflow_commit,
               'proof':proof,'runtimePacketSealSHA256':runtime_seal,'browserLaunched':False},output,indent=2)
    output.write('\n')
print(runtime_seal)
