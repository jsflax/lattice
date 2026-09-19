#!/usr/bin/env python3
"""Post-exit smoke evidence only. Never open original stores with SQLite."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time
import uuid


STORES = tuple('clients/' + name + '.sqlite' for name in (
    'hot-writer-0', 'hot-writer-1', 'hot-watcher', 'quiet-writer-0', 'quiet-watcher'
)) + ('relay/hot.sqlite', 'relay/quiet.sqlite')
SUFFIXES = ('', '-wal', '-shm')
BYTE_CAP = 64 * 2**20
JSON_CAP = 256 * 1024
ROW_CAP = 128
SMOKE = dict(writerCount=2, opsPerWriter=3, warmupPerWriter=1, quietOps=1,
             quietWarmupOps=1, payloadBytes=2048, driverWorkers=2,
             cadenceNS=40_000_000, staggerNS=5_000_000,
             quietCadenceNS=1_000_000_000, drainNS=20_000_000_000)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def checked_path(path, *, missing=False):
    """Reject symlinks at every existing component, not just the final file."""
    require(path.is_absolute() and '..' not in path.parts, 'noncanonical path')
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            if missing:
                return None
            raise
        require(not stat.S_ISLNK(info.st_mode), 'symlink rejected')
    require(path.resolve(strict=True) == path, 'noncanonical path')
    return info


def read_json(path):
    info = checked_path(path)
    require(stat.S_ISREG(info.st_mode) and info.st_size <= JSON_CAP, 'invalid JSON evidence file')
    with path.open('rb') as source:
        data = source.read(JSON_CAP + 1)
    require(len(data) <= JSON_CAP, 'JSON evidence cap exceeded')
    return json.loads(data), hashlib.sha256(data).hexdigest()


def validate_receipts(receipt, command):
    require(command.get('started') is True and type(command.get('exitCode')) is int,
            'SDK process was not started and reaped')
    cleanup = command.get('cleanup', {})
    require(cleanup.get('leaderReaped') is True and cleanup.get('groupGone') is True,
            'SDK process group absence not proved')
    require(receipt.get('schema') == 'lattice.sync-public-visibility/1'
            and receipt.get('mode') == 'smoke' and receipt.get('profile') == 'loaded',
            'only exact loaded smoke is admitted')
    require(receipt.get('effectiveParameters') == SMOKE, 'unexpected smoke parameters')
    require(all(type(value) is int for value in receipt['effectiveParameters'].values()),
            'smoke parameters must be integers')
    run = receipt.get('runID')
    require(isinstance(run, str) and str(uuid.UUID(run)).upper() == run, 'invalid run identity')
    expected = {}
    for stream, writers in [('hot', 2), ('quiet', 1)]:
        for writer in range(writers):
            for phase, count in [('warmup', 1), ('measured', 3 if stream == 'hot' else 1)]:
                for sequence in range(count):
                    key = f'{run}/{stream}/{phase}/{writer}/{sequence}'
                    expected[key] = (stream, phase, writer, sequence)
    rows = receipt.get('receipts', [])
    require(len(rows) == 10 and {row.get('id') for row in rows} == set(expected),
            'smoke must retain exactly ten unique operation receipts')
    for row in rows:
        stream, phase, writer, sequence = expected[row['id']]
        require((row.get('runID'), row.get('stream'), row.get('phase'), row.get('writer'), row.get('sequence'))
                == (run, stream, phase, writer, sequence), 'receipt identity mismatch')
        require(row.get('writerStoreID') == f'clients/{stream}-writer-{writer}.sqlite',
                'unexpected writer store')
        require(row.get('readerStoreID') in (None, f'clients/{stream}-watcher.sqlite'),
                'unexpected watcher store')
    return expected


def file_signature(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def inventory(fixture):
    rows, total = [], 0
    for store in STORES:
        require(checked_path(fixture / (store + '-journal'), missing=True) is None,
                'rollback journal is outside the admitted WAL fixture')
        for suffix in SUFFIXES:
            relative = store + suffix
            info = checked_path(fixture / relative, missing=True)
            if info is None:
                rows.append({'path': relative, 'present': False})
                continue
            require(stat.S_ISREG(info.st_mode), 'nonregular fixture file')
            total += info.st_size
            require(total <= BYTE_CAP, 'aggregate fixture byte cap exceeded')
            rows.append({'path': relative, 'present': True, 'bytes': info.st_size,
                         'signature': file_signature(info)})
    return rows, total


def copy_files(fixture, destination, rows):
    require(not destination.exists(), 'postmortem scratch must be new')
    destination.mkdir(mode=0o700)
    used = 0
    for row in rows:
        if not row['present']:
            continue
        source, target = fixture / row['path'], destination / row['path']
        checked_path(source)
        target.parent.mkdir(mode=0o700, exist_ok=True)
        hasher = hashlib.sha256()
        with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as handle:
            require(file_signature(os.fstat(handle.fileno())) == row['signature'], 'fixture changed before copy')
            with target.open('xb') as output:
                remaining = row['bytes']
                while remaining:
                    block = handle.read(min(remaining, 1024 * 1024))
                    require(bool(block), 'fixture shortened during copy')
                    used += len(block)
                    require(used <= BYTE_CAP, 'copy byte cap exceeded')
                    output.write(block); hasher.update(block); remaining -= len(block)
                require(not handle.read(1), 'fixture grew during copy')
            require(file_signature(os.fstat(handle.fileno())) == row['signature'], 'fixture changed during copy')
        row['sha256'] = hasher.hexdigest()
    return used


def inspect_copy(path, expected):
    # Imported only when a guarded hosted helper reaches this point. Unit tests
    # exercise admission/copy/report logic without importing or executing SQLite.
    import sqlite3
    deadline, ticks = time.monotonic() + 2, 0
    def progress():
        nonlocal ticks
        ticks += 1
        return int(ticks > 2000 or time.monotonic() > deadline)
    connection = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=0.1)
    try:
        # Do not use immutable=1: copied WAL contents are part of the snapshot.
        connection.execute('PRAGMA query_only=ON')
        connection.execute('PRAGMA trusted_schema=OFF')
        connection.set_progress_handler(progress, 1000)
        tables = {'SyncVisibilityObject', 'AuditLog', '_lattice_sync_state'}
        allowed = tables | {'sqlite_master', 'sqlite_schema'}
        functions = {'count', 'substr', 'length', 'json_valid', 'json_extract', 'typeof'}
        def authorize(action, first, second, database, trigger):
            if trigger is not None:
                return sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_SELECT:
                return sqlite3.SQLITE_OK
            if action == sqlite3.SQLITE_READ and first in allowed and database == 'main':
                return sqlite3.SQLITE_OK
            if action == sqlite3.SQLITE_FUNCTION and (second or '').lower() in functions:
                return sqlite3.SQLITE_OK
            return sqlite3.SQLITE_DENY
        connection.set_authorizer(authorize)
        def query(sql, params=()):
            cursor = connection.execute(sql, params)
            rows = cursor.fetchmany(ROW_CAP + 1)
            require(len(rows) <= ROW_CAP, 'query row cap exceeded')
            names = [column[0] for column in cursor.description]
            return [dict(zip(names, row)) for row in rows]
        present = set()
        for name in sorted(tables):
            schema = query('SELECT type, substr(sql,1,256) AS prefix FROM main.sqlite_master WHERE name=? LIMIT 2', (name,))
            if not schema:
                continue
            require(len(schema) == 1 and schema[0]['type'] == 'table'
                    and re.match(r'^\s*CREATE\s+TABLE\s', schema[0]['prefix'], re.I),
                    'only ordinary fixture tables are admitted')
            present.add(name)
        result = {'presentTables': sorted(present), 'modelRows': [], 'auditRows': [], 'syncStateRows': []}
        if 'SyncVisibilityObject' in present:
            result['modelCount'] = query('SELECT count(*) AS n FROM main.SyncVisibilityObject')[0]['n']
            result['modelRows'] = query('SELECT id AS localRowID, substr(globalId,1,128) AS globalID, '
                'length(globalId) AS globalIDLength, substr(operationID,1,128) AS operationID, '
                'length(operationID) AS operationIDLength FROM main.SyncVisibilityObject ORDER BY id LIMIT 129')
        if 'AuditLog' in present:
            result['auditCount'] = query("SELECT count(*) AS n FROM main.AuditLog WHERE tableName='SyncVisibilityObject'")[0]['n']
            result['auditRows'] = query("SELECT id AS auditEntryID, substr(globalId,1,128) AS auditGlobalID, "
                "length(globalId) AS auditGlobalIDLength, rowId AS localRowID, substr(globalRowId,1,128) AS globalRowID, "
                "length(globalRowId) AS globalRowIDLength, substr(operation,1,16) AS operation, "
                "isFromRemote, isSynchronized, CASE WHEN json_valid(changedFields) THEN "
                "substr(json_extract(changedFields,'$.operationID'),1,128) END AS operationID "
                "FROM main.AuditLog WHERE tableName='SyncVisibilityObject' ORDER BY id LIMIT 129")
        if '_lattice_sync_state' in present and 'AuditLog' in present:
            # Sync IDs may be endpoint/token-bearing strings; emit no sync_id.
            result['syncStateRows'] = query("SELECT s.audit_entry_id AS auditEntryID, "
                "s.is_synchronized AS synchronized, count(*) AS channelCount FROM main._lattice_sync_state s "
                "JOIN main.AuditLog a ON a.id=s.audit_entry_id WHERE a.tableName='SyncVisibilityObject' "
                "GROUP BY s.audit_entry_id,s.is_synchronized ORDER BY s.audit_entry_id LIMIT 129")
        for row in result['modelRows'] + result['auditRows']:
            require(all(value is None or type(value) is int for key, value in row.items()
                        if key.endswith('Length') or key in ('localRowID', 'auditEntryID', 'isFromRemote', 'isSynchronized')),
                    'unexpected noninteger identity or state field')
            value = row.get('operationID')
            row['knownOperation'] = isinstance(value, str) and value in expected
            if not row['knownOperation']:
                # No unexpected user payload is emitted as a purported ID.
                row['operationID'] = None
            for key in ('globalID', 'auditGlobalID', 'globalRowID'):
                if key in row and (not isinstance(row[key], str) or not re.fullmatch(
                        r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', row[key])):
                    row[key] = None
                    row[key + 'Invalid'] = True
            if 'operation' in row and row['operation'] not in ('INSERT', 'UPDATE', 'DELETE'):
                row['operation'] = None
        return result
    finally:
        connection.close()


def collect(root):
    checked_path(root)
    allowed = Path.home() / 'localdev'
    checked_path(allowed)
    require(root != allowed and root.is_relative_to(allowed), 'root must be below HOME/localdev')
    fixture, receipts = root / 'visibility-smoke', root / 'receipts'
    checked_path(fixture); checked_path(receipts)
    receipt, receipt_sha = read_json(fixture / 'receipts.json')
    command, command_sha = read_json(receipts / 'sdk-probe-fixtures.json')
    expected = validate_receipts(receipt, command)
    rows, total = inventory(fixture)
    scratch = root / 'visibility-postmortem-copies'
    copied = copy_files(fixture, scratch, rows)
    report = {'schema': 'lattice.sync-visibility-postmortem/1', 'runID': receipt['runID'],
              'diagnosticOnly': True, 'frozenMeasurementComplete': receipt.get('complete'),
              'receiptSHA256': receipt_sha, 'sdkCommandSHA256': command_sha,
              'processExit': command['cleanup'], 'inputBytes': total, 'copiedBytes': copied,
              'byteCap': BYTE_CAP, 'rowCap': ROW_CAP, 'stores': [], 'files': rows,
              'limitations': ['Final copied state is not a delivery timeline or callback trace.',
                  'Absent audit rows may reflect retention; absence does not prove no delivery.',
                  'No row or audit payload strings, sync IDs, or arbitrary schema SQL are emitted.',
                  'Read-only SQLite may update copied SHM; originals are never opened by SQLite.',
                  'No repair, recorder input, benchmark acceptance or performance result.']}
    for store in STORES:
        entry = {'store': store, 'present': (scratch / store).is_file()}
        if entry['present']:
            try:
                entry.update(inspect_copy(scratch / store, expected))
            except Exception as error:
                # Error strings can contain schema/payload text; keep only type.
                entry['inspectionErrorType'] = type(error).__name__
        report['stores'].append(entry)
    # Join only emitted identities, never raw payloads. A row's current local ID
    # and its audit rowId can differ; retain both instead of assuming equality.
    report['operationAssociations'] = []
    for operation in sorted(expected):
        global_ids = set()
        for store in report['stores']:
            global_ids.update(row['globalID'].lower() for row in store.get('modelRows', [])
                              if row['operationID'] == operation and row['globalID'])
            global_ids.update(row['globalRowID'].lower() for row in store.get('auditRows', [])
                              if row['operationID'] == operation and row['globalRowID'])
        associations = []
        for store in report['stores']:
            if not {'SyncVisibilityObject', 'AuditLog'}.issubset(store.get('presentTables', [])):
                associations.append({'store': store['store'], 'available': False})
                continue
            models = [row for row in store['modelRows'] if row['operationID'] == operation]
            audits = [row for row in store['auditRows'] if row['operationID'] == operation
                      or (row['globalRowID'] and row['globalRowID'].lower() in global_ids)]
            associations.append({'store': store['store'], 'available': True,
                                 'modelCount': len(models), 'associatedAuditCount': len(audits),
                                 'modelLocalRowIDs': [row['localRowID'] for row in models],
                                 'auditEntryIDs': [row['auditEntryID'] for row in audits],
                                 'auditLocalRowIDs': [row['localRowID'] for row in audits]})
        report['operationAssociations'].append({'operationID': operation, 'globalIDs': sorted(global_ids),
                                                'stores': associations})
    for row in rows:
        if row['present']:
            require(file_signature(checked_path(fixture / row['path'])) == row['signature'],
                    'original changed during postmortem')
            del row['signature']
    require(read_json(fixture / 'receipts.json')[1] == receipt_sha, 'frozen receipt changed')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    report = collect(args.root)
    output = args.root / 'receipts/sync-visibility-postmortem.json'
    encoded = json.dumps(report, indent=2, sort_keys=True) + '\n'
    require(len(encoded.encode()) <= 2**20, 'postmortem report byte cap exceeded')
    with output.open('x') as handle:
        handle.write(encoded)
    print('Postmortem copied-store evidence written; frozen visibility verdict unchanged.')


if __name__ == '__main__':
    main()
