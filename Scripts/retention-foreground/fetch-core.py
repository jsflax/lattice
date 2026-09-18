from pathlib import Path
import argparse,sys,os,json
P=Path(__file__).resolve().parent;sys.path.insert(0,str(P/'harness'))
from guarded_runner import GuardedRunner,Interrupts,save_json
from prepare import SHA,TREE,verify_harness
parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,required=True);args=parser.parse_args();root=args.root.resolve(strict=True)
assert os.environ.get('GITHUB_ACTIONS')=='true' and '/localdev/' in str(root)
verify_harness();repo=root/'core-objects';assert not repo.exists();repo.mkdir();receipts=root/'fetch-receipts';receipts.mkdir(exist_ok=False)
env=dict(os.environ,TMPDIR=str(root/'tmp'),TMP=str(root/'tmp'),TEMP=str(root/'tmp'),PYTHONDONTWRITEBYTECODE='1')
with Interrupts() as interrupts:
 runner=GuardedRunner(root,receipts,env,interrupts,free_floor=int(12.5*2**30),packet_ceiling=512*2**20,log_ceiling=32*2**20,overall_seconds=150,reserve=15)
 runner.run('init',['git','init',str(repo)],cwd=root,timeout=15)
 runner.run('fetch',['git','fetch','--depth=1','https://github.com/jsflax/LatticeCore.git',SHA],cwd=repo,timeout=90)
 identity=runner.run('identity',['git','show','-s','--format=%H %T',SHA],cwd=repo,timeout=15).read_text().strip()
 assert identity==SHA+' '+TREE
 save_json(receipts/'RESULT.json',{'source':SHA,'tree':TREE,'success':True,'commands':runner.records,'noNativeBuild':True})
