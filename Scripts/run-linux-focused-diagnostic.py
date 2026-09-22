#!/usr/bin/env python3
"""One owned Linux diagnostic: 32 serial tests, 300-second process/cleanup budget.

No elevated ptrace policy, retries, test suppression or full-suite qualification.
The caller builds tests first; this control invokes only --skip-build.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

SUITES = ('FullTextSearchTests', 'GeoboundsTests')
FILTER = r'LatticeTests\.(FullTextSearchTests|GeoboundsTests)'
BOUND = 300
IDLE = 60
RESERVE = 30
MAX_FILE = 32 * 1024 * 1024
MAX_PROCESSES = 128


def write(path, value):
    with Path(path).open('x') as f:
        json.dump(value, f, indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())


def brief(error):
    return (type(error).__name__ + ': ' + str(error))[:1000]


def parse_proc_stat(pid, text):
    # comm can contain spaces and parentheses; fields after its last ')' start at3.
    end = text.rindex(')'); values = text[end + 2:].split()
    assert int(text[:text.index(' ')]) == pid and len(values) >= 20
    return dict(pid=pid, ppid=int(values[1]), pgid=int(values[2]), session=int(values[3]),
                startTicks=int(values[19]), state=values[0])


def proc_identity(pid):
    row = parse_proc_stat(pid, Path(f'/proc/{pid}/stat').read_text())
    row['uid'] = Path(f'/proc/{pid}').stat().st_uid
    try: row['executable'] = os.readlink(f'/proc/{pid}/exe')
    except (FileNotFoundError, ProcessLookupError): row['executable'] = None
    return row


def generation(row):
    return tuple(row[k] for k in ('pid', 'startTicks', 'uid'))


def current_process(row):
    try:
        current = proc_identity(row['pid'])
        return current if generation(current) == generation(row) else None
    except (FileNotFoundError, ProcessLookupError): return None


def same_process(row):
    return current_process(row) is not None


def live_processes(known):
    # A child exiting between two /proc reads is normal, not a cleanup failure.
    return [current for row in known.values()
            if (current := current_process(row)) is not None and current['state'] != 'Z']


def record_remaining_processes(known, report):
    remaining = []
    for row in known.values():
        try:
            if same_process(row): remaining.append(row)
        except BaseException as error:
            report['errors'].append(f'remaining identity PID {row["pid"]}: '+brief(error))
            # An unreadable identity is unresolved custody, never proof of exit.
            remaining.append({**row, 'closureIdentityUnavailable': True})
    report['remainingOwned'] = remaining


def children(pid):
    result = set()
    for task in Path(f'/proc/{pid}/task').iterdir():
        try: result.update(int(s) for s in (task/'children').read_text().split())
        except FileNotFoundError: pass
    return result


def observe_tree(root, known):
    # A dedicated subreaper owns only this SwiftPM tree. Completed diagnostic
    # debuggers are joined before observation resumes, so adopted direct
    # children here are original-tree orphans, including escaped sessions.
    pending = [root['pid'], *children(os.getpid())]; seen = set()
    while pending:
        pid = pending.pop()
        if pid in seen: continue
        seen.add(pid)
        if len(seen) > MAX_PROCESSES: raise RuntimeError('Owned tree exceeds process bound')
        try:
            row = proc_identity(pid)
            if pid == root['pid'] and generation(row) != generation(root):
                raise RuntimeError('Owned root identity changed')
            if row['uid'] != root['uid'] or row['startTicks'] < root['startTicks']:
                raise RuntimeError('Descendant identity is outside owned tree')
            if pid in known and generation(row) != generation(known[pid]):
                raise RuntimeError('Observed descendant PID was reused')
            known[pid] = row
            pending.extend(children(pid))
        except FileNotFoundError: pass
    return seen


def root_exited(proc):
    # Do not reap the group leader before teardown. Its PID anchors the owned PGID.
    return os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None


def signal_owned_group(proc, root, sig):
    row = proc_identity(proc.pid)
    if generation(row) != generation(root) or row['pgid'] != proc.pid or row['session'] != proc.pid:
        raise RuntimeError('Refuse signal: original session-leading process identity changed')
    os.killpg(proc.pid, sig)


def kill_observed_escape(row):
    """A descendant may create another session; signal its exact pidfd only."""
    fd = os.pidfd_open(row['pid'])
    try:
        if not same_process(row): raise RuntimeError('Escaped descendant identity changed')
        signal.pidfd_send_signal(fd, signal.SIGKILL)
    finally: os.close(fd)


def group_present(pgid):
    try: os.killpg(pgid, 0); return True
    except ProcessLookupError: return False
    except PermissionError: return True


def snapshot_proc(row, destination, deadline):
    report = {'original': row, 'files': {}, 'errors': []}
    if not same_process(row):
        report['errors'].append('Original process no longer present'); return report
    paths = [Path(f'/proc/{row["pid"]}') / n for n in ('status', 'wchan', 'cmdline')]
    try:
        tasks = sorted(Path(f'/proc/{row["pid"]}/task').iterdir())[:256]
        paths += [task/n for task in tasks for n in ('status', 'wchan', 'stack')]
    except OSError as error: report['errors'].append(brief(error))
    for path in paths:
        if time.monotonic() >= deadline:
            report['errors'].append('Proc snapshot deadline'); break
        try:
            with path.open('rb') as f: data = f.read(65537)
            if len(data) > 65536: raise ValueError('Proc file exceeds 64 KiB')
            name = str(path).removeprefix('/proc/').replace('/', '-') + '.txt'
            (destination/name).write_bytes(data)
            report['files'][str(path)] = {'file': name, 'bytes': len(data)}
        except (OSError, ValueError) as error: report['errors'].append(str(path) + ': ' + brief(error))
    report['sameProcessAfter'] = same_process(row)
    return report


def debugger(row, destination, deadline):
    result = {'target': row, 'available': False, 'stackCaptured': False, 'error': None,
              'directlyJoined': False}
    binary = shutil.which('gdb')
    if not binary or not same_process(row):
        result['error'] = 'gdb unavailable or original target has exited'; return result
    seconds = min(8.0, deadline - time.monotonic() - 2.0)
    if seconds <= 0:
        result['error'] = 'No debugger time remains'; return result
    argv = [binary, '-n', '-batch', '-p', str(row['pid']), '-ex', 'set pagination off',
            '-ex', 'thread apply all bt 40', '-ex', 'detach', '-ex', 'quit']
    result.update(available=True, argv=argv, seconds=seconds)
    def limit_output(): resource.setrlimit(resource.RLIMIT_FSIZE, (4*1024*1024, 4*1024*1024))
    with (destination/f'gdb-{row["pid"]}.txt').open('xb') as f:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=f, stderr=f,
                                start_new_session=True, preexec_fn=limit_output)
        result['debuggerPID'] = proc.pid
        try:
            result['debuggerIdentity'] = proc_identity(proc.pid)
            result['exitCode'] = proc.wait(timeout=seconds)
            result['directlyJoined'] = True
        except subprocess.TimeoutExpired:
            result['timedOut'] = True
            os.killpg(proc.pid, signal.SIGKILL)
            result['exitCode'] = proc.wait(timeout=max(.1, deadline-time.monotonic()))
            result['directlyJoined'] = True
        except BaseException:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL); proc.wait(timeout=max(.1, deadline-time.monotonic()))
            raise
    body = (destination/f'gdb-{row["pid"]}.txt').read_text(errors='replace')
    result['stackCaptured'] = result.get('exitCode') == 0 and bool(re.search(r'^#0\s', body, re.M))
    if not result['stackCaptured']: result['error'] = 'No usable user-space stack; retained gdb output may report denied ptrace'
    return result


def expected_tests(workspace):
    expected = set(); sources = {}
    for suite in SUITES:
        path = workspace/'Tests/LatticeTests'/f'{suite}.swift';data = path.read_bytes()
        names = re.findall(r'@Test\s+func\s+(\w+)\(', data.decode())
        assert len(names) == 16 and len(names) == data.decode().count('@Test')
        expected.update((f'LatticeTests.{suite}', name+'()') for name in names)
        sources[str(path)] = {'sha256': hashlib.sha256(data).hexdigest(), 'functions': names}
    return expected, sources


def qualify_results(directory, expected):
    paths = [directory/n for n in ('focused.xml', 'focused-swift-testing.xml') if (directory/n).is_file()]
    # XCTest may write an empty companion document. Exactly one document must
    # contain our32 cases; all documents must have zero issues/skips.
    populated = []
    for path in paths:
        assert path.stat().st_size <= MAX_FILE, 'XML exceeds diagnostic size bound'
        tree = ET.fromstring(path.read_bytes()); cases = list(tree.iter('testcase'))
        if cases: populated.append(cases)
        for suite in tree.iter('testsuite'):
            assert all(int(suite.get(k, '0')) == 0 for k in ('errors', 'failures', 'skipped'))
        assert all(not list(case) for case in cases)
    assert len(populated) == 1 and len(populated[0]) == 32
    assert {(x.get('classname'), x.get('name')) for x in populated[0]} == expected
    event_path = directory/'focused-events.jsonl'
    assert event_path.stat().st_size <= MAX_FILE, 'Events exceed diagnostic size bound'
    rows = [json.loads(line) for line in event_path.read_text().splitlines() if line]
    assert rows and all(isinstance(row, dict) for row in rows), 'Missing native JSON event records'
    return {'passed': True, 'functions': 32, 'suites': 2, 'fullSuiteQualified': False, 'nativeEventRecords': len(rows)}


def progress_tail(path):
    if not path.exists(): return {'present': False, 'events': []}
    result = {'present': True, 'bytes': path.stat().st_size, 'events': []}
    with path.open('rb') as f:
        offset = max(0, result['bytes'] - 65536); f.seek(offset); tail = f.read(65536)
    lines = tail.splitlines()
    if offset and lines: lines = lines[1:]
    result['unparsedLines'] = 0
    for line in lines[-20:]:
        try: result['events'].append(json.loads(line))
        except (ValueError, UnicodeError): result['unparsedLines'] += 1
    return result


def run(workspace, directory):
    if sys.platform != 'linux': raise RuntimeError('Linux-only control')
    directory.mkdir(parents=True, exist_ok=False)
    started = time.monotonic(); deadline = started + BOUND
    stopped = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda number, _: stopped.append(number))
    argv = ['swift', 'test', '--force-resolved-versions', '--skip-build', '--no-parallel',
            '--filter', FILTER, '--event-stream-output-path', str(directory/'focused-events.jsonl'),
            '--event-stream-version', '0', '--xunit-output', str(directory/'focused.xml')]
    report = {'schema': 'linux-focused-diagnostic/v1', 'argv': argv, 'sources': {},
              'boundSeconds': BOUND, 'idleSeconds': IDLE, 'cleanupReserveSeconds': RESERVE,
              'fullSuiteQualified': False, 'passed': False, 'errors': [], 'signals': [], 'diagnostics': [],
              'rootJoined': False, 'descendants': [], 'remainingOwned': [], 'groupsAfterJoin': [],
              'securitySettingsChanged': False}
    proc = None; root = None; known = {}; reason = None; rootcode = None
    with (directory/'stdout.log').open('xb') as stdout, (directory/'stderr.log').open('xb') as stderr:
        try:
            # Reap owned descendants if SwiftPM exits before them. No ptrace policy change.
            libc = ctypes.CDLL(None, use_errno=True)
            if libc.prctl(36, 1, 0, 0, 0) != 0: raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')
            expected, sources = expected_tests(workspace); report['sources'] = sources
            report['bootID'] = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
            report['clockTicksPerSecond'] = os.sysconf('SC_CLK_TCK')
            proc = subprocess.Popen(argv, cwd=workspace, stdin=subprocess.DEVNULL,
                                    stdout=stdout, stderr=stderr, start_new_session=True)
            root = proc_identity(proc.pid);assert root['pgid'] == root['session'] == proc.pid
            known[proc.pid] = root;report['root'] = root
            write(directory/'START.json', {'root': root, 'argv': argv, 'sources': sources, 'monotonicStart': started})
            progress = None; changed = time.monotonic()
            while True:
                observe_tree(root, known)
                if root_exited(proc): break
                events = directory/'focused-events.jsonl'
                stamp = (events.stat().st_size, events.stat().st_mtime_ns) if events.exists() else None
                if stamp != progress: progress = stamp; changed = time.monotonic()
                now = time.monotonic()
                if stopped: reason = 'external cancellation'; break
                if any(f.stat().st_size > MAX_FILE for f in (directory/'stdout.log', directory/'stderr.log')) or (stamp and stamp[0] > MAX_FILE):
                    reason = 'diagnostic output exceeded 32 MiB'; break
                if now >= deadline - RESERVE: reason = 'hard execution deadline'; break
                if now - changed >= IDLE: reason = '60 seconds without native event progress'; break
                time.sleep(.1)
            report['stopReason'] = reason
            report['progressAtStop'] = progress_tail(directory/'focused-events.jsonl')
            if reason and not stopped:
                targets = [r for r in known.values() if r.get('executable') and Path(r['executable']).name == 'LatticePackageTests.xctest' and same_process(r)]
                if len(targets) != 1: report['errors'].append(f'Expected one exact test descendant for stacks, observed {len(targets)}')
                targets = targets[:1] + [root]
                snapshots = directory/'stacks';snapshots.mkdir()
                capture_end = min(deadline - 8, time.monotonic() + 22)
                for row in targets:
                    report['diagnostics'].append({'proc': snapshot_proc(row, snapshots, min(capture_end, time.monotonic()+2)),
                                                  'gdb': debugger(row, snapshots, capture_end)})
        except BaseException as error:
            report['errors'].append(brief(error));reason = reason or 'control failure'
        finally:
            if proc is not None:
                def observe_for_cleanup():
                    try: observe_tree(root, known)
                    except BaseException as error: report['errors'].append('cleanup observation: '+brief(error))
                try:
                    if root is None:
                        root = proc_identity(proc.pid);known[proc.pid] = root
                    observe_for_cleanup()
                    live = live_processes(known)
                    if reason or live:
                        if reason is None: reason = 'Owned descendants survived the SwiftPM exit'
                        # Resume any ptrace-stopped child before graceful teardown.
                        for sig in (signal.SIGCONT, signal.SIGTERM):
                            try:
                                signal_owned_group(proc, root, sig);report['signals'].append(signal.Signals(sig).name)
                            except BaseException as error: report['errors'].append('group signal: '+brief(error))
                        end = min(deadline - 3, time.monotonic()+5)
                        while time.monotonic() < end:
                            observe_for_cleanup()
                            if not live_processes(known): break
                            time.sleep(.05)
                        if live_processes(known):
                            try:
                                signal_owned_group(proc, root, signal.SIGKILL);report['signals'].append('SIGKILL')
                            except BaseException as error: report['errors'].append('group kill: '+brief(error))
                        observe_for_cleanup()
                        for row in known.values():
                            current = current_process(row)
                            if current and current['state'] != 'Z' and current['pgid'] != root['pgid']:
                                try:
                                    kill_observed_escape(row)
                                    report['signals'].append({'escapedPID': row['pid'], 'signal': 'SIGKILL', 'via': 'pidfd'})
                                except ProcessLookupError: pass
                                except BaseException as error: report['errors'].append('escaped child cleanup: '+brief(error))
                except BaseException as error: report['errors'].append('group cleanup: '+brief(error))
                # Direct joining is attempted even if a procfs/signal operation failed.
                try:
                    rootcode = proc.wait(timeout=max(.1, deadline-time.monotonic()-1));report['rootJoined'] = True
                    # Reap only this dedicated supervisor's direct/adopted children.
                    while time.monotonic() < deadline - .5:
                        try:
                            # Late orphan adoption can follow leader termination.
                            # These are direct children of this dedicated subreaper,
                            # never a global name/PID search.
                            for pid in children(os.getpid()):
                                try:
                                    row = proc_identity(pid)
                                    if pid not in known: known[pid] = row
                                    if row['state'] != 'Z':
                                        kill_observed_escape(row)
                                        report['signals'].append({'adoptedPID': pid, 'signal': 'SIGKILL', 'via': 'pidfd'})
                                        reason = reason or 'Owned adopted child survived the SwiftPM exit'
                                except ProcessLookupError: pass
                                except FileNotFoundError: pass
                            # This dedicated supervisor only spawned the owned
                            # SwiftPM tree and already-joined diagnostic debuggers.
                            child, _ = os.waitpid(-1, os.WNOHANG)
                            if child == 0:
                                if all(not same_process(r) for r in known.values()): break
                                time.sleep(.05)
                        except ChildProcessError: break
                except BaseException as error: report['errors'].append('direct join: '+brief(error))
                try:
                    # Any still-adopted child means custody is incomplete, even
                    # if it was born between the last observation and root exit.
                    for pid in children(os.getpid()):
                        try:
                            row = proc_identity(pid)
                            if pid not in known: known[pid] = row
                        except FileNotFoundError: pass
                    report['groupsAfterJoin'] = [{'pgid': pgid, 'present': group_present(pgid)}
                        for pgid in sorted({row['pgid'] for row in known.values()})]
                except BaseException as error: report['errors'].append('closure observation: '+brief(error))
                record_remaining_processes(known, report)
    report['descendants'] = list(known.values());report['exitCode'] = rootcode
    report['stopReason'] = reason
    if not reason and not report['signals'] and rootcode == 0 and report['rootJoined'] and not report['remainingOwned'] and not any(row['present'] for row in report['groupsAfterJoin']) and not report['errors'] and not stopped:
        try: report['tests'] = qualify_results(directory, expected);report['passed'] = True
        except BaseException as error: report['errors'].append('test qualification: '+brief(error))
    report['processSecondsBeforePublication'] = time.monotonic() - started
    report['timingScope'] = 'Setup through owned-process closure and qualification, measured before RESULT serialization/print; publication is inside the outer 20-minute job bound.'
    if report['processSecondsBeforePublication'] >= BOUND: report['passed'] = False;report['errors'].append('300-second process bound exceeded')
    report['externalSignals'] = stopped
    write(directory/'RESULT.json', report)
    print(json.dumps({'passed': report['passed'], 'result': str(directory/'RESULT.json'), 'processSecondsBeforePublication': report['processSecondsBeforePublication']}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser();parser.add_argument('--workspace', type=Path, required=True);parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    sys.exit(run(args.workspace.resolve(), args.output.resolve()))
