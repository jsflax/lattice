"""Receipt checks for unchanged published JS lifecycle and TypeScript oracles."""
from collections import Counter


def validate_native(receipt, expected, assets):
    if receipt.get('passed') is not True or receipt.get('failure') is not None:
        raise ValueError('Native lifecycle suite did not pass')
    if receipt.get('asyncErrors') != [] or receipt.get('fatalLogs') != []:
        raise ValueError('Native lifecycle asynchronous failure')
    tests = receipt.get('tests', [])
    if [row.get('name') for row in tests] != expected['caseNames'] or len(tests) != 16:
        raise ValueError('Native lifecycle case inventory changed')
    zero = dict.fromkeys(['nativeOwners', 'retainedHandles', 'schedulers', 'pendingCallbacks', 'nativeDatabases'], 0)
    if receipt.get('baseline') != zero or receipt.get('final') != zero:
        raise ValueError('Native lifecycle final resources did not return to zero')
    if any(row.get('passed') is not True or row.get('before') != zero or row.get('after') != zero for row in tests):
        raise ValueError('Native lifecycle case or per-case resource cleanup failed')
    source = receipt.get('receipt', {})
    if source.get('harness', {}).get('sha256') != expected['harnessSHA256'] or source.get('node') != 'v' + expected['nodeVersion']:
        raise ValueError('Native lifecycle harness or Node identity mismatch')
    for kind in ['js', 'wasm']:
        for field in ['sha256', 'bytes']:
            if source.get(kind, {}).get(field) != assets['lattice.' + kind][field]:
                raise ValueError('Native lifecycle consumed different assets: ' + kind)
    scope = receipt.get('scope', {})
    if not all(scope.get(key) is True for key in ['actualRebuiltWasm', 'actualSQLite', 'actualBindings', 'fixtureWebSocketOnly']):
        raise ValueError('Native lifecycle runtime scope missing')
    if any(scope.get(key) is not False for key in ['realBrowser', 'liveNetwork', 'remoteSync', 'opfs', 'fullMatrix', 'performanceComparison', 'releaseQualification']):
        raise ValueError('Native fixture overclaims compatibility scope')
    if receipt.get('fixture', {}).get('remainingHandles') != 0:
        raise ValueError('Native lifecycle handles remain')
    return {'passed': 16, 'failed': 0, 'allResourceCountersZero': True,
            'harnessSHA256': expected['harnessSHA256'], 'fixtureWebSocketOnly': True}


def validate_typescript(report, expected):
    cases = [case for suite in report.get('testResults', []) for case in suite.get('assertionResults', [])]
    counts = dict(Counter(case.get('status') for case in cases))
    if report.get('success') is not True or counts != expected['counts']:
        raise ValueError('Published JS TypeScript counts changed or failed')
    skipped = sorted((row.get('fullName') or row.get('title') or '').strip()
                     for row in cases if row.get('status') != 'passed')
    if skipped != sorted(expected['skippedNames']):
        raise ValueError('Published JS skipped-case inventory changed')
    return {'counts': counts, 'skippedNames': skipped, 'allNamedCasesPassed': False,
            'note': 'Six existing browser-required skips remain skips; they are not native passes.'}
