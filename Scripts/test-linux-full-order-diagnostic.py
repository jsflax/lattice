"""Pure full-census/event/XML checks. No child process, procfs or native execution."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('full_diagnostic',Path(__file__).with_name('run-linux-full-order-diagnostic.py'))
control = importlib.util.module_from_spec(spec);spec.loader.exec_module(control)


def fixture(two_parameter_functions=False):
    suite='Module.Suite'; keys=[suite+'/ordinary()',suite+'/parameter(value:)',suite+'/existingSkip()']
    identifiers={key:key+'/Fixture.swift:1:1' for key in keys}
    params={keys[1]:['0','1']}
    if two_parameter_functions: params[keys[0]]=['0','1']
    census={'functionCount':3,'executingFunctionCount':2,'suiteCount':1,
            'functionLabels':['ordinary()','parameter(value:)','existingSkip()'],
            'inheritedSkipKeys':[keys[2]],'parameterCases':params,'parameterCaseCount':sum(map(len,params.values()))}
    rows=[{'version':0,'kind':'test','payload':{'id':suite,'kind':'suite','name':'Suite'}}]
    rows += [{'version':0,'kind':'test','payload':{'id':identifiers[key],'kind':'function','name':key.split('/')[1]}} for key in keys]
    def event(kind,identifier=None,case=None):
        payload={'kind':kind}
        if identifier:payload['testID']=identifier
        if case is not None:payload['_testCase']={'id':'argument-'+case,'displayName':case}
        rows.append({'version':0,'kind':'event','payload':payload})
    event('runStarted');event('testStarted',suite);event('testSkipped',identifiers[keys[2]])
    for key in keys[:2]:
        event('testStarted',identifiers[key])
        for argument in params.get(key,[]):
            event('testCaseStarted',identifiers[key],argument);event('testCaseEnded',identifiers[key],argument)
        event('testEnded',identifiers[key])
    event('testEnded',suite);event('runEnded')
    return rows,census


class FullOrderTests(unittest.TestCase):
    def test_complete_serial_functions_skips_and_cases_reconcile(self):
        rows,census=fixture(); result=control.qualify_native_events(rows,census)
        self.assertEqual(len(result['functionKeys']),3)
        self.assertEqual(result['parameterCases'],2)
        self.assertEqual(result['skips'],set(census['inheritedSkipKeys']))

    def test_argument_identity_is_scoped_to_function(self):
        rows,census=fixture(two_parameter_functions=True)
        self.assertEqual(control.qualify_native_events(rows,census)['parameterCases'],4)

    def test_new_skip_is_not_waived(self):
        rows,census=fixture()
        for row in rows:
            p=row['payload']
            if p.get('kind')=='testStarted' and '/ordinary()/' in p.get('testID',''):
                p['kind']='testSkipped';break
        with self.assertRaises(AssertionError):control.qualify_native_events(rows,census)

    def test_missing_inherited_skip_is_incomplete(self):
        rows,census=fixture();rows=[r for r in rows if r['payload']['kind']!='testSkipped']
        with self.assertRaises(AssertionError):control.qualify_native_events(rows,census)

    def test_repeated_argument_cannot_replace_missing_argument(self):
        rows,census=fixture()
        for row in rows:
            case=row['payload'].get('_testCase')
            if case and case['displayName']=='1':case.update(id='argument-0',displayName='0')
        with self.assertRaises(AssertionError):control.qualify_native_events(rows,census)

    def test_case_end_must_match_original_case_identity(self):
        rows,census=fixture()
        next(r['payload']['_testCase'] for r in rows if r['payload']['kind']=='testCaseEnded')['id']='different-argument'
        with self.assertRaises(AssertionError):control.qualify_native_events(rows,census)

    def test_complete_cases_without_run_end_cannot_pass(self):
        rows,census=fixture()
        with self.assertRaises(AssertionError):control.qualify_native_events(rows[:-1],census)

    def test_overlapping_function_cannot_claim_serial_order(self):
        rows,census=fixture()
        index=next(i for i,r in enumerate(rows) if r['payload']['kind']=='testStarted' and '/parameter(' in r['payload'].get('testID',''))
        row=rows.pop(index);rows.insert(index-1,row)
        with self.assertRaises(AssertionError):control.qualify_native_events(rows,census)

    def test_issue_event_cannot_be_hidden_by_later_completion(self):
        rows,census=fixture();rows.insert(-1,{'version':0,'kind':'event','payload':{'kind':'issueRecorded'}})
        with self.assertRaises(AssertionError):control.qualify_native_events(rows,census)

    def test_same_count_but_changed_function_label_cannot_pass(self):
        rows,census=fixture();rows[1]['payload']['name']='replacement()'
        with self.assertRaises(AssertionError):control.qualify_native_events(rows,census)

    def test_xml_function_rows_and_exact_skip_set_are_independent(self):
        rows,census=fixture();native=control.qualify_native_events(rows,census)
        tree=ET.Element('testsuites');suite=ET.SubElement(tree,'testsuite',tests='2',skipped='1',errors='0',failures='0')
        for key in sorted(native['functionKeys']):
            classname,name=key.split('/')
            case=ET.SubElement(suite,'testcase',classname=classname,name=name)
            if key in native['skips']:ET.SubElement(case,'skipped')
        with tempfile.TemporaryDirectory(dir=SCRATCH) as d:
            path=Path(d)/'full-swift-testing.xml';path.write_bytes(ET.tostring(tree))
            self.assertEqual(control.qualify_xml(Path(d),native),path.name)
            case=next(c for c in tree.iter('testcase') if not list(c));ET.SubElement(case,'skipped')
            path.write_bytes(ET.tostring(tree))
            with self.assertRaises(AssertionError):control.qualify_xml(Path(d),native)

    def test_real_census_binds_unchanged_test_sources_and_known_skips(self):
        census,sources=control.expected_tests(Path(__file__).resolve().parent.parent)
        self.assertEqual(len(sources),107)
        self.assertEqual(census['functionCount'],census['executingFunctionCount']+len(census['inheritedSkipKeys']))
        self.assertEqual(sum(len(v) for v in census['parameterCases'].values()),17)


if __name__=='__main__':
    if len(sys.argv)!=2:raise SystemExit('usage: test-linux-full-order-diagnostic.py ABSOLUTE_SCRATCH')
    SCRATCH=Path(sys.argv.pop()).resolve();SCRATCH.mkdir(parents=True,exist_ok=True)
    unittest.main()
