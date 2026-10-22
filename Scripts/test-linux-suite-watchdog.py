#!/usr/bin/env python3
"""Small process fixtures; never invokes Swift, a network, or a repository store."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("watchdog", Path(__file__).with_name("linux-suite-watchdog.py"))
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)


def portable_rows(group):
    # Only used by these tiny fixtures on macOS; production always uses /proc.
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,pgid=,stat="], text=True)
    rows = []
    for line in output.splitlines():
        pid, pgid, state = line.split()
        if int(pgid) == group:
            rows.append({"pid": int(pid), "group": int(pgid), "state": state[0]})
    return rows


class WatchdogTests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ.get("LATTICE_WATCHDOG_FIXTURE_ROOT", Path.home() / "localdev" / "watchdog-fixtures"))
        self.assertTrue(root.is_absolute() and "localdev" in root.parts)
        root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="suite-", dir=root)
        self.root = Path(self.temporary.name)
        if sys.platform == "linux":
            watchdog.become_subreaper()

    def tearDown(self):
        self.temporary.cleanup()

    def run_fixture(self, code, seconds=5, diagnose=None):
        output = self.root / "evidence"
        result = watchdog.supervise([sys.executable, "-c", code], output, seconds,
            inspect=watchdog.owned_rows if sys.platform == "linux" else portable_rows,
            diagnose=diagnose or (lambda *_: None))
        return result, json.loads((output / "result.json").read_text())

    def test_success_and_exit_status_are_preserved(self):
        for code in (0, 17):
            with self.subTest(code=code):
                self.root = Path(self.temporary.name) / str(code)
                result, report = self.run_fixture("raise SystemExit(" + str(code) + ")")
                self.assertEqual(result, code)
                self.assertEqual(report["testExitCode"], code)
                self.assertTrue(report["cleanupComplete"])
                self.assertNotIn("terminatedPIDs", report)

    def test_timeout_captures_before_killing_term_ignoring_process(self):
        def capture(directory, pid):
            os.kill(pid, 0)
            (directory / "observed-live").write_text(str(pid))
        result, report = self.run_fixture(
            "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)",
            seconds=0.3, diagnose=capture)
        self.assertEqual(result, 124)
        self.assertTrue((self.root / "evidence" / "observed-live").exists())
        self.assertTrue(report["timedOut"] and report["forcedKill"] and report["cleanupComplete"])
        self.assertEqual(report["testExitCode"], -signal.SIGKILL)
        with self.assertRaises(ProcessLookupError):
            os.kill(report["pid"], 0)

    def test_timeout_reaps_descendants_and_does_not_signal_unrelated_process(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
        try:
            child_file = self.root / "child-pid"
            code = ("import os,signal,time; p=os.fork(); "
                    "signal.signal(signal.SIGTERM, lambda *_: (os.waitpid(p,0),exit(0)) if p else exit(0)); "
                    "open(" + repr(str(child_file)) + ",'w').write(str(os.getpid())) if not p else None; time.sleep(30)")
            result, report = self.run_fixture(code, seconds=0.5)
            self.assertEqual(result, 124)
            self.assertTrue(report["cleanupComplete"])
            self.assertIsNone(unrelated.poll())
            self.assertEqual(report["survivors"], [])
            with self.assertRaises(ProcessLookupError):
                os.kill(int(child_file.read_text()), 0)
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_diagnostic_failure_still_kills_and_reports_timeout(self):
        def failed(*_):
            raise OSError("fixture diagnostic unavailable")
        result, report = self.run_fixture("import time; time.sleep(30)", seconds=0.2, diagnose=failed)
        self.assertEqual(result, 124)
        self.assertEqual(report["diagnosticError"], "OSError")
        self.assertTrue(report["cleanupComplete"])

    def test_inspection_failure_does_not_leak_owned_process(self):
        def failed(_):
            raise ValueError("fixture inventory overflow")
        output = self.root / "evidence"
        result = watchdog.supervise([sys.executable, "-c", "import time; time.sleep(30)"], output, 0.2,
                                   inspect=failed, diagnose=lambda *_: None)
        report = json.loads((output / "result.json").read_text())
        self.assertEqual(result, 124)
        self.assertEqual(report["cleanupError"], "ValueError")
        self.assertFalse(report["cleanupComplete"])
        with self.assertRaises(ProcessLookupError):
            os.kill(report["pid"], 0)

    def test_signal_during_spawn_is_deferred_until_owned_child_cleanup(self):
        original = subprocess.Popen
        signalled = False
        def spawn(*args, **kwargs):
            nonlocal signalled
            child = original(*args, **kwargs)
            if not signalled:
                signalled = True
                os.kill(os.getpid(), signal.SIGTERM)
            return child
        with patch.object(watchdog.subprocess, "Popen", side_effect=spawn):
            result, report = self.run_fixture("import time; time.sleep(30)")
        self.assertEqual(result, 128 + signal.SIGTERM)
        self.assertTrue(report["cleanupComplete"])
        with self.assertRaises(ProcessLookupError):
            os.kill(report["pid"], 0)

    def test_post_reap_inspection_failure_never_signals_reusable_group(self):
        scans = 0
        inspect = watchdog.owned_rows if sys.platform == "linux" else portable_rows
        def failed_after_reap(group):
            nonlocal scans
            scans += 1
            if scans > 1:
                # The first scan sees the unreaped, normally exited leader;
                # the next scan occurs after child.wait() has reaped it.
                with self.assertRaises(ProcessLookupError):
                    os.kill(group, 0)
                raise ValueError("fixture post-reap inventory failure")
            return inspect(group)
        output = self.root / "evidence"
        with patch.object(watchdog.os, "killpg") as signal_group:
            result = watchdog.supervise([sys.executable, "-c", "raise SystemExit(0)"], output, 5,
                inspect=failed_after_reap, diagnose=lambda *_: None)
        report = json.loads((output / "result.json").read_text())
        signal_group.assert_not_called()
        self.assertEqual(scans, 2)
        self.assertEqual(result, 1)
        self.assertEqual(report["testExitCode"], 0)
        self.assertEqual(report["cleanupError"], "ValueError")
        self.assertFalse(report["cleanupComplete"])

    def test_debugger_output_limit_applies_to_owned_diagnostic_only(self):
        path = self.root / "bounded.txt"
        with path.open("wb") as output:
            child = subprocess.run([sys.executable, "-c", "import os; os.write(1,b'x'*(2*1024*1024)); os.write(1,b'x')"],
                stdout=output, stderr=subprocess.DEVNULL, preexec_fn=watchdog.diagnostic_limit, timeout=5)
        self.assertNotEqual(child.returncode, 0)
        self.assertLessEqual(path.stat().st_size, watchdog.STACK_BYTES)

    def test_proc_identity_uses_group_session_and_start_after_parenthesized_name(self):
        proc = self.root / "proc"
        for pid, group, session in ((123, 123, 123), (124, 123, 123), (125, 123, 99), (126, 99, 99)):
            path = proc / str(pid)
            path.mkdir(parents=True)
            fields = ["S", "1", str(group), str(session)] + ["0"] * 15 + ["4321"]
            (path / "stat").write_text(str(pid) + " (fixture (name)) " + " ".join(fields))
        rows = watchdog.owned_rows(123, proc)
        self.assertEqual([row["pid"] for row in rows], [123, 124])
        self.assertEqual(rows[0]["start"], 4321)
        self.assertEqual(rows[0]["name"], "fixture (name)")
        path = self.root / "oversize"
        path.write_bytes(b"x" * 129)
        with self.assertRaises(ValueError):
            watchdog.read_small(path, 128)


if __name__ == "__main__":
    unittest.main()
