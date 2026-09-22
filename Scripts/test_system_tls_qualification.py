"""Pure helper tests: no native process, Security.framework, cert or trust use."""
import contextlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import system_tls_trust as trust
import system_tls_qualification as qualification

ROOT = Path(__file__).resolve().parents[2] / 'preparation' / 'sdk-system-tls-qualification-001' / 'pure-test-scratch'


class Fixture(unittest.TestCase):
    def setUp(self):
        ROOT.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT)
        self.root = Path(self.temporary.name)
    def tearDown(self): self.temporary.cleanup()


class TrustClassification(Fixture):
    def test_only_typed_absence_is_empty(self):
        self.assertEqual(trust.classify_trust(-25263, None), {'status': -25263, 'inventory': {}})
        for status, raw in [(-25293, None), (-36, None), (1, None), (0, None), (-25263, b'')]:
            with self.assertRaises(ValueError): trust.classify_trust(status, raw)

    def test_empty_success_is_logically_empty_without_claiming_byte_absence(self):
        raw = plistlib.dumps({'trustVersion': 1, 'trustList': {}})
        value = trust.classify_trust(0, raw)
        self.assertEqual(value['inventory'], {})
        self.assertEqual(value['status'], 0)
        self.assertIn('rawSHA256', value)

    def test_serialized_trust_entries_preserve_bytes_dates_and_members(self):
        raw = plistlib.dumps({'trustVersion': 1, 'trustList': {'EXACT': {'policy': b'\x00\x01', 'result': 1}}})
        self.assertEqual(trust.classify_trust(0, raw)['inventory']['EXACT'], {'policy': {'data': 'AAE='}, 'result': 1})
        for value in [{'trustVersion': 2, 'trustList': {}}, {'trustVersion': 1, 'trustList': {}, 'unknown': 1}, {'trustVersion': 1, 'trustList': []}]:
            with self.assertRaises(ValueError): trust.classify_trust(0, plistlib.dumps(value))

    def test_nested_trust_is_bounded(self):
        value = 1
        for _ in range(34): value = [value]
        with self.assertRaises(ValueError): trust.canonical(value)
        with self.assertRaises(ValueError): trust.canonical([1, 2], budget=[2])

    def test_exact_pem_inventory_rejects_text_and_malformed_base64(self):
        self.assertEqual(trust.certificates(b''), [])
        self.assertEqual(trust.certificates(b'-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n'), [b'abc'])
        with self.assertRaises(ValueError): trust.certificates(b'command failed')
        with self.assertRaises(ValueError): trust.certificates(b'-----BEGIN CERTIFICATE-----\n?\n-----END CERTIFICATE-----')

    def test_bundle_drift_never_calls_replacement(self):
        bundle = self.root / 'bundle'; bundle.write_bytes(b'foreign')
        armed = {'state': {'platform': 'Linux', 'nonce': '0' * 32}, 'baseline': {'sha256': trust.sha(b'before'), 'installedSHA256': trust.sha(b'installed')}}
        with patch.object(trust, 'BUNDLE', bundle), patch.object(trust, 'replace_bundle') as replacement:
            with self.assertRaisesRegex(ValueError, 'foreign Linux bundle drift'): trust.cleanup(self.root, armed, None)
            replacement.assert_not_called()

    def test_partial_install_original_bytes_cleanup_without_rewrite(self):
        bundle = self.root / 'bundle'; bundle.write_bytes(b'before')
        (self.root / 'private').mkdir(); (self.root / 'receipts').mkdir()
        (self.root / 'private/bundle.before').write_bytes(b'before')
        metadata = {'mode': 420, 'uid': 0, 'gid': 0}
        armed = {'state': {'platform': 'Linux', 'nonce': '0' * 32}, 'baseline': {'sha256': trust.sha(b'before'), 'installedSHA256': trust.sha(b'installed'), 'metadata': metadata}}
        with patch.object(trust, 'BUNDLE', bundle), patch.object(trust, 'bundle_metadata', return_value=metadata), patch.object(trust, 'replace_bundle') as replacement:
            trust.cleanup(self.root, armed, None); replacement.assert_not_called()
        self.assertTrue(json.loads((self.root / 'receipts/RESTORED.json').read_text())['success'])

    def test_successful_cleanup_recheck_preserves_first_receipt(self):
        bundle = self.root / 'bundle'; bundle.write_bytes(b'before')
        (self.root / 'private').mkdir(); (self.root / 'receipts').mkdir(); (self.root / 'private/bundle.before').write_bytes(b'before')
        metadata = {'mode': 420, 'uid': 0, 'gid': 0}
        armed = {'state': {'platform': 'Linux', 'nonce': '0' * 32}, 'baseline': {'sha256': trust.sha(b'before'), 'installedSHA256': trust.sha(b'installed'), 'metadata': metadata}}
        with patch.object(trust, 'BUNDLE', bundle), patch.object(trust, 'bundle_metadata', return_value=metadata), patch.object(trust, 'replace_bundle') as replacement:
            trust.cleanup(self.root, armed, None)
            first = (self.root / 'receipts/RESTORED.json').read_bytes()
            trust.cleanup(self.root, armed, None)
            self.assertEqual((self.root / 'receipts/RESTORED.json').read_bytes(), first)
            self.assertEqual((self.root / 'receipts/RESTORED-RECHECK.json').read_bytes(), first)
            replacement.assert_not_called()

    def test_installed_linux_bytes_restore_exact_preimage(self):
        bundle = self.root / 'bundle'; bundle.write_bytes(b'installed')
        (self.root / 'private').mkdir(); (self.root / 'receipts').mkdir(); (self.root / 'private/bundle.before').write_bytes(b'before')
        metadata = {'mode': 420, 'uid': 0, 'gid': 0}
        armed = {'state': {'platform': 'Linux', 'nonce': '0' * 32}, 'baseline': {'sha256': trust.sha(b'before'), 'installedSHA256': trust.sha(b'installed'), 'metadata': metadata}}
        calls = []
        def replacement(raw, meta, nonce): calls.append((raw, meta, nonce)); bundle.write_bytes(raw)
        with patch.object(trust, 'BUNDLE', bundle), patch.object(trust, 'bundle_metadata', return_value=metadata), patch.object(trust, 'replace_bundle', side_effect=replacement):
            trust.cleanup(self.root, armed, None)
        self.assertEqual(calls, [(b'before', metadata, '0' * 32)])

    def test_hosted_guard_refuses_local_before_any_runtime(self):
        with self.assertRaisesRegex(ValueError, 'explicitly hosted'): trust.hosted(self.root, {}, 'Darwin')
        with patch.object(trust.ctypes, 'CDLL') as load:
            with self.assertRaises(ValueError): trust.hosted(self.root, {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted'}, 'Darwin')
            load.assert_not_called()


class CaseInventory(Fixture):
    def config(self): return {'nonce': 'owned', 'trustedCertificateSHA256': 'trusted', 'unknownCertificateSHA256': 'unknown'}
    def events(self):
        events = []
        for name in qualification.CASES:
            base = {'nonce': 'owned', 'case': name, 'adapter': 'stock-NIO-system-roots'}
            events.append({**base, 'phase': 'started'})
            plain = name == 'plain_ws_untrusted'; negative = name in ('hostname_mismatch', 'independent_unknown_ca'); redirect = name == 'redirect_disqualified'
            count = 2 if name == 'trusted_wss_reconnect' else 1
            host = '127.0.0.1' if plain or name == 'hostname_mismatch' else 'localhost'
            events.append({**base, 'phase': 'completed', 'certificateSHA256': 'none' if plain else 'unknown' if name == 'independent_unknown_ca' else 'trusted',
                'serverShutdown': True, 'proofAfterClose': False, 'proofBeforeClose': name in ('trusted_wss_open_close', 'trusted_wss_reconnect'),
                'port': 12345, 'opens': 0 if negative or redirect else count, 'serverOpens': 0 if negative or redirect else count,
                'errors': 1 if negative or redirect else 0, 'redirects': int(redirect),
                'url': f'{"ws" if plain else "wss"}://{host}:12345/{"redirect" if redirect else "tls"}'})
        return events
    def log(self, events, suffix=''):
        path = self.root / 'cases.log'
        path.write_text('◇ Test hostedSystemTrustMatrix() started.\n' + ''.join(qualification.PREFIX + json.dumps(x) + '\n' for x in events) +
                        '✔ Test hostedSystemTrustMatrix() passed after 1.0 seconds.\n✔ Test run with 1 test in 1 suite passed after 1.0 seconds.\n' + suffix)
        return path
    def test_all_cases_execute_and_positive_proofs_required(self):
        self.assertEqual(len(qualification.validate_cases(self.log(self.events()), self.config(), 'Linux')), 12)
        events = self.events(); events[3]['proofBeforeClose'] = False
        with self.assertRaises(ValueError): qualification.validate_cases(self.log(events), self.config(), 'Linux')
    def test_missing_duplicate_foreign_and_skipped_events_refuse(self):
        for edit in ('missing', 'duplicate', 'foreign', 'skip', 'redirect'):
            events = self.events(); suffix = ''
            if edit == 'missing': events.pop()
            if edit == 'duplicate': events[-1] = events[-2]
            if edit == 'foreign': events[-1]['nonce'] = 'wrong'
            if edit == 'skip': suffix = '◇ Test skipped\n'
            if edit == 'redirect': events[-1]['redirects'] = 0
            with self.subTest(edit=edit), self.assertRaises(ValueError): qualification.validate_cases(self.log(events, suffix), self.config(), 'Linux')
    def test_source_inventory_matches_one_new_actual_fixture(self):
        sdk = Path(__file__).resolve().parents[1]
        self.assertEqual(qualification.source_inventory(sdk)['identifiers'], [qualification.IDENTITY])


class FakeProcess:
    pid = 777
    returncode = 0
    def poll(self): return self.returncode


class CleanupCommand(Fixture):
    def runner(self):
        class Runner:
            overall_deadline = 1000
            env = {}; records = []
            class Interrupts:
                received = ['SIGTERM']
                @staticmethod
                def hold(): return contextlib.nullcontext()
            interrupts = Interrupts()
            def run(self, *_args, **_kwargs): raise AssertionError('ordinary run must never be called after signal')
            def cleanup(self, process): return {'groupGone': True, 'leaderReaped': True}
            def measure(self, _log): return {}
            def violation(self, _sample): return None
        runner = Runner(); runner.records = []; runner.receipts = self.root
        (self.root / 'OWNERSHIP.json').write_text(json.dumps({'overallDeadline': 1000}))
        return runner
    def test_signal_cleanup_does_not_resume_normal_runner_or_clear_signal(self):
        runner = self.runner()
        with patch.object(trust, 'hosted'), patch.object(qualification.time, 'monotonic', return_value=100), patch.object(qualification.subprocess, 'Popen', return_value=FakeProcess()) as launch:
            qualification.cleanup_command(runner, self.root, self.root)
        self.assertEqual(launch.call_args.args[0][2], 'cleanup')
        self.assertEqual(runner.interrupts.received, ['SIGTERM'])
        record = json.loads((self.root / 'system-tls-trust-cleanup.json').read_text())
        self.assertTrue(record['success']); self.assertTrue(record['cleanupOnly']); self.assertEqual(record['receivedSignals'], ['SIGTERM'])
    def test_cleanup_deadline_refuses_launch(self):
        runner = self.runner()
        with patch.object(trust, 'hosted'), patch.object(qualification.time, 'monotonic', return_value=1001), patch.object(qualification.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(RuntimeError, 'deadline exhausted'): qualification.cleanup_command(runner, self.root, self.root)
            launch.assert_not_called()
    def test_cleanup_first_error_survives_secondary_resource_failure(self):
        runner = self.runner(); runner.violation = lambda _: 'artifact ceiling'
        process = FakeProcess(); process.returncode = 7
        with patch.object(trust, 'hosted'), patch.object(qualification.time, 'monotonic', return_value=100), patch.object(qualification.subprocess, 'Popen', return_value=process):
            with self.assertRaisesRegex(RuntimeError, 'restoration helper failed'): qualification.cleanup_command(runner, self.root, self.root)
        record = json.loads((self.root / 'system-tls-trust-cleanup.json').read_text())
        self.assertFalse(record['success']); self.assertEqual(record['evidenceErrors'], [{'message': 'artifact ceiling'}])
    def test_cleanup_requires_original_deadline(self):
        runner = self.runner(); runner.overall_deadline = 1100
        with patch.object(trust, 'hosted'), patch.object(qualification.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(ValueError, 'original runner'): qualification.cleanup_command(runner, self.root, self.root)
            launch.assert_not_called()
    def test_owned_process_proof_missing_refuses_trust_cleanup(self):
        runner = self.runner(); runner.records = [{'label': 'system-tls-fixtures'}]
        (self.root / 'system-tls-fixtures.json').write_text(json.dumps({'cleanup': {'groupGone': False, 'leaderReaped': True}}))
        with self.assertRaisesRegex(RuntimeError, 'retirement proof'): qualification.owned_commands_gone(runner)


if __name__ == '__main__':
    unittest.main()
