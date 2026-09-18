import ast
from pathlib import Path
import tempfile
import unittest
import qualify

P = Path(__file__).resolve().parent

class ToolLookup(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=P / 'check-tmp')
        self.root = Path(self.temp.name)
        self.tool = self.root / 'swift'
        self.tool.write_text('fixture path only; never executed')
        self.log = self.root / 'lookup.log'
    def tearDown(self): self.temp.cleanup()
    def parse(self, text):
        self.log.write_text(text)
        return qualify.selected_tool_path(self.log, 'swift')
    def test_exact_single_existing_absolute_path(self):
        self.assertEqual(self.parse(str(self.tool) + '\n'), str(self.tool.resolve()))
        self.assertEqual(self.parse(str(self.tool)), str(self.tool.resolve()))
    def test_actual_retained_warning_logs_are_rejected(self):
        for name in ('swift', 'xctest'):
            with self.subTest(name=name), self.assertRaisesRegex(AssertionError, 'exactly one path line'):
                qualify.selected_tool_path(P / 'lookup-fixtures' / ('selected-' + name + '-path.log'), name)
    def test_ambiguous_relative_empty_and_extra_output_rejected(self):
        for text in ('', 'swift\n', str(self.tool) + '\n' + str(self.tool) + '\n',
                     str(self.tool) + '\n\n', 'unexpected warning\n' + str(self.tool) + '\n',
                     ' ' + str(self.tool) + '\n', str(self.tool) + '\x00\n'):
            with self.subTest(text=repr(text)), self.assertRaises(AssertionError): self.parse(text)
    def test_missing_wrong_basename_and_directory_rejected(self):
        for text in (str(self.root / 'missing/swift'), str(self.root / 'xctest')):
            with self.subTest(text=text), self.assertRaises(AssertionError): self.parse(text)
        self.tool.unlink(); self.tool.mkdir()
        with self.assertRaises(AssertionError): self.parse(str(self.tool))
    def test_output_bound_rejected(self):
        with self.assertRaisesRegex(AssertionError, 'path bound'): self.parse('/' + 'x' * 4098)
    def test_lookup_argv_unsets_only_backtrace(self):
        for name in ('swift', 'xctest'):
            self.assertEqual(qualify.tool_lookup_argv(name), ['/usr/bin/env', '-u', 'SWIFT_BACKTRACE', 'xcrun', '--find', name])
        with self.assertRaises(AssertionError): qualify.tool_lookup_argv('other')
    def test_both_lookup_calls_use_narrow_argv_and_unchanged_timeout(self):
        tree = ast.parse((P / 'qualify.py').read_text())
        calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                 and n.func.attr == 'run' and n.args and isinstance(n.args[0], ast.Constant)
                 and n.args[0].value in ('selected-swift-path', 'selected-xctest-path')]
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertIsInstance(call.args[1], ast.Call)
            self.assertEqual(call.args[1].func.id, 'tool_lookup_argv')
            self.assertEqual(next(k.value.value for k in call.keywords if k.arg == 'timeout'), 30)
        source = (P / 'qualify.py').read_text()
        self.assertIn("SWIFT_BACKTRACE=config['swiftBacktrace']", source)
