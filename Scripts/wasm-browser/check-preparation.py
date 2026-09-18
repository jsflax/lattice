"""Small source checks only: no dependencies, browser, server or WASM execution."""
import ast,hashlib,json,sys
from pathlib import Path
P=Path(__file__).parent
sys.dont_write_bytecode=True
from input_contract import validate_config
checks=[]
for file in sorted(P.glob('*.py')):
    ast.parse(file.read_text());checks.append('AST '+file.name)
config=json.loads((P/'config.json').read_text());inputs=json.loads((P/'ci-inputs.json').read_text())
assert config['executedArms']==['B']
assert len(config['originalCaseNames'])==23 and len(set(config['originalCaseNames']))==23
assert config['jsSourceHashes']['test/browser/tests.ts']=='15bc899a8cff25a93181a163fb277dce44f19c5f372b71374ef636bd12725e0e'
assert config['regressionCaseNames']==['audit_fields_memory_transaction','audit_fields_persistent_transaction','audit_link_rows_once_persistent','audit_unsubscribe_queued_and_idempotent','audit_unsubscribe_inside_callback','audit_close_suppresses_queued_callback']
checks.append('Only B; original23 bytes frozen; six exact names')
historical=(P/config['historicalBaseline']['receipt']).read_bytes()
assert hashlib.sha256(historical).hexdigest()==config['historicalBaseline']['receiptSHA256']
cases=json.loads(historical)['cases']
assert {s:sum(c['status']==s for c in cases)for s in ['pass','fail','skip']}=={'pass':21,'fail':2,'skip':0}
checks.append('Historical baseline remains21pass2fail0skip')
seal_bytes=(P/'PREPARATION-RESULT.json').read_bytes()
assert hashlib.sha256(seal_bytes).hexdigest()==inputs['runtimePacketSealSHA256']
for name,expected in json.loads(seal_bytes)['files'].items():
    data=(P/name).read_bytes();assert len(data)==expected['bytes'] and hashlib.sha256(data).hexdigest()==expected['sha256']
checks.append('Every runtime input matches its source seal')
if config['artifactInputReady']:
    validate_config(config,inputs);checks.append('Actual artifact fields complete; runtime reauthenticates archive')
else:
    try:validate_config(config,inputs)
    except ValueError as error:assert 'has not been built' in str(error)
    else:raise AssertionError('Unbuilt candidate artifact was accepted')
    checks.append('Pending artifact rejected before runtime setup')
result={'sourceChecksPassed':True,'checks':checks,'readyForRuntime':config['artifactInputReady'],'browserLaunched':False,'buildExecuted':False,'browserCandidateQualified':False,'fullABCompatibility':False,'baselineQualified':False,'releaseGraphAccepted':False}
(P/'OFFLINE-CHECKS.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'sourceChecks':len(checks),'readyForRuntime':config['artifactInputReady']}))
