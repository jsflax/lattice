import copy
import ast
import tempfile
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
    def source_fixture(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        root=Path(temp.name);nested=root/'Examples/NotesApp/.swiftpm/xcode/workspace'
        nested.parent.mkdir(parents=True);nested.write_text('committed workspace')
        (root/'Package.swift').write_text('package')
        expected={str(x.relative_to(root)):qualify.sha(x) for x in (nested,root/'Package.swift')}
        return root,nested,expected
    def test_sources_include_committed_nested_swiftpm(self):
        root,nested,expected=self.source_fixture()
        (root/'.swiftpm').mkdir();(root/'.swiftpm/bookkeeping.json').write_text('{}')
        qualify.sources(root,expected)
    def test_sources_reject_missing_changed_unexpected_nested_and_symlink(self):
        for mode in ('missing','changed','unexpected','symlink'):
            with self.subTest(mode=mode):
                root,nested,expected=self.source_fixture()
                if mode=='missing':nested.unlink()
                elif mode=='changed':nested.write_text('drift')
                elif mode=='unexpected':(nested.parent/'extra').write_text('not committed')
                else:
                    nested.unlink();nested.symlink_to(root/'Package.swift')
                with self.assertRaises(ValueError):qualify.sources(root,expected)
    def edit_fixture(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        parent=Path(temp.name).resolve();sdk=parent/'SDK';core=parent/'Core'
        sdk.mkdir();core.mkdir();(sdk/'Package.swift').write_text('package')
        (core/'private.cpp').write_text('separately authenticated Core')
        (sdk/'Packages').mkdir();(sdk/'Packages/LatticeCore').symlink_to(core,target_is_directory=True)
        return sdk,core,{'Package.swift':qualify.sha(sdk/'Package.swift')}
    def test_exact_owned_edit_link_is_recorded_without_traversal(self):
        sdk,core,expected=self.edit_fixture()
        self.assertEqual(qualify.sources(sdk,expected,edited_core=core),{'Packages/LatticeCore':str(core)})
    def test_edit_link_is_not_admitted_before_graph(self):
        sdk,core,expected=self.edit_fixture()
        with self.assertRaisesRegex(ValueError,'Packages/LatticeCore'):qualify.sources(sdk,expected)
    def test_edit_link_rejections(self):
        for mode in ('relative','wrong','dangling','missing','ordinary-directory','core-symlink','extra-link','metadata-link','nested-link','parent-link'):
            with self.subTest(mode=mode):
                sdk,core,expected=self.edit_fixture();link=sdk/'Packages/LatticeCore'
                if mode in ('relative','wrong','dangling','missing','ordinary-directory'):
                    link.unlink()
                    if mode=='relative':link.symlink_to('../../Core',target_is_directory=True)
                    elif mode=='wrong':link.symlink_to(sdk,target_is_directory=True)
                    elif mode=='dangling':link.symlink_to(core/'missing',target_is_directory=True)
                    elif mode=='ordinary-directory':link.mkdir()
                elif mode=='core-symlink':
                    core.rename(core.parent/'other');core.symlink_to(core.parent/'other',target_is_directory=True)
                elif mode=='extra-link':(sdk/'extra').symlink_to(core,target_is_directory=True)
                elif mode=='metadata-link':
                    (sdk/'.swiftpm').mkdir();(sdk/'.swiftpm/escape').symlink_to(core,target_is_directory=True)
                elif mode=='nested-link':
                    (sdk/'Examples').mkdir();(sdk/'Examples/LatticeCore').symlink_to(core,target_is_directory=True)
                else:
                    (sdk/'Packages').rename(sdk/'other');(sdk/'Packages').symlink_to(sdk/'other',target_is_directory=True)
                with self.assertRaises(ValueError):qualify.sources(sdk,expected,edited_core=core)
    def test_core_inventory_still_rejects_all_links(self):
        sdk,core,expected=self.edit_fixture();(core/'alias').symlink_to(core/'private.cpp')
        with self.assertRaisesRegex(ValueError,'alias'):qualify.sources(core,{'private.cpp':qualify.sha(core/'private.cpp')})
    def test_source_link_receipt_and_graph_state_binding(self):
        text=Path(qualify.__file__).read_text()
        self.assertIn("entry['state'].get('path')==str(core)",text)
        self.assertIn("entry['subpath']=='LatticeCore'",text)
        self.assertIn('edited_core=core if graph_done else None',text)
        self.assertIn("'SOURCE-CHECK-%03d.json'",text)
    def test_final_error_clears_all_acceptance(self):
        result={'success':True,'mechanismQualified':True,'experimentCompleted':True,'observedCount':420}
        qualify.clear_acceptance(result)
        self.assertFalse(any(result[x] for x in ('success','mechanismQualified','experimentCompleted')))
        self.assertEqual(result['observedCount'],420)

if __name__=='__main__':unittest.main()
