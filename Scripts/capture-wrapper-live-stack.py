#!/usr/bin/env python3
"""One best-effort macOS diagnostic; native output and outcome remain separate.

Source-only candidate. No runtime capability, attachment, or latency qualification
is implied. The hosted job owner remains responsible for native-tree cancellation.
"""
import argparse
import ctypes
import hashlib
import json
import os
import re
import resource
import secrets
import select
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

REPORT_LIMIT = 4 * 1024 * 1024
DIAG_LIMIT = 64 * 1024
JSON_LIMIT = 64 * 1024
COMMAND = ["swift", "test", "--force-resolved-versions"]
SAMPLE = "/usr/bin/sample"
ENV_KEYS = ("LATTICE_STACK_MARKER_SOCKET", "LATTICE_STACK_MARKER_NONCE")
MARKER = re.compile(rb"LATTICE_STACK_V1 ([0-9a-f]{32}) ([1-9][0-9]{0,9}) 0 (open|closed) (0|[1-9][0-9]{0,19}) (missing|true|false)\n")


def brief(exc):
    return (type(exc).__name__ + ": " + str(exc))[:600]


def identity_stat(s):
    return {k: getattr(s, k) for k in
            ("st_dev", "st_ino", "st_size", "st_mode", "st_mtime_ns", "st_ctime_ns")}


def file_pin(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not 0 <= before.st_size <= limit:
            raise ValueError("nonregular or oversized file")
        digest, size = hashlib.sha256(), 0
        while True:
            block = os.read(fd, min(65536, limit + 1 - size))
            if not block:
                break
            size += len(block)
            if size > limit:
                raise ValueError("file grew beyond limit")
            digest.update(block)
        after = os.fstat(fd)
        if identity_stat(before) != identity_stat(after) or size != before.st_size:
            raise ValueError("file changed during bounded read")
        return {"path": path, "bytes": size, "sha256": digest.hexdigest(),
                "stat": identity_stat(after)}
    finally:
        os.close(fd)


def write_once(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            if n <= 0:
                raise OSError("short evidence write")
            view = view[n:]
    finally:
        os.close(fd)


def json_bytes(value):
    data = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()
    if len(data) > JSON_LIMIT:
        raise ValueError("JSON evidence exceeds bound")
    return data


class BSDInfo(ctypes.Structure):
    # Public sys/proc_info.h PROC_PIDTBSDINFO (3), LP64 layout: 136 bytes.
    _fields_ = [(name, ctypes.c_uint32) for name in
                ("flags", "status", "xstatus", "pid", "ppid", "uid", "gid",
                 "ruid", "rgid", "svuid", "svgid", "rfu_1")] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [
        (name, ctypes.c_uint32) for name in
        ("nfiles", "pgid", "pjobc", "e_tdev", "e_tpgid")] + [
        ("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64),
        ("start_usec", ctypes.c_uint64)]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def generation(row):
    return tuple(row[key] for key in
                 ("pid", "birthSeconds", "birthMicroseconds", "uid", "ppid", "pgid"))


def same_chain(actual, original):
    # Ancestors may exec a Swift subcommand in the same process generation.
    # The sampled target must retain its complete image identity as well.
    return (len(actual) == len(original) >= 2 and actual[0] == original[0] and
            all(generation(a) == generation(b) for a, b in zip(actual[1:], original[1:])))


class Mac:
    def __init__(self):
        if sys.platform != "darwin" or ctypes.sizeof(BSDInfo) != 136:
            raise RuntimeError("unqualified platform or public structure layout")
        self.proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        self.proc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                          ctypes.c_void_p, ctypes.c_int]
        self.proc.proc_pidinfo.restype = ctypes.c_int
        self.proc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.proc.proc_pidpath.restype = ctypes.c_int
        self.lib.mach_absolute_time.argtypes = []
        self.lib.mach_absolute_time.restype = ctypes.c_uint64
        self.lib.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
        self.lib.mach_timebase_info.restype = ctypes.c_int
        tb = Timebase()
        if self.lib.mach_timebase_info(ctypes.byref(tb)) != 0 or not tb.numer or not tb.denom:
            raise RuntimeError("mach timebase unavailable")
        self.timebase = {"numer": tb.numer, "denom": tb.denom}

    def ticks(self):
        return int(self.lib.mach_absolute_time())

    def identity(self, pid):
        if not 1 < pid <= 2147483647:
            raise ValueError("invalid target PID")
        info = BSDInfo()
        ctypes.set_errno(0)
        n = self.proc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        if n != 136 or info.pid != pid or not info.start_sec or info.start_usec >= 1000000:
            raise OSError(ctypes.get_errno(), "proc_pidinfo incomplete/invalid", str(pid))
        buf = ctypes.create_string_buffer(4096)
        ctypes.set_errno(0)
        n = self.proc.proc_pidpath(pid, buf, 4096)
        if not 0 < n < 4096 or buf.raw[n] != 0:
            raise OSError(ctypes.get_errno(), "proc_pidpath incomplete/invalid", str(pid))
        path = os.fsdecode(buf.raw[:n])
        if not os.path.isabs(path):
            raise ValueError("process image path is not absolute")
        image = os.stat(path, follow_symlinks=False)
        if not stat.S_ISREG(image.st_mode):
            raise ValueError("process image is not a regular file")
        return {"pid": pid, "uid": info.uid, "ppid": info.ppid, "pgid": info.pgid,
                "birthSeconds": info.start_sec, "birthMicroseconds": info.start_usec,
                "path": path, "imageStat": identity_stat(image)}

    def ancestry(self, pid, driver):
        chain, seen = [], set()
        for _ in range(16):
            if pid in seen:
                raise ValueError("ancestry cycle")
            seen.add(pid)
            row = self.identity(pid)
            if row["uid"] != driver["uid"]:
                raise ValueError("ancestry UID differs from owned driver")
            chain.append(row)
            if pid == driver["pid"]:
                if generation(row) != generation(driver):
                    raise ValueError("owned driver generation changed")
                if len(chain) < 2:
                    raise ValueError("marker did not identify a driver descendant")
                target = chain[0]
                if (target["birthSeconds"], target["birthMicroseconds"]) < (
                        driver["birthSeconds"], driver["birthMicroseconds"]):
                    raise ValueError("target predates owned driver")
                return chain
            pid = row["ppid"]
        raise ValueError("no bounded ancestry to owned driver")


def sampler_limit():
    # Only the sampler inherits this limit, never swift/test.
    resource.setrlimit(resource.RLIMIT_FSIZE, (REPORT_LIMIT, REPORT_LIMIT))


class Capture:
    def __init__(self, directory, pid, mac):
        self.mac, self.directory = mac, directory
        self.started = time.monotonic()
        self.end = self.started + 5.0
        self.work_end = self.started + 4.0
        self.stop_at = None
        self.killed = False
        self.finished = False
        self.pipes, self.output = {}, bytearray()
        self.streams = []
        self.proc = None
        self.after_checked = False
        self.identity_stable = False
        self.row = {"claimed": True, "argv": [SAMPLE, str(pid), "1", "10", "-file",
                    os.path.join(directory, "sample.txt")], "budgetSeconds": 5,
                    "cleanupReserveSeconds": 1, "reportLimitBytes": REPORT_LIMIT,
                    "combinedDiagnosticsLimitBytes": DIAG_LIMIT, "errors": [],
                    "diagnosticOrdering": "pipe read order, not a cross-stream timing proof",
                    "spawned": False, "returncode": None, "reaped": False, "groupAbsent": None,
                    "forcedStop": False, "targetResumeState": "NOT_OBSERVED"}
        write_once(os.path.join(directory, "CAPTURE-CLAIM.json"), json_bytes(self.row))
        self.row["launchTicks"] = mac.ticks()
        try:
            if time.monotonic() >= self.work_end:
                self.row["launchSkipped"] = "WORK_DEADLINE"
                raise TimeoutError("claim publication exhausted sampler work budget")
            self.proc = subprocess.Popen(self.row["argv"], stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         start_new_session=True, preexec_fn=sampler_limit)
            self.row["pid"] = self.proc.pid
            self.row["spawned"] = True
            # Own both streams before either fileno/nonblocking operation can fail.
            self.streams = [self.proc.stdout, self.proc.stderr]
            self.pipes = {stream.fileno(): (name, stream) for name, stream in
                          zip(("stdout", "stderr"), self.streams)}
            for fd in self.pipes:
                os.set_blocking(fd, False)
        except Exception as exc:
            self.row["errors"].append(brief(exc))
            if self.proc is None:
                self.finished = True
                self.row["finishTicks"] = mac.ticks()
            else:
                # A failed set_blocking must never leave a blocking FD for pump().
                for stream in self.streams:
                    self.close_pipe(stream)
                self.pipes.clear()
                self.stop("sampler setup failure")

    def group_signal(self, sig):
        # Never signal a test target. Only this unreaped, session-leading Popen.
        if self.proc is None or self.proc.returncode is not None:
            return
        try:
            if os.getpgid(self.proc.pid) != self.proc.pid:
                raise RuntimeError("sampler group ownership changed")
            os.killpg(self.proc.pid, sig)
        except ProcessLookupError:
            pass
        except Exception as exc:
            self.row["errors"].append(brief(exc))

    def stop(self, reason):
        if self.stop_at is None and not self.finished:
            self.stop_at = time.monotonic()
            self.row["stopReason"] = reason
            self.row["forcedStop"] = True
            self.row["targetResumeState"] = "UNKNOWN"
            self.group_signal(signal.SIGTERM)

    def close_pipe(self, stream):
        try:
            stream.close()
        except Exception as exc:
            self.row["errors"].append(brief(exc))

    def pump(self):
        if self.finished:
            return
        now = time.monotonic()
        if now >= self.work_end:
            self.stop("sampler work deadline")
        if self.stop_at is not None and now >= min(self.stop_at + .25, self.end) and not self.killed:
            self.killed = True
            self.group_signal(signal.SIGKILL)
        for fd, (_, stream) in list(self.pipes.items()):
            try:
                block = os.read(fd, 8192)
            except BlockingIOError:
                continue
            except OSError as exc:
                self.row["errors"].append(brief(exc))
                block = b""
            if not block:
                self.close_pipe(stream)
                del self.pipes[fd]
            else:
                available = DIAG_LIMIT - len(self.output)
                self.output.extend(block[:available])
                if len(block) > available:
                    self.row["diagnosticsTruncated"] = True
                    self.stop("combined diagnostic output cap")
        rc = self.proc.poll() if self.proc is not None else None
        if rc is not None:
            self.row.update(returncode=rc, reaped=True)
        if (rc is not None and not self.pipes) or now >= self.end:
            if rc is None:
                self.stop("sampler total deadline; reaping not proved")
                self.row["cleanupIncomplete"] = True
            for _, stream in self.pipes.values():
                self.close_pipe(stream)
            self.pipes.clear()
            self.finished = True
            self.row["finishTicks"] = self.mac.ticks()
            self.row["elapsedSeconds"] = time.monotonic() - self.started
            self.row["withinBudget"] = self.row["elapsedSeconds"] <= 5.0
            if self.proc is not None:
                try:
                    os.killpg(self.proc.pid, 0)
                    self.row["groupAbsent"] = False
                except ProcessLookupError:
                    self.row["groupAbsent"] = True
                except OSError:
                    self.row["groupAbsent"] = None
            if self.row["groupAbsent"] is not True or rc != 0:
                self.row["targetResumeState"] = "UNKNOWN"

    def check_after(self, driver, original, evidence):
        if not self.finished or self.after_checked:
            return
        self.after_checked = True
        if not self.row["spawned"]:
            return
        try:
            chain = self.mac.ancestry(original[0]["pid"], driver)
            self.identity_stable = same_chain(chain, original)
            evidence.append({"phase": "after-capture", "ticks": self.mac.ticks(),
                             "chain": chain, "matchesOpen": self.identity_stable})
        except Exception as exc:
            self.row["errors"].append("post-capture identity: " + brief(exc))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if command != COMMAND:
        parser.error("only the original swift test --force-resolved-versions command is admitted")
    # Admission claims prevent accidental local invocation; they are not authentication.
    ci = (os.environ.get("GITHUB_ACTIONS") == "true" and
          all(re.fullmatch(r"[1-9][0-9]*", os.environ.get(key, "")) for key in
              ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")) and
          os.environ.get("GITHUB_JOB") == "macos" and
          os.environ.get("CONSUMER_LEG") == "macos-swiftpm")
    if not ci:
        print(json.dumps({"controllerStatus": "REFUSED_OUTSIDE_DECLARED_CI",
                          "nativeLaunched": False, "nativeReturncode": None}), file=sys.stderr)
        return 2
    event = {"schema": "lattice.hosted-live-stack-diagnostic/1", "nativeArgv": COMMAND,
             "nativeReturncode": None, "nativeCompleted": False, "nativeLaunched": False,
             "diagnostic": "UNAVAILABLE", "ciEnvironmentClaimsAuthenticated": False,
             "markers": [], "errors": [], "targetChecks": [], "capture": None,
             "intervalAssociation": "UNOBSERVED", "actualPlatformQualified": False,
             "scope": "first measured iteration 0 armed wait scope; not wait-body entry",
             "limits": ["Datagrams are lossy; sender PID is not kernel-authenticated.",
                        "PID-only attachment is non-atomic despite repeated identity checks.",
                        "Sampling may perturb latency; no latency qualification follows.",
                        "Thread stacks are not an inventory of suspended async tasks.",
                        "Forced sampler termination leaves target resume state UNKNOWN.",
                        "Kernel IO and SIGKILL/reaping have no universal bounded guarantee.",
                        "Hosted job owner owns native-tree cancellation; no target signals here.",
                        "SIGKILL or host loss may prevent all final evidence publication."]}
    event["run"] = {key: os.environ.get(key, "")[:256] for key in
                    ("GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT",
                     "GITHUB_JOB", "CONSUMER_LEG", "RUNNER_OS", "RUNNER_ARCH")}
    env = dict(os.environ)
    for key in ENV_KEYS:
        env.pop(key, None)
    cancellation = [None]
    previous = {}
    def cancelled(sig, _frame):
        cancellation[0] = sig
    for sig in (signal.SIGINT, signal.SIGTERM):
        previous[sig] = signal.signal(sig, cancelled)
    directory = None
    socket_dir = None
    sock = None
    mac = None
    driver = None
    native = None
    capture = None
    opened = None
    closed = None
    due = None
    enabled = False
    claimed = False
    exitcode = 2
    try:
        try:
            path = args.evidence_dir
            if not os.path.isabs(path) or path.startswith("//") or os.path.normpath(path) != path:
                raise ValueError("evidence directory must be an absolute normalized fresh path")
            os.mkdir(path, 0o700)
            directory = path
            event["evidenceDirectory"] = directory
            event["controller"] = file_pin(os.path.abspath(__file__), REPORT_LIMIT)
            event["samplerTool"] = file_pin(SAMPLE, REPORT_LIMIT)
            mac = Mac()
            event["timebase"] = mac.timebase
            event["setupTicks"] = mac.ticks()
            nonce = secrets.token_hex(16)
            event["nonce"] = nonce
            runner_temp = os.environ.get("RUNNER_TEMP")
            if not runner_temp or not os.path.isabs(runner_temp):
                raise ValueError("absolute RUNNER_TEMP is required for the owned socket")
            socket_dir = tempfile.mkdtemp(prefix="ls-", dir=runner_temp)
            socket_path = os.path.join(socket_dir, "m")
            if len(os.fsencode(socket_path)) > 100:
                raise ValueError("owned socket path exceeds 100 bytes")
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            sock.setblocking(False)
            sock.set_inheritable(False)
            sock.bind(socket_path)
            os.chmod(socket_path, 0o600)
            env[ENV_KEYS[0]], env[ENV_KEYS[1]] = socket_path, nonce
            enabled = True
            event["diagnostic"] = "WAITING_FOR_MARKER"
        except Exception as exc:
            event["errors"].append(brief(exc))
            for key in ENV_KEYS:
                env.pop(key, None)
        if cancellation[0] is None:
            try:
                native = subprocess.Popen(COMMAND, env=env)
                event["nativeLaunched"] = True
                event["nativePID"] = native.pid
            except Exception as exc:
                event["errors"].append("native launch: " + brief(exc))
                exitcode = 127
        if native is not None and enabled:
            try:
                driver = mac.identity(native.pid)
                event["driver"] = driver
            except Exception as exc:
                enabled = False
                event["errors"].append(brief(exc))
                event["diagnostic"] = "IDENTITY_UNAVAILABLE"
        while native is not None:
            rc = native.poll()
            if rc is not None:
                event.update(nativeReturncode=rc, nativeCompleted=True)
                exitcode = rc if rc >= 0 else 128 - rc
            if cancellation[0] is not None or rc is not None:
                if capture is not None and not capture.finished:
                    capture.stop("controller cancelled" if cancellation[0] else "native command completed")
                    capture.pump()
                    capture.check_after(driver, event["targetChecks"][0]["chain"], event["targetChecks"])
                    if not capture.finished:
                        select.select([], [], [], .02)
                        continue
                break
            if sock is not None and enabled:
                for _ in range(32):
                    try:
                        data = sock.recv(257)
                    except BlockingIOError:
                        break
                    receipt = mac.ticks()
                    match = MARKER.fullmatch(data)
                    try:
                        if match is None or len(data) > 256:
                            raise ValueError("malformed marker")
                        got_nonce, pid, phase, ticks, arrived = match.groups()
                        pid, ticks = int(pid), int(ticks)
                        phase, arrived = phase.decode(), arrived.decode()
                        if got_nonce.decode() != event["nonce"] or ticks >= 2**64 or ticks > receipt:
                            raise ValueError("marker nonce or clock is invalid")
                        row = {"pid": pid, "iteration": 0, "phase": phase, "ticks": ticks,
                               "arrived": arrived, "receiptTicks": receipt}
                        if phase == "open":
                            if opened is not None or arrived != "missing" or ticks < event["setupTicks"]:
                                raise ValueError("duplicate or invalid open marker")
                            chain = mac.ancestry(pid, driver)
                            event["targetChecks"].append({"phase": "open", "chain": chain})
                            opened = row
                            due = time.monotonic() + 1.0
                            event["diagnostic"] = "ARMED"
                        else:
                            if opened is None or closed is not None or arrived not in ("true", "false"):
                                raise ValueError("unpaired or invalid closed marker")
                            if pid != opened["pid"] or ticks < opened["ticks"]:
                                raise ValueError("closed marker identity or clock mismatch")
                            closed = row
                            due = None
                            if not claimed:
                                event["diagnostic"] = "CLOSED_BEFORE_CAPTURE"
                        event["markers"].append(row)
                    except Exception as exc:
                        enabled = False
                        due = None
                        event["diagnostic"] = "INVALID_MARKER_OR_IDENTITY"
                        event["errors"].append(brief(exc))
                        if capture is not None:
                            capture.stop("marker or identity invalid")
                        break
            if enabled and due is not None and time.monotonic() >= due and not claimed:
                claimed = True
                due = None
                try:
                    chain = mac.ancestry(opened["pid"], driver)
                    if not same_chain(chain, event["targetChecks"][0]["chain"]):
                        raise ValueError("target/ancestry changed before capture")
                    event["targetChecks"].append({"phase": "before-capture", "chain": chain})
                    capture = Capture(directory, opened["pid"], mac)
                    event["diagnostic"] = "CAPTURE_ATTEMPTED"
                except Exception as exc:
                    enabled = False
                    event["diagnostic"] = "CAPTURE_UNAVAILABLE"
                    event["errors"].append(brief(exc))
            if capture is not None:
                capture.pump()
                capture.check_after(driver, event["targetChecks"][0]["chain"], event["targetChecks"])
            readers = [sock] if sock is not None and enabled else []
            select.select(readers, [], [], .02 if capture and not capture.finished else .05)
    except Exception as exc:
        event["errors"].append("controller: " + brief(exc))
        # A diagnostic failure must not abandon or replace a still-running native result.
        if native is not None:
            while native.poll() is None and cancellation[0] is None:
                if capture is not None and not capture.finished:
                    capture.stop("controller diagnostic failure")
                    try:
                        capture.pump()
                        capture.check_after(driver, event["targetChecks"][0]["chain"], event["targetChecks"])
                    except Exception:
                        pass
                select.select([], [], [], .05)
            if native.returncode is not None:
                rc = native.returncode
                event.update(nativeReturncode=rc, nativeCompleted=True)
                exitcode = rc if rc >= 0 else 128 - rc
    finally:
        if capture is not None:
            if not capture.finished:
                capture.stop("controller finalization")
                while not capture.finished and time.monotonic() < capture.end:
                    try:
                        capture.pump()
                        capture.check_after(driver, event["targetChecks"][0]["chain"], event["targetChecks"])
                    except Exception as exc:
                        event["errors"].append(brief(exc))
                        break
                    select.select([], [], [], .02)
            event["capture"] = capture.row
            capture.check_after(driver, event["targetChecks"][0]["chain"], event["targetChecks"])
            sampled = (capture.row["spawned"] and capture.row.get("pid") is not None and
                       capture.row["reaped"] and capture.row["returncode"] == 0 and
                       capture.row["groupAbsent"] is True and not capture.row["forcedStop"] and
                       capture.row.get("withinBudget") is True)
            if sampled and capture.identity_stable and enabled and closed is not None and capture.row.get("finishTicks"):
                inside = (opened["ticks"] <= capture.row["launchTicks"] <=
                          capture.row["finishTicks"] <= closed["ticks"])
                event["intervalAssociation"] = "ARMED_SCOPE_ENVELOPE" if inside else "PARTIAL_OR_OUTSIDE"
            else:
                event["intervalAssociation"] = "UNVERIFIED"
            try:
                write_once(os.path.join(directory, "sampler-diagnostics.bin"), bytes(capture.output))
                event["report"] = file_pin(os.path.join(directory, "sample.txt"), REPORT_LIMIT)
            except Exception as exc:
                event["errors"].append(brief(exc))
        event["controllerSignal"] = cancellation[0]
        event["captureClaimConsumed"] = claimed
        if cancellation[0] is not None and not event["nativeCompleted"]:
            exitcode = 128 + cancellation[0]
        if sock is not None:
            try:
                sock.close()
            except Exception as exc:
                event["errors"].append(brief(exc))
        if socket_dir is not None:
            try:
                path = os.path.join(socket_dir, "m")
                if os.path.lexists(path):
                    os.unlink(path)
                os.rmdir(socket_dir)
            except Exception as exc:
                event["errors"].append(brief(exc))
        try:
            if directory is not None:
                write_once(os.path.join(directory, "RESULT.json"), json_bytes(event))
        except Exception as exc:
            print("live-stack evidence unavailable: " + brief(exc), file=sys.stderr)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return exitcode


if __name__ == "__main__":
    sys.exit(main())
