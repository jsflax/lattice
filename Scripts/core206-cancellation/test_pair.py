import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('pair', HERE / 'run-pair.py')
PAIR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PAIR)


class PairTests(unittest.TestCase):
    def setUp(self):
        scratch = HERE / 'test-scratch'
        scratch.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.tmp.name)
        self.packet = self.root / 'tools'
        self.packet.mkdir()
        for _, name, core in PAIR.ARMS:
            (self.packet / name).write_text(json.dumps({'coreCommit': core}))
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()
        (HERE / 'test-scratch').rmdir()

    def fake_runner(self, *, fail_control=False, signal_control=False, omit_command=False):
        def run():
            args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
            root = Path(args['--root'])
            self.calls.append(root.name)
            receipts = root / 'receipts'
            receipts.mkdir()
            success = not (fail_control and root.name == 'A-core205')
            signals = ['SIGTERM'] if signal_control and root.name == 'A-core205' else []
            command = {'started': True, 'success': success, 'receivedSignals': signals,
                       'cleanup': {'groupGone': True, 'leaderReaped': True, 'signals': [], 'errors': []}}
            if not omit_command:
                (receipts / 'full-test.json').write_text(json.dumps(command))
            (receipts / 'RESULT.json').write_text(json.dumps({
                'success': success, 'receivedSignals': signals,
                'commands': [{'label': 'full-test', 'success': success}]}))
            if not success:
                raise RuntimeError('preserved control assertion failure')
        return run

    def test_control_failure_is_retained_and_candidate_runs_once(self):
        result = PAIR.run_pair(self.root, self.packet, self.fake_runner(fail_control=True), clock=lambda: 100)
        self.assertEqual(self.calls, ['A-core205', 'B-core206'])
        self.assertFalse(result['allArmsSucceeded'])
        self.assertTrue(result['candidateRuntimeSucceeded'])
        self.assertEqual(result['arms'][0]['raisedError']['message'], 'preserved control assertion failure')
        self.assertFalse(result['releaseAccepted'])

    def test_signal_prevents_second_arm(self):
        result = PAIR.run_pair(self.root, self.packet, self.fake_runner(signal_control=True), clock=lambda: 100)
        self.assertEqual(self.calls, ['A-core205'])
        self.assertIsNotNone(result['stopReason'])

    def test_missing_command_cleanup_prevents_second_arm(self):
        result = PAIR.run_pair(self.root, self.packet, self.fake_runner(omit_command=True), clock=lambda: 100)
        self.assertEqual(self.calls, ['A-core205'])
        self.assertIsNotNone(result['stopReason'])

    def test_insufficient_remaining_time_never_starts_arm(self):
        moments = iter([100, 100 + PAIR.PAIR_SECONDS - PAIR.RESERVE_SECONDS - 5399,
                        100 + PAIR.PAIR_SECONDS - PAIR.RESERVE_SECONDS - 5399,
                        100 + PAIR.PAIR_SECONDS - PAIR.RESERVE_SECONDS - 5399])
        result = PAIR.run_pair(self.root, self.packet, self.fake_runner(), clock=lambda: next(moments))
        self.assertEqual(self.calls, [])
        self.assertIn('5400', result['stopReason'])

    def test_wrong_core_never_invokes_runner(self):
        (self.packet / 'binding-A.json').write_text(json.dumps({'coreCommit': 'f' * 40}))
        result = PAIR.run_pair(self.root, self.packet, self.fake_runner(), clock=lambda: 100)
        self.assertEqual(self.calls, [])
        self.assertIn('Core binding', result['stopReason'])

    def test_fresh_roots_and_evidence_cannot_be_reused(self):
        runner = self.fake_runner()
        result = PAIR.run_pair(self.root, self.packet, runner, clock=lambda: 100)
        self.assertTrue(result['allArmsSucceeded'])
        with self.assertRaises(FileExistsError):
            PAIR.run_pair(self.root, self.packet, runner, clock=lambda: 100)
        self.assertEqual(len(self.calls), 2)

    def test_argv_is_restored_after_control_failure(self):
        before = sys.argv
        PAIR.run_pair(self.root, self.packet, self.fake_runner(fail_control=True), clock=lambda: 100)
        self.assertIs(sys.argv, before)

    def test_missing_candidate_result_preserves_failure_and_final_receipt(self):
        original = self.fake_runner()
        def runner():
            original()
            root = Path(dict(zip(sys.argv[1::2], sys.argv[2::2]))['--root'])
            if root.name == 'B-core206':
                (root / 'receipts/RESULT.json').unlink()
                raise RuntimeError('candidate original failure')
        result = PAIR.run_pair(self.root, self.packet, runner, clock=lambda: 100)
        self.assertFalse(result['allArmsSucceeded'])
        self.assertEqual(result['arms'][1]['raisedError']['message'], 'candidate original failure')
        self.assertEqual(result['arms'][1]['resultReadError']['type'], 'FileNotFoundError')
        self.assertTrue((self.root / 'pair-receipts/RESULT.json').is_file())

    def test_malformed_candidate_result_preserves_failure_and_final_receipt(self):
        original = self.fake_runner()
        def runner():
            original()
            root = Path(dict(zip(sys.argv[1::2], sys.argv[2::2]))['--root'])
            if root.name == 'B-core206':
                (root / 'receipts/RESULT.json').write_text('{')
                raise RuntimeError('candidate original failure')
        result = PAIR.run_pair(self.root, self.packet, runner, clock=lambda: 100)
        self.assertFalse(result['allArmsSucceeded'])
        self.assertEqual(result['arms'][1]['raisedError']['message'], 'candidate original failure')
        self.assertEqual(result['arms'][1]['resultReadError']['type'], 'JSONDecodeError')
        self.assertTrue((self.root / 'pair-receipts/B-core206.json').is_file())
        self.assertTrue((self.root / 'pair-receipts/RESULT.json').is_file())

    def test_malformed_command_receipt_prevents_candidate(self):
        original = self.fake_runner()
        def runner():
            original()
            root = Path(dict(zip(sys.argv[1::2], sys.argv[2::2]))['--root'])
            (root / 'receipts/full-test.json').write_text('[]')
        result = PAIR.run_pair(self.root, self.packet, runner, clock=lambda: 100)
        self.assertEqual(self.calls, ['A-core205'])
        self.assertIsNotNone(result['stopReason'])

    def test_nested_cleanup_shapes_fail_closed(self):
        receipts = self.root / 'receipts'
        receipts.mkdir()
        result = {'receivedSignals': [], 'commands': [{'label': 'full-test', 'success': True}]}
        for cleanup in [[], None, 'missing']:
            with self.subTest(cleanup=cleanup):
                (receipts / 'full-test.json').write_text(json.dumps({
                    'started': True, 'success': True, 'receivedSignals': [], 'cleanup': cleanup}))
                self.assertFalse(PAIR.can_continue(result, receipts))

    def test_missing_candidate_cleanup_never_claims_candidate_success(self):
        original = self.fake_runner()
        def runner():
            original()
            root = Path(dict(zip(sys.argv[1::2], sys.argv[2::2]))['--root'])
            if root.name == 'B-core206':
                command = root / 'receipts/full-test.json'
                value = json.loads(command.read_text())
                value['cleanup'] = None
                command.write_text(json.dumps(value))
        result = PAIR.run_pair(self.root, self.packet, runner, clock=lambda: 100)
        self.assertFalse(result['candidateRuntimeSucceeded'])
        self.assertFalse(result['allArmsSucceeded'])
        self.assertTrue((self.root / 'pair-receipts/RESULT.json').is_file())


if __name__ == '__main__':
    unittest.main()
