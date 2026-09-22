"""Pure mocked lifecycle checks; never starts sudo/Security or changes trust."""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import system_tls_privileged as helper
import system_tls_trust as trust
import system_tls_qualification as qualification

ROOT = Path(__file__).resolve().parents[2] / 'preparation/sdk-system-tls-privileged-cleanup-001/pure-test-scratch'


class Clock:
    def __init__(self): self.value = 100.0
    def now(self): self.value += 0.1; return self.value
    def sleep(self, value): self.value += value


class PrivilegedLifecycle(unittest.TestCase):
    def setUp(self):
        ROOT.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT); self.root = Path(self.temp.name)
        (self.root / 'receipts').mkdir(); (self.root / 'private').mkdir()
        self.certificate = b'mocked certificate bytes'
        (self.root / 'private/trusted-ca.pem').write_bytes(self.certificate)
        self.state = {'identity': {'actual': 'hosted'}, 'nonce': 'owned', 'workDeadline': 180, 'overallDeadline': 200}
        self.armed = {'state': self.state, 'caPEMSHA256': trust.sha(self.certificate), 'caSHA256': 'owned-sha'}
        trust.save(self.root / 'OWNERSHIP.json', self.state); trust.save(self.root / 'ARMED.json', self.armed)
        self.name = 'cleanup-1-05-remove-trust-privileged'
        self.request = {'root': str(self.root), 'name': self.name, 'nonce': 'owned', 'phase': 'cleanup-1',
                        'number': 5, 'label': 'remove-trust', 'deadline': 130, 'retirementDeadline': 134}
        self.path = self.root / 'receipts' / (self.name + '-request.json')
        trust.save(self.path, self.request)
    def tearDown(self): self.temp.cleanup()

    def execute(self, mode='success', mutation=None):
        if mutation:
            value = json.loads(self.path.read_text()); mutation(value); self.path.write_text(json.dumps(value))
        events = []; clock = Clock(); handlers = {}
        class Process:
            pid = 707; returncode = None
            def wait(self, timeout):
                events.append(('wait', timeout)); self.returncode = 7 if mode == 'nonzero' else 0
        process = Process()
        def group(pgid, number):
            events.append(('signal', pgid, number))
            if mode == 'permission': raise PermissionError('owned group was not retired')
            if number == 0: raise ProcessLookupError()
        def waitid(*_args):
            if mode == 'signal': handlers[signal.SIGTERM](signal.SIGTERM, None); return None
            if mode in ('timeout', 'eof'): return None
            return SimpleNamespace(si_code=1, si_status=7 if mode == 'nonzero' else 0)
        def launch(argv, **kwargs):
            events.append(('launch', argv, kwargs)); return process
        def register(number, handler):
            old = handlers.get(number, signal.SIG_DFL); handlers[number] = handler; return old
        uid, gid = self.path.stat().st_uid, self.path.stat().st_gid
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, {'SUDO_UID': str(uid), 'SUDO_GID': str(gid)}))
            for target, name, value in [
                (helper.os, 'geteuid', lambda: 0), (helper.os, 'uname', lambda: SimpleNamespace(sysname='Darwin')),
                (helper.pwd, 'getpwuid', lambda _: SimpleNamespace(pw_dir=str(self.root))),
                (trust, 'hosted', lambda *a, **k: self.state['identity']),
                (helper.subprocess, 'Popen', launch), (helper.os, 'killpg', group),
                (helper.os, 'waitid', waitid), (helper.time, 'monotonic', clock.now), (helper.time, 'sleep', clock.sleep),
                (helper.select, 'select', lambda *a: ([0] if mode == 'eof' else [], [], [])),
                (helper.os, 'read', lambda *_: b''), (helper.os, 'fstat', lambda _: SimpleNamespace(st_size=0)),
                (helper.signal, 'signal', register),
                (helper, 'write_receipt', lambda path, value, *_: trust.save(path, value)),
                (helper.os, 'CLD_EXITED', 1), (helper.os, 'P_PID', 1),
                (helper.os, 'WEXITED', 4), (helper.os, 'WNOHANG', 1), (helper.os, 'WNOWAIT', 16),
            ]:
                stack.enter_context(patch.object(target, name, value, create=True))
            stack.enter_context(patch.object(trust.ctypes, 'CDLL', side_effect=AssertionError('no native framework')))
            outcome = helper.supervise(self.path)
        return outcome, json.loads((self.root / 'receipts' / (self.name + '-result.json')).read_text()), events

    def test_completed_command_still_retires_descendants_before_reaping(self):
        ok, record, events = self.execute()
        self.assertTrue(ok); self.assertEqual(record['exitCode'], 0)
        before_wait = events[:next(i for i, item in enumerate(events) if item[0] == 'wait')]
        self.assertEqual([item[2] for item in before_wait if item[0] == 'signal'], [signal.SIGTERM, signal.SIGKILL])
        self.assertTrue(record['cleanup']['groupGone']); self.assertTrue(record['cleanup']['leaderReaped'])
        self.assertEqual(events[0][1], [trust.SECURITY, 'remove-trusted-cert', '-d', str(self.root / 'private/trusted-ca.pem')])
        self.assertTrue(events[0][2]['start_new_session'])

    def test_timeout_retirement_does_not_become_success(self):
        ok, record, _ = self.execute('timeout')
        self.assertFalse(ok); self.assertIn('original time/output', record['primaryError']['message'])
        self.assertTrue(record['cleanup']['groupGone']); self.assertEqual(record['deadline'], 130)
        self.assertEqual(record['retirementDeadline'], 134)

    def test_caller_eof_cancels_privileged_work(self):
        ok, record, _ = self.execute('eof')
        self.assertFalse(ok); self.assertIn('caller exited', record['primaryError']['message'])
        self.assertTrue(record['cleanup']['groupGone'])

    def test_signal_cannot_turn_cleanup_into_success(self):
        ok, record, _ = self.execute('signal')
        self.assertFalse(ok); self.assertEqual(record['receivedSignals'], [signal.SIGTERM])
        self.assertTrue(record['cleanup']['groupGone'])

    def test_nonzero_command_preserves_first_error_after_retirement(self):
        ok, record, _ = self.execute('nonzero')
        self.assertFalse(ok); self.assertEqual(record['exitCode'], 7)
        self.assertEqual(record['primaryError']['message'], 'privileged TLS command failed')
        self.assertTrue(record['cleanup']['groupGone'])

    def test_permission_failure_is_not_retirement_proof(self):
        ok, record, _ = self.execute('permission')
        self.assertFalse(ok); self.assertFalse(record['cleanup']['groupGone'])
        self.assertTrue(record['cleanup']['errors'])
        with self.assertRaisesRegex(RuntimeError, 'no retirement proof'): trust.privileged_result(self.path)

    def test_expired_deadline_never_launches_command(self):
        with patch.object(helper.subprocess, 'Popen', side_effect=AssertionError('no process')):
            with self.assertRaisesRegex(ValueError, 'deadline differs'):
                self.execute(mutation=lambda value: value.update(deadline=99))

    def test_foreign_command_phase_refuses_before_launch(self):
        with self.assertRaisesRegex(ValueError, 'outside its phase'):
            self.execute(mutation=lambda value: value.update(phase='prepare'))

    def test_wrapper_proof_is_required_even_after_child_retirement(self):
        _, record, _ = self.execute()
        with self.assertRaises(FileNotFoundError): trust.privileged_commands_gone(self.root)
        receipt = self.path.with_name(self.name.removesuffix('-privileged') + '.json')
        parent = {'privilegedRequest': str(self.path), 'privilegedCleanup': record, 'privilegedWrapperGroupGone': False}
        trust.save(receipt, parent)
        with self.assertRaisesRegex(RuntimeError, 'wrapper has no bound'): trust.privileged_commands_gone(self.root)
        parent['privilegedWrapperGroupGone'] = True; receipt.write_text(json.dumps(parent))
        trust.privileged_commands_gone(self.root)

    def test_foreign_completion_cannot_authorize_cleanup(self):
        self.execute(); result = self.path.with_name(self.name + '-result.json')
        value = json.loads(result.read_text()); value['nonce'] = 'foreign'; result.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'another request'): trust.privileged_result(self.path)

    def test_arbitrary_executable_is_not_an_operation(self):
        with self.assertRaisesRegex(ValueError, 'unreviewed'): helper.command(self.root, '/bin/sh', self.armed)

    def test_cleanup_retry_retains_first_failure_and_original_runner(self):
        runner = object(); attempts = []
        def cleanup(actual, sdk, root, attempt):
            self.assertIs(actual, runner); self.assertEqual(root, self.root); attempts.append(attempt)
            if attempt == 1: raise RuntimeError('original cleanup failure')
            trust.save(root / 'receipts/RESTORED.json', {'success': True, 'nonce': 'owned'})
        with patch.object(qualification, 'owned_commands_gone'), patch.object(trust, 'privileged_commands_gone'), patch.object(qualification, 'cleanup_command', side_effect=cleanup):
            failures = qualification.restore_trust(runner, self.root, self.root, 'owned')
        self.assertEqual(attempts, [1, 2]); self.assertEqual(failures, [{'type': 'RuntimeError', 'message': 'original cleanup failure'}])

    def test_cleanup_cannot_retry_while_prior_root_process_is_unproved(self):
        with patch.object(qualification, 'owned_commands_gone'), patch.object(trust, 'privileged_commands_gone', side_effect=[None, RuntimeError('root child unproved')]), patch.object(qualification, 'cleanup_command', side_effect=RuntimeError('first failure')) as cleanup:
            failures = qualification.restore_trust(object(), self.root, self.root, 'owned')
        self.assertEqual(cleanup.call_count, 1); self.assertEqual(len(failures), 2)
        self.assertEqual(failures[-1]['message'], 'root child unproved')

    def test_cleanup_retry_is_finite_even_if_both_attempts_fail(self):
        with patch.object(qualification, 'owned_commands_gone'), patch.object(trust, 'privileged_commands_gone'), patch.object(qualification, 'cleanup_command', side_effect=RuntimeError('failure')) as cleanup:
            failures = qualification.restore_trust(object(), self.root, self.root, 'owned')
        self.assertEqual(cleanup.call_count, 2); self.assertEqual(len(failures), 2)

    def parent_command(self, result_present):
        class Wrapper:
            pid = 909; returncode = 0; stdin = io.StringIO()
            def poll(self): return 0
        def launch(argv, **kwargs):
            self.assertEqual(argv[0:2], ['sudo', '-n'])
            self.assertIn('-I', argv); self.assertIn('-B', argv)
            self.assertTrue(kwargs['start_new_session'])
            request_path = Path(argv[-1]); request = json.loads(request_path.read_text())
            if result_present:
                proof = {'nonce': request['nonce'], 'requestSHA256': trust.sha(request_path.read_bytes()),
                         'argv': helper.command(self.root, 'install', self.armed), 'deadline': request['deadline'],
                         'retirementDeadline': request['retirementDeadline'], 'success': True,
                         'cleanup': {'groupGone': True, 'leaderReaped': True, 'errors': []}}
                trust.save(request_path.with_name(request['name'] + '-result.json'), proof)
            return Wrapper()
        with patch.object(trust.time, 'monotonic', return_value=100), patch.object(trust.os, 'waitid', lambda *a: None, create=True), patch.object(trust.subprocess, 'Popen', side_effect=launch), patch.object(helper, 'group_present', return_value=False):
            return trust.Commands(self.root, 'install', 200).run('install', ['sudo', '-n', *helper.command(self.root, 'install', self.armed)])

    def test_parent_requires_bound_privileged_result_even_when_sudo_exits_zero(self):
        with self.assertRaises(FileNotFoundError): self.parent_command(False)
        record = json.loads((self.root / 'receipts/install-01-install.json').read_text())
        self.assertFalse(record['success']); self.assertTrue(record['evidenceErrors'])

    def test_parent_checks_work_and_wrapper_retirement_before_return(self):
        self.assertEqual(self.parent_command(True), b'')
        record = json.loads((self.root / 'receipts/install-01-install.json').read_text())
        self.assertTrue(record['success']); self.assertTrue(record['privilegedWrapperGroupGone'])
        self.assertTrue(record['privilegedCleanup']['cleanup']['groupGone'])

    def test_parent_rejects_unreviewed_privileged_argv_before_launch(self):
        with patch.object(trust.time, 'monotonic', return_value=100), patch.object(trust.os, 'waitid', lambda *a: None, create=True), patch.object(trust.subprocess, 'Popen', side_effect=AssertionError('no native process')) as launch:
            with self.assertRaisesRegex(ValueError, 'argv differs'):
                trust.Commands(self.root, 'install', 200).run('install', ['sudo', '-n', trust.SECURITY, 'foreign-command'])
        launch.assert_not_called()


if __name__ == '__main__': unittest.main()
