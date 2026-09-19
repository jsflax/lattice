"""Synthetic fixed-input rejection checks; never resolve/build/run Swift or SQLite."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest

import validate as v
import qualify

P = Path(__file__).resolve().parent

class ValidationTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ['CONSUMER_CHECK_ROOT']).resolve(strict=True)
        self.assertTrue(parent.is_relative_to(Path.home() / 'localdev'))
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.inputs = v.load(P / 'publication-inputs.json')
        self.inputs.update(publicationQualified=False, dispatchReady=False)
        self.expected = v.pins({'version': 3, 'pins': v.load(P / 'OBSERVED-SDK-PINS.json')['pins']})
        self.inputs['sdk']['commit'] = 'a' * 40
        self.inputs['core']['commit'] = 'c' * 40
        self.expected['latticecore']['state'] = copy.deepcopy(v.SDK_CORE_STATE)
        self.consumer_expected = v.consumer_expected_pins(self.expected, self.inputs)

    def lock(self, subset=False):
        selected = [self.consumer_expected['latticecore']] if subset else list(self.consumer_expected.values())
        return {'version': 3, 'originHash': 'd' * 64, 'pins': [*copy.deepcopy(selected), v.sdk_pin(self.inputs)]}

    def write(self, name, body):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(body))
        return v.digest(path)

    def bound(self):
        x = self.inputs
        x.update(publicationQualified=True, dispatchReady=True, sdkExpectedCompletePins=list(self.expected.values()))
        for role in ('sdk', 'core'):
            item = x[role]; item.update(tree=v.REVIEWED_CORE_TREE if role == 'core' else 'e' * 40,
                                       releaseWorkflowRun=123, releaseWorkflowAttempt=1)
            release = {'tag_name': item['tag'], 'draft': False, 'prerelease': False,
                'published_at': 'synthetic-time', 'id': 12,
                'html_url': item['repository'].removesuffix('.git') + '/releases/tag/' + item['tag']}
            run = {'id': 123, 'run_attempt': 1, 'head_sha': item['commit'], 'status': 'completed',
                'conclusion': 'success', 'repository': {'html_url': item['repository'].removesuffix('.git')},
                'path': '.github/workflows/release.yml'}
            item['releaseObjectSHA256'] = self.write(item['releaseObjectFile'], release)
            item['releaseEvidenceSHA256'] = self.write(item['releaseEvidenceFile'], run)
        x['core']['releaseReceiptSHA256'] = self.write(x['core']['releaseReceiptFile'],
            {'schemaVersion': 1, 'sourceSha': x['core']['commit'], 'state': 'validated-and-packaged'})
        x['sdk']['bindingReceiptSHA256'] = self.write(x['sdk']['bindingReceiptFile'], {'synthetic': True})
        return x

    def result(self, phase='write'):
        return {'schema': 'lattice.release-consumer/1', 'phase': phase, 'pid': 42,
            'checkedRowCount': 3, 'rollbackRowAbsent': True,
            'rollbackSentinelCaught': True if phase == 'write' else None, 'rows': copy.deepcopy(v.EXPECTED_ROWS)}

    def runtime(self, record, phase='write'):
        return v.runtime('CONSUMER_RESULT ' + json.dumps(record) + '\n', phase, 42)

    def test_unbound_gate_refuses_before_file_reads(self):
        with self.assertRaisesRegex(ValueError, 'unbound'):
            v.publication(self.inputs, self.root / 'not-created')

    def test_synthetic_bound_publication_and_complete_graph(self):
        self.assertEqual(v.publication(self.bound(), self.root), self.expected)
        actual, omitted = v.consumer_pins(self.lock(), self.consumer_expected, self.inputs)
        self.assertEqual(len(actual), 35); self.assertEqual(omitted, [])

    def test_product_subset_reports_all_omissions(self):
        actual, omitted = v.consumer_pins(self.lock(True), self.consumer_expected, self.inputs)
        self.assertEqual(set(actual), {'lattice', 'latticecore'})
        self.assertEqual(omitted, sorted(set(self.expected) - {'latticecore'}))

    def test_missing_originhash_and_duplicate_pins_rejected(self):
        x = self.lock(); x.pop('originHash')
        with self.assertRaisesRegex(ValueError, 'originHash'): v.consumer_pins(x, self.consumer_expected, self.inputs)
        x = self.lock(); x['pins'].append(x['pins'][0])
        with self.assertRaisesRegex(ValueError, 'duplicate'): v.consumer_pins(x, self.consumer_expected, self.inputs)

    def test_revision_version_repository_and_kind_drift_rejected(self):
        for field in ('revision', 'version', 'location', 'kind'):
            with self.subTest(field=field):
                x = self.lock(); pin = next(p for p in x['pins'] if p['identity'] == 'latticecore')
                if field in ('revision', 'version'): pin['state'][field] = 'f' * 40 if field == 'revision' else '2.0.4'
                else: pin[field] = 'unexpected'
                with self.assertRaises(ValueError): v.consumer_pins(x, self.consumer_expected, self.inputs)

    def test_unknown_identity_branch_and_missing_core_rejected(self):
        for mutation in ('unknown', 'branch', 'missing'):
            with self.subTest(mutation=mutation):
                x = self.lock(True)
                if mutation == 'unknown':
                    pin = copy.deepcopy(x['pins'][0]); pin['identity'] = 'unreviewed'; x['pins'].append(pin)
                elif mutation == 'branch': x['pins'][0]['state']['branch'] = 'main'
                else: x['pins'] = [pin for pin in x['pins'] if pin['identity'] != 'latticecore']
                with self.assertRaises(ValueError): v.consumer_pins(x, self.consumer_expected, self.inputs)

    def test_only_consumer_core_pin_advances_without_mutating_sdk(self):
        before = copy.deepcopy(self.expected)
        derived = v.consumer_expected_pins(self.expected, self.inputs)
        self.assertEqual(self.expected, before)
        self.assertEqual({k: x for k, x in derived.items() if k != 'latticecore'},
                         {k: x for k, x in before.items() if k != 'latticecore'})
        self.assertEqual(derived['latticecore']['state'], {'revision': 'c' * 40, 'version': '2.0.6'})
        derived['latticecore']['state']['revision'] = 'f' * 40
        self.assertEqual(self.expected, before)

    def test_old_core_consumer_pin_is_rejected(self):
        x = self.lock()
        next(p for p in x['pins'] if p['identity'] == 'latticecore')['state'] = copy.deepcopy(v.SDK_CORE_STATE)
        with self.assertRaises(ValueError): v.consumer_pins(x, self.consumer_expected, self.inputs)

    def test_rewritten_sdk_lock_is_rejected(self):
        x = self.bound()
        next(p for p in x['sdkExpectedCompletePins'] if p['identity'] == 'latticecore')['state'] = {'revision': 'c' * 40, 'version': '2.0.5'}
        with self.assertRaisesRegex(ValueError, 'immutable SDK Core'): v.publication(x, self.root)
        with self.assertRaisesRegex(ValueError, 'immutable SDK Core'): v.consumer_expected_pins(v.pins({'version':3,'pins':x['sdkExpectedCompletePins']}),x)

    def test_release_bytes_drift_rejected(self):
        x = self.bound(); (self.root / x['sdk']['releaseObjectFile']).write_text('{}')
        with self.assertRaisesRegex(ValueError, 'hash differs'): v.publication(x, self.root)

    def test_failed_workflow_and_mismatched_source_rejected(self):
        for key, value in [('conclusion', 'failure'), ('head_sha', 'f' * 40), ('run_attempt', 2)]:
            with self.subTest(key=key):
                x = self.bound(); item = x['core']; run = v.load(self.root / item['releaseEvidenceFile']); run[key] = value
                item['releaseEvidenceSHA256'] = self.write(item['releaseEvidenceFile'], run)
                with self.assertRaises(ValueError): v.publication(x, self.root)

    def test_core_receipt_wrong_state_rejected(self):
        x = self.bound(); item = x['core']
        item['releaseReceiptSHA256'] = self.write(item['releaseReceiptFile'],
            {'schemaVersion': 1, 'sourceSha': item['commit'], 'state': 'packaged-awaiting-native-validation'})
        with self.assertRaisesRegex(ValueError, 'not qualified'): v.publication(x, self.root)

    def test_runtime_both_phases_accept_exact_rows(self):
        for phase in ('write', 'read'): self.runtime(self.result(phase), phase)

    def test_runtime_missing_duplicate_wrong_pid_and_wrong_phase(self):
        row = self.result(); text = 'CONSUMER_RESULT ' + json.dumps(row) + '\n'
        for candidate, phase, pid in [('', 'write', 42), (text * 2, 'write', 42), (text, 'write', 43), (text, 'read', 42)]:
            with self.subTest(candidate=candidate[:10], phase=phase, pid=pid):
                with self.assertRaises(ValueError): v.runtime(candidate, phase, pid)

    def test_runtime_count_rollback_values_and_types_rejected(self):
        for mutation in ('count', 'rollback', 'sentinel', 'value', 'bool'):
            with self.subTest(mutation=mutation):
                x = self.result()
                if mutation == 'count': x['checkedRowCount'] = 2
                elif mutation == 'rollback': x['rollbackRowAbsent'] = False
                elif mutation == 'sentinel': x['rollbackSentinelCaught'] = False
                elif mutation == 'value': x['rows'][1]['title'] = 'wrong'
                else: x['rows'][0]['ordinal'] = True
                with self.assertRaises(ValueError): self.runtime(x)

    def test_compact_command_summary_is_not_full_receipt(self):
        with self.assertRaises(ValueError): v.command({'label': 'build', 'success': True})

    def test_failed_cleanup_signal_and_receipt_log_drift(self):
        path = self.root / 'log'; path.write_text('synthetic\n')
        record = {'success': True, 'started': True, 'exitCode': 0, 'logSHA256': v.digest(path),
            'logBytes': path.stat().st_size, 'cleanup': {'groupGone': True, 'leaderReaped': True}}
        v.command(record, path)
        for key, value in [('exitCode', 1), ('receivedSignals', ['SIGTERM']), ('stopReason', 'timeout')]:
            x = copy.deepcopy(record); x[key] = value
            with self.assertRaises(ValueError): v.command(x, path)
        x = copy.deepcopy(record); x['cleanup']['groupGone'] = False
        with self.assertRaises(ValueError): v.command(x, path)
        path.write_text('drift\n')
        with self.assertRaisesRegex(ValueError, 'log drift'): v.command(record, path)

    def test_final_failure_clears_acceptance_preserves_observed(self):
        for key, value in [('evidenceErrors', ['drift']), ('primaryError', 'failed'),
                           ('receivedSignals', ['SIGTERM']), ('binaryUnchanged', False)]:
            x = {name: True for name in v.ACCEPTANCE}
            x.update(sourceAndLockUnchanged=True, binaryUnchanged=True, allOwnedGroupsGone=True, observed={'rows': 3})
            x[key] = value; v.finalize(x)
            self.assertTrue(all(x[name] is False for name in v.ACCEPTANCE)); self.assertEqual(x['observed'], {'rows': 3})

    def test_result_write_failure_reset(self):
        x = {name: True for name in v.ACCEPTANCE}; x['observed'] = {'buildExitZero': True}
        v.reject_acceptance(x)
        self.assertTrue(all(x[name] is False for name in v.ACCEPTANCE)); self.assertTrue(x['observed']['buildExitZero'])

    def test_duplicate_json_and_path_escape_rejected(self):
        with self.assertRaises(ValueError): v.parse('{"pins":[],"pins":[]}')
        for name in ('../escape', '/absolute'):
            with self.assertRaises(ValueError): v.file_at(self.root, name)

    def test_fixed_input_closure_and_final_clock_order(self):
        self.assertEqual(len(qualify.REQUIRED_INPUTS), 9)
        self.assertTrue(all((P / name).is_file() for name in qualify.REQUIRED_INPUTS))
        text = (P / 'qualify.py').read_text()
        measure = text.index("sample = runner.measure(receipts / 'consumer-debug-build.log')")
        deadline = text.index("'final resource measurement exceeded budget'", measure)
        acceptance = text.index('check.finalize(result)', deadline)
        self.assertLess(measure, deadline); self.assertLess(deadline, acceptance)

if __name__ == '__main__':
    unittest.main()
