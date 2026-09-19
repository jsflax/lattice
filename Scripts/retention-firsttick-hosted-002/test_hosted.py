"""Pure guard/admission tests; no compiler, SQLite, commands or signals run."""
import ast
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

P=Path(__file__).resolve().parent
sys.path.insert(0,str(P/'harness'))
import hosted_guard as guard
import guarded_runner as original
import hosted

class HostedTests(unittest.TestCase):
    def setUp(self):
        (P/'pure-tmp').mkdir(exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=P/'pure-tmp')
        self.root=Path(self.tmp.name)
        for name in ['baseline','bounded','control','hosted-receipts']:(self.root/name).mkdir()
        self.binding={'deadline':1000,'aggregateDeadline':1300,'started':0}
        self.active=SimpleNamespace(root=self.root,binding=self.binding,runners=[])
        self.interrupts=SimpleNamespace(received=[])
        self.previous=guard.ACTIVE;guard.ACTIVE=self.active
    def tearDown(self):
        guard.ACTIVE=self.previous;self.tmp.cleanup()
    def runner(self, overall=1500):
        receipts=self.root/'baseline'/'receipts';receipts.mkdir(exist_ok=True)
        return guard.AggregateRunner(self.root/'baseline',receipts,{},self.interrupts,
            free_floor=guard.FREE_BYTES,packet_ceiling=guard.PACKET_BYTES,log_ceiling=guard.LOG_BYTES,
            overall_seconds=overall,reserve=30)
    def sample(self):
        return {'freeBytes':guard.FREE_BYTES,'packetBytes':guard.PACKET_BYTES,'logBytes':guard.LOG_BYTES,
                'aggregateBytes':guard.AGGREGATE_BYTES,'armBytes':{'baseline':guard.PACKET_BYTES,'bounded':guard.PACKET_BYTES}}
    def test_shared_deadline_cannot_reset_at_later_stage(self):
        with patch.object(original.time,'monotonic',return_value=100):r=self.runner()
        self.assertEqual((r.overall_deadline,r.work_deadline),(1000,970))
        with patch.object(original.time,'monotonic',return_value=400):later=self.runner()
        self.assertEqual((later.overall_deadline,later.work_deadline),(1000,970))
    def test_shorter_original_stage_deadline_and_reserve_remain(self):
        with patch.object(original.time,'monotonic',return_value=100):r=self.runner(overall=200)
        self.assertEqual((r.overall_deadline,r.work_deadline),(300,270))
    def test_local_and_aggregate_caps_are_independent_and_exact(self):
        r=self.runner();good=self.sample();self.assertIsNone(r.violation(good))
        for key,value in [('freeBytes',guard.FREE_BYTES-1),('packetBytes',guard.PACKET_BYTES+1),
                          ('logBytes',guard.LOG_BYTES+1),('aggregateBytes',guard.AGGREGATE_BYTES+1)]:
            with self.subTest(key=key):self.assertIsNotNone(r.violation(good|{key:value}))
        changed=copy.deepcopy(good);changed['armBytes']['bounded']+=1
        self.assertEqual(r.violation(changed),'source packet ceiling')
    def test_measure_counts_whole_root_without_replacing_local_count(self):
        r=self.runner();base=self.sample();base.pop('aggregateBytes');base.pop('armBytes')
        sizes={self.root:130,self.root/'baseline':20,self.root/'bounded':30}
        with patch.object(original.GuardedRunner,'measure',return_value=base), \
             patch.object(guard,'allocated',side_effect=lambda p:sizes[p]):
            sample=r.measure(self.root/'none')
        self.assertEqual(sample['packetBytes'],guard.PACKET_BYTES)
        self.assertEqual(sample['aggregateBytes'],130)
        self.assertEqual(sample['armBytes'],{'baseline':20,'bounded':30})
    def test_unchanged_full_timeout_is_mandatory(self):
        r=self.runner()
        with patch.object(original.GuardedRunner,'run',return_value='fake') as run:
            r.run('compile',['compiler'],cwd=self.root,timeout=1200)
        self.assertEqual(run.call_args.kwargs['timeout'],1200)
        self.assertIs(run.call_args.kwargs['require_full_timeout'],True)
    def test_exhausted_aggregate_refuses_before_process_creation(self):
        self.interrupts=original.Interrupts()
        with patch.object(original.time,'monotonic',return_value=100):r=self.runner()
        with patch.object(r,'measure',return_value=self.sample()), \
             patch.object(original.time,'monotonic',return_value=900), \
             patch.object(original.subprocess,'Popen') as launch, \
             self.assertRaisesRegex(RuntimeError,'unchanged command timeout'):
            r.run('sample',['never-executed'],cwd=self.root,timeout=120)
        launch.assert_not_called()
        record=guard.read(r.receipts/'sample.json')
        self.assertFalse(record['started']);self.assertFalse(record['success'])
        self.assertEqual(record['timeoutSeconds'],120)
    def test_runner_requires_active_stage_and_original_limits(self):
        guard.ACTIVE=None
        with self.assertRaisesRegex(ValueError,'active'):self.runner()
        guard.ACTIVE=self.active
        with self.assertRaisesRegex(ValueError,'original resource limits'):
            guard.AggregateRunner(self.root/'baseline',self.root,{},self.interrupts,
                free_floor=guard.FREE_BYTES,packet_ceiling=guard.PACKET_BYTES+1,log_ceiling=guard.LOG_BYTES)
    def end(self,name,**changes):
        folder=self.root/'hosted-receipts'
        guard.save(folder/(name+'-START.json'),{'stage':name})
        value={'stage':name,'success':True,'primaryError':None,'evidenceErrors':[],'receivedSignals':[],'commands':[]}|changes
        guard.save(folder/(name+'-END.json'),value)
    def test_fixed_order_rejects_missing_failed_and_incomplete_predecessor(self):
        folder=self.root/'hosted-receipts'
        with self.assertRaises(ValueError):guard.prior_stages(folder,'baseline-fetch')
        self.end('toolchain',success=False,primaryError={'type':'failed'})
        with self.assertRaisesRegex(ValueError,'failed predecessor'):guard.prior_stages(folder,'baseline-fetch')
        (folder/'toolchain-END.json').unlink()
        with self.assertRaisesRegex(ValueError,'incomplete predecessor'):guard.prior_stages(folder,'baseline-fetch')
    def test_fixed_order_accepts_only_complete_prefix_and_refuses_duplicate(self):
        folder=self.root/'hosted-receipts'
        for name in guard.ORDER[:4]:self.end(name)
        self.assertEqual(set(guard.prior_stages(folder,'baseline-run')),set(guard.ORDER[:4]))
        with self.assertRaises(ValueError):guard.prior_stages(folder,'baseline-build')
        with self.assertRaises(ValueError):guard.prior_stages(folder,'bounded-fetch')
    def test_prior_command_receipt_and_log_are_both_rehashed(self):
        receipt=self.root/'command.json';log=self.root/'command.log'
        receipt.write_text('{}');log.write_text('first')
        command={'receipt':str(receipt),'sha256':guard.digest(receipt),'log':str(log),'logSHA256':guard.digest(log)}
        self.end('toolchain',commands=[command]);folder=self.root/'hosted-receipts'
        guard.prior_stages(folder,'baseline-fetch')
        log.write_text('changed')
        with self.assertRaisesRegex(ValueError,'command log drift'):guard.prior_stages(folder,'baseline-fetch')
    def test_finalization_preserves_primary_and_records_secondary_failure(self):
        guard.ACTIVE=None;stage=guard.Stage('toolchain')
        with patch.object(guard,'context',return_value=(self.root,self.binding)), \
             patch.object(guard,'verify_arm'),patch.object(guard,'verify_materialized_source'), \
             patch.object(guard.time,'monotonic',return_value=100), \
             patch.object(guard,'allocated',return_value=guard.AGGREGATE_BYTES+1), \
             self.assertRaisesRegex(RuntimeError,'first failure'):
            with stage:raise RuntimeError('first failure')
        result=guard.read(self.root/'hosted-receipts/toolchain-END.json')
        self.assertEqual(result['primaryError']['message'],'first failure')
        self.assertFalse(result['success']);self.assertEqual(result['evidenceErrors'][0]['check'],'resources')
        self.assertIsNone(guard.ACTIVE)
    def test_success_waits_for_final_resource_and_custody_checks(self):
        guard.ACTIVE=None
        with patch.object(guard,'context',return_value=(self.root,self.binding)), \
             patch.object(guard,'verify_arm'),patch.object(guard,'verify_materialized_source'), \
             patch.object(guard.time,'monotonic',return_value=100), \
             patch.object(guard,'allocated',return_value=0), \
             patch.object(shutil,'disk_usage',return_value=SimpleNamespace(free=guard.FREE_BYTES)):
            with guard.Stage('toolchain'):pass
        result=guard.read(self.root/'hosted-receipts/toolchain-END.json')
        self.assertTrue(result['success']);self.assertEqual(result['finalResources']['aggregateBytes'],0)
    def context_fixture(self):
        home=self.root/'home';root=home/'localdev/lattice-retention-firsttick-123-1';root.mkdir(parents=True)
        packet=root/'packet';packet.mkdir();shutil.copy2(P/'CONFIG.json',packet/'CONFIG.json')
        metadata={'runID':'123','attempt':'1','workflowCommit':'a'*40,'repository':'fixture/repo'}
        config=guard.read(packet/'CONFIG.json');seal='b'*64
        admission={'schemaVersion':1,'packetSealSHA256':seal,'workflowCommit':'a'*40,'attempt':'1',
            'executionAdmitted':True,'sources':config['sources'],'aggregate':config['aggregate'],
            'perPacket':config['perPacket'],'protocolParentReviewSHA256':config['protocolParentReviewSHA256']}
        guard.save(root/'ADMISSION.json',admission)
        guard.save(root/'BOOTSTRAP.json',{'root':str(root),'startedMonotonic':100,'hosted':metadata,'bootID':'fixtureboot'})
        env={'RETENTION_HOSTED_ROOT':str(root),'RETENTION_PACKET_SEAL_SHA256':seal,
             'RETENTION_ADMISSION_SHA256':guard.digest(root/'ADMISSION.json'),'GITHUB_RUN_ID':'123',
             'GITHUB_RUN_ATTEMPT':'1','GITHUB_SHA':'a'*40,'GITHUB_REPOSITORY':'fixture/repo'}
        return home,root,env
    def test_exact_admission_boot_identity_and_one_clock(self):
        home,root,env=self.context_fixture();original_read=Path.read_text
        def text(path,*args,**kwargs):
            return 'fixtureboot' if str(path)=='/proc/sys/kernel/random/boot_id' else original_read(path,*args,**kwargs)
        with patch.dict(os.environ,env),patch.object(Path,'home',return_value=home), \
             patch.object(guard.platform,'system',return_value='Linux'),patch.object(guard.platform,'machine',return_value='x86_64'), \
             patch.object(Path,'read_text',text),patch.object(guard,'packet_check'), \
             patch.object(guard.time,'monotonic',return_value=200):
            _,binding=guard.context()
            self.assertEqual(binding['aggregateDeadline'],14500)
            self.assertEqual(binding['deadline'],14200)
            with patch.dict(os.environ,{'GITHUB_RUN_ATTEMPT':'2'}),self.assertRaises(ValueError):guard.context()
            with (root/'ADMISSION.json').open('a') as f:f.write('\n')
            with self.assertRaisesRegex(ValueError,'admission byte drift'):guard.context()
    def test_protocol_sources_and_stage_body_are_byte_preserved(self):
        hosted.require_preservation()
        prior=(P/'evidence/protocol-run.py').read_text();current=(P/'harness/run.py').read_text()
        self.assertEqual(prior.split('    verify_harness()\n',1)[1],current.split('    verify_harness()\n',1)[1])
        self.assertIn('start_new_session=False',(P/'harness/supervise.py').read_text())
        self.assertIn('deadline = started + 115',(P/'harness/supervise.py').read_text())
    def test_manifests_and_limits_match_fixed_proposal(self):
        config=guard.read(P/'CONFIG.json');prior=guard.read(P/'evidence/HOSTED-ORIGINAL-SCHEDULE-PROPOSAL.json')
        self.assertEqual(config['perPacket'],prior['perPacket'])
        for arm in ['baseline','bounded']:
            manifest=guard.read(P/'sources'/arm/'SOURCE-MANIFEST.json')
            self.assertEqual(len(manifest['files']),883)
            self.assertEqual(sum(x['bytes'] for x in manifest['files'].values()),prior['sources'][arm]['bytes'])
            self.assertEqual(guard.digest(P/'sources'/arm/'SOURCE-MANIFEST.json'),prior['sources'][arm]['manifestSHA256'])
            for key in ['source','tree']:self.assertEqual(manifest[key],config['sources'][arm][key])
    def test_workflow_is_held_manual_sequential_and_no_nested_runner(self):
        text=(P/'retention-foreground.yml').read_text()
        self.assertIn('if: ${{ false }}',text);self.assertNotIn('  push:',text)
        self.assertIn('timeout-minutes: 240',text);self.assertIn('runs-on: ubuntu-24.04',text)
        self.assertIn('export TASK_ROOT TMPDIR=',text)
        self.assertLess(text.index("'startedMonotonic':time.monotonic()"),text.index('git init'))
        offsets=[]
        for arm in ['baseline','bounded']:
            for stage in ['prepare','build','run']:
                offsets.append(text.index(f'"$TASK_ROOT/{arm}/harness/run.py" {stage}'))
        self.assertEqual(offsets,sorted(offsets))
        for f in [P/'hosted.py',P/'harness/hosted_guard.py']:
            tree=ast.parse(f.read_text())
            self.assertFalse(any(isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and
                n.func.attr in ['Popen','fork','setsid','kill','killpg'] for n in ast.walk(tree)))

if __name__=='__main__':unittest.main()
