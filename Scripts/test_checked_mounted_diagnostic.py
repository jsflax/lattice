"""Pure parser/source controls; never imports SDK code or opens a product database."""
import ast
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
import checked_mounted_diagnostic as diagnostic

HERE = Path(__file__).resolve().parent


def observed(phase):
    return {'format': diagnostic.FORMAT, 'phase': phase, 'available': True,
            'reason': 'observed', 'sqliteCode': 0, 'closeCode': 0, 'cookie': 7,
            'markers': [{'key': 'schema_fingerprint:0000000000000001', 'value': '7'}]}


class DiagnosticControls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'actual-command.log'
        self.rows = [observed(phase) for phase in diagnostic.PHASES]

    def log(self, rows=None, passed=True):
        lines = [f'◇ Test {diagnostic.TEST}() started.']
        lines += [diagnostic.PREFIX + json.dumps(row) for row in (self.rows if rows is None else rows)]
        if passed:
            lines += [f'✔ Test {diagnostic.TEST}() passed after 0.991 seconds.',
                      '✔ Test run with 1 test in 1 suite passed after 0.995 seconds.']
        else:
            lines += [f'✘ Test {diagnostic.TEST}() failed after 0.991 seconds with 1 issue.',
                      '✘ Test run with 1 test in 1 suite failed after 0.995 seconds with 1 issue.']
        self.path.write_text('\n'.join(lines) + '\n')
        return diagnostic.parse(self.path, 'Darwin', test_passed=passed)

    def refusal(self, rows):
        with self.assertRaises((ValueError, TypeError)):
            self.log(rows)

    def test_six_real_phase_shape(self):
        result = self.log()
        self.assertTrue(result['allSQLiteObservationsAvailable'])
        self.assertEqual([row['phase'] for row in result['phases']], list(diagnostic.PHASES))

    def test_linux_unavailable_is_explicit_not_fabricated(self):
        rows = [{'format': diagnostic.FORMAT, 'phase': phase, 'available': False,
                 'reason': 'sqlite_module_unavailable'} for phase in diagnostic.PHASES]
        self.log(rows)
        result = diagnostic.parse(self.path, 'Linux', test_passed=True)
        self.assertFalse(result['allSQLiteObservationsAvailable'])
        self.assertTrue(all('cookie' not in row for row in result['phases']))

    def test_linux_cannot_claim_mac_sqlite_observation(self):
        self.log()
        with self.assertRaises(ValueError): diagnostic.parse(self.path, 'Linux', test_passed=True)

    def test_failed_original_test_stays_failed(self):
        self.assertFalse(self.log(passed=False)['actualCommandPassed'])
        with self.assertRaises(ValueError): diagnostic.parse(self.path, 'Darwin', test_passed=True)

    def test_same_phase_missing_or_duplicate_refuses(self):
        for rows in (self.rows[:-1], self.rows + [self.rows[-1]], [self.rows[0]] + self.rows[:-1]):
            with self.subTest(count=len(rows)): self.refusal(rows)

    def test_wrong_order_refuses(self):
        self.rows[0], self.rows[1] = self.rows[1], self.rows[0]
        self.refusal(self.rows)

    def test_unknown_field_or_reason_never_exports_secret(self):
        for key, value in [('secret', 'SECRET-CANARY'), ('reason', 'SECRET-CANARY')]:
            rows = copy.deepcopy(self.rows); rows[0][key] = value
            with self.assertRaises(ValueError) as caught: self.log(rows)
            self.assertNotIn('SECRET-CANARY', str(caught.exception))

    def test_duplicate_json_key_refuses(self):
        self.log(); text = self.path.read_text().replace('"cookie": 7', '"cookie": 7, "cookie": 8', 1)
        self.path.write_text(text)
        with self.assertRaises(ValueError): diagnostic.parse(self.path, 'Darwin', test_passed=True)

    def test_boolean_or_out_of_range_cookie_refuses(self):
        for value in (True, -1, 2147483648, '7', None):
            rows = copy.deepcopy(self.rows); rows[0]['cookie'] = value
            with self.subTest(value=value): self.refusal(rows)

    def test_unknown_status_type_refuses(self):
        for value in (True, -1, '0', 2147483648):
            rows = copy.deepcopy(self.rows); rows[0]['closeCode'] = value
            self.refusal(rows)

    def test_nonzero_close_cannot_be_available(self):
        self.rows[0]['closeCode'] = 5
        self.refusal(self.rows)

    def test_bounded_failure_record_preserves_no_payload(self):
        self.rows[0] = {'format': diagnostic.FORMAT, 'phase': 'aftercreate', 'available': False,
                        'reason': 'cookie_prepare', 'sqliteCode': 1, 'closeCode': 0}
        result = self.log(); self.assertFalse(result['allSQLiteObservationsAvailable'])
        self.rows[0]['cookie'] = 7; self.refusal(self.rows)

    def test_marker_bound_type_and_range(self):
        for markers in (self.rows[0]['markers'] * 33, None, [{'key': 'SECRET-CANARY', 'value': '7'}],
                        [{'key': 'schema_fingerprint:0000000000000001', 'value': '2147483648'}],
                        [{'key': 'schema_fingerprint:0000000000000001', 'value': '07'}]):
            rows = copy.deepcopy(self.rows); rows[0]['markers'] = markers
            self.refusal(rows)

    def test_marker_duplicate_or_order_refuses(self):
        for values in ((2, 1), (1, 1)):
            rows = copy.deepcopy(self.rows)
            rows[0]['markers'] = [{'key': f'schema_fingerprint:{value:016x}', 'value': '7'} for value in values]
            self.refusal(rows)

    def test_empty_markers_are_actual_data(self):
        self.rows[0]['markers'] = []
        self.assertEqual(self.log()['phases'][0]['markers'], [])

    def test_limits_allow_exact_endpoints(self):
        self.rows[0]['cookie'] = 2147483647
        self.rows[0]['markers'] = [{'key': f'schema_fingerprint:{value:016x}', 'value': '2147483647'} for value in range(32)]
        self.assertEqual(len(self.log()['phases'][0]['markers']), 32)

    def test_unknown_format_shape_or_platform_refuses(self):
        for value in ('unknown', [], None):
            rows = copy.deepcopy(self.rows); rows[0]['format'] = value; self.refusal(rows)
        self.log()
        with self.assertRaises(ValueError): diagnostic.parse(self.path, 'Unknown', test_passed=True)

    def test_no_test_or_extra_population_cannot_pass(self):
        self.log(); text = self.path.read_text()
        for bad in (text.replace(f'◇ Test {diagnostic.TEST}() started.\n', ''),
                    text.replace('with 1 test in', 'with 2 tests in'),
                    text.replace(f'✔ Test {diagnostic.TEST}()', '✔ Test otherTest()')):
            self.path.write_text(bad)
            with self.assertRaises(ValueError): diagnostic.parse(self.path, 'Darwin', test_passed=True)

    def test_oversized_event_refuses_without_echo(self):
        self.log(); self.path.write_text(diagnostic.PREFIX + 'SECRET-CANARY' * 1000 + '\n')
        with self.assertRaises(ValueError) as caught: diagnostic.parse(self.path, 'Darwin', test_passed=True)
        self.assertNotIn('SECRET-CANARY', str(caught.exception))

    def test_json_nonfinite_refuses(self):
        self.log(); self.path.write_text(self.path.read_text().replace('"cookie": 7', '"cookie": NaN', 1))
        with self.assertRaises(ValueError): diagnostic.parse(self.path, 'Darwin', test_passed=True)

    def test_symlink_log_refuses(self):
        self.log(); alias = self.path.with_name('alias.log'); alias.symlink_to(self.path)
        with self.assertRaises(ValueError): diagnostic.parse(alias, 'Darwin', test_passed=True)


class SourceBindings(unittest.TestCase):
    def test_controller_mode_same_guarded_build_and_runtime(self):
        source = (HERE / 'run-development.py').read_text()
        tree = ast.parse(source)
        main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'main')
        calls = [node for node in ast.walk(main) if isinstance(node, ast.Call)]
        option = [node for node in calls if isinstance(node.func, ast.Attribute) and node.func.attr == 'add_argument'
                  and node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == '--checked-mounted-diagnostic']
        self.assertEqual(len(option), 1); self.assertIsInstance(option[0].func.value, ast.Name)
        self.assertEqual(option[0].func.value.id, 'qualification')
        self.assertIn("'--skip-build', '--filter'", source)
        self.assertIn('timeout=args.test_timeout, require_full_timeout=True)', source)
        self.assertIn("env.pop('LATTICE_CHECKED_MOUNTED_DIAGNOSTIC', None)", source)
        self.assertIn("test_passed=command.get('success') is True", source)
        self.assertIn("save_json(receipts / 'compiler-input-proof.json', compiler_input_proof(build, core))", source)

    def test_workflow_mode_and_matched_exclusion_bound(self):
        source = (HERE.parent / '.github/workflows/development.yml').read_text() if (HERE.parent / '.github').exists() else (HERE.parents[0] / '.github/workflows/development.yml').read_text()
        self.assertIn('CHECKED_MOUNTED_DIAGNOSTIC: ${{ inputs.checked_mounted_diagnostic || false }}', source)
        self.assertIn('DEVELOPMENT_ARGUMENTS+=(--checked-mounted-diagnostic)', source)
        self.assertIn('${{ inputs.checked_mounted_diagnostic }}\'', source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
