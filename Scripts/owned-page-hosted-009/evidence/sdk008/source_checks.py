"""SDK007 source custody; no subprocess, compiler, resolver, database or network."""
from pathlib import Path
import ast
import hashlib
import importlib.util
import json

P=Path(__file__).resolve().parent
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
J=lambda p:json.loads(p.read_text())
PREVIOUS='86af87df1cbb10b688a8edc6f080775860ebdcc3799880120273d8adad7c5266'

def fresh_roots(config, *, require_no_runtime, require_no_owner):
    if require_no_runtime:
        assert not Path(config['runtimeRoot']).exists(), 'fresh runtime root required'
    if require_no_owner:
        assert not Path(config['runtimeRoot']+'-owner').exists(), 'fresh owner directory required before launch'

def verify(*, require_no_runtime=True, require_no_owner=False):
    old=P.with_name('owned-page-sdk-qualification-006')
    assert H(old/'SOURCE-READY.json')==PREVIOUS
    ready=J(old/'SOURCE-READY.json')
    for name,digest in ready['files'].items():
        q=old/name
        assert q.is_file() and not q.is_symlink() and H(q)==digest,name
    spec=importlib.util.spec_from_file_location('sdk006_source',old/'source_checks.py')
    prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
    prior.verify(require_no_runtime=False)
    changed={'ACCEPTANCE.md','COMMANDS.json','CONFIG.json','README.md','SOURCE-CHECKS.json',
             'SOURCE-DELTA.json','SUCCESSOR.patch','PURE-CHECKS.log','source_checks.py',
             'qualify.py','guarded_runner.py','test_preparation.py'}
    for name,digest in ready['files'].items():
        if name not in changed:assert H(P/name)==digest,name
    normalize=lambda s:s.replace('owned-page-sdk-qualification-008','owned-page-sdk-qualification-006')
    assert normalize((P/'CONFIG.json').read_text())==(old/'CONFIG.json').read_text()
    assert normalize((P/'COMMANDS.json').read_text())==(old/'COMMANDS.json').read_text()
    tests=normalize((P/'test_preparation.py').read_text()).replace("'ownedDescendantsGone':True,",'')
    assert tests==(old/'test_preparation.py').read_text(),'old cases preserved; only receipt fixture/path changed'
    extract=lambda p:{n.name:ast.get_source_segment(p.read_text(),n) for n in ast.parse(p.read_text()).body if isinstance(n,(ast.FunctionDef,ast.ClassDef))}
    before,after=extract(old/'qualify.py'),extract(P/'qualify.py')
    assert set(before)==set(after)
    assert {n for n in before if before[n]!=after[n]}=={'source_packet','clean','main'}
    c=J(P/'CONFIG.json')
    fresh_roots(c, require_no_runtime=require_no_runtime, require_no_owner=require_no_owner)
    return {'sourceOnly':True,'predecessorSeal':PREVIOUS,'productSourcesChanged':False,
            'allLimitsUnchanged':True,'allCommandsOnlyOwnedPathsChanged':True,
            'old43PureChecksPreserved':True,'original26And9Preserved':True,
            'sourceCounts':c['sourceCounts'],'runtimeAbsent':not Path(c['runtimeRoot']).exists(),
            'executionAdmitted':False}

if __name__=='__main__':print(json.dumps(verify(),indent=2,sort_keys=True))
