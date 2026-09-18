"""Exact four-case prerequisite classifier. No expected failure or skip admission."""
import re
import xml.etree.ElementTree as ET


def identifiers(expected):
    names = expected['caseIdentifiers']
    assert len(names) == len(set(names)) == expected['tests'] == 4
    assert len({name.split('/')[0] for name in names}) == expected['suites'] == 3
    assert expected['skipsAccepted'] is False
    assert all(re.fullmatch(r'LatticeTests\.[A-Za-z0-9_]+/[A-Za-z0-9_]+\(\)', name) for name in names)
    assert expected['caseNames'] == [name.split('/')[1][:-2] for name in names]
    pattern = re.compile(expected['filter'])
    assert all(pattern.fullmatch(name) for name in names)
    return names, pattern


def discover(text, expected):
    names, pattern = identifiers(expected)
    selected = [line.strip() for line in text.splitlines() if pattern.fullmatch(line.strip())]
    assert len(selected) == len(set(selected)) == 4
    assert sorted(selected) == sorted(names)
    return selected


def framework(xml, log, expected):
    names, _ = identifiers(expected)
    root = ET.fromstring(xml)
    assert root.tag in ('testsuites', 'testsuite')
    assert not list(root.iter('skipped')) and not list(root.iter('error')) and not list(root.iter('failure'))
    cases = list(root.iter('testcase'))
    actual = [case.attrib['classname'] + '/' + case.attrib['name'] for case in cases]
    assert len(actual) == len(set(actual)) == 4 and sorted(actual) == sorted(names)
    for suite in root.iter('testsuite'):
        for field in ('errors', 'failures', 'skipped'):
            if field in suite.attrib: assert int(suite.attrib[field]) == 0
    assert not re.search(r'\bskipped\b|unexpected signal|Exited with unexpected|recorded an issue|^✘', log, re.M)
    summary = re.findall(r'^✔ Test run with (\d+) tests(?: in (\d+) suites?)? passed after [\d.]+ seconds\.$', log, re.M)
    assert summary == [('4', '3')]
    starts = re.findall(r'^◇ Test ([A-Za-z0-9_]+)\(\) started\.$', log, re.M)
    passes = re.findall(r'^✔ Test ([A-Za-z0-9_]+)\(\) passed after [\d.]+ seconds\.$', log, re.M)
    assert len(starts) == len(passes) == 4
    assert sorted(starts) == sorted(passes) == sorted(expected['caseNames'])
    return {'executed': 4, 'passed': actual, 'failed': [], 'issues': 0, 'skipped': 0}
