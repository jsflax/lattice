"""Pure orchestration/admission DATA tests; never launch Git/Swift/native work."""
import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sync_matched_hosted', Path(__file__).with_name('sync_matched_hosted.py'))
hosted = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosted)


class HostedTests(unittest.TestCase):
    def setUp(self):
        # Explicit isolated localdev output, also on hosted runners.
        base = Path(__file__).resolve().parent
        self.temp = tempfile.TemporaryDirectory(prefix='matched-data-', dir=base)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'hosted-receipts').mkdir()
        self.env = dict(GITHUB_ACTIONS='true', GITHUB_EVENT_NAME='workflow_dispatch',
            GITHUB_REPOSITORY='jsflax/Lattice', GITHUB_SHA='b' * 40, GITHUB_RUN_ID='17',
            GITHUB_RUN_ATTEMPT='2', GITHUB_JOB='matched', DEVELOPMENT_LEG='macos')
        self.ident = hosted.identity(self.env)
        self.binding = {'baseline': {'sdkCommit': hosted.BASELINE, 'coreCommit': hosted.BASELINE_CORE},
                        'candidate': {'sdkCommit': 'b' * 40, 'coreCommit': 'c' * 40}}

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return path

    def test_real_identity_required(self):
        for key, value in [('GITHUB_ACTIONS', 'false'), ('GITHUB_EVENT_NAME', 'push'),
                           ('GITHUB_SHA', 'branch'), ('GITHUB_SHA', hosted.BASELINE),
                           ('GITHUB_RUN_ATTEMPT', '0'), ('DEVELOPMENT_LEG', 'other')]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                hosted.identity(dict(self.env, **{key: value}))

    def test_exact_roots_and_alias_refusal(self):
        home = self.root / 'home'
        (home / 'localdev').mkdir(parents=True)
        root = home / 'localdev/lattice-sync-matched-17-2-macos'
        (root / 'baseline').mkdir(parents=True)
        (root / 'candidate').mkdir()
        with patch.object(hosted.Path, 'home', return_value=home):
            self.assertNotEqual(*hosted.roots(root, self.ident).values())
            (root / 'candidate').rmdir()
            (root / 'candidate').symlink_to(root / 'baseline', target_is_directory=True)
            with self.assertRaises(ValueError):
                hosted.roots(root, self.ident)

    def test_full_budget_boundary_and_no_reset(self):
        start = 1_000_000_000
        last = start + (hosted.ENVELOPE_SECONDS - hosted.FINAL_RESERVE - hosted.PHASE_SECONDS) * 10**9
        self.assertEqual(hosted.admit(start, last), 12600)
        with self.assertRaises(ValueError):
            hosted.admit(start, last + 1)
        with self.assertRaises(ValueError):
            hosted.admit(start, start - 1)

    def test_each_original_runner_and_core(self):
        a = hosted.command(self.root, self.ident, self.binding, 'prepare-A')
        b = hosted.command(self.root, self.ident, self.binding, 'prepare-B')
        self.assertEqual(a[1], str(self.root / 'baseline/lattice/Scripts/run-development.py'))
        self.assertEqual(b[1], str(self.root / 'candidate/lattice/Scripts/run-development.py'))
        self.assertEqual(a[a.index('--sdk-sha') + 1], hosted.BASELINE)
        self.assertEqual(a[a.index('--core-sha') + 1], hosted.BASELINE_CORE)
        self.assertEqual(b[b.index('--sdk-sha') + 1], self.ident['GITHUB_SHA'])
        self.assertEqual(a[-1], '--sync-matched-prepare')
        self.assertEqual(a[a.index('--test-timeout') + 1], '1800')
        linux = hosted.command(self.root, dict(self.ident, DEVELOPMENT_LEG='linux'), self.binding, 'prepare-A')
        self.assertEqual(linux[linux.index('--test-timeout') + 1], '5400')

    def test_candidate_coordinator_uses_both_originals(self):
        argv = hosted.command(self.root, self.ident, self.binding, 'measure')
        self.assertEqual(argv[1], str(self.root / 'candidate/lattice/Scripts/sync_matched_experiment.py'))
        self.assertEqual(argv[argv.index('--baseline-root') + 1], str(self.root / 'baseline'))
        self.assertEqual(argv[argv.index('--candidate-root') + 1], str(self.root / 'candidate'))
        self.assertEqual(len(set(hosted.profile_names())), 30)

    def prepare_execute(self):
        self.write('hosted-receipts/PLAN.json', {'identity': self.ident, 'bindings': self.binding})
        return patch.object(hosted, 'context', return_value=(self.ident, {'monotonicNS': 1_000_000_000}, self.binding))

    def test_exec_replaces_process_after_issue(self):
        with self.prepare_execute(), patch.object(hosted.time, 'monotonic_ns', return_value=2_000_000_000), \
                patch.object(hosted.os, 'execve', side_effect=RuntimeError('test intercept')) as execute:
            with self.assertRaisesRegex(RuntimeError, 'test intercept'):
                hosted.execute(self.root, 'prepare-A')
        issued = hosted.read(self.root / 'hosted-receipts/prepare-A-ISSUED.json')
        self.assertIs(issued['execAttempted'], True)
        self.assertEqual(execute.call_args.args[1], issued['argv'])

    def test_refused_budget_recorded_before_any_exec(self):
        with self.prepare_execute(), patch.object(hosted.time, 'monotonic_ns', return_value=20_000 * 10**9), \
                patch.object(hosted.os, 'execve') as execute:
            with self.assertRaises(ValueError):
                hosted.execute(self.root, 'prepare-A')
            execute.assert_not_called()
        issued = hosted.read(self.root / 'hosted-receipts/prepare-A-ISSUED.json')
        self.assertIs(issued['execAttempted'], False)
        self.assertIn('full unchanged12600s', issued['admissionError'])

    def test_failed_preparation_cannot_admit_measurement(self):
        self.write('hosted-receipts/prepare-A-RESULT.json', {'success': False})
        with self.prepare_execute(), patch.object(hosted.os, 'execve') as execute:
            with self.assertRaises(ValueError):
                hosted.execute(self.root, 'measure')
            execute.assert_not_called()

    def complete_measurement(self, original, exit_code=0):
        self.write('hosted-receipts/measure-ISSUED.json', {'identity': self.ident, 'bindings': self.binding, 'execAttempted': True})
        self.write('matched-receipts/RESULT.json', original)
        with patch.object(hosted, 'context', return_value=(self.ident, {}, self.binding)):
            hosted.complete(self.root, 'measure', exit_code)

    def test_measurement_refuses_29_or_duplicate_or_numeric_failure(self):
        original = {'success': True, 'numericalGatesPass': True,
                    'attemptedProfiles': hosted.profile_names(), 'unattempted': []}
        for change in [{'attemptedProfiles': hosted.profile_names()[:-1]},
                       {'attemptedProfiles': hosted.profile_names()[:-1] + [hosted.profile_names()[0]]},
                       {'numericalGatesPass': False}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.complete_measurement(dict(original, **change))
            (self.root / 'hosted-receipts/measure-RESULT.json').unlink()

    def test_original_nonzero_exit_not_rescued_by_result(self):
        original = {'success': True, 'numericalGatesPass': True,
                    'attemptedProfiles': hosted.profile_names(), 'unattempted': []}
        with self.assertRaises(ValueError):
            self.complete_measurement(original, 1)
        result = hosted.read(self.root / 'hosted-receipts/measure-RESULT.json')
        self.assertIs(result['success'], False)
        self.assertIsNotNone(result['innerResultSHA256'])

    def test_retention_excludes_store_and_build(self):
        self.write('baseline/receipts/RESULT.json', {'success': False})
        self.write('baseline/scratch/store.sqlite', {'private': True})
        self.write('captures/1/A/loaded/receipts.json', {'rows': []})
        manifest = hosted.retain(self.root)
        names = {row['path'] for row in manifest['copied']}
        self.assertEqual(names, {'baseline/receipts/RESULT.json', 'captures/1/A/loaded/receipts.json'})

    def test_retention_limits_and_symlink_refuse(self):
        path = self.write('candidate/receipts/large.log', {'content': 'large'})
        alias = self.root / 'candidate/receipts/alias.log'
        alias.symlink_to(path)
        with patch.object(hosted, 'UPLOAD_FILE_BYTES', 4):
            manifest = hosted.retain(self.root)
        self.assertEqual(len(manifest['omitted']), 2)
        self.assertEqual(manifest['copied'], [])

    def test_store_inside_receipt_directory_is_not_uploaded(self):
        self.write('candidate/receipts/unexpected.sqlite', {'private': True})
        manifest = hosted.retain(self.root)
        self.assertEqual(manifest['copied'], [])
        self.assertEqual(manifest['omitted'][0]['path'], 'candidate/receipts/unexpected.sqlite')

    def test_native_probe_xml_is_retained_byte_exact(self):
        xml = b'<?xml version="1.0"?><testsuites><testsuite tests="14" failures="0"/></testsuites>\n'
        for name in ('baseline', 'candidate'):
            path = self.root / name / 'receipts/native-probe.xml'
            path.parent.mkdir(parents=True)
            path.write_bytes(xml)
        manifest = hosted.retain(self.root)
        self.assertEqual(manifest['omitted'], [])
        self.assertEqual({row['path'] for row in manifest['copied']},
                         {'baseline/receipts/native-probe.xml', 'candidate/receipts/native-probe.xml'})
        for row in manifest['copied']:
            self.assertEqual((self.root / 'upload' / row['path']).read_bytes(), xml)

    def test_original_final_package_receipts_are_retained_byte_exact(self):
        original = b'{"pins":[],"version":2}\n'
        names = {'baseline/receipts/Package.resolved.final',
                 'candidate/receipts/Package.resolved.final'}
        for name in names:
            path = self.root / name
            path.parent.mkdir(parents=True)
            path.write_bytes(original)
        manifest = hosted.retain(self.root)
        self.assertEqual(manifest['omitted'], [])
        self.assertEqual({row['path'] for row in manifest['copied']}, names)
        for row in manifest['copied']:
            self.assertEqual(row['bytes'], len(original))
            self.assertEqual(row['sha256'], hashlib.sha256(original).hexdigest())
            self.assertEqual((self.root / 'upload' / row['path']).read_bytes(), original)

    def test_final_receipt_exception_requires_the_exact_basename(self):
        names = {'candidate/receipts/unrelated.final',
                 'candidate/receipts/OtherPackage.resolved.final',
                 'candidate/receipts/package.resolved.final',
                 'candidate/receipts/Package.resolved.final.backup'}
        for name in names:
            self.write(name, {'notAnOriginalFinalLock': True})
        manifest = hosted.retain(self.root)
        self.assertEqual(manifest['copied'], [])
        self.assertEqual({row['path'] for row in manifest['omitted']}, names)

    def test_final_receipt_cannot_bypass_alias_count_or_byte_limits(self):
        original = b'{"pins":[],"version":2}\n'
        for kind in ('alias', 'file-bytes', 'total-bytes', 'file-count'):
            with self.subTest(kind=kind):
                root = self.root / kind
                path = root / 'candidate/receipts/Package.resolved.final'
                path.parent.mkdir(parents=True)
                if kind == 'alias':
                    target = root / 'original-lock'
                    target.write_bytes(original)
                    path.symlink_to(target)
                else:
                    path.write_bytes(original)
                with patch.multiple(hosted,
                        UPLOAD_FILE_BYTES=len(original) - 1 if kind == 'file-bytes' else hosted.UPLOAD_FILE_BYTES,
                        UPLOAD_BYTES=len(original) - 1 if kind == 'total-bytes' else hosted.UPLOAD_BYTES,
                        UPLOAD_FILES=0 if kind == 'file-count' else hosted.UPLOAD_FILES):
                    manifest = hosted.retain(root)
                self.assertEqual(manifest['copied'], [])
                self.assertEqual([row['path'] for row in manifest['omitted']],
                                 ['candidate/receipts/Package.resolved.final'])
                self.assertFalse((root / 'upload/candidate/receipts/Package.resolved.final').exists())

    def test_malformed_originals_still_retain_raw_logs_and_unknown_progress(self):
        paths = ('hosted-receipts/prepare-A-RESULT.json', 'hosted-receipts/measure-RESULT.json',
                 'hosted-receipts/measure-ISSUED.json', 'matched-receipts/RESULT.json')
        for index, (name, malformed) in enumerate((name, body) for name in paths for body in ('{broken', '[]')):
            with self.subTest(name=name, malformed=malformed):
                root = self.root / ('malformed-' + str(index))
                (root / 'hosted-receipts').mkdir(parents=True)
                if name != 'hosted-receipts/measure-ISSUED.json':
                    hosted.save(root / 'hosted-receipts/measure-ISSUED.json', {'execAttempted': True})
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(malformed)
                for log in ('baseline/test-logs/native.log', 'matched-receipts/matched-1-A-loaded.log'):
                    target = root / log
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b'actual raw failure log\n')
                with patch.dict(hosted.os.environ, self.env, clear=True), patch.object(hosted, 'roots'), self.assertRaises(ValueError):
                    hosted.finalize(root)
                final = hosted.read(root / 'hosted-receipts/FINAL.json')
                self.assertIs(final['success'], False)
                self.assertTrue(final['evidenceErrors'])
                self.assertEqual(final['progress']['profileDenominator'], 30)
                self.assertIsNone(final['progress']['attemptedProfiles'])
                self.assertIsNone(final['progress']['unattempted'])
                self.assertEqual(path.read_text(), malformed)
                for log in ('baseline/test-logs/native.log', 'matched-receipts/matched-1-A-loaded.log'):
                    self.assertEqual((root / 'upload' / log).read_bytes(), b'actual raw failure log\n')
                if name == 'matched-receipts/RESULT.json':
                    self.assertEqual((root / 'upload' / name).read_text(), malformed)

    def test_phase_success_without_actual_inner_summary_cannot_pass(self):
        for phase in hosted.PHASES:
            self.write('hosted-receipts/' + phase + '-RESULT.json', {'success': True})
        with patch.dict(hosted.os.environ, self.env, clear=True), patch.object(hosted, 'roots'), self.assertRaises(ValueError):
            hosted.finalize(self.root)
        final = hosted.read(self.root / 'hosted-receipts/FINAL.json')
        self.assertIs(final['success'], False)
        self.assertIsNone(final['progress']['attemptedProfiles'])
        self.assertIsNone(final['progress']['unattempted'])

    def test_finalize_distinguishes_unattempted_refused_and_unknown(self):
        for index, attempted in enumerate((None, False, True)):
            root = self.root / str(index)
            (root / 'hosted-receipts').mkdir(parents=True)
            if attempted is not None:
                hosted.save(root / 'hosted-receipts/measure-ISSUED.json', {'execAttempted': attempted})
            with patch.dict(hosted.os.environ, self.env, clear=True), patch.object(hosted, 'roots'), self.assertRaises(ValueError):
                hosted.finalize(root)
            result = hosted.read(root / 'hosted-receipts/FINAL.json')
            self.assertIs(result['success'], False)
            self.assertEqual(result['progress']['profileDenominator'], 30)
            if attempted is True:
                self.assertIsNone(result['progress']['attemptedProfiles'])
                self.assertIsNone(result['progress']['unattempted'])
            else:
                self.assertEqual(result['progress']['attemptedProfiles'], [])
                self.assertEqual(result['progress']['unattempted'], hosted.profile_names())

    def test_registered_workflow_gates_and_keeps_false_defaults(self):
        workflow = Path(__file__).parents[1] / '.github/workflows/development.yml'
        text = workflow.read_text()
        self.assertIn('  development:\n    if: ${{ !inputs.sync_matched_experiment }}\n', text)
        self.assertIn('  matched:\n    if: ${{ inputs.sync_matched_experiment }}\n', text)
        self.assertIn('      sync_matched_experiment:', text)
        self.assertIn('for mode in $OTHER_MODES; do test "$mode" != true; done', text)
        for mode in ('sync_probe_qualification', 'sync_full_calibration', 'sync_matched_prepare', 'recovery_refresh_qualification'):
            self.assertIn('${{ inputs.' + mode + ' }}', text)
        self.assertNotIn('actions/checkout', text)
        self.assertIn('runner: macos-26', text)
        self.assertIn('container: swift:6.3-noble', text)


if __name__ == '__main__':
    unittest.main()
