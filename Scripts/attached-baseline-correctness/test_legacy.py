"""Pure classifier/source checks; no native product, Swift, git, or network."""
from copy import deepcopy
from pathlib import Path
import ast, json, re, unittest
import legacy_analysis as a
import qualify

P = Path(__file__).resolve().parent
expected = json.loads((P/'legacy-expected-tests.json').read_text())

def evidence():
    cases = []
    log = []
    for identity in expected['caseIdentifiers']:
        suite, name = identity.split('/')
        cases.append(f'<testcase classname="{suite}" name="{name}" time="0.1"/>')
        log += [f'◇ Test {name} started.', f'✔ Test {name} passed after 0.1 seconds.']
    xml = '<testsuites><testsuite tests="4" errors="0" failures="0" skipped="0">'+''.join(cases)+'</testsuite></testsuites>'
    return xml, '\n'.join(log+['✔ Test run with 4 tests in 3 suites passed after 0.4 seconds.'])

class Legacy(unittest.TestCase):
    def test_exact_four_passes(self):
        actual = a.framework(*evidence(), expected)
        self.assertEqual(actual['executed'],4); self.assertEqual(actual['skipped'],0)

    def test_discovery_ignores_unselected_but_rejects_missing_duplicate(self):
        text='\n'.join(expected['caseIdentifiers'])
        self.assertEqual(a.discover(text+'\nLatticeTests.Other/other()',expected),expected['caseIdentifiers'])
        for bad in [text.replace(expected['caseIdentifiers'][0],''),text+'\n'+expected['caseIdentifiers'][0]]:
            with self.assertRaises(AssertionError):a.discover(bad,expected)

    def test_filter_matches_only_exact_selected_names(self):
        pattern=re.compile(expected['filter'])
        for name in expected['caseIdentifiers']:
            self.assertTrue(pattern.fullmatch(name))
            for wrong in ['Other'+name,name+'extra',name.replace('()', '(parameter:)'),name.replace('LatticeTests.','FakeTests.')]:
                self.assertFalse(pattern.fullmatch(wrong))

    def test_skip_error_failure_global_issue_signal_reject(self):
        xml,log=evidence()
        for element in ['<skipped/>','<error/>','<failure/>']:
            with self.assertRaises(AssertionError):a.framework(xml.replace('</testsuite>',element+'</testsuite>'),log,expected)
        for bad in ['\n✘ unknown failure','\nrecorded an issue','\nunexpected signal 11','\n➜ Test unknown() skipped.']:
            with self.assertRaises(AssertionError):a.framework(xml,log+bad,expected)

    def test_wrong_duplicate_or_extra_cases_reject(self):
        xml,log=evidence()
        for bad in [xml.replace('LiveResultsKeysetTests','OtherSuite'),xml.replace(expected['caseNames'][0],expected['caseNames'][1]),xml.replace('</testsuite>','<testcase classname="Other" name="extra()"/></testsuite>')]:
            with self.assertRaises(AssertionError):a.framework(bad,log,expected)

    def test_missing_start_pass_summary_or_wrong_total_reject(self):
        xml,log=evidence()
        for bad in [log.replace('◇ Test '+expected['caseNames'][0]+'() started.',''),log.replace('✔ Test '+expected['caseNames'][0]+'() passed after 0.1 seconds.',''),log.replace('4 tests','3 tests'),log.replace('in 3 suites','in 4 suites'),log+'\n✔ Test run with 4 tests in 3 suites passed after 0.4 seconds.']:
            with self.assertRaises(AssertionError):a.framework(xml,bad,expected)

    def test_xml_suite_failure_totals_reject(self):
        xml,log=evidence()
        for field in ['errors','failures','skipped']:
            with self.assertRaises(AssertionError):a.framework(xml.replace(field+'="0"',field+'="1"'),log,expected)

    def test_final_failure_clears_legacy_acceptance(self):
        value=dict(success=True,primaryError=None,evidenceErrors=[],receivedSignals=[],experimentCompleted=True,
            correctedFocusedAccepted=False,legacyChecksQualified=True,correctedBaselinePrerequisitesAccepted=True,
            benchmarkAdmissionAccepted=False,arms={'corrected':{'actual':{'executed':4}}})
        for key,error in [('primaryError',{'failure':1}),('evidenceErrors',[{'failure':1}]),('receivedSignals',[15]),('success',False)]:
            changed=deepcopy(value);changed[key]=error;qualify.finalize_acceptance(changed)
            self.assertFalse(changed['legacyChecksQualified']);self.assertFalse(changed['correctedBaselinePrerequisitesAccepted'])
            self.assertFalse(changed['benchmarkAdmissionAccepted']);self.assertEqual(changed['arms'],value['arms'])

    def test_exact_config_guard_and_build_scope(self):
        config=json.loads((P/'config.json').read_text()); prior=json.loads((P/'prior-packet-seal.json').read_text())
        import hashlib
        self.assertEqual(hashlib.sha256((P/'guarded_runner.py').read_bytes()).hexdigest(),prior['files']['guarded_runner.py'])
        self.assertEqual(hashlib.sha256((P/'build_proof.py').read_bytes()).hexdigest(),prior['files']['build_proof.py'])
        self.assertEqual((config['buildSeconds'],config['testSeconds'],config['overallSeconds'],config['reserveSeconds'],config['j']),(5400,180,18000,600,2))
        source=(P/'qualify.py').read_text();ast.parse(source)
        self.assertIn("for arm in ('corrected',):",source)
        self.assertNotIn("for arm in ('original', 'corrected'):",source)
        self.assertIn("time.monotonic() < runner.overall_deadline",source)
        self.assertNotIn("expected_nonzero.add",source)
        self.assertIn("verify_build(context)",source)

    def test_owned_log_patch_only_logger_and_no_test_assertions(self):
        patch=(P/'owned-log.patch').read_text()
        added=[x[1:] for x in patch.splitlines() if x.startswith('+') and not x.startswith('+++')]
        removed=[x[1:] for x in patch.splitlines() if x.startswith('-') and not x.startswith('---')]
        self.assertTrue(any('/tmp/lattice_swift_tests.log' in x for x in removed))
        self.assertTrue(any('LATTICE_TEST_LOG_PATH' in x for x in added))
        self.assertTrue(any('preconditionFailure' in x for x in added))
        self.assertFalse(any('@Test' in x or '#expect' in x or '#require' in x for x in added+removed))

if __name__=='__main__':unittest.main()
