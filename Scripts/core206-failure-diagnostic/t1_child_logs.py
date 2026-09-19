"""Bounded, post-cleanup retention of the unchanged SDK T1 child's raw logs.

No process launch, signal, wait, environment mutation, or test interpretation.
The caller persists this manifest and treats incomplete capture as evidence failure.
"""
import hashlib
import os
from pathlib import Path
import re
import stat


VARIANTS = ('file', 'memory', 'namedmemory')
LABELS = ('full-test', 'focused-test')
NAME = re.compile(r't1_child_(file|memory|namedmemory)_[A-Za-z0-9_-]{8}\.log\Z')
MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 24 * 1024 * 1024
MAX_FILES = 3
MAX_DIRECTORY_ENTRIES = 4096
CHUNK = 64 * 1024
MAX_ERROR_TEXT = 512


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _read_complete(fd, before, remaining):
    limit = min(MAX_FILE, remaining)
    if before.st_size > limit:
        raise ValueError('child log exceeds byte limit; no truncated copy retained')
    parts, count = [], 0
    while True:
        block = os.read(fd, min(CHUNK, limit + 1 - count))
        if not block:
            break
        parts.append(block)
        count += len(block)
        if count > limit:
            raise ValueError('child log grew beyond byte limit; no truncated copy retained')
    after = os.fstat(fd)
    if _identity(before) != _identity(after) or count != before.st_size:
        raise ValueError('child log changed during capture')
    return b''.join(parts)


def collect(tmp_root, destination, test_record, *, expected_label):
    """Return explicit complete/partial/missing/blocked evidence for all three variants.

    test_record is the ACTUAL named command receipt, not RESULT.commands' summary.
    Only fresh dedicated arm TMPDIRs are admissible; the caller establishes that binding.
    destination's parent must already exist. A fresh directory is created exclusively.
    Complete raw files only are retained: a rejected/failed copy is listed as missing.
    """
    tmp_root, destination = Path(tmp_root), Path(destination)
    result = {'schema': 1, 'expectedLabel': expected_label,
              'expectedVariants': list(VARIANTS), 'files': [],
              'missingVariants': list(VARIANTS), 'errors': [], 'bytes': 0,
              'complete': False, 'status': 'blocked', 'inventoryComplete': False,
              'cleanupAccepted': False,
              'limits': {'files': MAX_FILES, 'perFileBytes': MAX_FILE,
                         'totalBytes': MAX_TOTAL, 'directoryEntries': MAX_DIRECTORY_ENTRIES},
              'sourceDirectory': str(tmp_root), 'destinationDirectory': str(destination)}

    def error(stage, problem, name=None):
        item = {'stage': stage, 'error': str(problem)[:MAX_ERROR_TEXT]}
        if name is not None:
            item['name'] = name[:256]
        result['errors'].append(item)

    cleanup = test_record.get('cleanup') if isinstance(test_record, dict) else None
    if (expected_label not in LABELS or not isinstance(test_record, dict)
            or test_record.get('label') != expected_label or test_record.get('started') is not True
            or not isinstance(cleanup, dict) or cleanup.get('groupGone') is not True
            or cleanup.get('leaderReaped') is not True):
        error('admission', 'matching full-test/focused-test receipt, started test, and proven cleanup required')
        return result
    result['cleanupAccepted'] = True
    source_dir_fd = output_dir_fd = None
    try:
        # Descriptor-relative opens prevent a replaced directory/path from redirecting files.
        source_dir_fd = os.open(tmp_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        destination.mkdir(exist_ok=False)
        output_dir_fd = os.open(destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        candidates = []
        with os.scandir(source_dir_fd) as entries:
            for index, entry in enumerate(entries):
                if index >= MAX_DIRECTORY_ENTRIES:
                    error('inventory', 'directory entry limit reached')
                    break
                if entry.name.startswith('t1_child_'):
                    candidates.append(entry.name)
                    if len(candidates) > MAX_FILES:
                        error('inventory', 'child log count exceeds three; inventory incomplete')
                        break
            else:
                result['inventoryComplete'] = True
        grouped = {variant: [] for variant in VARIANTS}
        for name in sorted(candidates):
            match = NAME.fullmatch(name)
            if match is None:
                error('inventory', 'unsupported child log filename', name)
            else:
                grouped[match.group(1)].append(name)
        for variant, names in grouped.items():
            if len(names) != 1:
                if names:
                    error('inventory', 'multiple logs for storage variant ' + variant)
                continue
            name, source_fd, output_fd, created = names[0], None, None, False
            try:
                info = os.stat(name, dir_fd=source_dir_fd, follow_symlinks=False)
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError('child log must be a regular file, never a symlink')
                source_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                    dir_fd=source_dir_fd)
                opened = os.fstat(source_fd)
                if not stat.S_ISREG(opened.st_mode) or _identity(info) != _identity(opened):
                    raise ValueError('child log identity changed before open')
                data = _read_complete(source_fd, opened, MAX_TOTAL - result['bytes'])
                os.close(source_fd)
                source_fd = None
                output_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                    0o600, dir_fd=output_dir_fd)
                created = True
                offset = 0
                while offset < len(data):
                    written = os.write(output_fd, memoryview(data)[offset:])
                    if written <= 0:
                        raise OSError('child log output made no progress')
                    offset += written
                os.close(output_fd)
                output_fd = None
                result['files'].append({'variant': variant, 'name': name, 'bytes': len(data),
                                        'sha256': hashlib.sha256(data).hexdigest(),
                                        'completeFile': True})
                result['bytes'] += len(data)
            except (OSError, ValueError) as problem:
                error('capture', problem, name)
                if created:
                    try:
                        os.unlink(name, dir_fd=output_dir_fd)
                    except OSError as removal:
                        error('remove incomplete output', removal, name)
            finally:
                for fd in (source_fd, output_fd):
                    if fd is not None:
                        os.close(fd)
    except (OSError, ValueError) as problem:
        error('directory', problem)
    finally:
        for fd in (source_dir_fd, output_dir_fd):
            if fd is not None:
                os.close(fd)
    captured = {item['variant'] for item in result['files']}
    result['missingVariants'] = [variant for variant in VARIANTS if variant not in captured]
    result['complete'] = (result['inventoryComplete'] and not result['missingVariants']
                          and not result['errors'])
    result['status'] = 'complete' if result['complete'] else ('partial' if captured else 'missing')
    return result
