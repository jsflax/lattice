"""Pure cooperative signal schedules; no signal, process or trust operation."""
import contextlib
import json
from pathlib import Path
import signal
import sys
import unittest
from unittest.mock import patch

import system_tls_privileged as helper
import system_tls_qualification as qualification
import system_tls_trust as trust
import test_system_tls_privileged as prior


class Cancellation(unittest.TestCase):
    # Reuse only fixture construction and mocked root-supervisor execution;
    # do not inherit/redeclare the earlier seventeen test cases.
    setUp = prior.PrivilegedLifecycle.setUp
    tearDown = prior.PrivilegedLifecycle.tearDown
    execute = prior.PrivilegedLifecycle.execute

    def command(self, where, first_failure=False):
        # This fixture also supports the standalone root-supervisor test.
        # Its unused request is not part of this separate install schedule.
        self.path.unlink()
        handlers = {}
        launched = []
        receipt_path = self.root / 'receipts/install-01-install.json'
        request_path = self.root / 'receipts/install-01-install-privileged-request.json'
        original_save = trust.save
        def register(number, handler):
            previous = handlers.get(number, signal.SIG_DFL)
            handlers[number] = handler
            return previous
        def interrupt():
            handlers[signal.SIGTERM](signal.SIGTERM, None)
        def proof(success):
            request = json.loads(request_path.read_text())
            result_path = request_path.with_name(request['name'] + '-result.json')
            if result_path.exists(): return
            original_save(result_path, {
                'nonce': request['nonce'], 'requestSHA256': trust.sha(request_path.read_bytes()),
                'argv': helper.command(self.root, 'install', self.armed),
                'deadline': request['deadline'], 'retirementDeadline': request['retirementDeadline'],
                'success': success, 'cleanup': {'groupGone': True, 'leaderReaped': True, 'errors': []},
            })
        class Pipe:
            closed = False
            def close(pipe):
                pipe.closed = True
                if where == 'finally': interrupt()
                proof(False)
        class Wrapper:
            pid = 909
            returncode = 2 if first_failure else 0
            stdin = Pipe()
            polls = 0
            def poll(process):
                process.polls += 1
                if where == 'poll' and process.polls == 1:
                    interrupt()
                    return None
                return process.returncode
        def launch(argv, **kwargs):
            self.assertEqual(Path(argv[-1]), request_path)
            self.assertTrue(request_path.exists())
            self.assertTrue(kwargs['start_new_session'])
            launched.append(Wrapper())
            if where == 'launch': interrupt()
            if where in ('finally', 'receipt') or first_failure: proof(not first_failure)
            return launched[-1]
        def save(path, value):
            if Path(path) == receipt_path and where == 'receipt': interrupt()
            original_save(path, value)
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(trust.signal, 'signal', register))
            stack.enter_context(patch.object(trust.time, 'monotonic', return_value=100))
            stack.enter_context(patch.object(trust.os, 'waitid', lambda *a: None, create=True))
            stack.enter_context(patch.object(trust.subprocess, 'Popen', side_effect=launch))
            stack.enter_context(patch.object(trust.ctypes, 'CDLL', side_effect=AssertionError('no native framework')))
            stack.enter_context(patch.object(helper, 'group_present', return_value=False))
            stack.enter_context(patch.object(trust, 'save', side_effect=save))
            with trust.CommandInterrupts() as interrupts:
                commands = trust.Commands(self.root, 'install', 200, interrupts)
                if where == 'before': interrupt()
                try:
                    commands.run('install', ['sudo', '-n', *helper.command(self.root, 'install', self.armed)])
                except BaseException as error:
                    failure = error
                else:
                    self.fail('a signalled command must not return success')
        self.assertTrue(all(value == signal.SIG_DFL for value in handlers.values()))
        if where == 'before':
            self.assertEqual(launched, [])
            self.assertFalse(request_path.exists())
            return failure, None
        self.assertEqual(len(launched), 1)
        self.assertTrue(launched[0].stdin.closed)
        record = json.loads(receipt_path.read_text())
        self.assertTrue(record['privilegedWrapperGroupGone'])
        self.assertEqual(record['evidenceErrors'], [])
        # This is the actual admission gate used by finalization, not a fake
        # assertion that root-child retirement alone implies wrapper cleanup.
        trust.privileged_commands_gone(self.root)
        return failure, record

    def test_signal_before_admission_creates_no_unowned_request(self):
        failure, _ = self.command('before')
        self.assertIsInstance(failure, trust.TrustInterrupted)

    def test_term_during_popen_retains_child_and_both_bound_receipts(self):
        failure, record = self.command('launch')
        self.assertIsInstance(failure, trust.TrustInterrupted)
        self.assertFalse(record['success'])
        self.assertEqual(record['receivedSignals'], ['SIGTERM'])
        # The earlier review's real restoration gate now permits the narrow
        # cleanup call once all mocked root/wrapper ownership is proved.
        attempts = []
        def cleanup(_runner, _sdk, root, attempt):
            attempts.append(attempt)
            trust.save(root / 'receipts/RESTORED.json', {'success': True, 'nonce': 'owned'})
        with patch.object(qualification, 'owned_commands_gone'), patch.object(qualification, 'cleanup_command', side_effect=cleanup):
            self.assertEqual(qualification.restore_trust(object(), self.root, self.root, 'owned'), [])
        self.assertEqual(attempts, [1])

    def test_term_during_poll_stops_work_and_keeps_wrapper_proof(self):
        failure, record = self.command('poll')
        self.assertIsInstance(failure, trust.TrustInterrupted)
        self.assertFalse(record['success'])
        self.assertEqual(record['receivedSignals'], ['SIGTERM'])

    def test_term_during_finally_overrides_already_selected_success_return(self):
        failure, record = self.command('finally')
        self.assertIsInstance(failure, trust.TrustInterrupted)
        self.assertFalse(record['success'])
        self.assertEqual(record['receivedSignals'], ['SIGTERM'])

    def test_term_during_receipt_construction_still_fails_helper_outcome(self):
        failure, _ = self.command('receipt')
        self.assertIsInstance(failure, trust.TrustInterrupted)

    def test_cleanup_signal_preserves_earlier_command_error(self):
        failure, record = self.command('finally', first_failure=True)
        self.assertEqual(type(failure), RuntimeError)
        self.assertEqual(str(failure), 'TLS command failed: install')
        self.assertEqual(record['error']['message'], str(failure))
        self.assertFalse(record['success'])
        self.assertEqual(record['receivedSignals'], ['SIGTERM'])

    def test_early_eof_retirement_cannot_spend_unused_work_budget(self):
        success, record, events = self.execute('eof')
        self.assertFalse(success)
        waits = [item[1] for item in events if item[0] == 'wait']
        self.assertEqual(len(waits), 1)
        self.assertLessEqual(waits[0], helper.RETIRE_SECONDS)
        self.assertLess(record['cleanupDeadline'], record['retirementDeadline'])
        self.assertEqual(record['deadline'], 130)
        self.assertEqual(record['retirementDeadline'], 134)

    def test_signal_latch_is_bounded_and_never_raises_in_handler(self):
        latch = trust.CommandInterrupts()
        for _ in range(100):
            for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): latch.handle(number, None)
        self.assertEqual(latch.received, ['SIGTERM', 'SIGINT', 'SIGHUP'])
        with self.assertRaises(trust.TrustInterrupted): latch.check()

    def test_actual_main_installs_and_passes_latch_before_install_command(self):
        self.state.update(platform='Darwin', nonce='a' * 32)
        (self.root / 'OWNERSHIP.json').write_text(json.dumps(self.state))
        (self.root / 'ARMED.json').write_text(json.dumps(self.armed))
        handlers = {}
        def register(number, handler):
            old = handlers.get(number, signal.SIG_DFL)
            handlers[number] = handler
            return old
        def install(root, armed, commands):
            self.assertEqual(root, self.root)
            self.assertEqual(armed, self.armed)
            self.assertEqual(commands.deadline, self.state['workDeadline'])
            self.assertIsInstance(commands.interrupts, trust.CommandInterrupts)
            handlers[signal.SIGTERM](signal.SIGTERM, None)
            commands.run('install', ['sudo', '-n', *helper.command(root, 'install', armed)])
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sys, 'argv', ['trust', 'install', '--root', str(self.root)]))
            stack.enter_context(patch.object(trust, 'hosted', return_value=self.state['identity']))
            stack.enter_context(patch.object(trust.platform, 'system', return_value='Darwin'))
            stack.enter_context(patch.object(trust.signal, 'signal', side_effect=register))
            stack.enter_context(patch.object(trust, 'install', side_effect=install))
            launch = stack.enter_context(patch.object(trust.subprocess, 'Popen', side_effect=AssertionError('cancelled before launch')))
            with self.assertRaises(trust.TrustInterrupted): trust.main()
            launch.assert_not_called()
        self.assertTrue(all(handler == signal.SIG_DFL for handler in handlers.values()))


if __name__ == '__main__': unittest.main()
