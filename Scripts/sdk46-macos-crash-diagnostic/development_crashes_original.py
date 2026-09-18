"""Bounded, post-test crash evidence from this development job's test bundle."""
import hashlib
import os
from pathlib import Path
import stat
import time


MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 16 * 1024 * 1024
MAX_FILES = 8
MAX_CANDIDATES = 64
MAX_DIRECTORY_ENTRIES = 4096
MAX_METADATA = 64
MAX_ERROR_TEXT = 1024
PREFIXES = ('LatticePackageTests', 'swiftpm-testing-helper')


def collect(root, destination, started_at, *, directories=None, wait_seconds=3):
    root, destination = Path(root), Path(destination)
    expected = list((root / 'scratch').glob('*/debug/LatticePackageTests.xctest/Contents/MacOS/LatticePackageTests'))
    result = {'scope': 'post-test reports naming this exact test bundle',
              'startedAtEpoch': started_at, 'files': [], 'rejected': [],
              'errors': [], 'bytes': 0, 'inventoryTruncated': False,
              'metadataOmitted': {'errors': 0, 'rejected': 0},
              'limits': {'file': MAX_FILE, 'total': MAX_TOTAL, 'files': MAX_FILES,
                         'candidates': MAX_CANDIDATES, 'directoryEntries': MAX_DIRECTORY_ENTRIES,
                         'metadataPerKind': MAX_METADATA, 'errorText': MAX_ERROR_TEXT}}

    def record(kind, value):
        if len(result[kind]) < MAX_METADATA:
            if isinstance(value, dict):
                value = {key: text[:MAX_ERROR_TEXT] if isinstance(text, str) else text
                         for key, text in value.items()}
            result[kind].append(value)
        else:
            result['metadataOmitted'][kind] += 1
    if len(expected) != 1:
        record('errors', 'expected exactly one development test bundle')
        return result
    marker = str(expected[0]).encode()
    result['testBundleExecutable'] = str(expected[0])
    if directories is None:
        directories = [Path.home() / 'Library/Logs/DiagnosticReports', Path('/Library/Logs/DiagnosticReports')]
    deadline = time.monotonic() + min(max(wait_seconds, 0), 3)
    seen = set()
    destination.mkdir(exist_ok=False)
    while True:
        for directory in directories:
            try:
                candidates = []
                with os.scandir(directory) as entries:
                    for index, entry in enumerate(entries):
                        if index >= MAX_DIRECTORY_ENTRIES:
                            result['inventoryTruncated'] = True
                            break
                        if entry.name.startswith(PREFIXES) and Path(entry.name).suffix in ('.ips', '.crash'):
                            candidates.append(Path(entry.path))
                candidates.sort()
            except FileNotFoundError:
                continue
            except OSError as error:
                record('errors', {'directory': str(directory), 'error': str(error)})
                continue
            for path in candidates:
                if len(seen) >= MAX_CANDIDATES:
                    result['inventoryTruncated'] = True
                    break
                if not path.name.startswith(PREFIXES) or path.suffix not in ('.ips', '.crash'):
                    continue
                try:
                    info = path.lstat()
                    identity = (str(path), info.st_ino, info.st_size, info.st_mtime_ns)
                    if identity in seen or info.st_mtime < started_at or not stat.S_ISREG(info.st_mode):
                        continue
                    seen.add(identity)
                    if len(result['files']) >= MAX_FILES or info.st_size > min(MAX_FILE, MAX_TOTAL - result['bytes']):
                        record('rejected', {'name': path.name, 'reason': 'byte/file limit'})
                        continue
                    # A replaced FIFO must not block open before fstat can reject it.
                    # Never follow a swapped symlink or read beyond the fixed byte cap.
                    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(fd, 'rb') as source:
                        opened = os.fstat(source.fileno())
                        if not stat.S_ISREG(opened.st_mode):
                            raise OSError('report is no longer a regular file')
                        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                            raise OSError('report identity changed before open')
                        data = source.read(MAX_FILE + 1)
                        after = os.fstat(source.fileno())
                    if (after.st_size, after.st_mtime_ns) != (info.st_size, info.st_mtime_ns):
                        seen.discard(identity)  # A later pass may see the completed report.
                        continue
                    if len(data) > min(MAX_FILE, MAX_TOTAL - result['bytes']):
                        record('rejected', {'name': path.name, 'reason': 'byte limit after read'})
                        continue
                    if marker not in data:
                        record('rejected', {'name': path.name, 'reason': 'exact test bundle absent'})
                        continue
                    name = f'{len(result["files"]):02d}-{path.name}'
                    with (destination / name).open('xb') as output:
                        output.write(data)
                    result['files'].append({'name': name, 'bytes': len(data),
                                            'sha256': hashlib.sha256(data).hexdigest()})
                    result['bytes'] += len(data)
                except OSError as error:
                    record('errors', {'name': path.name, 'error': str(error)})
        if time.monotonic() >= deadline:
            break
        time.sleep(min(0.25, max(0, deadline - time.monotonic())))
    result['reportsFound'] = bool(result['files'])
    return result
