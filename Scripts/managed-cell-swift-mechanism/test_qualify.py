import copy
import ast
from pathlib import Path
import unittest
import qualify

class Log:
    def __init__(self,text):self.text=text
    def read_text(self):return self.text

class QualifierTests(unittest.TestCase):
    def inputs(self):
        flags=['-D'+x for x in qualify.FEATURES]
        proof={'nativeObjects':{'x':{'expandedArguments':['clang','-c','x.cpp',*flags]}}}
        extra=' '.join('-Xcc -D'+x for x in qualify.FEATURES)
        text='\n'.join('builtin-SwiftDriver -- /tools/swiftc -c -output-file-map /owned/map.json -cxx-interoperability-mode=default -module-name '+module+' '+extra+' -D LATTICE_MANAGED_CELL_SWIFT_MECHANISM' for module in ('Lattice','LatticeTests'))
        return proof,Log(text)
    def test_actual_uniform_flags(self):
        proof,log=self.inputs();self.assertEqual(set(qualify.uniform_flags(proof,log,Path('/owned'),lambda a,s:(a,{}))),{'Lattice','LatticeTests'})
    def test_missing_and_conflicting_flags_reject(self):
        for mode in range(5):
            with self.subTest(mode=mode):
                proof,log=self.inputs()
                if mode==0:proof['nativeObjects']['x']['expandedArguments'].remove('-D'+qualify.FEATURES[0])
                elif mode==1:proof['nativeObjects']['x']['expandedArguments'].append('-U'+qualify.FEATURES[0])
                elif mode==2:log.text=log.text.replace('-Xcc -D'+qualify.FEATURES[0],'')
                elif mode==3:log.text=log.text.splitlines()[0]
                else:log.text=log.text.replace(' -D LATTICE_MANAGED_CELL_SWIFT_MECHANISM','')
                with self.assertRaises(ValueError):qualify.uniform_flags(proof,log,Path('/owned'),lambda a,s:(a,{}))
    def test_build_proof_retains_owned_maps(self):
        tree=ast.parse(Path(qualify.__file__).read_text())
        calls=[n for n in ast.walk(tree) if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and isinstance(n.func.value,ast.Name) and n.func.value.id=='build_proof' and n.func.attr=='make']
        self.assertEqual(len(calls),1)
        values={k.arg:ast.unparse(k.value) for k in calls[0].keywords}
        self.assertEqual(values['map_receipts'],"receipts / 'swift-output-maps'")
        self.assertEqual(values['temporary'],"root / 'tmp'")
    def test_final_error_clears_all_acceptance(self):
        result={'success':True,'mechanismQualified':True,'experimentCompleted':True,'observedCount':420}
        qualify.clear_acceptance(result)
        self.assertFalse(any(result[x] for x in ('success','mechanismQualified','experimentCompleted')))
        self.assertEqual(result['observedCount'],420)

if __name__=='__main__':unittest.main()
