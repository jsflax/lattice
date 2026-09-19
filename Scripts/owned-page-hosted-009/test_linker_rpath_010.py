"""Replay the exact hosted linker operand as pure data; no native execution."""
import ast
import json
from pathlib import Path
import shlex
import tempfile
import unittest
import build_proof as proof

P = Path(__file__).resolve().parent

class ObservedLinkerOperand(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=P/'pure-tmp')
        self.scratch = Path(self.tmp.name)
    def tearDown(self):
        self.tmp.cleanup()
    def actual_command(self):
        fixture = P/'fixtures/linker-rpath-010'
        args = shlex.split((fixture/'actual-command.txt').read_text())
        response = self.scratch/'Objects.LinkFileList'
        response.write_bytes((fixture/'Objects.LinkFileList').read_bytes())
        original = [arg for arg in args if arg.startswith('@') and Path(arg[1:]).is_absolute()]
        self.assertEqual(len(original), 1)
        return [('@'+str(response)) if arg == original[0] else arg for arg in args], response
    def test_old_refusal_and_new_exact_command_expansion(self):
        args, response = self.actual_command()
        old = ast.parse((P/'evidence/sdk008/build_proof.py').read_text())
        node = next(n for n in old.body if isinstance(n, ast.FunctionDef) and n.name == 'native_arguments')
        namespace = dict(proof.__dict__)
        exec(compile(ast.Module(body=[node], type_ignores=[]), '<original-function>', 'exec'), namespace)
        with self.assertRaisesRegex(AssertionError, 'native response path must be explicit'):
            namespace['native_arguments'](args, self.scratch)
        expanded, files = proof.native_arguments(args, self.scratch)
        wanted = []
        for arg in args:
            wanted.extend(shlex.split(response.read_text()) if arg == '@'+str(response) else [arg])
        self.assertEqual(expanded, wanted)
        self.assertEqual(files, {str(response): proof.guard.digest(response)})
        self.assertIn('@loader_path/../../../', expanded)
    def test_only_two_exact_operands_in_exact_context_are_literals(self):
        for literal in ['@loader_path', '@loader_path/../../../']:
            args = ['swiftc', '-Xlinker', '-rpath', '-Xlinker', literal]
            self.assertEqual(proof.native_arguments(args, self.scratch), (args, {}))
            for bad in [['swiftc', literal], ['swiftc', '-Xlinker', literal],
                        ['swiftc', '-Xlinker', '-rpath', literal],
                        ['swiftc', '-Xlinker', '-install_name', '-Xlinker', literal]]:
                with self.subTest(args=bad), self.assertRaises(AssertionError):
                    proof.native_arguments(bad, self.scratch)
        for literal in ['@loader_path/extra', '@loader_path/../../', '@loader_path/../../../../', '@other']:
            with self.subTest(literal=literal), self.assertRaises(AssertionError):
                proof.native_arguments(['swiftc', '-Xlinker', '-rpath', '-Xlinker', literal], self.scratch)
    def test_nested_response_still_enforces_driver_job_limit(self):
        response = self.scratch/'driver.rsp'
        response.write_text('-j2 -Xlinker -rpath -Xlinker @loader_path/../../../')
        self.assertEqual(proof.swift_driver_jobs(['swiftc', '@'+str(response)], self.scratch)['jobValues'], ['2'])
        response.write_text('-j16 -Xlinker -rpath -Xlinker @loader_path/../../../')
        with self.assertRaises(AssertionError):
            proof.swift_driver_jobs(['swiftc', '@'+str(response)], self.scratch)

if __name__ == '__main__':
    unittest.main()
