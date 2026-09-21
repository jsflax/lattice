"""Pure Python metadata, receipt and fake-runner checks. No native/SQLite work."""
import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import sync_full_calibration as c
from test_evaluate_sync import fixture


def command(success=True, **overrides):
    value = dict(started=True, exitCode=0 if success else 1, success=success,
                 primaryError=None, evidenceErrors=[], receivedSignals=[], stopReason=None,
                 cleanup=dict(groupGone=True, leaderReaped=True, signals=[], errors=[]),
                 argv=['swift', 'build', *c.FLAGS])
    value.update(overrides)
    return value


METADATA = dict(SDK_REVISION='a' * 40, CORE_REVISION='b' * 40, BUILD_ID='build',
                HOST_ID='host', RUN_GROUP='calibration:run', LOGGING='declared existing logging')


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        # Explicit localdev-backed tree, never the system temporary directory.
        self.temporary = tempfile.TemporaryDirectory(prefix='.calibration-test-', dir=Path(__file__).resolve().parents[1])
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def binding(self, root=None, **changes):
        root = root or self.root
        args = dict(root=root,
            sdk_inputs=dict(commit='a' * 40, tree='c' * 40),
            core_inputs=dict(commit='b' * 40, tree='d' * 40, path=str(root / 'Core')),
            graph=[dict(identity='latticecore' if i == 0 else f'dep{i}', revision='b' * 40 if i == 0 else 'e' * 40,
                        location=f'https://example.invalid/{i}') for i in range(34)],
            toolchain='Swift reviewed version',
            build=command(argv=['swift', 'build', '--scratch-path', str(root / 'scratch'), *c.FLAGS]),
            native=command(argv=['swift', 'run', '--scratch-path', str(root / 'native'), *c.FLAGS]),
            compiler_inputs={'sourceFiles': {str(root / 'Core/Sources/test.cpp'): 'f' * 64},
                             'samples': [{'source': str(root / 'Core/Sources/test.cpp'),
                                          'command': f'clang -DLATTICE_SYNC_COMMIT_PROBE -c {root}/Core/Sources/test.cpp'}]},
            env=dict(GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1', GITHUB_REPOSITORY='owner/repo',
                     GITHUB_JOB='development', DEVELOPMENT_LEG='linux', LATTICE_TEST_LOG_PATH=str(root / 'native.log')),
            host=dict(system='Linux', machine='x86_64', node='host1', cpuCount=2))
        args.update(changes)
        return c.make_binding(**args)

    def test_build_identity_excludes_execution_paths_and_host_but_binds_graph_toolchain_flags(self):
        one = self.binding()
        two = self.binding(root=self.root / 'other-run',
                           env=dict(GITHUB_RUN_ID='456', GITHUB_RUN_ATTEMPT='2', GITHUB_REPOSITORY='owner/repo',
                                    GITHUB_JOB='development', DEVELOPMENT_LEG='linux'),
                           host=dict(system='Linux', machine='x86_64', node='host2', cpuCount=2))
        self.assertEqual(one['metadata']['BUILD_ID'], two['metadata']['BUILD_ID'])
        self.assertNotEqual(one['metadata']['HOST_ID'], two['metadata']['HOST_ID'])
        self.assertNotEqual(one['metadata']['RUN_GROUP'], two['metadata']['RUN_GROUP'])
        self.assertNotEqual(one['metadata']['BUILD_ID'], self.binding(toolchain='different Swift')['metadata']['BUILD_ID'])
        self.assertNotEqual(one['metadata']['BUILD_ID'], self.binding(sdk_inputs=dict(commit='f' * 40, tree='c' * 40))['metadata']['BUILD_ID'])
        with self.assertRaisesRegex(ValueError, 'flag pair'):
            self.binding(build=command(argv=['swift', 'build', *c.FLAGS[:-2]]))

    def test_binding_refuses_incomplete_graph_build_and_execution_identity(self):
        for changed in (dict(graph=[]), dict(build=command(False)), dict(toolchain=''), dict(env={}),
                        dict(compiler_inputs=dict(sourceFiles={}, samples=[])),
                        dict(native=command(cleanup=dict(groupGone=False)))):
            with self.subTest(changed=changed), self.assertRaises(ValueError): self.binding(**changed)

    def test_plans_are_fresh_distinct_and_clear_inherited_profile_metadata(self):
        old = dict(KEEP='value', LATTICE_SYNC_VISIBILITY_PERF='0', LATTICE_SYNC_VISIBILITY_PROFILE='wrong',
                   LATTICE_SYNC_VISIBILITY_RUN_ORDER='stale')
        plans = c.profile_plan(self.root, dict(metadata=METADATA), old)
        self.assertEqual([p['expectedCount'] for p in plans], [8201, 41])
        self.assertEqual([p['metadata']['RUN_ORDER'] for p in plans], ['1:loaded', '2:quiet-only'])
        self.assertNotEqual(plans[0]['directory'], plans[1]['directory'])
        for p in plans:
            self.assertEqual(p['env'][c.PREFIX + 'PERF'], '1')
            self.assertEqual(p['env'][c.PREFIX + 'PROFILE'], p['profile'])
            self.assertEqual(p['env']['KEEP'], 'value')
            self.assertFalse(p['directory'].exists())
        self.assertEqual(old[c.PREFIX + 'PERF'], '0')
        plans[1]['directory'].mkdir()
        with self.assertRaisesRegex(ValueError, 'unused'): c.profile_plan(self.root, dict(metadata=METADATA), old)

    def test_exact_full_and_quiet_denominators_and_metadata_required(self):
        for profile, count in c.PROFILES:
            data = fixture(full=True, quiet_only=profile == 'quiet-only')
            data['metadata'] = dict(METADATA, RUN_ORDER='expected')
            result = c.analyze_profile(data, profile, data['metadata'])
            self.assertTrue(result['qualified'])
            self.assertEqual(result['analysis']['receiptCount'], count)
            self.assertFalse(result['performanceAccepted'])
            self.assertFalse(result['experimentAccepted'])
            metadata = dict(data['metadata'], BUILD_ID='wrong')
            self.assertFalse(c.analyze_profile(data, profile, metadata)['qualified'])
            data['receipts'].pop()
            result = c.analyze_profile(data, profile, data['metadata'])
            self.assertFalse(result['qualified'])
            self.assertEqual(result['analysis']['expectedReceiptCount'], count)

    def test_smoke_changed_schedule_or_missing_origin_cannot_qualify_full(self):
        for mutation in ('smoke', 'deadline', 'origin', 'complete'):
            data = fixture(full=mutation != 'smoke', quiet_only=True)
            data['metadata'] = METADATA.copy()
            if mutation == 'deadline': data['deadlineNS'] += 1
            if mutation == 'origin': data['receipts'][0].pop('postcommitNS')
            if mutation == 'complete': data['complete'] = False
            self.assertFalse(c.analyze_profile(data, 'quiet-only', METADATA)['qualified'])

    def test_one_actual_test_completion_required(self):
        p = self.root / 'test.log'
        good = f'✔ Test {c.CASE}() passed after 40.001 seconds.\n'
        p.write_text(good); self.assertEqual(c.check_full_log(p), [c.CASE])
        for bad in ('Test run passed after 1 second.\n', good.replace('passed', 'skipped'), good + good,
                    good + '✔ Test smallPublicVisibilityQualification() passed after 1.0 seconds.\n'):
            p.write_text(bad)
            with self.assertRaises(ValueError): c.check_full_log(p)

    def test_secondary_control_requires_clean_ordinary_exit(self):
        self.assertTrue(c.clean_exit(command(False)))
        for changed in (dict(started=False), dict(exitCode=-11), dict(stopReason='command timeout'),
                        dict(primaryError={'type': 'Interrupted'}), dict(receivedSignals=['SIGTERM']),
                        dict(cleanup=dict(groupGone=True, leaderReaped=False)),
                        dict(cleanup=dict(groupGone=True, leaderReaped=True, signals=['SIGTERM'], errors=[])),
                        dict(evidenceErrors=['missing proof'])):
            self.assertFalse(c.clean_exit(command(**changed)))

    def fake_run(self, loaded='success', quiet='success'):
        root = self.root
        receipts = root / 'receipts'; receipts.mkdir()
        original = {'KEEP': 'original'}
        calls = []
        first = RuntimeError('loaded first failure')
        class FakeRunner:
            env = original
            interrupts = SimpleNamespace(received=[])
            def run(fake, label, argv, **kwargs):
                calls.append(dict(label=label, argv=argv, kwargs=kwargs, env=copy.deepcopy(fake.env)))
                profile = fake.env[c.PREFIX + 'PROFILE']
                behavior = loaded if profile == 'loaded' else quiet
                record = command(behavior == 'success', argv=argv)
                if behavior == 'unclean': record['cleanup']['groupGone'] = False
                if behavior == 'budget': record.update(started=False, exitCode=None, stopReason='overall budget cannot admit unchanged command timeout')
                c.save(receipts / (label + '.json'), record)
                if behavior != 'budget':
                    directory = Path(fake.env[c.PREFIX + 'RUN_DIR']); directory.mkdir()
                    data = fixture(full=True, quiet_only=profile == 'quiet-only')
                    data['metadata'] = {k: fake.env[c.PREFIX + k] for k in (*METADATA, 'RUN_ORDER')}
                    if behavior != 'success': data['complete'] = False
                    if behavior == 'wrong-metadata': data['metadata']['BUILD_ID'] = 'unbound'
                    if behavior == 'missing-operation': data['receipts'].pop()
                    if behavior == 'malformed-raw': (directory / 'receipts.json').write_text('{broken')
                    elif behavior != 'missing-raw': c.save(directory / 'receipts.json', data)
                terminal = (f'✔ Test {c.CASE}() passed after 40.0 seconds.\n' if behavior == 'success' else
                            f'✘ Test {c.CASE}() failed after 40.0 seconds with 1 issue.\n')
                if behavior == 'malformed-inventory': terminal = 'failed\n'
                if behavior == 'wrong-inventory': terminal = '✘ Test otherCase() failed after 40.0 seconds with 1 issue.\n'
                if behavior == 'contradictory-inventory': terminal = f'✔ Test {c.CASE}() passed after 40.0 seconds.\n'
                if behavior != 'missing-inventory': (receipts / (label + '.log')).write_text(terminal)
                if behavior != 'success': raise first if profile == 'loaded' else RuntimeError('quiet first failure')
                return receipts / (label + '.log')
        runner = FakeRunner(); runner.receipts = receipts
        def binding(*_):
            value = dict(metadata=METADATA)
            c.save(receipts / 'sync-full-calibration-binding.json', value)
            return value
        with patch.object(c, 'prepare_binding', binding):
            try: c.run(runner, root / 'sdk', root, ['--scratch-path', str(root / 'scratch')], {}, {})
            except BaseException as error: caught = error
            else: caught = None
        self.assertIs(runner.env, original)
        summary = json.loads((receipts / 'sync-full-calibration.json').read_text())
        for call in calls:
            self.assertEqual(call['kwargs']['timeout'], 300)
            self.assertIs(call['kwargs']['require_full_timeout'], True)
            self.assertEqual(call['argv'][-2:], ['--filter', c.FILTER])
            c.require_flags(call['argv'])
        return calls, summary, caught, first

    def test_success_runs_exactly_two_fresh_profiles_with_unchanged_bounds(self):
        calls, summary, caught, _ = self.fake_run()
        self.assertIsNone(caught); self.assertTrue(summary['qualified'])
        self.assertEqual([p['qualified'] for p in summary['profiles']], [True, True])
        self.assertNotEqual(calls[0]['env'][c.PREFIX + 'RUN_DIR'], calls[1]['env'][c.PREFIX + 'RUN_DIR'])

    def test_clean_loaded_failure_runs_control_but_preserves_original_failure(self):
        calls, summary, caught, first = self.fake_run(loaded='assertion')
        self.assertIs(caught, first); self.assertEqual(len(calls), 2)
        self.assertFalse(summary['qualified'])
        self.assertEqual([p['qualified'] for p in summary['profiles']], [False, True])
        report = json.loads((self.root / 'receipts/sync-full-loaded-qualification.json').read_text())
        self.assertTrue(report['evidenceUsable'])
        self.assertEqual(report['testInventory']['outcome'], 'failed')

    def assert_evidence_failure_stops_control(self, behavior):
        calls, summary, caught, first = self.fake_run(loaded=behavior)
        self.assertIs(caught, first)
        self.assertEqual(len(calls), 1)
        self.assertFalse(summary['qualified'])
        self.assertFalse(summary['profiles'][1]['started'])
        report = json.loads((self.root / 'receipts/sync-full-loaded-qualification.json').read_text())
        self.assertFalse(report['evidenceUsable'])
        command_receipt = json.loads((self.root / 'receipts/sync-full-loaded.json').read_text())
        self.assertTrue(c.clean_exit(command_receipt))

    def test_clean_exit_missing_raw_stops_control(self):
        self.assert_evidence_failure_stops_control('missing-raw')

    def test_clean_exit_malformed_raw_stops_control(self):
        self.assert_evidence_failure_stops_control('malformed-raw')

    def test_clean_exit_missing_inventory_stops_control(self):
        self.assert_evidence_failure_stops_control('missing-inventory')

    def test_clean_exit_malformed_inventory_stops_control(self):
        self.assert_evidence_failure_stops_control('malformed-inventory')

    def test_clean_exit_wrong_inventory_stops_control(self):
        self.assert_evidence_failure_stops_control('wrong-inventory')

    def test_clean_exit_contradictory_inventory_stops_control(self):
        self.assert_evidence_failure_stops_control('contradictory-inventory')

    def test_clean_exit_unbound_metadata_stops_control(self):
        self.assert_evidence_failure_stops_control('wrong-metadata')

    def test_clean_exit_missing_registered_operation_stops_control(self):
        self.assert_evidence_failure_stops_control('missing-operation')

    def test_missing_process_cleanup_never_starts_control(self):
        calls, summary, caught, first = self.fake_run(loaded='unclean')
        self.assertIs(caught, first); self.assertEqual(len(calls), 1)
        self.assertFalse(summary['profiles'][1]['started'])

    def test_budget_refusal_is_retained_unstarted_and_cannot_pass(self):
        calls, summary, caught, first = self.fake_run(loaded='budget')
        self.assertIs(caught, first); self.assertEqual(len(calls), 1)
        self.assertFalse(summary['profiles'][0]['started'])
        self.assertFalse(summary['qualified'])

    def test_control_budget_refusal_cannot_replace_loaded_first_failure(self):
        calls, summary, caught, first = self.fake_run(loaded='assertion', quiet='budget')
        self.assertIs(caught, first); self.assertEqual(len(calls), 2)
        self.assertFalse(summary['profiles'][1]['started'])
        self.assertFalse(summary['qualified'])

    def test_quiet_failure_fails_pair_after_successful_loaded(self):
        calls, summary, caught, _ = self.fake_run(quiet='assertion')
        self.assertEqual(len(calls), 2); self.assertIsNotNone(caught)
        self.assertFalse(summary['qualified'])
        self.assertEqual([p['qualified'] for p in summary['profiles']], [True, False])

    def test_smoke_and_full_cli_flags_conflict_before_any_work(self):
        path = Path(__file__).with_name('run-development.py')
        spec = importlib.util.spec_from_file_location('calibration_cli_test', path)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        argv = [str(path), '--root', str(self.root), '--core-sha', 'b' * 40, '--test-timeout', '1800',
                '--sync-probe-qualification', '--sync-full-calibration']
        with patch('sys.argv', argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            module.main()
        self.assertEqual(error.exception.code, 2)
        self.assertFalse((self.root / 'receipts').exists())

    def test_unavailable_refresh_mode_refuses_before_work(self):
        path = Path(__file__).with_name('run-development.py')
        spec = importlib.util.spec_from_file_location('calibration_refresh_cli_test', path)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        for extra in ([], ['--sync-probe-qualification'], ['--sync-full-calibration']):
            argv = [str(path), '--root', str(self.root), '--core-sha', 'b' * 40,
                    '--test-timeout', '1800', '--recovery-refresh-qualification', *extra]
            with self.subTest(extra=extra), patch('sys.argv', argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                module.main()
            self.assertEqual(error.exception.code, 2)
            self.assertFalse((self.root / 'receipts').exists())


if __name__ == '__main__': unittest.main()
