#!/usr/bin/env python3
"""Offline preparation checks only: no dependency install, browser, server or WASM execution."""
import argparse,ast,hashlib,json,re,subprocess,zipfile
from datetime import datetime,timezone
from pathlib import Path
P=Path(__file__).resolve().parent

def sha(raw):return hashlib.sha256(raw).hexdigest()
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--js-source',type=Path,required=True)
    parser.add_argument('--engram-source',type=Path,required=True)
    parser.add_argument('--wasm-artifact',type=Path,required=True)
    args=parser.parse_args()
    config=json.loads((P/'config.json').read_text())
    result={'createdUTC':datetime.now(timezone.utc).isoformat(),'success':False,'browserLaunched':False,
        'wasmExecuted':False,'typescriptCompiled':False,'checks':[]}
    def checked(name,condition):
        if not condition:raise ValueError(name)
        result['checks'].append(name)
    for name in ['run-browser.py','check-preparation.py','guarded_runner.py']:
        ast.parse((P/name).read_text(),filename=name);result['checks'].append(name+' Python AST')
    subprocess.run(['node','--check',str(P/'driver.mjs')],check=True,capture_output=True)
    result['checks'].append('driver.mjs Node syntax only')
    source=args.js_source.resolve()
    head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()
    status=subprocess.check_output(['git','status','--porcelain=v1','--untracked-files=all'],cwd=source,text=True)
    checked('Exact clean readonly JS source',head==config['jsCommit'] and not status)
    for name,expected in config['jsSourceHashes'].items():checked('JS hash '+name,sha((source/name).read_bytes())==expected)
    names=re.findall(r"await test\('([^']+)'",(source/'test/browser/tests.ts').read_text())
    checked('Exact 23 original ordered case names',names==config['originalCaseNames'] and len(names)==23)
    checked('Frozen supervisor hash',sha((P/'guarded_runner.py').read_bytes())==config['supervisorSHA256'])
    checked('Frozen dedicated npm lock hash',sha((P/'package-lock.json').read_bytes())==config['playwrightLockSHA256'])
    package=json.loads((P/'package.json').read_text());lock=json.loads((P/'package-lock.json').read_text())
    checked('Exact Playwright package pin',package['devDependencies']['playwright']==config['playwrightVersion'])
    previous=json.loads(subprocess.check_output(['git','show','cf9810a:app/package-lock.json'],cwd=args.engram_source))
    for name in ['playwright','playwright-core']:
        row=lock['packages']['node_modules/'+name];older=previous['packages']['node_modules/'+name]
        checked(name+' version/url/integrity join',all(row[key]==older[key] for key in ['version','resolved','integrity']) and row['version']==config['playwrightVersion'])
    result['lockProvenance']={'engramCommit':subprocess.check_output(['git','rev-parse','cf9810a'],cwd=args.engram_source,text=True).strip(),
        'path':'app/package-lock.json','sourceLockSHA256':sha(subprocess.check_output(['git','show','cf9810a:app/package-lock.json'],cwd=args.engram_source)),
        'generatedLockSHA256':config['playwrightLockSHA256'],'generation':'npm install --package-lock-only --ignore-scripts --no-audit --no-fund; dedicated owned prefix/cache; no node_modules/browser installed'}
    checked('Untouched archived WASM artifact hash',sha(args.wasm_artifact.read_bytes())==config['artifactSHA256'])
    assets=[]
    with zipfile.ZipFile(args.wasm_artifact) as archive:
        for arm in ['A','B']:
            for kind in ['js','wasm']:
                expected=config['assets'][arm][kind];raw=archive.read(expected['zipMember'])
                checked(arm+' '+kind+' archived exact bytes',len(raw)==expected['bytes'] and sha(raw)==expected['sha256'])
                assets.append({'arm':arm,'kind':kind,**expected})
    result['assets']=assets
    mapping=json.loads((P/'NODE-SKIP-BROWSER-MAPPING.json').read_text())
    checked('Six skipped Node names mapped to real original browser cases',len(mapping['cases'])==6 and len(set(row['nodeCase'] for row in mapping['cases']))==6 and all(row['browserCases'] and all(name in names for name in row['browserCases']) for row in mapping['cases']))
    checked('No local node_modules or installed browser cache in preparation',not (P/'node_modules').exists() and not (P/'browser-cache').exists())
    result.update(success=True,preparationOnly=True,localChromiumCasesQualified=False,remoteSyncQualified=False,fullBrowserMatrixQualified=False)
    (P/'OFFLINE-CHECKS.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'success':True,'checks':len(result['checks']),'browserLaunched':False}))
if __name__=='__main__':main()
