"""Pure refusal tests. Files are synthetic; no compiler, resolver, subprocess or database."""
from collections import Counter
import copy
import json
from pathlib import Path
import tempfile
import unittest
import ast
from unittest.mock import patch
import build_proof
import qualify
import sdk_test_oracles
import source_checks

P=Path(__file__).resolve().parent

class Preparation(unittest.TestCase):
    def setUp(self):
        (P/'pure-tmp').mkdir(exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=P/'pure-tmp');self.root=Path(self.tmp.name)
    def tearDown(self):self.tmp.cleanup()
    def write(self,path,text='synthetic bytes'):
        path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text);return path
    def test_source_custody_and_all_oracles_unchanged(self):
        source_checks.verify()
        old=P/'evidence/sdk008'
        for name in ['runtime_oracles.py','sdk_test_oracles.py','EXPECTED-TESTS.json']:
            self.assertEqual(qualify.H(old/name),qualify.H(P/name))
    def proof_fixture(self):
        r=self.root;sdk=r/'SDK';core=r/'Core';scratch=r/'scratch';scratch.mkdir()
        core_source=self.write(core/'Sources/LatticeCore/src/owner.cpp');self.write(core/'Sources/LatticeSwiftCppBridge/src/empty.hpp')
        sqlite=self.write(core/'Sources/SqliteVec/src/sqlite-vec.c');fixture=self.write(sdk/'Qualification/DurablePageRuntimeFixture/runtime_fixture.cpp')
        lines=[];native={}
        for i,src in enumerate([core_source,sqlite,fixture]):
            obj=self.write(scratch/f'native{i}.o');native[str(src)]=str(obj)
            lines.append(f'/tools/clang++ -O0 -c {src} -o {obj}')
        specs={'Lattice':sdk/'Sources/Lattice/OwnedPageRead.swift','LatticeTests':sdk/'Tests/LatticeTests/OwnedPageReadTests.swift','LatticeSwiftModule':core/'Sources/LatticeSwiftModule/Protocols.swift','OwnedPageQualificationRuntime':sdk/'Qualification/OwnedPageQualificationRuntime/main.swift'}
        objs={}
        for mod,src in specs.items():
            self.write(src);obj=self.write(scratch/f'{mod}.o');objs[mod]=str(obj)
            mapping=self.write(scratch/f'arm64-apple-macosx/debug/{mod}.build/output-file-map.json',json.dumps({str(src):{'object':str(obj)}}))
            lines.append(f'/tools/swiftc -j2 -module-name {mod} -Onone -enable-testing -output-file-map {mapping} -c {src}')
        shared=[native[str(core_source)],native[str(sqlite)],objs['Lattice'],objs['LatticeSwiftModule']]
        test=self.write(scratch/'arm64-apple-macosx/debug/LatticePackageTests.xctest/Contents/MacOS/LatticePackageTests')
        runtime=self.write(scratch/'arm64-apple-macosx/debug/OwnedPageQualificationRuntime')
        for name,exe,extra in [('test',test,[objs['LatticeTests']]),('runtime',runtime,[objs['OwnedPageQualificationRuntime'],native[str(fixture)]])]:
            listing=self.write(scratch/f'{name}.LinkFileList','\n'.join(shared+extra)+'\n')
            lines.append(f'/tools/swiftc -target arm64-apple-macosx14.0 -sdk /bound/sdk -filelist {listing} -o {exe}')
        log=self.write(r/'build.log','\n'.join(lines)+'\n')
        return log,sdk,core,scratch,objs
    def make(self,values):
        log,sdk,core,scratch,_=values
        return build_proof.make(log,sdk,core,scratch,'Tests/LatticeTests/OwnedPageReadTests.swift',temporary=self.root/'tmp')
    def test_debug_two_product_positive_and_binary_custody(self):
        values=self.proof_fixture();proof=self.make(values);build_proof.verify_products(proof)
        self.assertEqual(set(proof['products']),{'tests','runtime'})
        Path(proof['products']['runtime']['binary']).write_text('changed')
        with self.assertRaises(AssertionError):build_proof.verify_products(proof)
    def test_all_actual_driver_jobs_must_be_explicit_two(self):
        for suffix in ['-j2', '-j 2', '-j2 -j 2']:
            self.assertTrue(build_proof.swift_driver_jobs(['swiftc'] + suffix.split(), self.root)['jobValues'])
        for suffix in ['', '-j16', '-j 16 -j2', '-j2 -j', '-j0', '-j2 -jbad', '-j2 -num-threads=16']:
            with self.subTest(suffix=suffix), self.assertRaises(AssertionError):
                build_proof.swift_driver_jobs(['swiftc'] + suffix.split(), self.root)
    def test_unselected_dependency_driver_cannot_hide_larger_jobs(self):
        v=self.proof_fixture()
        v[0].write_text(v[0].read_text() + '/tools/swiftc -j16 -module-name SomeDependency -output-file-map /not/used -c /some.swift\n')
        with self.assertRaises(AssertionError): self.make(v)
    def test_response_hidden_dependency_map_still_requires_jobs_two(self):
        v=self.proof_fixture();original=v[0].read_text()
        response=self.write(v[3]/'dependency-options.rsp','-output-file-map /unused/dependency-map.json')
        for jobs in ['-j16', '']:
            v[0].write_text(original+f'/tools/swiftc -module-name Dependency {jobs} @{response}\n')
            with self.subTest(jobs=jobs), self.assertRaises(AssertionError):self.make(v)
        v[0].write_text(original+f'/tools/swiftc -module-name Dependency -j2 @{response}\n')
        proof=self.make(v)
        record=next(x for x in proof['swiftDriverJobs'] if x['module']=='Dependency')
        self.assertEqual(record['jobValues'],['2'])
        self.assertEqual(record['responseFiles'],{str(response):qualify.H(response)})
        response.write_text('-output-file-map /changed/dependency-map.json')
        with self.assertRaises(AssertionError):build_proof.verify_products(proof)
    def test_response_hidden_entire_driver_is_classified(self):
        v=self.proof_fixture();original=v[0].read_text()
        response=self.write(v[3]/'all-options.rsp','-module-name Dependency -output-file-map /unused/map -j16')
        v[0].write_text(original+f'/tools/swiftc @{response}\n')
        with self.assertRaises(AssertionError):self.make(v)
        response.write_text('-module-name Dependency -output-file-map /unused/map -j2')
        self.assertEqual(len(self.make(v)['swiftDriverJobs']),5)
    def test_unknown_or_malformed_swift_driver_is_refused(self):
        v=self.proof_fixture();original=v[0].read_text()
        for line in ['/tools/swiftc -module-name Dependency -j2', '/tools/swiftc -module-name Dependency -c /source.swift -j2', '/tools/swiftc "unterminated']:
            v[0].write_text(original+line+'\n')
            with self.subTest(line=line), self.assertRaises(AssertionError):self.make(v)
    def test_actual_driver_response_options_bound_and_checked(self):
        response=self.write(self.root/'jobs.rsp','-j2')
        result=build_proof.swift_driver_jobs(['swiftc','@'+str(response)],self.root)
        self.assertEqual(result['responseFiles'],{str(response):qualify.H(response)})
        response.write_text('-j16')
        with self.assertRaises(AssertionError):build_proof.swift_driver_jobs(['swiftc','@'+str(response)],self.root)
    def test_non_native_required_module_layout_refused(self):
        v=self.proof_fixture();old=v[3]/'arm64-apple-macosx/debug/Lattice.build/output-file-map.json'
        other=self.write(v[3]/'out/Intermediates.noindex/Lattice-map.json',old.read_text())
        v[0].write_text(v[0].read_text().replace(str(old),str(other)))
        with self.assertRaises(AssertionError):self.make(v)
    def final_fixture(self):
        class Runner:
            overall_deadline=100
            def measure(self, path):return {'freeBytes':123}
            def violation(self, sample):return None
        return {'primaryError':{'message':'original failure'},'evidenceErrors':[]},Runner()
    def test_failed_command_does_not_skip_final_resources_or_deadline(self):
        result,runner=self.final_fixture();calls=[]
        def audit(receipts,label,wanted):
            calls.append(label)
            if label=='failed':raise ValueError('expected failed command')
            return {'label':label}
        with patch.object(qualify,'clean',audit):
            qualify.final_evidence(result,sources=lambda:calls.append('source'),products=lambda:calls.append('products'),
                observed={'failed':{},'later':{}},receipts=self.root,runner=runner,now=lambda:50)
        self.assertEqual(calls,['source','products','failed','later'])
        self.assertEqual(result['finalResources'],{'freeBytes':123})
        self.assertTrue(result['finalDeadline']['withinDeadline'])
        self.assertEqual(result['primaryError'],{'message':'original failure'})
        self.assertEqual([x['check'] for x in result['evidenceErrors']],['command:failed'])
    def test_all_final_failures_are_retained_and_deadline_still_runs(self):
        result,runner=self.final_fixture()
        def fail():raise ValueError('injected')
        runner.measure=lambda path:fail()
        with patch.object(qualify,'clean',side_effect=ValueError('failed command')):
            qualify.final_evidence(result,sources=fail,products=fail,observed={'x':{},'y':{}},
                receipts=self.root,runner=runner,now=lambda:101)
        self.assertEqual([x['check'] for x in result['evidenceErrors']],['sourceCustody','productCustody','command:x','command:y','resources','deadline'])
        self.assertFalse(result['finalDeadline']['withinDeadline'])
        self.assertEqual(result['primaryError'],{'message':'original failure'})
    def test_violating_final_resource_sample_is_retained(self):
        result,runner=self.final_fixture();runner.violation=lambda sample:'free floor'
        qualify.final_evidence(result,sources=lambda:None,products=lambda:None,observed={},receipts=self.root,runner=runner,now=lambda:50)
        self.assertEqual(result['finalResources'],{'freeBytes':123})
        self.assertEqual([x['check'] for x in result['evidenceErrors']],['resources'])
        self.assertTrue(result['finalDeadline']['withinDeadline'])
    def test_release_native_refused(self):
        v=self.proof_fixture();v[0].write_text(v[0].read_text().replace('-O0','-O2'))
        with self.assertRaises(AssertionError):self.make(v)
    def test_release_swift_refused(self):
        v=self.proof_fixture();v[0].write_text(v[0].read_text().replace('-Onone','-O'))
        with self.assertRaises(AssertionError):self.make(v)
    def test_missing_actual_owner_compile_refused(self):
        v=self.proof_fixture();v[0].write_text('\n'.join(v[0].read_text().splitlines()[1:]))
        with self.assertRaises(ValueError):self.make(v)
    def test_missing_actual_protocol_compile_refused(self):
        v=self.proof_fixture();v[0].write_text('\n'.join(x for x in v[0].read_text().splitlines() if '-module-name LatticeSwiftModule ' not in x))
        with self.assertRaises(AssertionError):self.make(v)
    def test_missing_named_object_refused(self):
        v=self.proof_fixture();Path(v[4]['Lattice']).unlink()
        with self.assertRaises(AssertionError):self.make(v)
    def test_runtime_missing_fixture_link_refused(self):
        v=self.proof_fixture();file=v[3]/'runtime.LinkFileList';file.write_text('\n'.join(file.read_text().splitlines()[:-1])+'\n')
        with self.assertRaises(AssertionError):self.make(v)
    def test_test_objects_in_runtime_refused(self):
        v=self.proof_fixture();file=v[3]/'runtime.LinkFileList';file.write_text(file.read_text()+v[4]['LatticeTests']+'\n')
        with self.assertRaises(AssertionError):self.make(v)
    def test_foreign_response_file_refused(self):
        foreign=self.write(self.root/'foreign.rsp','-DVALUE=1');scratch=self.root/'scratch';scratch.mkdir()
        with self.assertRaises(AssertionError):build_proof.native_arguments(['@'+str(foreign)],scratch)
    def macro_proof(self):
        native=['-DLATTICE_HAS_FRT=1','-DLATTICE_EXPERIMENTAL_OWNED_READ=1']
        swift=['swiftc','-cxx-interoperability-mode=default','-Xcc',native[0],'-Xcc',native[1],'-DLATTICE_EXPERIMENTAL_OWNED_READ']
        return {'nativeObjects':{'owned.cpp':{'expandedArguments':native}},'swiftModules':{n:{'argv':list(swift)} for n in ['Lattice','LatticeTests','OwnedPageQualificationRuntime']}}
    def test_uniform_feature_abi_controls(self):
        original=self.macro_proof();qualify.uniform(original)
        changes=[lambda p:p['nativeObjects']['owned.cpp']['expandedArguments'].pop(),lambda p:p['nativeObjects']['owned.cpp']['expandedArguments'].append('-DLATTICE_HAS_FRT=0'),lambda p:p['nativeObjects']['owned.cpp']['expandedArguments'].append('-ULATTICE_HAS_FRT'),lambda p:p['swiftModules']['Lattice']['argv'].pop(),lambda p:p['swiftModules']['OwnedPageQualificationRuntime']['argv'].__setitem__(3,'-DLATTICE_HAS_FRT=0')]
        for change in changes:
            value=copy.deepcopy(original);change(value)
            with self.assertRaises(ValueError):qualify.uniform(value)
    def test_clean_receipt_controls(self):
        rec=self.root/'receipts';rec.mkdir();self.write(rec/'x.log','ok');wanted={'argv':['owned'],'cwd':str(self.root),'timeoutSeconds':30}
        row={**wanted,'success':True,'started':True,'exitCode':0,'primaryError':None,'evidenceErrors':[],'receivedSignals':[],'logSHA256':qualify.H(rec/'x.log'),'cleanup':{'groupGone':True,'leaderReaped':True,'ownedDescendantsGone':True,'errors':[],'signals':[]}}
        self.write(rec/'x.json',json.dumps(row));qualify.clean(rec,'x',wanted)
        mutations=[lambda x:x.update(exitCode=1),lambda x:x.update(started=False),lambda x:x.update(timeoutSeconds=180),lambda x:x['cleanup'].update(signals=['SIGTERM']),lambda x:x['cleanup'].update(groupGone=False),lambda x:x.update(logSHA256='0'*64)]
        for mutate in mutations:
            value=copy.deepcopy(row);mutate(value);self.write(rec/'x.json',json.dumps(value))
            with self.assertRaises(ValueError):qualify.clean(rec,'x',wanted)
    def sdk_logs(self):
        e=json.loads((P/'EXPECTED-TESTS.json').read_text());lines=[]
        for n in e['declarations']:lines.append('✔ Test '+n+'('+('_:' if n in e['parameterized'] else '')+') passed after 0.01 seconds.')
        for n,vals in e['parameterized'].items():
            arg='status' if n.startswith('native') else 'cleanupFails'
            for v in vals:lines.append(f'◇ Test case passing 1 argument {arg} → {str(v).lower()} to {n}(_:) started.')
        lines.append('✔ Test run with 12 tests in 1 suite passed after 0.1 seconds.')
        xml='<testsuites><testsuite tests="12" failures="0" errors="0" skipped="0">'+''.join(f'<testcase classname="LatticeTests.OwnedPageReadTests" name="{n}()"/>' for n in e['declarations'])+'</testsuite></testsuites>'
        return e,self.write(self.root/'run.log','\n'.join(lines)),self.write(self.root/'run.xml',xml)
    def test_sdk_exact_parameter_invocations(self):
        e,log,xml=self.sdk_logs();self.assertEqual(sdk_test_oracles.analyze(log,xml,e)['invocations'],26)
        original=log.read_text()
        for bad in [original.replace('status → 4','status → 5'),original.replace('status → 4','status → 99'),original+'\n'+next(x for x in original.splitlines() if 'status → 4' in x),original.replace('Test run with 12','Test run with 0'),original+'\nrecorded an issue']:
            log.write_text(bad)
            with self.assertRaises(AssertionError):sdk_test_oracles.analyze(log,xml,e)
    def test_sdk_xml_wrong_suite_or_missing_case(self):
        e,log,xml=self.sdk_logs();original=xml.read_text()
        for bad in [original.replace('LatticeTests.OwnedPageReadTests','Other'),original.replace('failures="0"','failures="1"'),original.replace('tests="12"','tests="26"')]:
            xml.write_text(bad)
            with self.assertRaises(AssertionError):sdk_test_oracles.analyze(log,xml,e)

class RuntimeOutputDirectory(unittest.TestCase):
    def setUp(self):
        config=json.loads((P/'CONFIG.json').read_text())
        self.expected=str(Path(config['runtimeRoot'])/config['expectedNativeBinRelative'])
        self.path=self.expected.encode('utf-8')
        self.warning=qualify.NATIVE_BUILD_SYSTEM_WARNING

    def test_only_exact_path_with_optional_exact_warning_and_final_newline(self):
        for prefix in [b'',self.warning+b'\n']:
            for ending in [b'',b'\n']:
                with self.subTest(prefix=prefix,ending=ending):
                    self.assertEqual(qualify.runtime_output_directory(prefix+self.path+ending,self.expected),self.expected)

    def test_actual003_log_is_pinned_and_never_authorizes004_path(self):
        raw=(P/'fixtures/runtime-output-directory-003.log').read_bytes()
        old=str(Path(json.loads((P/'evidence/sdk008/CONFIG.json').read_text())['runtimeRoot'])/json.loads((P/'CONFIG.json').read_text())['expectedNativeBinRelative']).replace('owned-page-sdk-qualification-008','owned-page-sdk-qualification-003')
        self.assertEqual(len(raw),373)
        self.assertEqual(qualify.H(P/'fixtures/runtime-output-directory-003.log'),'0e42556c168321944c89ed9f35071d0b5d9e8879a0f76d3dd8138f62981054cc')
        self.assertEqual(qualify.runtime_output_directory(raw,old),old)
        with self.assertRaises(ValueError):qualify.runtime_output_directory(raw,self.expected)

    def test_unknown_duplicate_missing_or_wrong_output_refused(self):
        good=self.warning+b'\n'+self.path+b'\n'
        bad=[b'',b'\n',self.warning,self.warning+b'\n',b'/wrong/path\n',
             self.warning+b'\n/wrong/path\n',self.path+b'\n'+self.path,
             self.warning+b'\n'+good,good+self.path+b'\n',
             b'/wrong/path\n'+good,good+b'/wrong/path\n',
             b'warning: unknown\n'+self.path,self.path+b'\n'+self.warning,
             good+b'warning: unknown\n',good.replace(b'deprecated',b'DEPRECATED'),
             self.warning+b'\n\n'+self.path]
        for output in bad:
            with self.subTest(output=output),self.assertRaises(ValueError):
                qualify.runtime_output_directory(output,self.expected)

    def test_whitespace_control_and_interleaved_combined_output_refused(self):
        good=self.warning+b'\n'+self.path+b'\n'
        bad=[b' '+self.path,self.path+b' ',b'\n'+self.path,self.path+b'\n\n',
             good+b'\n',good.replace(b'\n',b'\r\n'),b'\x1b[32m'+good,
             self.path+b'\x00',good+b'\xff',self.warning[:20]+self.path+self.warning[20:],
             self.path[:20]+self.warning+b'\n'+self.path[20:]]
        for output in bad:
            with self.subTest(output=output),self.assertRaises(ValueError):
                qualify.runtime_output_directory(output,self.expected)

if __name__=='__main__':unittest.main()
