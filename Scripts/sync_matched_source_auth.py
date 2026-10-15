#!/usr/bin/env python3
"""Private same-session source authentication for the matched coordinator.

This is one GuardedRunner-owned batch, not 72 fabricated individual owners.
Every Git leader is waited and its group is observed worker-only before the
next command. Only the outer genuine owner can prove the whole group ended.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import types

REQUEST_LIMIT = 32 * 2**20
OUTPUT_LIMIT = 2**20
ENTRY_LIMIT = 64
BATCH_SECONDS = 60


def read_regular(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise ValueError('authentication input is not a bounded regular file')
        with os.fdopen(descriptor, 'rb', closefd=False) as source:
            data = source.read(limit + 1)
        after = os.fstat(descriptor)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode,
                                  value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if len(data) > limit or len(data) != before.st_size or identity(before) != identity(after):
            raise ValueError('authentication input changed or exceeded its bound')
        return data
    finally:
        os.close(descriptor)


def authenticated_source(path, expected):
    raw = read_regular(path, OUTPUT_LIMIT)
    if len(raw) != expected['bytes'] or hashlib.sha256(raw).hexdigest() != expected['sha256']:
        raise ValueError('executable supplier bytes changed before execution: ' + str(path))
    return raw


def prepare_worker(receipts, label, data, development, coordinator_path):
    root = Path(data['root'])
    helper = data['measurementFiles']['Scripts/sync_matched_source_auth.py']
    authenticated_source(Path(coordinator_path), data['measurementFiles']['Scripts/sync_matched_experiment.py'])
    authenticated_source(Path(__file__), helper)
    authenticated_source(Path(development.__file__), data['source']['sdk']['files']['Scripts/run-development.py'])
    raw = authenticated_source(root / 'lattice/Scripts/sync_matched_source_auth.py', helper)
    # Execute a fresh owned copy of the authenticated actual bytes, rather than
    # reopening the mutable prepared supplier after hashing it.
    worker = receipts / (label + '-WORKER.py')
    with worker.open('xb') as output:
        output.write(raw)
    worker.chmod(0o444)
    authenticated_source(worker, helper)
    return worker


def load_development(root, sdk_entry):
    if Path(sdk_entry['path']) != root / 'lattice':
        raise ValueError('the original first source entry must be the actual SDK')
    path = root / 'lattice/Scripts/run-development.py'
    raw = authenticated_source(path, sdk_entry['files']['Scripts/run-development.py'])
    # Run precisely these validated bytes; an import loader would reopen the
    # mutable path after authentication and could execute a replacement.
    module = types.ModuleType('matched_auth_development')
    module.__file__ = str(path)
    exec(compile(raw, str(path), 'exec'), module.__dict__)
    return module


def remaining(end):
    value = end - time.monotonic()
    if value <= 0:
        raise TimeoutError('fixed authentication batch deadline expired')
    return value


def observed_command(argv, cwd, path, end, records, kind):
    """No session/group creation; an unjoined failure remains outer-owner debt."""
    remaining(end)
    record = {'kind': kind, 'argv': argv, 'cwd': str(cwd), 'output': path.name,
              'started': False, 'leaderReaped': False, 'exitCode': None,
              'workerPID': os.getpid(), 'ownedPGID': os.getpgrp()}
    records.append(record)  # Retain the first issued attempt, including failure.
    started = time.monotonic()
    process = None
    try:
        with path.open('xb') as output:
            process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=False)
            record.update(started=True, pid=process.pid)
            record['childPGID'] = os.getpgid(process.pid)
            if record['childPGID'] != record['ownedPGID']:
                raise RuntimeError('authentication child escaped the actual owned group')
            while True:
                try:
                    record['exitCode'] = process.wait(timeout=min(0.05, remaining(end)))
                    record['leaderReaped'] = True
                except subprocess.TimeoutExpired:
                    pass
                if os.fstat(output.fileno()).st_size > OUTPUT_LIMIT:
                    raise ValueError('authentication command output overflow; partial retained')
                if record['leaderReaped']:
                    break
        data = read_regular(path, OUTPUT_LIMIT)
        record.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        if record['exitCode'] != 0:
            raise RuntimeError('authentication command failed: ' + kind)
        return data, process.pid
    finally:
        record['elapsedSeconds'] = time.monotonic() - started
        if process is not None and not record['leaderReaped']:
            # poll is a real nonblocking wait. Never claim an unsettled child
            # joined; the genuine outer GuardedRunner cleans the whole group.
            code = process.poll()
            if code is not None:
                record.update(exitCode=code, leaderReaped=True)


def require_worker_only(outputs, end, records, ordinal):
    raw, observer_pid = observed_command(
        ['ps', '-axo', 'pid=,pgid='], outputs, outputs / f'{ordinal:03d}-group.log',
        min(end, time.monotonic() + 2), records, 'owned-group-observation')
    rows = [line.split() for line in raw.decode('ascii').splitlines() if line.strip()]
    if any(len(row) != 2 or not all(cell.isdigit() for cell in row) for row in rows):
        raise ValueError('unparseable authentication owned-group observation')
    own = [int(pid) for pid, pgid in rows if int(pgid) == os.getpgrp()]
    # ps may include its own just-reaped leader in its real snapshot.
    actual = sorted(pid for pid in own if pid != observer_pid)
    records[-1]['ownedGroupMembersAfterObserver'] = actual
    if actual != [os.getpid()]:
        raise RuntimeError('authentication group is not worker-only; no next command admitted')


def authenticate(request_path, outputs):
    report = {'schema': 'lattice.sync-matched-source-auth/1', 'success': False,
              'firstFailure': None, 'evidenceErrors': [], 'repositories': [], 'commands': [],
              'workerPID': os.getpid(), 'ownedPGID': os.getpgrp(),
              'wholeGroupEndingProof': 'required from outer GuardedRunner; not issued here'}
    owned_outputs = False
    end = None
    try:
        if os.getpid() != os.getpgrp() or os.getsid(0) != os.getpid():
            raise RuntimeError('authentication requires a genuine outer-owned session leader')
        raw = read_regular(request_path, REQUEST_LIMIT)
        report['requestSHA256'] = hashlib.sha256(raw).hexdigest()
        request = json.loads(raw)
        issued, end = request['issuedMonotonic'], request['deadlineMonotonic']
        if (request.get('schema') != 'lattice.sync-matched-source-auth-request/1'
                or type(issued) not in (int, float) or type(end) not in (int, float)
                or not math.isfinite(issued) or not math.isfinite(end)
                or not 0 < end - issued <= BATCH_SECONDS or time.monotonic() < issued):
            raise ValueError('invalid fixed authentication deadline/request')
        remaining(end)
        entries = request['entries']
        if type(entries) is not list or not 0 < len(entries) <= ENTRY_LIMIT:
            raise ValueError('bounded complete authentication entries required')
        root = Path(request['root']).resolve(strict=True)
        if (root == (Path.home() / 'localdev').resolve(strict=True)
                or not root.is_relative_to((Path.home() / 'localdev').resolve(strict=True))):
            raise ValueError('authentication graph escaped original localdev root')
        if outputs.parent.resolve(strict=True) != request_path.parent.resolve(strict=True):
            raise ValueError('authentication outputs must share the issued receipt parent')
        outputs.mkdir(mode=0o700, exist_ok=False)
        owned_outputs = True
        development = load_development(root, entries[0])
        for ordinal, entry in enumerate(entries):
            remaining(end)
            path = Path(entry['path'])
            if not path.resolve(strict=True).is_relative_to(root):
                raise ValueError('source path retargeted outside prepared original')
            hash_started = time.monotonic()
            if development.tracked_manifest(path, entry['files']) != entry['files']:
                raise ValueError('prepared original tracked bytes changed: ' + str(path))
            row = {'ordinal': ordinal, 'path': str(path),
                   'trackedHashSeconds': time.monotonic() - hash_started}
            report['repositories'].append(row)
            for suffix, argv in (
                    ('head', ['git', 'rev-parse', 'HEAD']),
                    ('status', ['git', 'status', '--porcelain=v1', '-z', '--untracked-files=all'])):
                data, _ = observed_command(argv, path, outputs / f'{ordinal:03d}-{suffix}.log',
                                           end, report['commands'], suffix)
                require_worker_only(outputs, end, report['commands'], ordinal * 2 + (suffix == 'status'))
                if suffix == 'head':
                    if data.decode().strip() != entry['commit']:
                        raise ValueError('actual prepared checkout identity changed')
                else:
                    allowed = ('Package.resolved',) if path == root / 'lattice' else ()
                    if any(value[3:] not in allowed for value in data.decode().split('\0') if value):
                        raise ValueError('actual prepared source checkout state changed')
            row['verified'] = True
        remaining(end)
        report['success'] = True
    except BaseException as error:
        report['firstFailure'] = {'type': type(error).__name__, 'message': str(error)[:2048]}
    finally:
        def publication_end_check():
            if type(end) in (int, float) and math.isfinite(end) and time.monotonic() >= end:
                report['success'] = False
                failure = {'type': 'TimeoutError', 'message': 'fixed authentication deadline expired before publication'}
                if report['firstFailure'] is None:
                    report['firstFailure'] = failure
                else:
                    report['evidenceErrors'].append(failure)
        publication_end_check()
        wire = json.dumps(report, sort_keys=True)
        if len(wire.encode()) > OUTPUT_LIMIT:
            report['success'] = False
            if report['firstFailure'] is None:
                report['firstFailure'] = {'type': 'ValueError', 'message': 'authentication report overflow'}
        if owned_outputs:
            try:
                with (outputs / 'RESULT.json').open('x') as output:
                    json.dump(report, output, indent=2, sort_keys=True)
                    output.write('\n')
            except BaseException as error:
                report['success'] = False
                report['evidenceErrors'].append({'type': type(error).__name__, 'message': str(error)[:2048]})
        publication_end_check()
        wire = json.dumps(report, sort_keys=True)
        if len(wire.encode()) > OUTPUT_LIMIT:
            wire = json.dumps({'schema': report['schema'], 'success': False,
                               'firstFailure': report['firstFailure'], 'reportOverflow': True,
                               'completeReport': str(outputs / 'RESULT.json')}, sort_keys=True)
        print(wire, flush=True)
    return 0 if report['success'] else 1


def verify_success(report, request_sha, entries, root, outputs, command, end):
    """Parent consumes original raw output only after actual whole-group ending."""
    remaining(end)
    if (report.get('success') is not True or report.get('firstFailure') is not None
            or report.get('evidenceErrors') or report.get('requestSHA256') != request_sha
            or report.get('workerPID') != command.get('pid')
            or report.get('ownedPGID') != command.get('ownedPGID')
            or command.get('success') is not True
            or command.get('cleanup', {}).get('groupGone') is not True
            or command.get('cleanup', {}).get('leaderReaped') is not True
            or command.get('cleanup', {}).get('signals')):
        raise ValueError('actual authentication batch binding/ending is incomplete')
    rows, commands = report['repositories'], report['commands']
    if len(rows) != len(entries) or len(commands) != 4 * len(entries):
        raise ValueError('authentication result omitted/added an original source or command')
    for ordinal, (entry, row) in enumerate(zip(entries, rows)):
        if row.get('ordinal') != ordinal or row.get('path') != entry['path'] or row.get('verified') is not True:
            raise ValueError('authentication source order/result mismatch')
        for offset, (suffix, argv) in enumerate((
                ('head', ['git', 'rev-parse', 'HEAD']),
                ('status', ['git', 'status', '--porcelain=v1', '-z', '--untracked-files=all']))):
            actual, observer = commands[ordinal * 4 + offset * 2:ordinal * 4 + offset * 2 + 2]
            if actual['kind'] != suffix or actual['argv'] != argv or actual['cwd'] != entry['path']:
                raise ValueError('original Git command/output correspondence changed')
            expected = f'{ordinal:03d}-{suffix}.log'
            if actual['output'] != expected or observer['output'] != f'{ordinal * 2 + offset:03d}-group.log':
                raise ValueError('authentication output name correspondence changed')
            for item in (actual, observer):
                data = read_regular(outputs / item['output'], OUTPUT_LIMIT)
                if (len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']
                        or item['exitCode'] != 0 or item['leaderReaped'] is not True
                        or item['ownedPGID'] != report['ownedPGID']
                        or item['childPGID'] != report['ownedPGID']):
                    raise ValueError('actual authentication command bytes/wait/group changed')
            if (observer['kind'] != 'owned-group-observation'
                    or observer['argv'] != ['ps', '-axo', 'pid=,pgid=']
                    or observer.get('ownedGroupMembersAfterObserver') != [report['workerPID']]):
                raise ValueError('actual per-command worker-only observation is incomplete')
            raw = read_regular(outputs / expected, OUTPUT_LIMIT).decode()
            allowed = ('Package.resolved',) if Path(entry['path']) == root / 'lattice' else ()
            if ((suffix == 'head' and raw.strip() != entry['commit'])
                    or (suffix == 'status' and any(value[3:] not in allowed for value in raw.split('\0') if value))):
                raise ValueError('actual prepared source checkout identity/state changed')
    remaining(end)  # No profile may accept late cleanup/raw verification.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', type=Path, required=True)
    parser.add_argument('--outputs', type=Path, required=True)
    args = parser.parse_args()
    return authenticate(args.request, args.outputs)


if __name__ == '__main__':
    sys.exit(main())
