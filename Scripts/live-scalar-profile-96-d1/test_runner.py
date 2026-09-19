import ast
import copy
import hashlib
import json
import inspect
import guarded_runner as guard
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import profile_binding as binding

P=Path(__file__).resolve().parent
CONFIG=json.loads((P/'CONFIG.json').read_text())

class RunnerSourceTests(unittest.TestCase):
    def test_historical_full_prerequisites(self):
        value=binding.config_check(CONFIG,P)
        self.assertTrue(value['historicalOnly']);self.assertFalse(value['newProfileBuildOrRuntimeCredit'])
    def test_counts_and_limits_fixed(self):
        for key in ['canonicalSamples','calibrationSamples','warmups','measuredSamples','freeFloorBytes','packetCeilingBytes',
                    'logCeilingBytes','overallSeconds','finalizationReserveSeconds','buildTimeoutSeconds','measurementTimeoutSeconds']:
            value=copy.deepcopy(CONFIG);value[key]-=1
            with self.subTest(key=key),self.assertRaises(ValueError):binding.config_check(value,P)
    def test_changed_historical_hash(self):
        value=copy.deepcopy(CONFIG);value['prerequisites']['sdk-parent.json']='0'*64
        with self.assertRaises(ValueError):binding.config_check(value,P)
    def test_wrong_base_not_later_optimization(self):
        for key in ['candidateSDK','candidateCore']:
            value=copy.deepcopy(CONFIG);value[key]='a'*40
            with self.subTest(key=key),self.assertRaises(ValueError):binding.config_check(value,P)
    def test_no_target_or_physical_claim(self):
        for key in ['performanceTargetClaimed','physicalHostQualified']:
            value=copy.deepcopy(CONFIG);value[key]=True
            with self.subTest(key=key),self.assertRaises(ValueError):binding.config_check(value,P)
    def admission(self):
        return dict(scope=CONFIG['scope'],approved=True,runOnce=True,packetSealSHA256='a'*64,
                    sdkCommit=binding.SDK,coreCommit=binding.CORE,profileSourceReadySHA256=CONFIG['profileSourceReadySHA256'],
                    sdkPrerequisiteSHA256=CONFIG['prerequisites']['sdk-parent.json'],corePrerequisiteSHA256=CONFIG['prerequisites']['core-parent.json'],
                    physicalHostQualified=False,performanceTargetClaimed=False,ownerAllocation='synthetic test only, not real admission')
    def check_admission(self,value):
        (P/'pure-tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=P/'pure-tmp') as directory:
            path=Path(directory)/'admission.json';path.write_text(json.dumps(value))
            return binding.admission_check(path,binding.digest(path),CONFIG,'a'*64)
    def test_valid_synthetic_admission(self):self.check_admission(self.admission())
    def test_admission_refuses_missing_owner_or_wrong_binding(self):
        for key,value in [('approved',False),('runOnce',False),('ownerAllocation',''),('packetSealSHA256','b'*64),
                          ('sdkPrerequisiteSHA256','c'*64),('performanceTargetClaimed',True),('profileSourceReadySHA256','d'*64)]:
            row=self.admission();row[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.check_admission(row)
    def test_final_failure_does_not_skip_later_evidence(self):
        seen=[]
        class Runner:
            overall_deadline=1
            def measure(self,path):seen.append('resources');return {'freeBytes':1}
            def violation(self,value):return 'disk floor'
        result={'evidenceErrors':[],'primaryError':{'message':'original compile failure'}}
        def source():seen.append('source');raise ValueError('changed source')
        def proof():seen.append('proof');raise ValueError('changed proof')
        def failed_command(*args):seen.append('command');raise ValueError('failed command')
        def now():seen.append('deadline');return 2
        with patch.object(binding,'command_check',failed_command):
            binding.final_evidence(result,[('source',source),('proof',proof)],[{'label':'compile'}],P,Runner(),now)
        self.assertEqual(seen,['source','proof','command','resources','deadline'])
        self.assertEqual(len(result['evidenceErrors']),5)
        self.assertEqual(result['primaryError']['message'],'original compile failure')
        self.assertIn('finalResources',result)
    def test_measurement_exception_does_not_skip_deadline(self):
        seen=[]
        class Runner:
            overall_deadline=5
            def measure(self,path):raise ValueError('measurement failure')
        row={'evidenceErrors':[]}
        binding.final_evidence(row,[],[],P,Runner(),lambda:seen.append('deadline') or 4)
        self.assertEqual(seen,['deadline']);self.assertEqual(row['evidenceErrors'][0]['operation'],'resources')
    def test_retained_link_list_bytes_and_drift(self):
        (P/'pure-tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=P/'pure-tmp') as directory:
            root=Path(directory);source=root/'Objects.LinkFileList';source.write_text('/owned/object.o\n')
            proof={'nativeResponseFiles':{},'swiftModules':{},'linkGraph':{'binary':{'lists':[{'path':str(source),'SHA256':binding.digest(source)}]}}}
            rows=binding.retain_compiler_inputs(proof,{'responseFiles':{}},root/'copies')
            binding.verify_retained_inputs(rows)
            source.write_text('changed\n')
            with self.assertRaises(ValueError):binding.verify_retained_inputs(rows)
    def test_disabled_workflow_and_absent_runtime(self):
        text=(P/'profile-hosted.yml').read_text()
        self.assertIn('if: ${{ false }}',text)
        self.assertEqual(text.count('runs-on:'),1)
        self.assertNotIn('matrix:',text)
        self.assertFalse((P.parents[1]/'validation/live-scalar-profile-hosted-96-d1-003').exists())
    def test_runner_syntax_and_single_diagnostic_sequence(self):
        text=(P/'run-profile.py').read_text();ast.parse(text)
        self.assertIn("class StrictRunner(guard.GuardedRunner)",text)
        self.assertEqual(text.count("'B-profile-benchmark'"),1)
        self.assertNotIn("('A', 'baseline')",text)
        self.assertIn("LATTICE_PERF_REFINEMENT='0'",text)
        self.assertIn("LATTICE_PERF_REFINEMENT='1'",text)
        self.assertEqual(text.count('require_full_timeout=True'),2)
        self.assertIn("binding.final_evidence(result",text)
    def test_graph_policy_only_exact_core_postimages_differ(self):
        adapted=inspect.getsource(binding.verify_graph)
        adapted=adapted.replace('scratch, expected_core):','scratch):')
        adapted=adapted.replace("or (dirty and identity != 'latticecore')",'or dirty')
        adapted=adapted.replace("        if identity == 'latticecore':complete_sources(core, expected_core)\n",'')
        for name in ['graph_nodes','url_key','save_json']:adapted=adapted.replace('guard.'+name,name)
        self.assertEqual(ast.dump(ast.parse(adapted),include_attributes=False),
                         ast.dump(ast.parse(inspect.getsource(guard.verify_graph)),include_attributes=False))
    def test_guard_and_buildproof_byte_reuse(self):
        # P is .../execution/preparation/newpacket; predecessor is its sibling.
        root=P.parent/'frozen-read-copies-96-d1-001/packet'
        for name in ['guarded_runner.py','build_proof.py','perf_refinement_report.py']:
            self.assertEqual((P/name).read_bytes(),(root/name).read_bytes())
        self.assertEqual((P/'frozen_binding.py').read_bytes(),(root/'binding.py').read_bytes())

if __name__=='__main__':unittest.main()
