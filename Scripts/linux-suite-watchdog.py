#!/usr/bin/env python3
"""Linux CI deadline for an unchanged test command; no test selection or retries.

The suite owns a fresh process group. Keep its leader unreaped until cleanup so
the group ID cannot be reused. Diagnostics are bounded and best effort: ptrace
refusal is evidence, not permission to weaken the container's security policy.
"""
import argparse
import ctypes
import itertools
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import time

MAX_PROCESSES = 128
MAX_THREADS = 256
STACK_BYTES = 1024 * 1024


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def read_small(path, limit):
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("diagnostic field exceeds bound")
    return data.decode("utf-8", errors="replace").strip()


def process_row(directory):
    raw = read_small(directory / "stat", 8192)
    split = raw.rfind(")")
    fields = raw[split + 2:].split()
    if split < 0 or len(fields) < 20:
        raise ValueError("invalid proc stat")
    return {"pid": int(directory.name), "name": raw[raw.find("(") + 1:split][:64],
            "state": fields[0], "parent": int(fields[1]), "group": int(fields[2]),
            "session": int(fields[3]), "start": int(fields[19])}


def owned_rows(group, proc=Path("/proc")):
    rows = []
    for count, directory in enumerate(proc.iterdir()):
        if count >= 4096:
            raise ValueError("process scan exceeds bound")
        if not directory.name.isdecimal():
            continue
        try:
            row = process_row(directory)
            if row["group"] == group and row["session"] == group:
                if len(rows) == MAX_PROCESSES:
                    raise ValueError("owned process inventory exceeds bound")
                rows.append(row)
        except (FileNotFoundError, ProcessLookupError):
            pass
    return sorted(rows, key=lambda row: row["pid"])


def unreaped_status(child):
    result = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if result is None:
        return None
    return result.si_status if result.si_code == os.CLD_EXITED else -result.si_status


def become_subreaper():
    # Linux PR_SET_CHILD_SUBREAPER: orphaned fixture children become ours to
    # reap, rather than leaving zombies to the CI container's unrelated PID1.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "cannot own descendant cleanup")


def reap_group(group):
    while True:
        try:
            pid, _ = os.waitpid(-group, os.WNOHANG)
            if pid == 0:
                return
        except ChildProcessError:
            return


def diagnostic_limit():
    # Only GDB inherits this output limit, never the suite.
    resource.setrlimit(resource.RLIMIT_FSIZE, (STACK_BYTES, STACK_BYTES))


def capture(directory, group):
    rows = owned_rows(group)
    report = {"processes": rows, "threads": [], "truncatedThreads": False, "gdb": []}
    for row in rows:
        root = Path("/proc") / str(row["pid"])
        try:
            row["executable"] = os.readlink(root / "exe")[:2048]
            tasks = sorted(itertools.islice((root / "task").iterdir(), MAX_THREADS + 1), key=lambda p: int(p.name))
        except (FileNotFoundError, ProcessLookupError):
            continue
        for task in tasks:
            if len(report["threads"]) == MAX_THREADS:
                report["truncatedThreads"] = True
                break
            thread = {"pid": row["pid"], "tid": int(task.name)}
            for name, limit in (("comm", 128), ("wchan", 256), ("stack", 8192)):
                try:
                    thread[name] = read_small(task / name, limit)
                except (OSError, ValueError) as error:
                    thread[name + "Error"] = type(error).__name__
            report["threads"].append(thread)
    # Prefer actual test runners over the SwiftPM driver. At most two captures,
    # 20 seconds and 1 MiB each; no locals, frame arguments, init files or downloads.
    candidates = sorted(rows, key=lambda row: (not (
        row.get("executable", "").endswith((".xctest", "-test-runner"))), row["pid"]))
    for row in [r for r in candidates if r["state"] != "Z"][:2]:
        receipt = {"pid": row["pid"], "status": "unavailable"}
        report["gdb"].append(receipt)
        if not Path("/usr/bin/gdb").is_file():
            continue
        try:
            current = process_row(Path("/proc") / str(row["pid"]))
            if any(current[key] != row[key] for key in ("start", "group", "session")):
                receipt["status"] = "identity-changed"
                continue
            args = ["/usr/bin/gdb", "--batch", "--nx", "--nh",
                    "-iex", "set auto-load off", "-iex", "set debuginfod enabled off",
                    "-ex", "set pagination off", "-ex", "set confirm off",
                    "-ex", "set print frame-arguments none", "-ex", "set print elements 0",
                    "-ex", "attach " + str(row["pid"]), "-ex", "thread apply all bt 48",
                    "-ex", "detach", "-ex", "quit"]
            env = dict(os.environ, DEBUGINFOD_URLS="")
            debugger = None
            with (directory / ("gdb-" + str(row["pid"]) + ".txt")).open("xb") as log:
                try:
                    debugger = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                        env=env, start_new_session=True, preexec_fn=diagnostic_limit)
                    receipt["exitCode"] = debugger.wait(timeout=20)
                    # GDB may exit zero after a denied attach. This records the
                    # command outcome only; the bounded log is the stack evidence.
                    receipt["status"] = "command-completed" if debugger.returncode == 0 else "command-failed"
                except subprocess.TimeoutExpired:
                    receipt["status"] = "timeout"
                finally:
                    if debugger is not None and debugger.poll() is None:
                        os.killpg(debugger.pid, signal.SIGKILL)
                        debugger.wait(timeout=5)
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            receipt["error"] = type(error).__name__
    save(directory / "stacks.json", report)


def supervise(command, directory, seconds, *, inspect=owned_rows, status=unreaped_status, diagnose=capture):
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = {"deadlineSeconds": seconds, "timedOut": False, "interrupted": None,
              "testExitCode": None, "cleanupComplete": False}
    child = None
    leader_reaped = False
    previous = {}
    def interrupted(signum, frame):
        report["interrupted"] = signum
    started = time.monotonic()
    try:
        # Install non-raising handlers before spawn; PID ownership is published
        # before a received signal can lead to cleanup. Children inherit no mask.
        previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
        child = subprocess.Popen(command, start_new_session=True)
        report["pid"] = child.pid
        while status(child) is None and report["interrupted"] is None:
            if time.monotonic() - started >= seconds:
                report["timedOut"] = True
                print("Linux suite deadline exceeded; capturing bounded diagnostics.", flush=True)
                try:
                    diagnose(directory, child.pid)
                except (OSError, ValueError) as error:
                    report["diagnosticError"] = type(error).__name__
                break
            time.sleep(0.1)
    except (OSError, ValueError) as error:
        report["error"] = type(error).__name__
    finally:
        if child is not None:
            # The production status() never reaps the leader. Its PID/group ID
            # remains reserved through all signals, including descendant drain.
            try:
                live = [row for row in inspect(child.pid) if row["state"] != "Z"]
                if live:
                    report["terminatedPIDs"] = [row["pid"] for row in live]
                    os.killpg(child.pid, signal.SIGTERM)
                    until = time.monotonic() + 5
                    while any(row["state"] != "Z" for row in inspect(child.pid)) and time.monotonic() < until:
                        time.sleep(0.05)
                    if any(row["state"] != "Z" for row in inspect(child.pid)):
                        report["forcedKill"] = True
                        os.killpg(child.pid, signal.SIGKILL)
                report["testExitCode"] = child.wait(timeout=5)
                leader_reaped = True
                until = time.monotonic() + 2
                while True:
                    reap_group(child.pid)
                    remaining = inspect(child.pid)
                    if not remaining or time.monotonic() >= until:
                        break
                    time.sleep(0.05)
                report["survivors"] = remaining
                report["cleanupComplete"] = not report["survivors"]
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                report["cleanupError"] = type(error).__name__
                # Only an unreaped leader reserves the numeric group ID. After
                # reaping, a failed inspection is a failure report, never grounds
                # to signal a group that could now belong to another process.
                if not leader_reaped:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        report["testExitCode"] = child.wait(timeout=5)
                        leader_reaped = True
                        reap_group(child.pid)
                    except subprocess.TimeoutExpired:
                        report["unjoinedLeader"] = True
        report["elapsedSeconds"] = time.monotonic() - started
        try:
            save(directory / "result.json", report)
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    if report["timedOut"]:
        return 124
    if report["interrupted"] is not None:
        return 128 + report["interrupted"]
    if report.get("error") or not report["cleanupComplete"] or report.get("terminatedPIDs"):
        return 1
    code = report["testExitCode"]
    return code if code >= 0 else 128 - code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if sys.platform != "linux" or not 1 <= args.timeout_seconds <= 900 or not command:
        parser.error("requires Linux, a command and a deadline in 1...900 seconds")
    if not args.evidence.is_absolute() or "localdev" not in args.evidence.parts:
        parser.error("evidence must be an absolute localdev path")
    os.umask(0o077)
    become_subreaper()
    return supervise(command, args.evidence, args.timeout_seconds)


if __name__ == "__main__":
    sys.exit(main())
