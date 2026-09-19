"""Local source-only assembly; no compiler, resolver, database or network."""
from pathlib import Path
import hashlib,json,shutil,subprocess
P=Path(__file__).resolve().parent
B=P.parents[2]
OLD=P.with_name('owned-page-sdk-qualification-008')
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def put(path,value):
 path.parent.mkdir(parents=True,exist_ok=True)
 path.write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')
ready=json.loads((OLD/'SOURCE-READY.json').read_text())
for name,digest in ready['files'].items():
 assert H(OLD/name)==digest,name
 target=P/'evidence/sdk008'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(OLD/name,target)
shutil.copy2(OLD/'SOURCE-READY.json',P/'evidence/sdk008/SOURCE-READY.json')
review=OLD.with_name(OLD.name+'-review')/'INDEPENDENT-REVIEW.json'
shutil.copy2(review,P/'evidence/SDK008-INDEPENDENT-REVIEW.json')
for name in ['build_proof.py','guarded_runner.py','process_custody.py','detached_owner.py','runtime_oracles.py','sdk_test_oracles.py','test_build_proof_005.py','test_preparation.py','test_lifecycle.py','EXPECTED-TESTS.json','SDK-SOURCE-MANIFEST.json','CORE-SOURCE-MANIFEST.json','Package.resolved.original']:
 shutil.copy2(OLD/name,P/name)
shutil.copytree(OLD/'overlay',P/'overlay',dirs_exist_ok=True)
shutil.copytree(OLD/'fixtures',P/'fixtures',dirs_exist_ok=True)
c=json.loads((OLD/'CONFIG.json').read_text());original_root=c['runtimeRoot']
keys=['actualSwiftDriverJobs','buildSystem','clang','cxxStdlibInterface','expectedNativeBinRelative','flags','freshCompilationRequired','macosSDK','nativeABI','originalCases9','proposedLimits','sdkCommit','sdkTree','sourceCounts','swiftFeature','swiftc','unsetEnvironment']
config={k:c[k] for k in keys}
config.update(schemaVersion=1,scope='HELD hosted009 fresh SDK070/private Core919 FRT1 Debug qualification; exact26 fake-source plus9 direct cases',runtimeRoot='@RUNTIME@',ownedEnvironment=json.loads(json.dumps(c['ownedEnvironment']).replace(original_root,'@RUNTIME@')),runtimeEnvironment=json.loads(json.dumps(c['runtimeEnvironment']).replace(original_root,'@RUNTIME@')),sdkURL='https://github.com/jsflax/lattice.git',coreURL='https://github.com/jsflax/LatticeCore.git',coreBaseCommit='a09e622e4da3f603698d9f1069d6118e79397b2e',coreBaseTree='b77b51371ff107a81a05a4d5c259683f65120f4b',privateCoreSourceManifestSHA256=c['privateCoreSourceManifestSHA256'],toolIdentityPolicy='fresh hosted exact-byte binding, explicitly different from local SDK008 Xcode identity',toolPaths=sorted(json.loads((OLD/'EXTERNAL-INPUTS.json').read_text()).keys())[:0],executionAdmitted=False,resourceAdmission=False,publicActivation=False,FRT0OrIOSQualified=False)
config['toolPaths']=[x for x in json.loads((OLD/'EXTERNAL-INPUTS.json').read_text()) if x.startswith('/Applications/')]
put(P/'CONFIG.json',config)
put(P/'COMMANDS.json',json.loads((OLD/'COMMANDS.json').read_text().replace(original_root,'@RUNTIME@')))
repo=B/'execution/core-managed-route-004';base=config['coreBaseCommit']
rows=subprocess.check_output(['git','-C',str(repo),'ls-tree','-r','-z',base]).split(b'\0')
entries={}
for row in rows:
 if row:
  left,name=row.split(b'\t');mode,kind,oid=left.split();assert kind==b'blob';entries[name.decode()]=(mode.decode(),oid.decode())
proc=subprocess.Popen(['git','-C',str(repo),'cat-file','--batch'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
base_files={}
for name,(_,oid) in entries.items():
 proc.stdin.write(oid.encode()+b'\n');proc.stdin.flush();header=proc.stdout.readline().split();data=proc.stdout.read(int(header[2]));assert proc.stdout.read(1)==b'\n';base_files[name]=hashlib.sha256(data).hexdigest()
proc.stdin.close();assert proc.wait()==0
put(P/'CORE-BASE-MANIFEST.json',base_files)
effective=json.loads((P/'CORE-SOURCE-MANIFEST.json').read_text());assert set(base_files)<=set(effective)
changed={k:v for k,v in effective.items() if base_files.get(k)!=v}
for name,digest in changed.items():
 source=Path(c['privateCoreSource'])/name;assert H(source)==digest
 target=P/'core-postimages'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
put(P/'CORE-POSTIMAGES.json',changed)
put(P/'PRESERVATION.json',{'SDK008SealSHA256':H(OLD/'SOURCE-READY.json'),'SDK008ReviewSHA256':H(review),'SDK008SourceFiles':ready['files'],'reusedExactFiles':{n:H(P/n) for n in ['build_proof.py','guarded_runner.py','process_custody.py','detached_owner.py','runtime_oracles.py','sdk_test_oracles.py','EXPECTED-TESTS.json','SDK-SOURCE-MANIFEST.json','CORE-SOURCE-MANIFEST.json','Package.resolved.original']},'SDK008RuntimeRoot':original_root,'baseCoreFiles':len(base_files),'privateCoreFiles':len(effective),'corePostimages':len(changed),'noProductChanges':True,'allResourceLimitsUnchanged':True})
print(json.dumps({'privateCoreFiles':len(effective),'baseCoreFiles':len(base_files),'corePostimages':len(changed),'sdk008Seal':H(OLD/'SOURCE-READY.json')}))
