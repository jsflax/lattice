#!/usr/bin/env python3
"""Owning mechanism tests; no Swift/native benchmark or app is launched."""
import hashlib
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HERE = Path(__file__).resolve().parent
AUTH = load('source_auth_under_test', HERE / 'sync_matched_source_auth.py')
DEVELOPMENT = load('actual_auth_guard', HERE / 'run-development.py')


class SourceAuthenticationBatch(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ['LATTICE_MATCHED_AUTH_TEST_ROOT']).resolve(strict=True)
        self.assertTrue(base.is_relative_to((Path.home() / 'localdev').resolve(strict=True)))
        self.temporary = tempfile.TemporaryDirectory(prefix='source-auth-', dir=base)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.graph = self.root / 'graph'
        self.graph.mkdir()
        self.receipts = self.root / 'receipts'
        self.receipts.mkdir()
        self.git = shutil.which('git')
        self.assertIsNotNone(self.git)
        self.env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')

    def git_command(self, repository, *args):
        return subprocess.run([self.git, *args], cwd=repository, check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

    def repository(self, name):
        path = self.graph / name
        path.mkdir()
        self.git_command(path, 'init', '-q')
        (path / 'original.txt').write_bytes(b'actual tracked source\n')
        os.symlink('original.txt', path / 'original-link')
        if name == 'lattice':
            (path / 'Scripts').mkdir()
            for source in ('run-development.py', 'sync_matched_source_auth.py', 'sync_matched_experiment.py'):
                shutil.copyfile(HERE / source, path / 'Scripts' / source)
        self.git_command(path, 'add', '.')
        self.git_command(path, '-c', 'user.name=Qualification', '-c', 'user.email=qualification@example.invalid',
                         'commit', '-q', '-m', 'own immutable test source')
        names = self.git_command(path, 'ls-files', '-z').decode().split('\0')
        return {'path': str(path), 'commit': self.git_command(path, 'rev-parse', 'HEAD').decode().strip(),
                'files': DEVELOPMENT.tracked_manifest(path, names)}

    def prepared_data(self, entries):
        names = ('Scripts/sync_matched_source_auth.py', 'Scripts/sync_matched_experiment.py')
        return {'root': str(self.graph), 'source': {'sdk': entries[0]},
                'measurementFiles': {name: {'bytes': (HERE.parent / name).stat().st_size,
                    'sha256': hashlib.sha256((HERE.parent / name).read_bytes()).hexdigest()} for name in names}}

    def invoke(self, entries, *, expired=False, recorded_helper=False):
        issued = time.monotonic() - (61 if expired else 0)
        if recorded_helper:
            worker = AUTH.prepare_leg_worker(self.receipts, 'batch', self.prepared_data(entries),
                                             HERE / 'sync_matched_experiment.py')
        else:
            worker = AUTH.prepare_worker(self.receipts, 'batch', self.prepared_data(entries), DEVELOPMENT,
                                         HERE / 'sync_matched_experiment.py')
        request = self.receipts / 'REQUEST.json'
        request.write_text(json.dumps({'schema': 'lattice.sync-matched-source-auth-request/1',
            'root': str(self.graph), 'entries': entries, 'issuedMonotonic': issued,
            'deadlineMonotonic': issued + AUTH.BATCH_SECONDS}) + '\n')
        outputs = self.receipts / 'source-auth'
        with DEVELOPMENT.Interrupts() as interrupts:
            runner = DEVELOPMENT.GuardedRunner(self.root, self.receipts, self.env, interrupts,
                free_floor=0, packet_ceiling=2**30, log_ceiling=2**24,
                overall_seconds=75, reserve=2, poll_seconds=0.01, signal_grace=1)
            error = None
            try:
                runner.run('batch', [sys.executable, '-I', '-S', '-B', str(worker),
                           '--request', str(request), '--outputs', str(outputs)], cwd=self.graph,
                           # Expired negative explicitly reaches the worker's own expiry fence.
                           timeout=AUTH.BATCH_SECONDS if expired else AUTH.remaining(issued + AUTH.BATCH_SECONDS))
            except BaseException as caught:
                error = caught
        outer = json.loads((self.receipts / 'batch.json').read_text())
        report = json.loads((self.receipts / 'batch.log').read_text())
        return error, outer, report, outputs

    def wrapper(self, suffix):
        directory = self.root / 'negative-command-fixture'
        directory.mkdir()
        path = directory / 'git'
        path.write_text('#!' + sys.executable + '\nimport subprocess,sys\n'
            + 'actual=subprocess.run(' + repr([self.git]) + '+sys.argv[1:])\n'
            + 'if actual.returncode: sys.exit(actual.returncode)\n' + suffix)
        path.chmod(0o700)
        self.env['PATH'] = str(directory) + os.pathsep + os.environ['PATH']

    def test_exact_sources_symlink_outputs_and_real_same_group_waits(self):
        entries = [self.repository('lattice'), self.repository('LatticeCore')]
        original = [DEVELOPMENT.tracked_manifest(Path(entry['path']), entry['files']) for entry in entries]
        error, outer, report, outputs = self.invoke(entries)
        self.assertIsNone(error)
        self.assertTrue(outer['success'])
        self.assertTrue(outer['cleanup']['groupGone'])
        self.assertTrue(outer['cleanup']['leaderReaped'])
        self.assertEqual(outer['cleanup']['signals'], [])
        self.assertTrue(report['success'])
        AUTH.verify_success(report, hashlib.sha256((self.receipts / 'REQUEST.json').read_bytes()).hexdigest(),
                            entries, self.graph, outputs, outer,
                            json.loads((self.receipts / 'REQUEST.json').read_text())['deadlineMonotonic'])
        self.assertEqual(len(report['repositories']), 2)
        commands = [row for row in report['commands'] if row['kind'] in ('head', 'status')]
        self.assertEqual(len(commands), 4)
        for ordinal, entry in enumerate(entries):
            self.assertEqual((outputs / f'{ordinal:03d}-head.log').read_text().strip(), entry['commit'])
            self.assertEqual((outputs / f'{ordinal:03d}-status.log').read_bytes(), b'')
        for row in report['commands']:
            self.assertTrue(row['leaderReaped'])
            self.assertEqual(row['exitCode'], 0)
            self.assertEqual(row['childPGID'], report['ownedPGID'])
            self.assertNotIn('groupGone', row)  # Only the actual outer owner ends the whole group.
        self.assertEqual(original, [DEVELOPMENT.tracked_manifest(Path(entry['path']), entry['files']) for entry in entries])

    def test_distinct_recorded_leg_entries_use_one_outer_owner_and_swaps_refuse(self):
        # Two real SDK repositories differ in valid entry definitions. Both
        # authenticate through real Git children under the SAME outer class.
        legs = []
        outer_class = DEVELOPMENT.GuardedRunner
        for label in ('A', 'B'):
            parent = self.root / label
            parent.mkdir()
            self.graph = parent / 'graph'; self.graph.mkdir()
            self.receipts = parent / 'receipts'; self.receipts.mkdir()
            entry = self.repository('lattice')
            path = self.graph / 'lattice/Scripts/run-development.py'
            path.write_text(path.read_text() + '\ndef qualification_entry_variant():\n    return ' + repr(label) + '\n')
            self.git_command(Path(entry['path']), 'add', 'Scripts/run-development.py')
            self.git_command(Path(entry['path']), '-c', 'user.name=Qualification',
                             '-c', 'user.email=qualification@example.invalid',
                             'commit', '-q', '-m', 'actual distinct ' + label + ' entry')
            entry['commit'] = self.git_command(Path(entry['path']), 'rev-parse', 'HEAD').decode().strip()
            entry['files'] = DEVELOPMENT.tracked_manifest(Path(entry['path']), entry['files'])
            selected = AUTH.load_development(self.graph, entry)
            self.assertEqual(selected.qualification_entry_variant(), label)
            data = self.prepared_data([entry])
            error, outer, report, outputs = self.invoke([entry], recorded_helper=True)
            self.assertIsNone(error)
            self.assertTrue(outer['success'] and report['success'])
            self.assertTrue(outer['cleanup']['leaderReaped'] and outer['cleanup']['groupGone'])
            self.assertEqual(outer['cleanup']['signals'], [])
            request = json.loads((self.receipts / 'REQUEST.json').read_text())
            AUTH.verify_success(report, hashlib.sha256((self.receipts / 'REQUEST.json').read_bytes()).hexdigest(),
                                [entry], self.graph, outputs, outer, request['deadlineMonotonic'])
            self.assertIs(DEVELOPMENT.GuardedRunner, outer_class)
            legs.append((entry, selected, data, path.read_bytes()))
        self.assertNotEqual(legs[0][0]['files']['Scripts/run-development.py'],
                            legs[1][0]['files']['Scripts/run-development.py'])
        # Supplying A's already loaded helper as B's delegate is still refused
        # before a captured executable is created. No common-helper waiver.
        with self.assertRaisesRegex(ValueError, 'supplier bytes changed before execution'):
            AUTH.prepare_worker(self.receipts, 'swapped', legs[1][2], legs[0][1],
                                HERE / 'sync_matched_experiment.py')
        self.assertFalse((self.receipts / 'swapped-WORKER.py').exists())
        # Replacing the actual B supplier with A also refuses BEFORE loading it.
        b_path = Path(legs[1][0]['path']) / 'Scripts/run-development.py'
        b_path.write_bytes(legs[0][3])
        with self.assertRaisesRegex(ValueError, 'supplier bytes changed before execution'):
            AUTH.prepare_leg_worker(self.receipts, 'replaced', legs[1][2],
                                    HERE / 'sync_matched_experiment.py')
        self.assertFalse((self.receipts / 'replaced-WORKER.py').exists())

    def test_parent_refuses_changed_retained_output_after_real_success(self):
        entries = [self.repository('lattice')]
        error, outer, report, outputs = self.invoke(entries)
        self.assertIsNone(error)
        (outputs / '000-head.log').write_text('0' * 40 + '\n')
        with self.assertRaisesRegex(ValueError, 'bytes/wait/group changed'):
            AUTH.verify_success(report, hashlib.sha256((self.receipts / 'REQUEST.json').read_bytes()).hexdigest(),
                                entries, self.graph, outputs, outer,
                                json.loads((self.receipts / 'REQUEST.json').read_text())['deadlineMonotonic'])

    def test_parent_refuses_late_acceptance_after_real_success(self):
        entries = [self.repository('lattice')]
        error, outer, report, outputs = self.invoke(entries)
        self.assertIsNone(error)
        with self.assertRaisesRegex(TimeoutError, 'batch deadline expired'):
            AUTH.verify_success(report, hashlib.sha256((self.receipts / 'REQUEST.json').read_bytes()).hexdigest(),
                                entries, self.graph, outputs, outer, time.monotonic() - 1)

    def test_changed_prepared_worker_refuses_before_captured_executable_creation(self):
        entries = [self.repository('lattice')]
        data = self.prepared_data(entries)
        sentinel = self.root / 'untrusted-worker-ran'
        (self.graph / 'lattice/Scripts/sync_matched_source_auth.py').write_text(
            'from pathlib import Path\nPath(' + repr(str(sentinel)) + ').touch()\n')
        with self.assertRaisesRegex(ValueError, 'supplier bytes changed before execution'):
            AUTH.prepare_worker(self.receipts, 'batch', data, DEVELOPMENT, HERE / 'sync_matched_experiment.py')
        self.assertFalse(sentinel.exists())
        self.assertFalse((self.receipts / 'batch-WORKER.py').exists())

    def test_changed_delegated_development_refuses_before_import_side_effect(self):
        entries = [self.repository('lattice')]
        sentinel = self.root / 'untrusted-development-ran'
        (self.graph / 'lattice/Scripts/run-development.py').write_text(
            'from pathlib import Path\nPath(' + repr(str(sentinel)) + ').touch()\n')
        error, _, report, _ = self.invoke(entries)
        self.assertIsNotNone(error)
        self.assertIn('supplier bytes changed before execution', report['firstFailure']['message'])
        self.assertEqual(report['commands'], [])
        self.assertFalse(sentinel.exists())

    def test_changed_tracked_bytes_refuse_before_first_git(self):
        entry = self.repository('lattice')
        (Path(entry['path']) / 'original.txt').write_text('changed\n')
        error, outer, report, _ = self.invoke([entry])
        self.assertIsNotNone(error)
        self.assertFalse(outer['success'])
        self.assertFalse(report['success'])
        self.assertIn('tracked bytes changed', report['firstFailure']['message'])
        self.assertEqual(report['commands'], [])

    def test_actual_new_head_refuses_before_status(self):
        entry = self.repository('lattice')
        path = Path(entry['path'])
        (path / 'new.txt').write_text('new tracked object\n')
        self.git_command(path, 'add', 'new.txt')
        self.git_command(path, '-c', 'user.name=Qualification', '-c', 'user.email=qualification@example.invalid',
                         'commit', '-q', '-m', 'genuine changed head')
        error, _, report, outputs = self.invoke([entry])
        self.assertIsNotNone(error)
        self.assertIn('identity changed', report['firstFailure']['message'])
        self.assertTrue((outputs / '000-head.log').is_file())
        self.assertFalse((outputs / '000-status.log').exists())

    def test_actual_untracked_source_refuses(self):
        entry = self.repository('lattice')
        (Path(entry['path']) / 'unexpected.txt').write_text('unexpected\n')
        error, _, report, outputs = self.invoke([entry])
        self.assertIsNotNone(error)
        self.assertIn('state changed', report['firstFailure']['message'])
        self.assertIn(b'unexpected.txt', (outputs / '000-status.log').read_bytes())

    def test_only_original_sdk_resolved_change_is_allowed(self):
        entry = self.repository('lattice')
        (Path(entry['path']) / 'Package.resolved').write_text('same original allowed spelling\n')
        error, _, report, outputs = self.invoke([entry])
        self.assertIsNone(error)
        self.assertTrue(report['success'])
        self.assertEqual((outputs / '000-status.log').read_bytes(), b'?? Package.resolved\0')

    def test_fixed_expired_batch_never_starts_a_child_or_creates_output_root(self):
        entry = self.repository('lattice')
        error, _, report, outputs = self.invoke([entry], expired=True)
        self.assertIsNotNone(error)
        self.assertIn('deadline expired', report['firstFailure']['message'])
        self.assertEqual(report['commands'], [])
        self.assertFalse(outputs.exists())

    def test_actual_overflow_preserves_partial_and_refuses_without_parsing_it(self):
        entry = self.repository('lattice')
        # Negative-only executable calls the REAL Git first, then emits overflow.
        self.wrapper('sys.stdout.write("X" * (' + str(AUTH.OUTPUT_LIMIT) + '+1))\nsys.stdout.flush()\n')
        error, outer, report, outputs = self.invoke([entry])
        self.assertIsNotNone(error)
        self.assertFalse(outer['success'])
        self.assertIn('output overflow', report['firstFailure']['message'])
        self.assertGreater((outputs / '000-head.log').stat().st_size, AUTH.OUTPUT_LIMIT)
        self.assertFalse((outputs / '000-status.log').exists())
        self.assertTrue(outer['cleanup']['groupGone'])

    def test_actual_residual_descendant_refuses_next_command_and_outer_cleans_group(self):
        entry = self.repository('lattice')
        # Negative-only child is real, inherits the owned group, never detaches.
        self.wrapper('subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"],'
                     'start_new_session=False)\n')
        error, outer, report, outputs = self.invoke([entry])
        self.assertIsNotNone(error)
        self.assertIn('not worker-only', report['firstFailure']['message'])
        self.assertFalse((outputs / '000-status.log').exists())
        self.assertTrue(outer['cleanup']['groupGone'])
        self.assertTrue(outer['cleanup']['leaderReaped'])
        self.assertIn('SIGTERM', outer['cleanup']['signals'])

    def test_bounded_regular_reader_refuses_size_and_symlink_before_parsing(self):
        original = self.root / 'original'
        original.write_bytes(b'12345')
        with self.assertRaisesRegex(ValueError, 'bounded regular'):
            AUTH.read_regular(original, 4)
        alias = self.root / 'alias'
        alias.symlink_to(original.name)
        with self.assertRaises(OSError):
            AUTH.read_regular(alias, 10)
        fifo = self.root / 'actual-fifo'
        os.mkfifo(fifo, 0o600)
        with self.assertRaisesRegex(ValueError, 'bounded regular'):
            AUTH.read_regular(fifo, 10)
        self.assertEqual(original.read_bytes(), b'12345')



class SharedProcessClockAdmission(unittest.TestCase):
    def test_old_mac_refuses_before_any_supplier_or_worker_effect(self):
        with mock.patch.object(AUTH.sys, 'platform', 'darwin'), \
                mock.patch.object(AUTH.sys, 'version_info', (3, 9, 6)), \
                mock.patch.object(AUTH, 'authenticated_source') as read:
            for call in (lambda: AUTH.prepare_worker(None,None,None,None,None),
                         lambda: AUTH.prepare_leg_worker(None,None,None,None),
                         lambda: AUTH.remaining(12345)):
                with self.assertRaisesRegex(RuntimeError, 'shared monotonic clock'):
                    call()
            read.assert_not_called()

    def test_old_mac_worker_reports_refusal_before_request_read_or_outputs(self):
        wire = io.StringIO()
        with mock.patch.object(AUTH.sys, 'platform', 'darwin'), \
                mock.patch.object(AUTH.sys, 'version_info', (3, 9, 6)), \
                mock.patch.object(AUTH, 'read_regular') as read, contextlib.redirect_stdout(wire):
            self.assertEqual(AUTH.authenticate(None, None), 1)
            read.assert_not_called()
        report = json.loads(wire.getvalue())
        self.assertFalse(report['success'])
        self.assertIn('shared monotonic clock', report['firstFailure']['message'])
        self.assertEqual(report['commands'], [])
        self.assertEqual(report['repositories'], [])

    def test_actual_supported_runtime_child_uses_parent_monotonic_origin(self):
        AUTH.require_shared_process_clock()
        before = time.monotonic()
        child = subprocess.run([sys.executable, '-I', '-S', '-B', '-c',
                                'import time; print(time.monotonic())'],
                               check=True, capture_output=True, text=True, timeout=10)
        after = time.monotonic()
        self.assertLessEqual(before, float(child.stdout))
        self.assertLessEqual(float(child.stdout), after)

if __name__ == '__main__':
    unittest.main()
