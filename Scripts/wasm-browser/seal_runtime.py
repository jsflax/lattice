"""Seal runtime source bytes; this never qualifies or invents build assets."""
import hashlib,json
from pathlib import Path
FILES=['driver.mjs','run-browser.py','fetch-ci-inputs.py','input_contract.py','fixture.ts','fixture.html',
       'guarded_runner.py','config.json','package.json','package-lock.json','historical-A-original-23.json',
       'node-v20.18.0-SHASUMS256.txt','lifecycle_contract.py','NODE-SKIP-BROWSER-MAPPING.json',
       'audit-fixtures/audit-observation-regressions.ts','audit-fixtures/audit-observation-regressions.html']
def seal(root):
    root=Path(root)
    receipt={'schemaVersion':2,'scope':'corrected candidate runtime source only; historical baseline failed',
             'browserLaunched':False,'qualificationClaim':False,
             'files':{name:{'bytes':(root/name).stat().st_size,'sha256':hashlib.sha256((root/name).read_bytes()).hexdigest()}for name in FILES}}
    target=root/'PREPARATION-RESULT.json';target.write_text(json.dumps(receipt,indent=2)+'\n')
    inputs=json.loads((root/'ci-inputs.json').read_text());inputs['runtimePacketSealSHA256']=hashlib.sha256(target.read_bytes()).hexdigest()
    (root/'ci-inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
    return inputs['runtimePacketSealSHA256']
if __name__=='__main__':print(seal(Path(__file__).parent))
