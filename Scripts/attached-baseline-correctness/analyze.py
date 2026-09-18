"""Fixed two-case attached correctness oracle; no timing/performance acceptance."""
from pathlib import Path
import hashlib
import json
import re
import sqlite3
import xml.etree.ElementTree as ET

DISPLAY = 'attachedDisplayWarmIdentityAndRoutedWrites'
PRIME = 'originalPerRowPrimingRemainsOneStatement'
NAMES = [DISPLAY, PRIME]
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def command(record, exit_code=0):
    assert record['started'] and record['exitCode'] == exit_code
    assert record['success'] is (exit_code == 0)
    assert not record.get('primaryError') and not record.get('evidenceErrors')
    assert not record.get('receivedSignals') and not record.get('stopReason')
    assert record['cleanup']['leaderReaped'] and record['cleanup']['groupGone']
    assert not record['cleanup'].get('signals') and not record['cleanup'].get('errors')

def discover(text, expected):
    selected = [line.strip() for line in text.splitlines()
        if 'AttachedBaselineCorrectnessTests/' in line]
    assert sorted(selected) == sorted(expected['caseIdentifiers'])
    assert len(selected) == len(set(selected)) == 2
    return selected

def framework(xml, log, arm):
    root = ET.fromstring(xml)
    assert root.tag in ('testsuite', 'testsuites')
    assert not list(root.iter('skipped')) and not list(root.iter('error'))
    cases = list(root.iter('testcase'))
    assert len(cases) == 2
    actual = {}; issues = []
    for case in cases:
        name = case.attrib['name'].removesuffix('()')
        assert name in NAMES and name not in actual
        assert 'AttachedBaselineCorrectnessTests' in case.attrib.get('classname', '')
        assert not list(case.iter('skipped')) and not list(case.iter('error'))
        failures = list(case.iter('failure'))
        actual[name] = not failures
        issues.extend((name, ET.tostring(failure, encoding='unicode')) for failure in failures)
    assert set(actual) == set(NAMES)
    assert len(list(root.iter('failure'))) == len(issues)
    assert not re.search(r'\bskipped\b|unexpected signal|Exited with unexpected', log)
    if arm == 'original':
        assert actual == {DISPLAY: False, PRIME: True}
        assert len(issues) == 1 and issues[0][0] == DISPLAY
        assert 'ATTACHED_DISPLAY_ORACLE' in issues[0][1]
        assert len(re.findall(r'recorded an issue', log)) == 1
        assert re.search(r'Test run with 2 tests (?:in 1 suite )?failed .* with 1 issue\.', log)
    else:
        assert arm == 'corrected' and all(actual.values()) and not issues
        assert not re.search(r'recorded an issue|Test run.*failed', log)
        assert re.search(r'Test run with 2 tests (?:in 1 suite )?passed', log)
    return {'executed': 2, 'passed': [n for n in NAMES if actual[n]],
        'failed': [n for n in NAMES if not actual[n]], 'issues': len(issues), 'skipped': 0}

def values(rank):
    return {'rank': rank, 'title': f'memory-{rank:05d}', 'body': chr(97 + rank % 26) * 256,
        'accessCount': rank % 17, 'lastAccessedSeconds': 1_700_000_000 + rank,
        'pinned': rank % 3 == 0}

def uuid(rank):
    return f'00000000-0000-4000-8000-{rank + 1:012x}'

def case_receipts(root, arm):
    found = {p.name for p in root.iterdir()}
    assert found == set(NAMES), 'unexpected/missing case fixture'
    result = {}
    for name in NAMES:
        file = root / name / 'RESULT.json'
        assert file.stat().st_size <= 128 * 1024
        evidence = json.loads(file.read_text())
        assert evidence['caseName'] == name
        assert evidence['counts']['physicalRowsPerStore'] == 5000
        for physical in ('main', 'attached'):
            master = 'master-' + physical + '.sqlite'; copy = physical + '.sqlite'
            assert digest(root / name / master) == evidence['files'][master] == evidence['files'][copy]
        result[name] = evidence
    prime = result[PRIME]
    assert prime['complete'] and prime['phase'] == 'complete' and not prime.get('failure')
    assert prime['sql']['rawCollection'] == 1 and prime['sql']['priming100'] == 100
    assert prime['sql']['sixLiveFields'] == 600 and prime['counts']['primedRows'] == 100
    display = result[DISPLAY]
    if arm == 'original':
        assert not display['complete'] and display['phase'] == 'display_oracle'
        assert display['failure'] == 'invariant("ATTACHED_DISPLAY_ORACLE")'
        ranks = [rank - rank % 2 for rank in range(4000, 4100)]
        assert display['counts']['distinctObjects'] == 50
    else:
        assert display['complete'] and display['phase'] == 'complete' and not display.get('failure')
        ranks = list(range(4000, 4100))
        assert display['counts']['distinctObjects'] == 100
        assert display['sql']['warmLookup'] == 0 and display['sql']['warmSixLiveFields'] == 600
    assert display['returned'] == [values(rank) for rank in ranks]
    assert display['returnedUUIDs'] == [uuid(rank) for rank in ranks]
    assert display['localIDs'] == [rank // 2 + 1 for rank in range(4000, 4100)]
    assert display['counts']['distinctLocalIDs'] == 50
    assert display['counts']['coldOffsetFills'] == 1 and display['counts']['coldKeysetFills'] == 0
    assert display['counts']['coldAnchors'] <= 1 and display['sql']['sixLiveFields'] == 600
    return result

def physical_postimages(root, arm):
    # Called only after a clean native process exit and whole-group absence.
    # No URI immutable shortcut for potentially WAL-backed live copies.
    checked = 0
    for name in NAMES:
        for master in (True, False):
            for parity, physical in enumerate(('main', 'attached')):
                path = root / name / (('master-' if master else '') + physical + '.sqlite')
                db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=0)
                try:
                    rows = db.execute('SELECT id,globalId,rank,title,body,accessCount,lastAccessed,pinned FROM PerfRefinementMemory ORDER BY rank').fetchall()
                finally: db.close()
                assert len(rows) == 5000
                for index, row in enumerate(rows):
                    rank = index * 2 + parity; v = values(rank)
                    if arm == 'corrected' and name == DISPLAY and not master:
                        if rank in (4000, 4001):
                            v['accessCount'] += 1
                            v['lastAccessedSeconds'] = 1_800_000_000 + rank - 4000
                        if rank == 4001: v['title'] = 'outside-owner-04001'
                    normalized = (row[0], row[1].lower(), *row[2:])
                    assert normalized == (index + 1, uuid(rank), rank, v['title'], v['body'],
                        v['accessCount'], v['lastAccessedSeconds'], int(v['pinned'])), (name, master, parity, rank)
                    checked += 1
    return {'independentReadRows': checked, 'freshReadOnlyConnections': 8,
        'afterNativeGroupGone': True, 'pythonSQLiteVersion': sqlite3.sqlite_version}
