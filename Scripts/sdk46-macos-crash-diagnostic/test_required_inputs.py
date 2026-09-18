import ast
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import qualify

P = Path(__file__).resolve().parent


class RequiredInputs(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=P / 'check-tmp')
        self.root = Path(self.temp.name)
        self.files = {}
        for name in qualify.REQUIRED_RUNTIME_INPUTS:
            shutil.copyfile(P / name, self.root / name)
            self.files[name] = hashlib.sha256((self.root / name).read_bytes()).hexdigest()

    def tearDown(self):
        self.temp.cleanup()

    def check(self):
        seal = self.root / 'SOURCE-SEAL.json'
        seal.write_text(json.dumps({'scope': 'SDK46 macOS crash diagnostic source packet', 'files': self.files}))
        digest = hashlib.sha256(seal.read_bytes()).hexdigest()
        with patch.object(qualify, 'P', self.root):
            return qualify.packet(digest)

    def test_complete_packet_accepted(self):
        self.assertEqual(set(self.check()['files']), qualify.REQUIRED_RUNTIME_INPUTS)

    def test_each_required_input_missing_from_seal_rejected(self):
        for name in sorted(qualify.REQUIRED_RUNTIME_INPUTS):
            with self.subTest(name=name):
                value = self.files.pop(name)
                with self.assertRaisesRegex(AssertionError, 'required runtime inputs absent'):
                    self.check()
                self.files[name] = value

    def test_control_missing_on_disk_rejected(self):
        (self.root / 'CrashControl.swift').unlink()
        with self.assertRaises(FileNotFoundError):
            self.check()

    def test_control_drift_rejected(self):
        (self.root / 'CrashControl.swift').write_text('changed')
        with self.assertRaisesRegex(AssertionError, 'source packet drift: CrashControl.swift'):
            self.check()

    def test_static_local_import_and_literal_packet_input_closure(self):
        # Cover every direct local import and literal P/file use in the runtime
        # modules. Standard-library imports and the seal itself are separate.
        for name in qualify.REQUIRED_RUNTIME_INPUTS:
            if not name.endswith('.py'):
                continue
            tree = ast.parse((P / name).read_text())
            for node in ast.walk(tree):
                names = ([x.name for x in node.names] if isinstance(node, ast.Import)
                         else [node.module] if isinstance(node, ast.ImportFrom) and node.module else [])
                for module in names:
                    filename = module.split('.')[0] + '.py'
                    if (P / filename).is_file():
                        self.assertIn(filename, qualify.REQUIRED_RUNTIME_INPUTS, (name, filename))
                if (isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div)
                    and isinstance(node.left, ast.Name) and node.left.id == 'P'
                    and isinstance(node.right, ast.Constant) and isinstance(node.right.value, str)):
                    filename = node.right.value
                    if filename != 'SOURCE-SEAL.json':
                        self.assertIn(filename, qualify.REQUIRED_RUNTIME_INPUTS, (name, filename))

    def test_completeness_preflight_precedes_runtime_root_and_commands(self):
        source = (P / 'qualify.py').read_text()
        self.assertLess(source.index('source = packet('), source.index('root.mkdir('))
        self.assertLess(source.index('source = packet('), source.index("runner.run('swift-version'"))
