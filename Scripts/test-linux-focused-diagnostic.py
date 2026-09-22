"""Pure fixtures for the Linux control; never starts a process or reads procfs."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('focused', Path(__file__).with_name('run-linux-focused-diagnostic.py'))
control = importlib.util.module_from_spec(spec);spec.loader.exec_module(control)


class ControlTests(unittest.TestCase):
    def test_proc_comm_parentheses_do_not_shift_birth_identity(self):
        values = ['S', '10', '42', '42'] + ['0']*15 + ['123456'] + ['0']*3
        row = control.parse_proc_stat(42, '42 (swift (test) worker) ' + ' '.join(values))
        self.assertEqual((row['pid'], row['ppid'], row['pgid'], row['session'], row['startTicks']), (42,10,42,42,123456))

    def test_reused_pid_is_not_same_original_process(self):
        old = {'pid':42,'startTicks':123,'uid':1000}
        with patch.object(control, 'proc_identity', return_value={**old, 'startTicks':124}):
            self.assertFalse(control.same_process(old))

    def test_group_signal_refuses_changed_session(self):
        old = {'pid':42,'startTicks':123,'uid':1000,'pgid':42,'session':42}
        with patch.object(control, 'proc_identity', return_value={**old,'session':99}), patch.object(control.os,'killpg') as send:
            with self.assertRaises(RuntimeError): control.signal_owned_group(type('P',(),{'pid':42})(), old, 15)
            send.assert_not_called()

    def test_child_exit_during_proc_observation_is_normal(self):
        old = {'pid':42,'startTicks':123,'uid':1000,'state':'S'}
        with patch.object(control, 'proc_identity', side_effect=FileNotFoundError):
            self.assertEqual(control.live_processes({42:old}), [])
        with patch.object(control, 'proc_identity', return_value={**old,'state':'Z'}):
            self.assertEqual(control.live_processes({42:old}), [])

    def test_missing_debugger_does_not_claim_a_stack_or_launch_process(self):
        with patch.object(control.shutil,'which',return_value=None), patch.object(control.subprocess,'Popen') as spawn:
            result = control.debugger({'pid':42}, Path(SCRATCH), 1000)
            self.assertFalse(result['stackCaptured'])
            self.assertFalse(result['available'])
            self.assertFalse(result['directlyJoined'])
            spawn.assert_not_called()

    def test_progress_tail_preserves_incomplete_last_line(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as d:
            path = Path(d)/'events.jsonl'
            path.write_text('{"kind":"testStarted"}\n{"kind":')
            result = control.progress_tail(path)
            self.assertEqual(result['events'],[{'kind':'testStarted'}])
            self.assertEqual(result['unparsedLines'],1)

    def fixture(self, root):
        expected, _ = control.expected_tests(root)
        tree = ET.Element('testsuites');suite = ET.SubElement(tree,'testsuite',tests='32',errors='0',failures='0',skipped='0')
        for classname, name in sorted(expected): ET.SubElement(suite,'testcase',classname=classname,name=name)
        return expected, tree

    def test_exact_membership_is_32_not_just_nearest_query(self):
        expected, _ = control.expected_tests(Path(__file__).resolve().parent.parent)
        self.assertEqual(len(expected),32)
        self.assertIn(('LatticeTests.GeoboundsTests','test_GroupBy_WithBoundsQuery()'),expected)
        self.assertIn(('LatticeTests.GeoboundsTests','test_GroupBy_WithNearestQuery()'),expected)

    def test_xml_membership_and_native_evidence_are_both_required(self):
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(dir=SCRATCH) as d:
            d = Path(d);expected,tree = self.fixture(root)
            (d/'focused-swift-testing.xml').write_bytes(ET.tostring(tree))
            (d/'focused-events.jsonl').write_text(json.dumps({'kind':'event','payload':{'kind':'runEnded'}})+'\n')
            self.assertTrue(control.qualify_results(d,expected)['passed'])
            (d/'focused-events.jsonl').write_text('')
            with self.assertRaises(AssertionError): control.qualify_results(d,expected)

    def test_duplicate_or_skipped_case_cannot_claim_complete(self):
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(dir=SCRATCH) as d:
            d = Path(d);expected,tree = self.fixture(root)
            (d/'focused-events.jsonl').write_text('{}\n')
            cases = list(tree.iter('testcase'));cases[-1].set('name',cases[0].get('name'));cases[-1].set('classname',cases[0].get('classname'))
            (d/'focused.xml').write_bytes(ET.tostring(tree))
            with self.assertRaises(AssertionError): control.qualify_results(d,expected)
            expected,tree = self.fixture(root);ET.SubElement(next(tree.iter('testcase')),'skipped')
            (d/'focused.xml').write_bytes(ET.tostring(tree))
            with self.assertRaises(AssertionError): control.qualify_results(d,expected)


if __name__ == '__main__':
    if len(sys.argv)!=2: raise SystemExit('usage: test-linux-focused-diagnostic.py ABSOLUTE_SCRATCH')
    SCRATCH = Path(sys.argv.pop()).resolve();SCRATCH.mkdir(parents=True,exist_ok=True)
    unittest.main()
