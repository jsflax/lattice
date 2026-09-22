#!/usr/bin/env python3
"""Unfiltered serial Linux diagnostic. Reuses the frozen focused custody helpers."""
import argparse
import collections
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
BASE_CONTROLLER_SHA256 = '3c4689f56fcd7a3efff4ee8ae1eed2cb121fb289bb090390d7e6b746907fad03'
base_path = Path(__file__).with_name('run-linux-focused-diagnostic.py')
assert hashlib.sha256(base_path.read_bytes()).hexdigest() == BASE_CONTROLLER_SHA256
spec = importlib.util.spec_from_file_location('focused_custody', base_path)
custody = importlib.util.module_from_spec(spec); spec.loader.exec_module(custody)
for name in ('write', 'brief', 'proc_identity', 'current_process', 'same_process',
             'live_processes', 'record_remaining_processes', 'children', 'observe_tree',
             'root_exited', 'signal_owned_group', 'kill_observed_escape', 'group_present',
             'snapshot_proc', 'debugger', 'progress_tail'):
    globals()[name] = getattr(custody, name)
BOUND = 1800
IDLE = 660
RESERVE = 30
MAX_FILE = custody.MAX_FILE


def function_key(identifier):
    # ABI v0's last ID component is source-file:line:column.
    return identifier.rsplit('/', 1)[0]


def expected_tests(workspace):
    census = json.loads(Path(__file__).with_name('linux-full-order-census.json').read_text())
    assert census['functionCount'] == 695 and census['executingFunctionCount'] == 690
    assert census['suiteCount'] == 106 and census['parameterCaseCount'] == 17
    assert len(census['inheritedSkipKeys']) == 5 and len(census['parameterCases']) == 6
    actual = {str(p.relative_to(workspace)) for p in (workspace/'Tests').rglob('*.swift')}
    assert actual == set(census['sourceHashes']), 'Test source membership changed'
    sources = {}
    for relative, digest in census['sourceHashes'].items():
        path = workspace/relative
        assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, relative
        sources[str(path)] = {'sha256': digest}
    census['_workspace'] = str(workspace)
    return census, sources


def qualify_native_events(rows, census):
    assert rows and all(row.get('version') == 0 for row in rows)
    assert all(row.get('kind') in ('test', 'event') for row in rows)
    definitions = [row['payload'] for row in rows if row['kind'] == 'test']
    by_id = {item['id']: item for item in definitions}
    assert len(by_id) == len(definitions), 'Duplicate native definition'
    functions = {i:t for i,t in by_id.items() if t['kind'] == 'function'}
    suites = {i for i,t in by_id.items() if t['kind'] == 'suite'}
    assert len(functions) == census['functionCount'] and len(suites) == census['suiteCount']
    assert len(by_id) == len(functions) + len(suites)
    keys = {i:function_key(i) for i in functions}
    assert len(set(keys.values())) == len(keys)
    assert collections.Counter(t.get('displayName', t['name']) for t in functions.values()) == collections.Counter(census['functionLabels'])
    skips_expected = set(census['inheritedSkipKeys'])
    params = census['parameterCases']
    assert skips_expected <= set(keys.values()) and set(params) <= set(keys.values())
    started = set(); ended = set(); skipped = set(); suite_started = set(); suite_ended = set()
    cases_started = {}; cases_ended = {}; active = None; active_case = None
    run_started = 0; run_ended = 0
    for row in rows:
        if row['kind'] != 'event': continue
        event = row['payload']; kind = event['kind']; identifier = event.get('testID')
        if kind == 'runStarted':
            assert run_started == 0 and run_ended == 0
            run_started += 1; continue
        assert run_started == 1 and run_ended == 0
        if kind == 'runEnded':
            assert active is None and active_case is None
            run_ended += 1; continue
        assert kind in ('testStarted', 'testEnded', 'testSkipped', 'testCaseStarted', 'testCaseEnded'), kind
        assert identifier in by_id, 'Event refers to an undeclared test'
        if identifier in suites:
            if kind == 'testStarted':
                assert identifier not in suite_started; suite_started.add(identifier)
            else:
                assert kind == 'testEnded' and identifier in suite_started and identifier not in suite_ended
                suite_ended.add(identifier)
            continue
        key = keys[identifier]
        if kind == 'testSkipped':
            assert key in skips_expected and key not in skipped and key not in started
            skipped.add(key)
        elif kind == 'testStarted':
            assert active is None and key not in started and key not in skips_expected
            active = key; started.add(key)
        elif kind == 'testEnded':
            assert active == key and active_case is None and key not in ended
            active = None; ended.add(key)
        else:
            assert active == key and key in params
            case = event['_testCase']; identity = (key, case['displayName'])
            assert case['displayName'] in params[key] and isinstance(case['id'], str) and case['id']
            if kind == 'testCaseStarted':
                assert active_case is None and identity not in cases_started
                active_case = identity; cases_started[identity] = case['id']
            else:
                assert active_case == identity and identity not in cases_ended
                assert cases_started[identity] == case['id']
                active_case = None; cases_ended[identity] = case['id']
    assert run_started == run_ended == 1
    assert started == ended == set(keys.values()) - skips_expected
    assert len(started) == census['executingFunctionCount'] and skipped == skips_expected
    assert suite_started == suite_ended == suites
    expected_cases = {(key, value) for key, values in params.items() for value in values}
    assert set(cases_started) == set(cases_ended) == expected_cases
    assert len(cases_started) == census['parameterCaseCount']
    assert len({(key, identity) for (key, _), identity in cases_started.items()}) == len(cases_started), 'Duplicate parameter identity within one function'
    return {'functions': functions, 'functionKeys': set(keys.values()), 'skips': skipped,
            'parameterCases': len(cases_started), 'events': sum(row['kind']=='event' for row in rows)}


def junit_function_key(native_key):
    # ABI v0 top-level IDs use Module.function(); JUnit separates the module
    # classname and function name. Suite-member IDs already have that slash.
    if '/' in native_key:
        return native_key
    module, separator, name = native_key.partition('.')
    assert separator and module and name, 'Malformed top-level native function ID'
    return module + '/' + name


def qualify_xml(directory, native):
    expected = {junit_function_key(key): key for key in native['functionKeys']}
    assert len(expected) == len(native['functionKeys']), 'Colliding JUnit function identities'
    populated = []
    for path in sorted(directory.glob('full*.xml')):
        assert path.stat().st_size <= MAX_FILE
        tree = ET.fromstring(path.read_bytes()); cases = list(tree.iter('testcase'))
        for suite in tree.iter('testsuite'):
            assert all(int(suite.get(k, '0')) == 0 for k in ('errors', 'failures'))
        if not cases: continue
        populated.append(path.name)
        keys = [case.get('classname')+'/'+case.get('name') for case in cases]
        assert len(keys) == len(set(keys)) and set(keys) == set(expected)
        skips = set()
        for key, case in zip(keys, cases):
            nodes = list(case)
            if nodes:
                assert len(nodes) == 1 and nodes[0].tag == 'skipped'
                skips.add(expected[key])
        assert skips == native['skips'], 'New or missing XML skip'
        summaries = [suite for suite in tree.iter('testsuite') if list(suite.iter('testcase'))]
        assert len(summaries) == 1
        assert int(summaries[0].get('tests')) == len(keys)-len(skips)
        assert int(summaries[0].get('skipped')) == len(skips)
    assert len(populated) == 1
    return populated[0]


def qualify_results(directory, census):
    path = directory/'full-events.jsonl'; assert path.stat().st_size <= MAX_FILE
    rows = [json.loads(line) for line in path.read_text().splitlines() if line]
    native = qualify_native_events(rows, census)
    workspace = Path(census['_workspace'])
    for test in native['functions'].values():
        source = test['sourceLocation']; path = Path(source['_filePath'])
        relative = str(path.relative_to(workspace))
        assert relative in census['sourceHashes']
        assert path.read_text().splitlines()[source['line']-1].lstrip().startswith('@Test')
    xml = qualify_xml(directory, native)
    return {'passed': True, 'functionRows': census['functionCount'], 'executingFunctions': census['executingFunctionCount'],
            'suites': census['suiteCount'], 'inheritedSkips': sorted(native['skips']),
            'expandedParameterCases': native['parameterCases'], 'expandedExecutingCases': census['executingFunctionCount']-len(census['parameterCases'])+native['parameterCases'],
            'nativeEventRecords': len(rows), 'XML': xml, 'requiredCIGateQualified': False}


def run(workspace, directory):
    if sys.platform != 'linux': raise RuntimeError('Linux-only control')
    directory.mkdir(parents=True, exist_ok=False)
    started = time.monotonic(); deadline = started + BOUND
    stopped = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda number, _: stopped.append(number))
    argv = ['swift', 'test', '--force-resolved-versions', '--skip-build', '--no-parallel',
            '--event-stream-output-path', str(directory/'full-events.jsonl'),
            '--event-stream-version', '0', '--xunit-output', str(directory/'full.xml')]
    report = {'schema': 'linux-full-order-diagnostic/v1', 'argv': argv, 'sources': {},
              'boundSeconds': BOUND, 'idleSeconds': IDLE, 'cleanupReserveSeconds': RESERVE,
              'requiredCIGateQualified': False, 'passed': False, 'errors': [], 'signals': [], 'diagnostics': [],
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
                events = directory/'full-events.jsonl'
                stamp = (events.stat().st_size, events.stat().st_mtime_ns) if events.exists() else None
                if stamp != progress: progress = stamp; changed = time.monotonic()
                now = time.monotonic()
                if stopped: reason = 'external cancellation'; break
                if any(f.stat().st_size > MAX_FILE for f in (directory/'stdout.log', directory/'stderr.log')) or (stamp and stamp[0] > MAX_FILE):
                    reason = 'diagnostic output exceeded 32 MiB'; break
                if now >= deadline - RESERVE: reason = 'hard execution deadline'; break
                if now - changed >= IDLE: reason = '660 seconds without native event progress'; break
                time.sleep(.1)
            report['stopReason'] = reason
            report['progressAtStop'] = progress_tail(directory/'full-events.jsonl')
            if reason and not stopped:
                # Full scope includes watchdog tests that launch the same binary.
                # Stack SwiftPM's direct test child, not a nested fixture child.
                targets = [r for r in known.values() if r.get('executable') and Path(r['executable']).name == 'LatticePackageTests.xctest' and r['ppid'] == root['pid'] and same_process(r)]
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
    report['timingScope'] = 'Setup through owned-process closure and qualification, measured before RESULT serialization/print; publication is inside the outer 45-minute job bound.'
    if report['processSecondsBeforePublication'] >= BOUND: report['passed'] = False;report['errors'].append('1800-second process bound exceeded')
    report['externalSignals'] = stopped
    write(directory/'RESULT.json', report)
    print(json.dumps({'passed': report['passed'], 'result': str(directory/'RESULT.json'), 'processSecondsBeforePublication': report['processSecondsBeforePublication']}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser();parser.add_argument('--workspace', type=Path, required=True);parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    sys.exit(run(args.workspace.resolve(), args.output.resolve()))
