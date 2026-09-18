#!/usr/bin/env python3
"""Authenticate previously built WASM archive and exact JS source; no compilation/browser."""
import argparse,hashlib,importlib.util,json,os,platform,shutil,tarfile,time,zipfile
from pathlib import Path
P=Path(__file__).resolve().parent

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,required=True);args=parser.parse_args()
    if platform.system()!='Linux' or platform.machine()!='x86_64':raise ValueError('Pinned Linux x64 toolchain required')
    config=json.loads((P/'config.json').read_text());inputs=json.loads((P/'ci-inputs.json').read_text())
    seal_bytes=(P/'PREPARATION-RESULT.json').read_bytes()
    if hashlib.sha256(seal_bytes).hexdigest()!=inputs['runtimePacketSealSHA256']:raise ValueError('Runtime preparation seal mismatch')
    for name,expected in json.loads(seal_bytes)['files'].items():
        raw=(P/name).read_bytes()
        if len(raw)!=expected['bytes'] or hashlib.sha256(raw).hexdigest()!=expected['sha256']:raise ValueError('Sealed runtime input changed: '+name)
    checksum_bytes=(P/'node-v20.18.0-SHASUMS256.txt').read_bytes()
    if hashlib.sha256(checksum_bytes).hexdigest()!=inputs['node']['checksumSourceSHA256'] or (inputs['node']['sha256']+'  '+inputs['node']['archive']) not in checksum_bytes.decode().splitlines():raise ValueError('Official Node checksum receipt mismatch')
    if hashlib.sha256((P/'guarded_runner.py').read_bytes()).hexdigest()!=config['supervisorSHA256']:raise ValueError('Supervisor mismatch')
    if inputs['artifactID']!=config['artifactID'] or inputs['artifactRunID']!=config['wasmCI'] or inputs['artifactSHA256']!=config['artifactSHA256'] or inputs['jsCommit']!=config['jsCommit']:raise ValueError('CI inputs diverge from frozen runtime inputs')
    spec=importlib.util.spec_from_file_location('guarded_runner',P/'guarded_runner.py');guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)
    root=args.root.resolve();localdev=(Path.home()/'localdev').resolve()
    if not root.is_relative_to(localdev) or root==localdev or root.exists():raise ValueError('New owned localdev input root required')
    root.mkdir(parents=True);receipts=root/'receipts';receipts.mkdir();(root/'tmp').mkdir()
    env=os.environ.copy();env.update(TMPDIR=str(root/'tmp'),TMP=str(root/'tmp'),TEMP=str(root/'tmp'),PYTHONDONTWRITEBYTECODE='1')
    result={'success':False,'browserLaunched':False,'compiled':False,'inputs':inputs,'errors':[]};primary=None
    with guard.Interrupts() as interrupts:
        runner=guard.GuardedRunner(root,receipts,env,interrupts,free_floor=config['freeFloorBytes'],packet_ceiling=384*1024*1024,log_ceiling=8*1024*1024,overall_seconds=480,reserve=30,signal_grace=20)
        def command(label,argv,cwd=root,timeout=120):return runner.run(label,argv,cwd=cwd,timeout=timeout)
        try:
            node=inputs['node']
            if node['version']!=config['nodeVersion']:raise ValueError('Node input mismatch')
            node_archive=root/node['archive']
            command('node-download',['curl','--fail','--location','--silent','--show-error','--max-time','120','--max-filesize','67108864','--output',str(node_archive),node['url']],timeout=150)
            if node_archive.stat().st_size>64*1024*1024 or guard.digest(node_archive)!=node['sha256']:raise ValueError('Official Node archive hash/size mismatch')
            with tarfile.open(node_archive) as tar:
                members=tar.getmembers()
                if sum(member.size for member in members)>256*1024*1024:raise ValueError('Node extraction ceiling')
                for member in members:
                    name=Path(member.name)
                    if name.is_absolute() or '..' in name.parts or name.parts[0]!='node-v20.18.0-linux-x64' or not (member.isdir() or member.isfile() or member.issym() or member.islnk()):raise ValueError('Unsafe Node archive member')
                tar.extractall(root,members=members,filter='data')
            node_binary=root/'node-v20.18.0-linux-x64/bin/node'
            if command('node-version',[str(node_binary),'--version']).read_text().strip()!='v'+config['nodeVersion']:raise ValueError('Installed Node version mismatch')
            result['node']={**node,'archiveBytes':node_archive.stat().st_size,'executableSHA256':guard.digest(node_binary),'path':str(node_binary)}
            metadata_log=command('artifact-metadata',['gh','api',f"repos/{inputs['repository']}/actions/artifacts/{inputs['artifactID']}"])
            metadata=json.loads(metadata_log.read_text());run=metadata.get('workflow_run',{})
            if metadata.get('id')!=inputs['artifactID'] or metadata.get('expired') is not False or metadata.get('size_in_bytes')!=inputs['artifactBytes'] or metadata.get('digest')!='sha256:'+inputs['artifactSHA256'] or run.get('id')!=inputs['artifactRunID'] or run.get('head_sha')!=inputs['artifactRunHeadSHA']:raise ValueError('Artifact API metadata/source join failed')
            raw=command('artifact-download',['gh','api',f"repos/{inputs['repository']}/actions/artifacts/{inputs['artifactID']}/zip"])
            if raw.stat().st_size!=inputs['artifactBytes'] or guard.digest(raw)!=inputs['artifactSHA256']:raise ValueError('Downloaded archive size/hash mismatch')
            artifact=root/'artifact-10544642780.zip';shutil.copyfile(raw,artifact)
            asset_proof={}
            with zipfile.ZipFile(artifact) as archive:
                for arm in ['A','B']:
                    for kind in ['js','wasm']:
                        expected=config['assets'][arm][kind];info=archive.getinfo(expected['zipMember'])
                        if info.file_size!=expected['bytes'] or info.file_size>4*1024*1024:raise ValueError('Asset member size mismatch')
                        if hashlib.sha256(archive.read(info)).hexdigest()!=expected['sha256']:raise ValueError('Asset member hash mismatch')
                        asset_proof[arm+'-'+kind]=expected
            source=root/'LatticeJS';command('js-init',['git','init',str(source)])
            command('js-fetch',['git','fetch','--depth=1',inputs['jsRepository'],inputs['jsCommit']],source,timeout=180)
            command('js-checkout',['git','checkout','--detach',inputs['jsCommit']],source)
            identity=command('js-identity',['git','show','--no-patch','--format=%H %T','HEAD'],source).read_text().strip().split()
            if identity[0]!=inputs['jsCommit']:raise ValueError('Exact JS head mismatch')
            if command('js-status',['git','status','--porcelain=v1','--untracked-files=all'],source).read_text():raise ValueError('Fetched source is dirty')
            for name,expected in config['jsSourceHashes'].items():
                if guard.digest(source/name)!=expected:raise ValueError('Source inventory mismatch: '+name)
            result.update(success=True,artifact={'path':str(artifact),'bytes':artifact.stat().st_size,'sha256':guard.digest(artifact)},assets=asset_proof,js={'commit':identity[0],'tree':identity[1]},sourceHashes=config['jsSourceHashes'])
        except BaseException as error:primary=error;result['errors'].append(guard.error_record(error))
        finally:
            with interrupts.hold():
                try:
                    result['finalResources']=runner.measure(receipts/'RESULT.json')
                    if runner.violation(result['finalResources']):raise ValueError('Final input resource guard failed')
                except BaseException as error:result['errors'].append(guard.error_record(error))
                result.update(commands=runner.records,signals=interrupts.received,elapsedSeconds=time.monotonic()-runner.started)
                result['success']=result['success'] and not result['errors'] and not interrupts.received and all(row['success'] for row in runner.records) and time.monotonic()<=runner.overall_deadline
                guard.save_json(receipts/'RESULT.json',result)
    if not result['success']:
        if primary:raise primary
        raise RuntimeError('CI input authentication failed')
if __name__=='__main__':main()
