"""Passive diagnostic DATA, never a test, process-ending or numerical verdict."""
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import time
import uuid

PREFIX = b'LATTICE_BASELINE_LIFECYCLE '
PHASES = ('profile_entered', 'observations_frozen', 'clients_close_loop_returned',
          'relay_shutdown_returned', 'wrappers_release_returned',
          'pool_shutdown_returned', 'logging_block_returned', 'report_written')
MAX_LINE = 8192
MAX_REPORT = 8 * 2**20
MAX_READ = 32 * 2**20
MAX_LOG = 512 * 2**20
FLOOR = 12 * 2**30

class ObservationRefused(ValueError):
    pass

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ObservationRefused('duplicate JSON key')
        result[key] = value
    return result

def strict_json(text):
    def bad_number(value):
        raise ObservationRefused('nonfinite JSON number')
    def bounded_int(value):
        if len(value) > 32:
            raise ObservationRefused('JSON integer length refused')
        return int(value)
    def bounded_float(value):
        if len(value) > 128:
            raise ObservationRefused('JSON float length refused')
        number = float(value)
        if not math.isfinite(number):
            raise ObservationRefused('nonfinite JSON number')
        return number
    return json.loads(text, object_pairs_hook=unique_object, parse_constant=bad_number,
                      parse_int=bounded_int, parse_float=bounded_float)

def normalized_uuid(value):
    if not isinstance(value, str) or len(value) != 36:
        raise ObservationRefused('UUID spelling unavailable')
    result = str(uuid.UUID(value))
    if result != value.lower():
        raise ObservationRefused('UUID spelling unavailable')
    return result

def image_uuids(text):
    rows = text.splitlines()
    if not 1 <= len(rows) <= 4:
        raise ObservationRefused('actual image UUID rows unavailable')
    result = []
    for row in rows:
        match = re.fullmatch(r'UUID: ([0-9A-Fa-f-]{36}) \((arm64e?|x86_64)\) (.+)', row)
        if not match:
            raise ObservationRefused('actual image UUID row refused')
        result.append(dict(uuid=normalized_uuid(match[1]), arch=match[2], path=match[3]))
    if len({(row['uuid'], row['arch']) for row in result}) != len(result):
        raise ObservationRefused('duplicate image UUID row')
    return result

def unexpected_sig11(log_path):
    needle = b'exited with unexpected signal code 11'
    tail, count = b'', 0
    with Path(log_path).open('rb') as source:
        while True:
            block = source.read(min(65536, MAX_LOG + 1 - count))
            if not block:
                return False
            count += len(block)
            if count > MAX_LOG:
                raise ObservationRefused('original log bound refused')
            if needle in tail + block:
                return True
            tail = (tail + block)[-(len(needle) - 1):]

def phases(log_path, command, diagnostic_id, allowed_images, started_wall, ended_wall):
    normalized_uuid(diagnostic_id)
    rows = []
    with Path(log_path).open('rb') as source:
        while True:
            line = source.readline(MAX_LINE + 1)
            if not line:
                break
            if len(line) > MAX_LINE:
                # Consume a non-observation line in bounded pieces. A split or
                # oversized observation is unknown, never repaired by joining.
                if line.startswith(PREFIX):
                    raise ObservationRefused('oversized lifecycle line')
                while line and not line.endswith(b'\n'):
                    line = source.readline(MAX_LINE + 1)
                continue
            if not line.startswith(PREFIX):
                continue
            if len(rows) == len(PHASES) or not line.endswith(b'\n'):
                raise ObservationRefused('lifecycle count or framing refused')
            row = strict_json(line[len(PREFIX):].decode('utf-8', 'strict'))
            expected = {'schema', 'phase', 'diagnosticID', 'fixtureRunID', 'pid', 'ppid',
                        'pgid', 'image', 'monotonicNS', 'wallSeconds'}
            if not isinstance(row, dict) or set(row) != expected:
                raise ObservationRefused('lifecycle fields refused')
            if (row['schema'] != 'lattice.baseline-lifecycle/1'
                    or row['phase'] != PHASES[len(rows)] or row['diagnosticID'] != diagnostic_id):
                raise ObservationRefused('lifecycle order or identity refused')
            normalized_uuid(row['fixtureRunID'])
            if (any(type(row[key]) is not int or row[key] <= 0 for key in ('pid', 'ppid', 'pgid', 'monotonicNS'))
                    or row['monotonicNS'] >= 2**64 or row['pid'] == row['ppid']
                    or row['pid'] == command.get('pid') or row['pgid'] != command.get('ownedPGID')
                    or command.get('started') is not True or row['image'] not in allowed_images):
                raise ObservationRefused('actual descendant or image unavailable')
            wall = row['wallSeconds']
            if (type(wall) not in (int, float) or not math.isfinite(wall)
                    or not started_wall <= wall <= ended_wall + 1):
                raise ObservationRefused('lifecycle wall window refused')
            if rows and (any(row[key] != rows[0][key] for key in ('pid', 'ppid', 'pgid', 'image', 'fixtureRunID'))
                         or row['monotonicNS'] < rows[-1]['monotonicNS'] or wall < rows[-1]['wallSeconds']):
                raise ObservationRefused('lifecycle host or time changed')
            rows.append(row)
    if not rows:
        raise ObservationRefused('no qualified test-host observation')
    return dict(qualified=True, rows=rows, host=rows[0], lastPhase=rows[-1]['phase'],
                directParentMatchesDriver=rows[0]['ppid'] == command.get('pid'),
                ownedSessionGroupMatchesDriver=True,
                originalCleanupOrCompletionAuthority=False)

def report_time(value):
    if not isinstance(value, str) or len(value) > 64:
        raise ObservationRefused('OS report time unavailable')
    for spelling in ('%Y-%m-%d %H:%M:%S.%f %z', '%Y-%m-%d %H:%M:%S %z',
                     '%Y-%m-%dT%H:%M:%S.%f%z', '%Y-%m-%dT%H:%M:%S%z'):
        try:
            return datetime.strptime(value, spelling).timestamp()
        except ValueError:
            continue
    raise ObservationRefused('OS report time spelling refused')

def matching_report(raw, observation, started_wall, ended_wall, uuid_sets, test_image):
    if not 0 < len(raw) <= MAX_REPORT or observation.get('qualified') is not True:
        raise ObservationRefused('OS report bound or host unavailable')
    text = raw.decode('utf-8', 'strict')
    first, separator, remaining = text.partition('\n')
    if not separator or len(first) > 65536:
        raise ObservationRefused('modern OS report framing unavailable')
    header, report = strict_json(first), strict_json(remaining)
    if not isinstance(header, dict) or not isinstance(report, dict):
        raise ObservationRefused('OS report objects unavailable')
    host = observation['host']
    if type(report.get('pid')) is not int or report['pid'] != host['pid'] or report.get('procPath') != host['image']:
        raise ObservationRefused('OS report PID or executable differs')
    launch, capture = report_time(report.get('procLaunch')), report_time(report.get('captureTime'))
    if not (started_wall <= launch <= host['wallSeconds'] + 1
            and launch <= capture <= ended_wall + 10 and capture >= started_wall):
        raise ObservationRefused('OS report launch or capture window differs')
    exception = report.get('exception')
    if not isinstance(exception, dict) or exception.get('type') != 'EXC_BAD_ACCESS' or exception.get('signal') != 'SIGSEGV':
        raise ObservationRefused('OS report is not the requested SIG11 fault')
    images = report.get('usedImages')
    if not isinstance(images, list) or not 1 <= len(images) <= 2048:
        raise ObservationRefused('OS report loaded images unavailable')
    proved = {}
    for required in {host['image'], test_image}:
        actual = [normalized_uuid(row.get('uuid')) for row in images
                  if isinstance(row, dict) and row.get('path') == required]
        if len(actual) != 1 or actual[0] not in uuid_sets.get(required, set()):
            raise ObservationRefused('OS report exact loaded image UUID differs')
        proved[required] = actual[0]
    return dict(pid=host['pid'], executable=host['image'], launchWall=launch, captureWall=capture,
                exceptionType='EXC_BAD_ACCESS', signal='SIGSEGV', matchedActualImageUUIDs=proved,
                lastObservedPhase=observation['lastPhase'], causeAssigned=False)

def stable_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= MAX_REPORT
                or before.st_nlink != 1 or before.st_uid not in (0, os.getuid())
                or before.st_mode & 0o022):
            raise ObservationRefused('OS report regular ownership or bound refused')
        chunks, count = [], 0
        while count < before.st_size:
            block = os.read(fd, min(1048576, before.st_size - count))
            if not block:
                break
            chunks.append(block); count += len(block)
        after = os.fstat(fd)
        fields = ('st_dev', 'st_ino', 'st_size', 'st_uid', 'st_mode', 'st_nlink', 'st_mtime_ns', 'st_ctime_ns')
        if count != before.st_size or os.read(fd, 1) or any(getattr(before, key) != getattr(after, key) for key in fields):
            raise ObservationRefused('OS report changed during bounded read')
        return b''.join(chunks)
    finally:
        os.close(fd)

def report_roots():
    return (Path.home() / 'Library/Logs/DiagnosticReports', Path('/Library/Logs/DiagnosticReports'))

def collect_reports(receipts, observation, started_wall, ended_wall, uuid_sets, test_image,
                    deadline, wait_for_sig11):
    result = dict(scope='Only strictly matched OS reports copied; absence is not no-crash proof',
                  matched=[], refusals={}, aggregateReadBytes=0, originalOutcomeUnchanged=True,
                  matchingReportUnavailable=True, admittedReportReads=0,
                  maximumAdmittedReadBytes=MAX_READ)
    if observation.get('qualified') is not True:
        result['unavailable'] = 'no qualified test-host identity'
        return result
    seen = set()
    def refuse(category):
        result['refusals'][category] = result['refusals'].get(category, 0) + 1
    for attempt in range(5):
        if time.monotonic() >= deadline:
            break
        for root in report_roots():
            try:
                if root.resolve(strict=True) != root or root.is_symlink() or not root.is_dir():
                    raise ObservationRefused('OS report directory alias refused')
                with os.scandir(root) as entries:
                    for ordinal, entry in enumerate(entries):
                        if ordinal >= 128:
                            refuse('directory-entry-bound'); break
                        if time.monotonic() >= deadline:
                            break
                        if not entry.name.endswith('.ips') or str(root / entry.name) in seen:
                            continue
                        path = root / entry.name
                        try:
                            st = path.lstat()
                            if not started_wall - 2 <= st.st_mtime <= ended_wall + 10:
                                continue
                            # Every attempted read, including a malformed or
                            # changing file, consumes one full per-file allowance.
                            # Four attempts * 8 MiB bounds all raw report reads.
                            if result['admittedReportReads'] >= MAX_READ // MAX_REPORT:
                                refuse('aggregate-read-bound'); return result
                            result['admittedReportReads'] += 1
                            raw = stable_regular(path)
                            result['aggregateReadBytes'] += len(raw)
                            proof = matching_report(raw, observation, started_wall, ended_wall, uuid_sets, test_image)
                            if time.monotonic() >= deadline:
                                refuse('fixed-capture-deadline'); return result
                            v = os.statvfs(receipts)
                            if v.f_bavail * v.f_frsize < FLOOR + len(raw) + 64 * 2**20:
                                raise ObservationRefused('original disk floor')
                            target = Path(receipts) / ('SIG11-OS-REPORT-' + str(len(result['matched']) + 1) + '.ips')
                            try:
                                with target.open('xb') as out:
                                    out.write(raw)
                                target.chmod(0o444)
                            except OSError as error:
                                result['copyDebt'] = dict(path=str(target), errorType=type(error).__name__,
                                                          completeCopyUnproved=True)
                                result['matchingReportUnavailable'] = True
                                return result
                            result['matched'].append(dict(proof=proof, copy=str(target), bytes=len(raw),
                                sha256=hashlib.sha256(raw).hexdigest(), sourceWasReadOnly=True))
                            result['matchingReportUnavailable'] = False
                            return result
                        except (OSError, ValueError, TypeError, RecursionError, UnicodeError) as error:
                            refuse(type(error).__name__)
                        seen.add(str(path))
            except (OSError, ValueError) as error:
                refuse(type(error).__name__)
        if result['matched'] or not wait_for_sig11:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(2, remaining))
    result['matchingReportUnavailable'] = not result['matched']
    return result
