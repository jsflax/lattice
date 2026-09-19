"""Unchanged nine-case runtime/postimage oracles from preserved failed001."""
from contextlib import closing
import hashlib
import json
import sqlite3
from urllib.parse import quote
H = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def analyze_runtime(log, config):
    records = [json.loads(line.removeprefix('DURABLE_RUNTIME ')) for line in log.read_text().splitlines()
               if line.startswith('DURABLE_RUNTIME ')]
    assert [x['case'] for x in records] == config['expectedCases'], 'exact nine ordered cases required'
    assert all(x['passed'] is True for x in records)
    assert len({x['case'] for x in records}) == 9
    for index in [0, 3, 6, 8]:
        facts = records[index]['facts']['raw'] if index == 8 else records[index]['facts']
        assert facts['snapshot'][0] == facts['frame'][2]
        assert facts['auditIDs'] == [facts['frame'][1], facts['frame'][2]]
        assert len(facts['text']) == len(facts['integers']) == 2
        token = bytes(facts['cursorBytes']).decode('ascii')
        assert len(token) == 139 and token.startswith('lrc1:f:')
        assert token[7:39] == bytes(facts['snapshotIdentities'][0]).decode('ascii')
        assert token[40:72] == bytes(facts['snapshotIdentities'][1]).decode('ascii')
        assert token[73:105] == bytes(facts['frameKey']).decode('ascii')
        assert int(token[106:122], 16) == facts['frame'][0]
        assert int(token[123:139], 16) == facts['frame'][2]
        for row, operation in zip(facts['text'], ['INSERT', 'UPDATE']):
            assert len(row) == 5 and row[1]['bytes'] == list(b'OwnedModel')
            assert row[2]['bytes'] == list(operation.encode())
        assert facts['backingBytes'] > facts['arenaBytes'] >= 0
    final = records[5]['facts']
    expected = {'failures': 0, 'realReads': 2, 'captures': 3, 'commits': 4,
                'writerCountersPreserved': 2, 'ownerCloses': 3, 'ownerDestructions': 3,
                'checkpointBusy': 0, 'checkpointLog': 0, 'checkpointDone': 0,
                'preCancelReads': 1, 'preCancelStatus': 12,
                'preCancelCleanup': True, 'preCancelFileAbsent': True}
    assert final == expected
    assert records[1]['facts'] == {'expired': True}
    edge = {'failures': 0, 'owners': 1, 'captures': 1, 'oracleReads': 1, 'commits': 2,
            'closes': 1, 'removedFiles': 0, 'checkpointBusy': 0, 'checkpointLog': 0, 'checkpointDone': 0}
    assert records[6]['facts']['edgeCounters'] == edge and records[6]['facts']['ownerExpired'] is True
    assert records[7]['facts'] == {'ownerExpired': True, 'backingExpired': True}
    edge.update(owners=2, captures=2, oracleReads=2, commits=4, closes=2, removedFiles=1)
    facts = records[8]['facts']
    assert facts['edgeCounters'] == edge
    assert facts['statuses'] == [3, 1, 2, 0, 1, 12]
    assert facts['closedError'] == 'observation owner closed' and facts['independentCancelled'] is False
    assert facts['ownerExpired'] is True and facts['backingExpired'] is True
    return records

def physical_postimages(root, records):
    result = {}
    for name, index in [('original.sqlite', 0), ('independent.sqlite', 3), ('edge.sqlite', 6)]:
        path = root / name
        assert path.is_file() and not path.is_symlink()
        wal = root / (name + '-wal')
        assert not wal.exists() or wal.stat().st_size == 0
        digest = H(path)
        with closing(sqlite3.connect('file:' + quote(str(path)) + '?mode=ro&immutable=1', uri=True)) as db:
            rows = db.execute('SELECT id,value FROM OwnedModel ORDER BY id').fetchall()
            audit = db.execute("SELECT id,tableName,operation,rowId FROM AuditLog WHERE tableName='OwnedModel' ORDER BY id").fetchall()
            frames = db.execute('SELECT count(*) FROM _lattice_observation_frames').fetchone()[0]
        assert len(rows) == 1 and rows[0][1] == 12
        assert len(audit) == 3 and [x[2] for x in audit] == ['INSERT', 'UPDATE', 'UPDATE']
        assert all(x[1] == 'OwnedModel' and x[3] == rows[0][0] for x in audit)
        assert [x[0] for x in audit[:2]] == records[index]['facts']['auditIDs'] and frames == 2
        assert H(path) == digest
        result[name] = {'sha256': digest, 'modelRows': rows, 'auditRows': audit, 'frames': frames,
                        'walBytes': wal.stat().st_size if wal.exists() else 0}
    assert all(not (root / (name + suffix)).exists() for name in ['cancelled.sqlite', 'edge-stop.sqlite'] for suffix in ['', '-wal', '-shm'])
    return result
