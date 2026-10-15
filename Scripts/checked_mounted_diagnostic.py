"""Strict bounded DATA parser for one original checked-mounted test; no success grant."""
import json
import re
from pathlib import Path

PREFIX = 'LATTICE_CHECKED_MOUNTED_PHASE '
PHASES = ('aftercreate', 'childinit', 'childadd', 'parentinit', 'parentadd', 'close')
TEST = 'fullLinkedExistingCatalogAndRowsSurviveRepeatedCheckedOpen'
FORMAT = 'lattice-checked-mounted-seed/1'
REASONS = {'sqlite_module_unavailable', 'sqlite_open', 'cookie_prepare', 'cookie_result',
           'markers_prepare', 'markers_result', 'sqlite_close', 'observed'}
MAX_LOG = 512 * 2**20  # Same existing command-log ceiling; no workload/clock change.
MAX_LINE = 65536


def require(value):
    if not value:
        raise ValueError('checked_mounted_diagnostic_invalid')


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def integer(value, maximum=2147483647):
    return type(value) is int and 0 <= value <= maximum


def validate(row, phase, system):
    require(type(row) is dict and row.get('format') == FORMAT and row.get('phase') == phase
            and type(row.get('available')) is bool and type(row.get('reason')) is str and row['reason'] in REASONS)
    base = {'format', 'phase', 'available', 'reason'}
    if row['reason'] == 'sqlite_module_unavailable':
        require(set(row) == base and row['available'] is False)
        return
    require(system == 'Darwin')
    require(base | {'sqliteCode'} <= set(row) <= base | {'sqliteCode', 'closeCode', 'finalizeCode', 'cookie', 'markers'})
    require(all(integer(row[key]) for key in ('sqliteCode', 'closeCode', 'finalizeCode') if key in row))
    if not row['available']:
        require(row['reason'] != 'observed' and 'cookie' not in row and 'markers' not in row)
        return
    require(set(row) == base | {'sqliteCode', 'closeCode', 'cookie', 'markers'}
            and row['reason'] == 'observed' and row['sqliteCode'] == row['closeCode'] == 0
            and integer(row['cookie']) and type(row['markers']) is list and len(row['markers']) <= 32)
    keys = []
    for marker in row['markers']:
        require(type(marker) is dict and set(marker) == {'key', 'value'}
                and type(marker['key']) is str and re.fullmatch(r'schema_fingerprint:[0-9a-f]{16}', marker['key'])
                and type(marker['value']) is str and re.fullmatch(r'0|[1-9][0-9]{0,9}', marker['value'])
                and int(marker['value']) <= 2147483647)
        keys.append(marker['key'])
    require(keys == sorted(set(keys)))


def parse(path, system, *, test_passed):
    require(type(test_passed) is bool and system in ('Darwin', 'Linux'))
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_LOG)
    rows = []
    starts = passes = failures = summaries = 0
    consumed = 0
    with path.open('rb') as source:
        while True:
            raw = source.readline(MAX_LINE + 1)
            if not raw:
                break
            consumed += len(raw)
            require(consumed <= MAX_LOG and len(raw) <= MAX_LINE)
            # Swift stdout is UTF-8. No replacement text can masquerade as an event.
            line = raw.decode('utf-8').strip()
            if line.startswith(PREFIX):
                require(len(raw) <= 8192 and len(rows) < len(PHASES))
                row = json.loads(line[len(PREFIX):], object_pairs_hook=unique,
                                 parse_constant=lambda _: require(False))
                validate(row, PHASES[len(rows)], system)
                rows.append(row)
            starts += line == f'◇ Test {TEST}() started.'
            passes += bool(re.fullmatch(r'✔ Test ' + TEST + r'\(\) passed after [0-9]+\.[0-9]+ seconds\.', line))
            failures += bool(re.fullmatch(r'✘ Test ' + TEST + r'\(\) failed after [0-9]+\.[0-9]+ seconds with [1-9][0-9]* issues?\.', line))
            if re.match(r'[✔✘] Test run with ', line):
                require(re.fullmatch(r'[✔✘] Test run with 1 test(?: in [1-9][0-9]* suites?)? (?:passed|failed) after [0-9]+\.[0-9]+ seconds(?: with [1-9][0-9]* issues?)?\.', line))
                require((' passed after ' in line) == test_passed)
                summaries += 1
    require(len(rows) == len(PHASES) and starts == summaries == 1
            and passes == int(test_passed) and failures == int(not test_passed))
    return {'format': 'lattice-checked-mounted-phase-observations/1', 'system': system,
            'selectedTest': TEST, 'actualCommandPassed': test_passed, 'phases': rows,
            'allSQLiteObservationsAvailable': all(row['available'] for row in rows),
            'scope': 'bounded read-only seed DATA only; no full-suite, performance or release acceptance'}
