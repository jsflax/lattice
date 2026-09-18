"""Strict control and framework gates; a crash never becomes SDK success."""
import re
import signal
import xml.etree.ElementTree as ET


def clean(record, expected=0):
    assert record['started'] and record['exitCode'] == expected
    assert record['success'] is (expected == 0)
    assert not record.get('primaryError') and not record.get('evidenceErrors')
    assert not record.get('stopReason') and not record.get('receivedSignals')
    cleanup = record['cleanup']
    assert cleanup['leaderReaped'] and cleanup['groupGone']
    assert not cleanup.get('errors') and not cleanup.get('signals')


def control(record, log):
    clean(record, -signal.SIGSEGV)
    assert re.search(r'(?:Signal 11|signal 11|SIGSEGV|Segmentation fault)', log)
    assert re.search(r'^\s*(?:\d+\s+|\*\s*frame #\d+:).*latticeSDK46DiagnosticCrashControl', log, re.M)
    assert re.search(r'(?:Thread \d+ crashed|Backtrace|backtrace|frame #\d+)', log)
    assert not re.search(r'(?:Press (?:enter|return)|interactive prompt|unsupported option|unknown option)', log, re.I)
    return {'expectedSignal': 'SIGSEGV', 'namedControlFrame': True,
            'noninteractiveWithinTenSeconds': True, 'completeGroupCleanup': True}


def discovery(text, expected):
    actual = [line.strip() for line in text.splitlines()
              if line.strip().startswith('LatticeTests.') and any(
                  marker in line for marker in ('ProjectionMemoryConsumerExecutorTests/',
                  'ProjectionMemoryTests/pausedBatchConsumerKeepsSnapshotWhileLiveWriterChanges('))]
    assert sorted(actual) == sorted(expected), ('focused discovery mismatch', actual)
    assert len(actual) == len(set(actual)) == 4
    return actual


def focused(record, xml, log, expected):
    clean(record)
    root = ET.fromstring(xml)
    assert root.tag in ('testsuites', 'testsuite')
    assert not list(root.iter('failure')) and not list(root.iter('error')) and not list(root.iter('skipped'))
    cases = list(root.iter('testcase')); assert len(cases) == 4
    actual = []
    for case in cases:
        classname = case.attrib['classname']
        name = case.attrib['name'].removesuffix('()')
        matches = [item for item in expected if item.endswith('/' + name + '()')
                   and item.split('/')[0].split('.')[-1] in classname.split('.')]
        assert len(matches) == 1
        actual.append(matches[0])
    assert sorted(actual) == sorted(expected) and len(set(actual)) == 4
    assert re.search(r'Test run with 4 tests (?:in \d+ suites? )?passed', log)
    assert not re.search(r'recorded an issue|unexpected signal|Test run.*failed', log)
    return {'executed': 4, 'failed': 0, 'skipped': 0, 'identifiers': actual}


def full(record, log):
    clean(record)
    summaries = re.findall(r'Test run with (\d+) tests(?: in (\d+) suites?)? passed', log)
    assert len(summaries) == 1 and int(summaries[0][0]) > 4
    assert not re.search(r'recorded an issue|unexpected signal|Test run.*failed', log)
    return {'reportedTests': int(summaries[0][0]),
            'reportedSuites': int(summaries[0][1]) if summaries[0][1] else None,
            'scope': 'unchanged full selection/concurrency; framework total may include skips'}
