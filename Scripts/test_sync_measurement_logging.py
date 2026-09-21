"""Pure controls/receipt tests; no native process or SQLite work."""
import unittest
import sync_measurement_logging as m

class MeasurementLoggingTests(unittest.TestCase):
    def test_environment_removes_presence_controls_and_preserves_unrelated_values(self):
        original = {'LOG_LEVEL': 'debug', 'LATTICE_DUMP_SQL': '0', 'LATTICE_LOG_LEVEL': '4',
                    'LATTICE_ACK_PATH_DIAGNOSTICS': '1', 'LATTICE_OBSERVER_WORKER_DIAGNOSTICS': '1',
                    'KEEP': 'value', 'LATTICE_TEST_LOG_PATH': '/owned/native.log'}
        before = dict(original); controlled = m.apply_environment(original)
        self.assertEqual(original, before)
        self.assertEqual(controlled[m.CONTROL], m.POLICY)
        self.assertNotIn('LOG_LEVEL', controlled); self.assertNotIn('LATTICE_DUMP_SQL', controlled)
        for key in ['LATTICE_LOG_LEVEL', 'LATTICE_ACK_PATH_DIAGNOSTICS', 'LATTICE_OBSERVER_WORKER_DIAGNOSTICS']:
            self.assertEqual(controlled[key], '0')
        self.assertEqual(controlled['KEEP'], 'value')
        self.assertEqual(controlled['LATTICE_TEST_LOG_PATH'], '/owned/native.log')
        m.require_controls(controlled)

    def test_control_application_is_idempotent(self):
        value = m.apply_environment({'KEEP': 'value'})
        self.assertEqual(m.apply_environment(value), value)

    def test_absent_diagnostic_switches_have_the_disabled_source_semantics(self):
        m.require_controls({})
        m.require_controls({'LATTICE_ACK_PATH_DIAGNOSTICS': '0', 'LATTICE_OBSERVER_WORKER_DIAGNOSTICS': '0'})

    def test_present_sql_dump_is_refused_even_when_empty_or_zero(self):
        for value in ['', '0', '1']:
            with self.subTest(value=value), self.assertRaises(ValueError): m.require_controls({'LATTICE_DUMP_SQL': value})

    def test_inherited_framework_level_and_enabled_or_ambiguous_diagnostics_refuse(self):
        for key in ['LOG_LEVEL', 'LATTICE_ACK_PATH_DIAGNOSTICS', 'LATTICE_OBSERVER_WORKER_DIAGNOSTICS']:
            for value in ['1', 'debug', 'false', '']:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError): m.require_controls({key: value})

    def test_complete_attestation_allows_unrelated_metadata(self):
        value = dict(m.ATTESTATION, SDK_REVISION='a' * 40)
        self.assertTrue(m.metadata_valid(value)); m.require_metadata(value)

    def test_each_missing_or_contradictory_attestation_field_refuses(self):
        for key in m.ATTESTATION:
            for replacement in [None, 'unspecified', '1']:
                value = dict(m.ATTESTATION)
                if replacement is None: value.pop(key)
                else: value[key] = replacement
                with self.subTest(key=key, replacement=replacement), self.assertRaises(ValueError): m.require_metadata(value)

    def test_old_declared_policy_cannot_relabel_prior_receipts(self):
        for value in [{'LOGGING': 'unspecified'}, {'LOGGING': 'existing runner environment'}, {'LOGGING': m.POLICY}]:
            self.assertFalse(m.metadata_valid(value))
            with self.assertRaises(ValueError): m.require_metadata(value)


class MeasurementLoggingGateTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        from pathlib import Path
        self.temporary = tempfile.TemporaryDirectory(prefix='.logging-test-', dir=Path(__file__).resolve().parents[1])
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def smoke(self, metadata, complete=True):
        import json
        import sync_probe_qualification as q
        from test_evaluate_sync import fixture
        root = self.root / str(len(list(self.root.iterdir())))
        (root / 'visibility-smoke').mkdir(parents=True)
        receipts = root / 'qualification'; receipts.mkdir()
        data = fixture(); data.update(metadata=metadata, complete=complete)
        raw = root / 'visibility-smoke/receipts.json'
        raw.write_text(json.dumps(data))
        before = raw.read_bytes()
        try:
            q.qualify_public_receipts(root, receipts)
        finally:
            self.assertEqual(raw.read_bytes(), before)
            self.assertTrue((receipts / 'public-visibility-qualification.json').is_file())

    def test_smoke_gate_requires_actual_complete_logging_attestation(self):
        self.smoke(dict(m.ATTESTATION))
        for changes in ({'LOGGING': 'unspecified'}, {'nativeLoggingLevelAtStart': '1'},
                        {'nativeLoggingLevelAtEnd': '4'}, {'nativeLoggingSink': 'unknown'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.smoke(dict(m.ATTESTATION, **changes))
        with self.assertRaises(ValueError): self.smoke({'LOGGING': m.POLICY})

    def test_logging_cannot_override_the_existing_smoke_completion_failure(self):
        with self.assertRaisesRegex(ValueError, 'ten exact operations'):
            self.smoke(dict(m.ATTESTATION), complete=False)

    def test_full_gate_rejects_missing_or_failed_readback_even_with_matching_declared_metadata(self):
        import sync_full_calibration as c
        from test_evaluate_sync import fixture
        data = fixture(full=True, quiet_only=True)
        data['metadata'] = dict(m.ATTESTATION)
        self.assertTrue(c.analyze_profile(data, 'quiet-only', data['metadata'])['qualified'])
        for key in m.ATTESTATION:
            data['metadata'] = dict(m.ATTESTATION)
            del data['metadata'][key]
            result = c.analyze_profile(data, 'quiet-only', data['metadata'])
            self.assertFalse(result['qualified']); self.assertFalse(result['evidenceUsable'])
        data['metadata'] = dict(m.ATTESTATION, nativeLoggingLevelAtEnd='4')
        self.assertFalse(c.analyze_profile(data, 'quiet-only', data['metadata'])['qualified'])

    def test_each_full_child_gets_the_same_controls_without_mutating_parent(self):
        import sync_full_calibration as c
        original = {'LOG_LEVEL': 'debug', 'LATTICE_DUMP_SQL': '0',
                    'LATTICE_ACK_PATH_DIAGNOSTICS': '1', 'LATTICE_OBSERVER_WORKER_DIAGNOSTICS': '1'}
        before = dict(original)
        plans = c.profile_plan(self.root, {'metadata': {'LOGGING': m.POLICY}}, original)
        self.assertEqual(len(plans), 2)
        for plan in plans:
            m.require_controls(plan['env'])
            self.assertEqual(plan['env']['LATTICE_LOG_LEVEL'], '0')
            self.assertEqual(plan['env'][m.CONTROL], m.POLICY)
            self.assertEqual(plan['metadata']['LOGGING'], m.POLICY)
        self.assertEqual(original, before)
