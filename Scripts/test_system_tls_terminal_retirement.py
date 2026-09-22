"""Pure owned-child terminal schedules. No process, signal or trust operation."""
import contextlib
import signal
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import system_tls_privileged as helper
import test_system_tls_privileged as prior


class TerminalRetirement(unittest.TestCase):
    def execute(self, *, group='gone', terminal_pid=707, terminal_code=1,
                active=False, expired=False, wait_failure=False, late_absence=False):
        events = []; clock = prior.Clock()
        class Process:
            pid = 707; returncode = None
            def wait(self, timeout):
                events.append(('reap', self.pid, timeout))
                if wait_failure: raise subprocess.TimeoutExpired('owned child', timeout)
                self.returncode = 0
                return 0
        process = Process()
        terminal = None if active else SimpleNamespace(si_pid=terminal_pid, si_code=terminal_code, si_status=0)
        def observe(pgid, number):
            events.append(('group', pgid, number))
            self.assertEqual(pgid, process.pid)
            if number:
                self.assertIsNone(process.returncode, 'never signal a reusable PGID after reap')
                if not active: raise PermissionError('unnecessary signal would reproduce TLS004')
            else:
                self.assertEqual(process.returncode, 0, 'absence is observed after exact reap')
                if group == 'permission': raise PermissionError('absence is unproved')
                if group == 'gone':
                    if late_absence: clock.value = 200
                    raise ProcessLookupError()
        with contextlib.ExitStack() as stack:
            for target, name, value in (
                    (helper.os, 'killpg', observe), (helper.time, 'monotonic', clock.now),
                    (helper.time, 'sleep', clock.sleep), (helper.os, 'CLD_EXITED', 1),
                    (helper.os, 'CLD_KILLED', 2), (helper.os, 'CLD_DUMPED', 3)):
                stack.enter_context(patch.object(target, name, value, create=True))
            result = helper.retire(process, 99 if expired else 104, terminal)
        return result, events, clock.value

    def test_terminal_success_never_attempts_destructive_signal_that_would_fail(self):
        result, events, _ = self.execute()
        self.assertEqual(result, {'groupGone': True, 'leaderReaped': True, 'signals': [], 'errors': []})
        self.assertEqual([x[0] for x in events], ['reap', 'group'])
        self.assertEqual(events[-1], ('group', 707, 0))

    def test_live_group_after_terminal_reap_refuses_without_signalling(self):
        result, events, elapsed = self.execute(group='live')
        self.assertTrue(result['leaderReaped']); self.assertFalse(result['groupGone'])
        self.assertEqual(result['signals'], []); self.assertEqual(result['errors'], [])
        self.assertTrue(all(x[2] == 0 for x in events if x[0] == 'group'))
        self.assertLess(elapsed, 105)

    def test_permission_denied_absence_is_not_proof(self):
        result, events, _ = self.execute(group='permission')
        self.assertTrue(result['leaderReaped']); self.assertFalse(result['groupGone'])
        self.assertEqual(result['signals'], [])
        self.assertEqual(result['errors'], [{'type': 'PermissionError', 'message': 'absence is unproved'}])
        self.assertEqual(events[-1], ('group', 707, 0))

    def test_foreign_pid_observation_cannot_select_terminal_retirement(self):
        result, events, _ = self.execute(terminal_pid=708)
        self.assertFalse(result['leaderReaped']); self.assertFalse(result['groupGone'])
        self.assertEqual(result['errors'][0]['type'], 'ValueError'); self.assertEqual(events, [])

    def test_nonterminal_status_cannot_select_terminal_retirement(self):
        result, events, _ = self.execute(terminal_code=4)
        self.assertFalse(result['leaderReaped']); self.assertFalse(result['groupGone'])
        self.assertEqual(result['errors'][0]['type'], 'ValueError'); self.assertEqual(events, [])

    def test_expired_original_retirement_deadline_does_not_wait_or_probe(self):
        result, events, _ = self.execute(expired=True)
        self.assertFalse(result['leaderReaped']); self.assertFalse(result['groupGone'])
        self.assertEqual(events, [])

    def test_failed_exact_reap_cannot_probe_or_claim_group_absence(self):
        result, events, _ = self.execute(wait_failure=True)
        self.assertFalse(result['leaderReaped']); self.assertFalse(result['groupGone'])
        self.assertEqual(result['errors'][0]['type'], 'TimeoutExpired')
        self.assertEqual([x[0] for x in events], ['reap'])

    def test_absence_returning_after_deadline_does_not_authorize_cleanup(self):
        result, events, _ = self.execute(late_absence=True)
        self.assertTrue(result['leaderReaped']); self.assertFalse(result['groupGone'])
        self.assertEqual(events[-1], ('group', 707, 0))

    def test_active_child_retains_signal_before_reap_order(self):
        result, events, _ = self.execute(active=True)
        self.assertTrue(result['leaderReaped']); self.assertTrue(result['groupGone'])
        self.assertEqual(result['signals'], [signal.SIGTERM, signal.SIGKILL])
        self.assertEqual([x[0] for x in events], ['group', 'group', 'reap', 'group'])
        self.assertEqual(events[-1], ('group', 707, 0))


class TerminalSupervisor(unittest.TestCase):
    # Reuse the actual-supervisor fixture only, not its seventeen test methods.
    setUp = prior.PrivilegedLifecycle.setUp
    tearDown = prior.PrivilegedLifecycle.tearDown
    execute = prior.PrivilegedLifecycle.execute

    def test_nonzero_terminal_status_preserves_primary_without_signal(self):
        success, record, events = self.execute('nonzero')
        self.assertFalse(success); self.assertEqual(record['exitCode'], 7)
        self.assertEqual(record['primaryError']['message'], 'privileged TLS command failed')
        self.assertEqual(record['terminalObservation'], {'pid': 707, 'code': 1, 'status': 7})
        self.assertTrue(record['cleanup']['groupGone']); self.assertEqual(record['cleanup']['signals'], [])
        self.assertEqual([x[2] for x in events if x[0] == 'signal'], [0])

    def test_cancel_after_terminal_observation_never_becomes_success(self):
        original = helper.retire
        def retire(process, deadline, terminal):
            self.assertEqual(terminal.si_pid, process.pid)
            # Invoke the installed mock handler; never deliver an OS signal.
            handler = helper.signal.signal(signal.SIGTERM, signal.SIG_IGN)
            helper.signal.signal(signal.SIGTERM, handler)
            handler(signal.SIGTERM, None)
            return original(process, deadline, terminal)
        with patch.object(helper, 'retire', side_effect=retire):
            success, record, _ = self.execute()
        self.assertFalse(success); self.assertEqual(record['receivedSignals'], [signal.SIGTERM])
        self.assertTrue(record['cleanup']['groupGone']); self.assertEqual(record['cleanup']['signals'], [])

    def test_active_cancellation_keeps_original_error_and_anchor(self):
        success, record, events = self.execute('signal')
        self.assertFalse(success); self.assertIn('caller exited', record['primaryError']['message'])
        self.assertEqual(record['receivedSignals'], [signal.SIGTERM])
        self.assertNotIn('terminalObservation', record)
        before_reap = events[:next(i for i, event in enumerate(events) if event[0] == 'wait')]
        self.assertEqual([x[2] for x in before_reap if x[0] == 'signal'], [signal.SIGTERM, signal.SIGKILL])


if __name__ == '__main__': unittest.main()
