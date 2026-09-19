"""Bound the existing Swift Testing declarations, arguments and XML, without editing tests."""
from collections import Counter
import json
import re
import xml.etree.ElementTree as ET

def discovery(log, expected):
    text = log.read_text()
    selected = [x for x in text.splitlines() if x.startswith('LatticeTests.OwnedPageReadTests/')]
    names = [re.fullmatch(r'LatticeTests\.OwnedPageReadTests/(\w+)\([^)]*\)(?:/.*)?', x) for x in selected]
    assert all(names) and len(selected) == len(set(selected)) == 12
    assert sorted(x.group(1) for x in names) == sorted(expected['declarations'])
    return selected

def analyze(log, xml, expected):
    assert log.stat().st_size < 16 * 2**20 and xml.stat().st_size < 4 * 2**20
    text = log.read_text()
    assert not re.search(r'recorded an issue|failed after|skipped|No matching test cases', text, re.I)
    document = ET.parse(xml).getroot()
    assert not any(list(document.iter(x)) for x in ('failure','error','skipped'))
    rows = list(document.iter('testcase')); counts = Counter()
    for row in rows:
        assert row.attrib['classname'] == 'LatticeTests.OwnedPageReadTests'
        match = re.fullmatch(r'(\w+)\([^\n]*\)(?:\s*\[[^\n]*\])?', row.attrib['name'])
        assert match and match.group(1) in expected['declarations']
        counts[match.group(1)] += 1
    declarations = Counter({x:1 for x in expected['declarations']})
    invocations = declarations.copy()
    for name, values in expected['parameterized'].items(): invocations[name] = len(values)
    # Some Swift Testing reporters aggregate a parameterized function in XML.
    # Both forms still require the full distinct argument and successful function evidence below.
    assert counts in (declarations, invocations), 'unknown/incomplete XML shape'
    for suite in document.iter('testsuite'):
        assert int(suite.attrib['tests']) == len(list(suite.iter('testcase')))
        assert all(int(suite.attrib.get(k,'0')) == 0 for k in ('errors','failures','skipped'))
    passed = re.findall(r'(?m)^.*?Test (\w+)\([^\n]*?\) passed after ', text)
    assert Counter(passed) == declarations, 'all twelve declarations must complete exactly once'
    argument_rows = re.findall(r'Test case passing 1 argument (\w+) → (\S+) to (\w+)\(_:\) started\.', text)
    wanted = [('status', str(x), 'nativeFailuresRemainDistinctWithoutAdvancingInput') for x in range(4,18)]
    wanted += [('cleanupFails',str(x).lower(),'runningDeadlineWaitsForCleanupAndDiscardsLateSuccess') for x in (False,True)]
    assert Counter(argument_rows) == Counter(wanted), 'exact sixteen parameterized invocations required'
    summaries = re.findall(r'Test run with (\d+) tests? in (\d+) suites? passed', text)
    assert len(summaries)==1 and int(summaries[0][0]) in (12,26) and summaries[0][1]=='1'
    return {'declarations':12,'invocations':26,'parameterizedInvocations':argument_rows,
            'xmlCaseCount':len(rows),'reportedSummaryTests':int(summaries[0][0]),'failures':0,'skips':0}
