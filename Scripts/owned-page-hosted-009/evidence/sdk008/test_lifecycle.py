"""Pure lifecycle refusal/closure tests; no processes are launched or signalled."""
import copy
import json
from pathlib import Path
import signal
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import detached_owner as owner
import guarded_runner as guard
import process_custody as pc
import qualify
import source_checks

P=Path(__file__).resolve().parent


class Lifecycle(unittest.TestCase):
    def setUp(self):
        (P/'pure-tmp').mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=P/'pure-tmp')
        self.root=Path(self.temp.name)
        self.nodes={1:self.node(1,0,1)}
        self.commands={1:'python leader '+str(self.root)}
    def tearDown(self):self.temp.cleanup()
    def node(self,pid,ppid,pgid,birth=10):
        return {'pid':pid,'ppid':ppid,'pgid':pgid,'birth':[birth,pid],'zombie':False}
    def table(self):
        return {pid:n|{'command':self.commands.get(pid,'python child'),'commandSHA256':'hash'} for pid,n in self.nodes.items()}
    def ledger(self):
        return pc.Custody(1,self.root,self.root/'events.jsonl',parent_pid=0,get_identity=lambda pid:copy.deepcopy(self.nodes.get(pid)),take_snapshot=self.table)
    def test_distinct_groups_and_reparenting_retain_ancestry(self):
        c=self.ledger();self.nodes[2]=self.node(2,1,2);self.nodes[3]=self.node(3,2,3)
        c.refresh();self.assertEqual(set(c.known),{1,2,3})
        del self.nodes[1];self.nodes[2]['ppid']=999
        self.assertEqual(set(c.refresh()),{2,3})
    def test_pid_reuse_refuses_signals(self):
        c=self.ledger();saved=c.known[1];self.nodes[1]['birth']=[20,1]
        with patch.object(pc.os,'kill') as kill, self.assertRaises(RuntimeError):c.signal(saved,signal.SIGTERM)
        kill.assert_not_called()
    def test_snapshot_failure_is_not_absence(self):
        c=self.ledger();c.take_snapshot=lambda:(_ for _ in ()).throw(RuntimeError('missing table'))
        with self.assertRaises(RuntimeError):c.refresh()
    def test_path_only_orphan_is_ambiguous_not_owned(self):
        c=self.ledger();self.nodes[9]=self.node(9,999,9);self.commands[9]='python '+str(self.root/'orphan')
        c.refresh();self.assertEqual(set(c.known),{1});self.assertEqual(set(c.ambiguous),{9})
    def test_similar_foreign_path_is_not_owned_or_ambiguous(self):
        c=self.ledger();self.nodes[9]=self.node(9,999,9);self.commands[9]='python '+str(self.root)+'-foreign/a'
        c.refresh();self.assertFalse(c.ambiguous);self.assertNotIn(9,c.known)
    def test_changed_parent_birth_does_not_grant_ownership(self):
        c=self.ledger();self.nodes[1]['birth']=[99,1];self.nodes[2]=self.node(2,1,2)
        with self.assertRaises(RuntimeError):c.refresh()
        self.assertNotIn(2,c.known)
    def test_reparented_child_closed_after_leader_exits(self):
        c=self.ledger();self.nodes[2]=self.node(2,1,2);c.refresh();del self.nodes[1];self.nodes[2]['ppid']=999
        class Process:
            def poll(self):return 0
            def wait(self,timeout):return 0
        with patch.object(pc.os,'kill',side_effect=lambda pid,sig:self.nodes.pop(pid)) as kill:
            proof=c.close(Process(),time.monotonic()+1,0.1)
        self.assertTrue(proof['ownedDescendantsGone']);self.assertTrue(proof['leaderReaped'])
        kill.assert_called_once_with(2,signal.SIGTERM)
    def test_ambiguous_process_never_signalled_or_accepted(self):
        c=self.ledger();del self.nodes[1];self.nodes[9]=self.node(9,999,9);self.commands[9]=str(self.root/'orphan')
        class Process:
            def poll(self):return 0
            def wait(self,timeout):return 0
        with patch.object(pc.os,'kill') as kill:proof=c.close(Process(),time.monotonic(),0)
        kill.assert_not_called();self.assertFalse(proof['ownedDescendantsGone'])
        self.assertEqual([x['pid'] for x in proof['ambiguous']],[9])
    def test_reused_launch_directory_refuses_before_fork(self):
        with patch.object(owner.os,'fork') as fork,self.assertRaises(FileExistsError):
            owner.launch(self.root,lambda:0,{},overall_seconds=1)
        fork.assert_not_called()
    def test_direct_child_parent_must_match(self):
        self.nodes[1]['ppid']=999
        with self.assertRaisesRegex(RuntimeError,'direct command child'):self.ledger()
    def test_detachment_wait_is_bounded_without_relaunch(self):
        with patch.object(owner.os,'fork',return_value=42) as fork, \
             patch.object(owner.os,'waitpid',return_value=(0,0)) as wait, \
             patch.object(owner.time,'monotonic',side_effect=[0,0,6]), \
             patch.object(owner.time,'sleep'), self.assertRaisesRegex(RuntimeError,'wait uncertain'):
            owner.launch(self.root/'new',lambda:0,{},overall_seconds=10)
        fork.assert_called_once();wait.assert_called_once_with(42,owner.os.WNOHANG)
    def test_ack_timeout_never_relaunches(self):
        with patch.object(owner.os,'fork',return_value=42) as fork, \
             patch.object(owner.os,'waitpid',return_value=(42,0)), \
             patch.object(owner.time,'monotonic',side_effect=[0,0,6]), \
             self.assertRaisesRegex(RuntimeError,'acknowledgement uncertain'):
            owner.launch(self.root/'new',lambda:0,{},overall_seconds=10)
        fork.assert_called_once()
    def test_complete_publication_refuses_existing_evidence(self):
        target=self.root/'record.json';owner.exclusive(target,{'first':True})
        with self.assertRaises(FileExistsError):owner.exclusive(target,{'second':True})
        self.assertEqual(json.loads(target.read_text()),{'first':True})
    def test_late_child_discovered_and_term_then_kill_escalates(self):
        c=self.ledger();self.nodes[2]=self.node(2,1,2);c.refresh()
        class Process:
            def poll(self):return 0
            def wait(self,timeout):return 0
        def kill(pid,sig):
            if pid==1:
                self.nodes[3]=self.node(3,2,3)
                self.nodes.pop(1,None)
            elif pid==2 and sig==signal.SIGTERM:pass
            else:self.nodes.pop(pid,None)
        with patch.object(pc.os,'kill',side_effect=kill):
            proof=c.close(Process(),time.monotonic()+1,0.06)
        self.assertTrue(proof['ownedDescendantsGone']);self.assertIn(3,c.known)
        self.assertIn({'pid':2,'signal':'SIGKILL'},proof['signals'])
    def test_surviving_descendant_refuses_closure(self):
        c=self.ledger()
        class Process:
            def poll(self):return 0
            def wait(self,timeout):return 0
        with patch.object(pc.os,'kill'):
            proof=c.close(Process(),time.monotonic(),0)
        self.assertFalse(proof['ownedDescendantsGone'])
    def control(self):
        c=owner.Control.__new__(owner.Control);c.directory=self.root
        c.owner={'nonce':'one','identity':self.node(1,0,1),'overallDeadline':time.monotonic()+10};c.last=0
        return c
    def test_stale_control_identity_refuses(self):
        c=self.control();(self.root/'STOP.json').write_text(json.dumps({'nonce':'wrong','identity':c.owner['identity']}))
        with self.assertRaisesRegex(RuntimeError,'identity mismatch'):c.check('test')
    def test_exact_control_causes_terminal_stop(self):
        c=self.control();(self.root/'STOP.json').write_text(json.dumps({'nonce':'one','identity':c.owner['identity']}))
        with self.assertRaisesRegex(RuntimeError,'stop requested'):c.check('test')
    def test_heartbeat_is_bounded_and_replaced(self):
        c=self.control();c.check('first');c.last=0;c.check('second')
        self.assertEqual(json.loads((self.root/'STATUS.json').read_text())['phase'],'second')
        self.assertLess((self.root/'STATUS.json').stat().st_size,4096)
    def test_same_original_cap_boundaries(self):
        g=guard.GuardedRunner.__new__(guard.GuardedRunner)
        g.free_floor=12*2**30;g.packet_ceiling=8*2**30;g.log_ceiling=512*2**20
        good={'freeBytes':12*2**30,'packetBytes':8*2**30,'logBytes':512*2**20}
        self.assertIsNone(g.violation(good))
        self.assertEqual(g.violation(good|{'freeBytes':good['freeBytes']-1}),'disk floor')
        self.assertEqual(g.violation(good|{'packetBytes':good['packetBytes']+1}),'artifact ceiling')
        self.assertEqual(g.violation(good|{'logBytes':good['logBytes']+1}),'artifact ceiling')
    def test_actual_detached_entry_creates_owner_then_authenticates_before_staging(self):
        root=self.root/'runtime';directory=root.with_name(root.name+'-owner')
        config={'runtimeRoot':str(root),'proposedLimits':{'overallSeconds':10}}
        calls=[];seal='a'*64
        class StagingReached(Exception):pass
        def packet(expected,*,no_runtime=False,prelaunch=False):
            self.assertEqual(expected,seal)
            calls.append((no_runtime,prelaunch,directory.exists()))
            source_checks.fresh_roots(config,require_no_runtime=no_runtime,require_no_owner=prelaunch)
            return config
        def launch(directory,body,description,*,overall_seconds):
            directory.mkdir()
            control=SimpleNamespace(owner={'description':description},check=lambda phase:None)
            with patch.object(owner,'Control',return_value=control), \
                 patch.object(Path,'mkdir',side_effect=StagingReached):
                return body()  # Actual qualify.main must reach runtime creation after authentication.
        with patch.object(qualify,'source_packet',side_effect=packet), \
             patch.object(owner,'launch',side_effect=launch), \
             patch.object(owner.sys,'argv',['detached_owner.py','--reviewed-sdk-owned-page-qualification','--source-ready-sha256',seal]), \
             self.assertRaises(StagingReached):
            owner.main()
        self.assertEqual(calls,[(True,True,False),(True,False,True)])
        self.assertFalse(root.exists())
    def test_owner_directory_allowed_only_after_prelaunch_and_runtime_always_fresh(self):
        root=self.root/'runtime';directory=root.with_name(root.name+'-owner')
        config={'runtimeRoot':str(root)};directory.mkdir()
        with self.assertRaisesRegex(AssertionError,'before launch'):
            source_checks.fresh_roots(config,require_no_runtime=True,require_no_owner=True)
        source_checks.fresh_roots(config,require_no_runtime=True,require_no_owner=False)
        root.mkdir()
        with self.assertRaisesRegex(AssertionError,'runtime root'):
            source_checks.fresh_roots(config,require_no_runtime=True,require_no_owner=False)
    def test_qualifier_refuses_unowned_direct_entry_before_runtime_creation(self):
        root=self.root/'runtime';config={'runtimeRoot':str(root)}
        with patch.object(qualify,'source_packet',return_value=config), \
             patch.object(owner,'Control',return_value=SimpleNamespace(owner=None)), \
             patch.object(owner.sys,'argv',['qualify.py','--reviewed-sdk-owned-page-qualification','--source-ready-sha256','a'*64]), \
             self.assertRaisesRegex(ValueError,'authenticated detached owner required'):
            qualify.main()
        self.assertFalse(root.exists())


if __name__=='__main__':unittest.main()
