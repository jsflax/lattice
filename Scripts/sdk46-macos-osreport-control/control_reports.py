"""Control-only copy of the reviewed bounded collector; never scans for an SDK bundle."""
import copy
import hashlib
import os
from pathlib import Path
import stat
import time
import parse_report

MAX_FILE, MAX_TOTAL, MAX_FILES = 8 * 2**20, 16 * 2**20, 8
MAX_CANDIDATES, MAX_ENTRIES, MAX_METADATA, MAX_TEXT = 64, 4096, 64, 1024



class Collector:
    def __init__(self, root, destination, started_at, executable, pid, exit_end, directories=None):
        self.root, self.destination = Path(root), Path(destination)
        self.started_at = started_at
        self.directories = directories if directories is not None else [
            Path.home() / 'Library/Logs/DiagnosticReports', Path('/Library/Logs/DiagnosticReports')]
        assert len(self.directories) <= 2
        executable = Path(executable)
        if executable.is_symlink() or not executable.is_file() or executable.parent != self.root / 'control':
            raise ValueError('expected one exact regular owned control executable')
        if type(pid) is not int or pid <= 0 or not 0 < started_at <= exit_end:
            raise ValueError('expected observed owned PID and launch/exit interval')
        self.executable, self.pid, self.exit_end = str(executable), pid, exit_end
        self.prefixes = (executable.name,)
        self.destination.mkdir(exist_ok=False)
        self.seen, self.hashes = set(), set()
        self.stopped = False
        self.result = {'scope': 'bounded owned PID/name/time report custody; strict path/stack admission remains separate',
            'controlExecutable': str(executable), 'startedAtEpoch': started_at,
            'ownedPID':pid, 'exitEndEpoch':exit_end,
            'files': [], 'bytes': 0, 'errors': [], 'rejected': [], 'scans': [],
            'inventoryTruncated': False, 'metadataOmitted': {'errors': 0, 'rejected': 0},
            'limits': {'file': MAX_FILE, 'total': MAX_TOTAL, 'files': MAX_FILES,
                'candidates': MAX_CANDIDATES, 'entriesPerDirectoryPass': MAX_ENTRIES,
                'metadataPerKind': MAX_METADATA, 'errorText': MAX_TEXT, 'scans': 1, 'arrivalWindowSeconds': 60},
            'counters': {'eligibleReadAttempts': 0, 'incompleteRetries': 0, 'duplicateContents': 0}}

    def record(self, kind, value):
        if len(self.result[kind]) < MAX_METADATA:
            self.result[kind].append({k: v[:MAX_TEXT] if isinstance(v, str) else v for k, v in value.items()})
        else:
            self.result['metadataOmitted'][kind] += 1

    def scan(self, label, *, wait_seconds=60):
        if self.stopped:
            raise RuntimeError('collector stopped after output custody failure')
        if len(self.result['scans']) >= 1:
            raise ValueError('aggregate scan cap reached')
        started = time.monotonic()
        scan = {'label': label, 'beginEpoch': time.time(), 'beginMonotonic': started,
                'attempts': 0, 'directories': {str(p): {'presentPasses': 0, 'missingPasses': 0,
                    'entries': 0, 'matchingNames': 0, 'oldOrNonregular': 0} for p in self.directories}}
        self.result['scans'].append(scan)
        deadline = started + min(60, max(0, wait_seconds))
        while True:
            scan['attempts'] += 1
            for directory in self.directories:
                facts = scan['directories'][str(directory)]
                try:
                    candidates = []
                    with os.scandir(directory) as entries:
                        facts['presentPasses'] += 1
                        for index, entry in enumerate(entries):
                            if index >= MAX_ENTRIES:
                                self.result['inventoryTruncated'] = True
                                break
                            facts['entries'] += 1
                            if entry.name.startswith(self.prefixes) and Path(entry.name).suffix in ('.ips', '.crash'):
                                facts['matchingNames'] += 1
                                candidates.append(Path(entry.path))
                    candidates.sort()
                except FileNotFoundError:
                    facts['missingPasses'] += 1
                    continue
                except OSError as error:
                    self.record('errors', {'directory': str(directory), 'error': str(error)})
                    continue
                for path in candidates:
                    if self.result['counters']['eligibleReadAttempts'] >= MAX_CANDIDATES:
                        self.result['inventoryTruncated'] = True
                        break
                    try:
                        info = path.lstat()
                        identity = (str(path), info.st_ino, info.st_size, info.st_mtime_ns)
                        if identity in self.seen:
                            continue
                        if info.st_mtime < self.started_at or not stat.S_ISREG(info.st_mode):
                            facts['oldOrNonregular'] += 1
                            continue
                        self.seen.add(identity)
                        self.result['counters']['eligibleReadAttempts'] += 1
                        if len(self.result['files']) >= MAX_FILES or info.st_size > min(MAX_FILE, MAX_TOTAL - self.result['bytes']):
                            self.record('rejected', {'name': path.name, 'reason': 'aggregate file/byte limit'})
                            continue
                        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                        with os.fdopen(fd, 'rb') as source:
                            opened = os.fstat(source.fileno())
                            if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                                raise OSError('report type/identity changed before open')
                            data = source.read(MAX_FILE + 1)
                            after = os.fstat(source.fileno())
                        if (after.st_size, after.st_mtime_ns) != (info.st_size, info.st_mtime_ns):
                            self.result['counters']['incompleteRetries'] += 1
                            self.seen.discard(identity)
                            continue
                        if len(data) > min(MAX_FILE, MAX_TOTAL - self.result['bytes']):
                            self.record('rejected', {'name': path.name, 'reason': 'aggregate byte limit after read'})
                            continue
                        try:
                            candidate = parse_report.retention_candidate(data, executable=self.executable, pid=self.pid,
                                launch_begin=self.started_at, exit_end=self.exit_end, scan_end=time.time())
                        except (ValueError, UnicodeError, RecursionError) as error:
                            self.record('rejected', {'name': path.name, 'reason': str(error)[:MAX_TEXT]})
                            continue
                        digest = hashlib.sha256(data).hexdigest()
                        if digest in self.hashes:
                            self.result['counters']['duplicateContents'] += 1
                            continue
                        name = f'{len(self.result["files"]):02d}-{path.name}'
                        # Reserve the entire charge and slot before output starts. A
                        # short/failed write stays accounted and stops all later scans.
                        entry = {'name': name, 'reservedBytes': len(data), 'scan': label,
                                 'status': 'copy-not-completed', 'candidateIdentity': candidate}
                        self.result['files'].append(entry)
                        self.result['bytes'] += len(data)
                        try:
                            with (self.destination / name).open('xb') as target:
                                if target.write(data) != len(data):
                                    raise OSError('short crash report write')
                        except BaseException as error:
                            self.stopped = True
                            self.record('errors', {'name': name, 'error': str(error),
                                                  'scope': 'output custody; reserved bytes retained'})
                            scan.update(endEpoch=time.time(), endMonotonic=time.monotonic())
                            raise RuntimeError('crash report copy failed; collection stopped') from error
                        entry.update(status='complete', bytes=len(data), sha256=digest)
                        self.hashes.add(digest)
                    except OSError as error:
                        self.record('errors', {'name': path.name, 'error': str(error)})
            if time.monotonic() >= deadline:
                break
            time.sleep(min(.25, max(0, deadline - time.monotonic())))
        scan.update(endEpoch=time.time(), endMonotonic=time.monotonic())
        self.result['reportsFound'] = bool(self.result['files'])
        return copy.deepcopy(self.result)

    def snapshot(self):
        for entry in self.result['files']:
            if entry['status'] == 'complete':
                path = self.destination / entry['name']
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, 'rb') as source:
                    before = os.fstat(source.fileno())
                    assert stat.S_ISREG(before.st_mode) and before.st_size == entry['bytes']
                    data = source.read(MAX_FILE + 1)
                    after = os.fstat(source.fileno())
                assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                assert len(data) == entry['bytes'] <= MAX_FILE
                assert hashlib.sha256(data).hexdigest() == entry['sha256']
        self.result['custodyStopped'] = self.stopped
        self.result['reportsFound'] = any(x['status'] == 'complete' for x in self.result['files'])
        return copy.deepcopy(self.result)
