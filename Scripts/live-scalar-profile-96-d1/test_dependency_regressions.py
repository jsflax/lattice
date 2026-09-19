"""Saved dependency bytes and synthetic finalization only; no native execution."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import profile_proof as profile
import profile_binding as binding

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('profile_run_for_test', HERE / 'run-profile.py')
runner_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner_module)


class ActualDependencySyntaxTests(unittest.TestCase):
    def test_saved_actual_swift_rules_match_authenticated_output_maps(self):
        drivers = json.loads((HERE / 'fixtures/swift-drivers.json').read_text())
        for module, size, digest, count in (
            ('Lattice', 1869918, '81eaee83b82dba3f3bf286c1b65f8c98da336f1de555a74842e2431207b91828', 73),
            ('LatticeTests', 7180184, 'f0f2c8964542162544c204627b04a1097ad27463ca1ce2d24de2f9d675fc0c02', 124),
        ):
            with self.subTest(module=module):
                raw = (HERE / 'fixtures' / (module + '.d')).read_bytes()
                self.assertEqual((len(raw), hashlib.sha256(raw).hexdigest()), (size, digest))
                rules = profile.parse_dependency_rules(raw, multi_rule=True)
                mapping = json.loads((HERE / 'fixtures' / (module + '-output-file-map.json')).read_text())
                argv = drivers[module]
                module_output = Path(profile.one(argv, '-emit-module-path'))
                scratch = module_output.parents[1]
                expected = profile.swift_dependency_targets(mapping, argv, scratch)
                self.assertEqual(len(rules), count)
                targets = [target for names, _ in rules for target in names]
                self.assertEqual(len(targets), len(set(targets)))
                self.assertEqual(set(targets), expected)
                for _, inputs in rules:
                    self.assertTrue(set(mapping) - {''} <= set(inputs))
                # Repeated WMO input text is parsed once, not once per output.
                self.assertEqual(len({id(inputs) for _, inputs in rules}), 1)

    def test_actual_fixture_does_not_supply_required_importer_header_evidence(self):
        rules = profile.parse_dependency_rules((HERE / 'fixtures/LatticeTests.d').read_bytes(), multi_rule=True)
        for _, inputs in rules:
            self.assertTrue(any(x.endswith('/Tests/CLatticeTestSQLite/module.modulemap') for x in inputs))
            self.assertFalse(any(x.endswith('/Tests/CLatticeTestSQLite/shim.h') for x in inputs))
            self.assertFalse(any(x.endswith('/Sources/LatticeCore/include/lattice/perf_live_profile.h') for x in inputs))
        # Grammar acceptance is not header/importer acceptance. The production
        # make() records the separately authenticated source/configuration chain
        # as inference; it never fabricates direct transitive-header/PCM proof.

    def test_saved_actual_importer_context_supports_only_labelled_chain_inference(self):
        work = HERE / 'pure-test-work'
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='actual-chain-', dir=work) as directory:
            root = Path(directory)
            sdk, core, scratch = root/'lattice', root/'LatticeCore', root/'scratch'
            sources = {}
            for relative, source_root, fixture in ((profile.MODULE_MAP_RELATIVE, sdk, 'module.modulemap'),
                                                  (profile.SDK_PATHS[0], sdk, 'shim.h'),
                                                  (profile.CORE_PATHS[2], core, 'perf_live_profile.h')):
                path = source_root/relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((HERE/'fixtures'/fixture).read_bytes())
                sources[str(path)] = binding.digest(path)
            cache = scratch/'arm64-apple-macosx/release/ModuleCache'
            cache.mkdir(parents=True)
            original = '/Users/runner/localdev/lattice-live-scalar-profile-35436821175-1/candidate'
            relocated = lambda value: value.replace(original, str(root)).replace('/Applications/', str(root/'Applications') + '/')
            driver = [relocated(x) for x in json.loads((HERE/'fixtures/swift-drivers.json').read_text())['LatticeTests']]
            frontend = [relocated(x) for x in json.loads((HERE/'fixtures/swift-frontends.json').read_text())['LatticeTests']]
            language, importer = profile.swift_channels(frontend)
            arguments = language + importer
            for index, arg in enumerate(arguments):
                directory = Path(arguments[index + 1]) if arg == '-I' else Path(arg[2:]) if arg.startswith('-I') else None
                if directory is not None:
                    self.assertTrue(directory.is_relative_to(root))
                    directory.mkdir(parents=True, exist_ok=True)
            rules = profile.parse_dependency_rules((HERE/'fixtures/LatticeTests.d').read_bytes(), multi_rule=True)
            dependencies = {'files': {str(sdk/profile.MODULE_MAP_RELATIVE): sources[str(sdk/profile.MODULE_MAP_RELATIVE)]},
                            'rules': {relocated(target): [relocated(x) for x in inputs]
                                      for targets, inputs in rules for target in targets}}
            chain = profile.importer_header_chain(driver, frontend, sdk, core, scratch, dependencies, sources)
            self.assertTrue(chain['directSwiftModuleMapDependency'])
            self.assertFalse(chain['directSwiftTransitiveHeaderProofClaimed'])
            self.assertFalse(chain['pcmCustody'])
            self.assertEqual(chain['contexts']['driver']['moduleCachePath'], str(cache))
            self.assertEqual(chain['contexts']['objectFrontend']['moduleCachePath'], str(cache))
            self.assertTrue(chain['requiresRuntimeCounterValidation'])

    def test_native_still_rejects_multiple_rules(self):
        with self.assertRaisesRegex(ValueError, 'unknown dependency rule'):
            profile.parse_dependency_rules(b'a.o: a.cpp\nb.o: b.cpp\n')

    def test_continuations_and_escaped_spaces_preserved(self):
        raw = b'output\\ name.o: source\\ name.swift \\\n header\\ name.h\n'
        self.assertEqual(profile.parse_dependency_rules(raw),
                         [(['output name.o'], ['source name.swift', 'header name.h'])])

    def test_unsupported_make_syntax_stays_rejected(self):
        for value in (b'$name', b'#comment', b'bad;command', b'a|b', b'null\0byte', b'bare\rname'):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'unsupported dependency syntax'):
                profile.parse_dependency_rules(b'target: ' + value + b'\n', multi_rule=True)

    def test_file_cap_enforced_before_decode(self):
        with self.assertRaisesRegex(ValueError, 'dependency byte cap'):
            profile.parse_dependency_rules(b'\xff' * (profile.DEPENDENCY_BYTE_CAP + 1), multi_rule=True)

    def test_rule_and_name_caps_remain_bounded(self):
        with self.assertRaisesRegex(ValueError, 'unknown dependency rule'):
            profile.parse_dependency_rules(b't: i\n' * (profile.DEPENDENCY_RULE_CAP + 1), multi_rule=True)
        with self.assertRaisesRegex(ValueError, 'oversized dependency rule'):
            profile.parse_dependency_rules(b't: ' + b'i ' * (profile.DEPENDENCY_NAMES_PER_RULE + 1))


class PartialCompilerCustodyTests(unittest.TestCase):
    def setUp(self):
        work = HERE / 'pure-test-work'
        work.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='partial-custody-', dir=work)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / 'synthetic-binary'
        self.binary.write_bytes(b'synthetic, never executed')
        self.proof = {'binary': str(self.binary)}
        self.receipt = self.root / 'COMPILER-PROOF.json'
        self.receipt.write_text(json.dumps(self.proof))
        self.context = {'proofHash': binding.digest(self.receipt)}

    def test_failed_supplement_keeps_verified_base_custody_and_primary_error(self):
        class Runner:
            overall_deadline = 10
            def measure(self, path): return {'freeBytes': 100}
            def violation(self, value): return None
        result = {'primaryError': {'type': 'ValueError', 'message': 'dependency byte cap'}, 'evidenceErrors': []}
        operation = lambda: runner_module.compiler_custody(self.proof, None, self.context, self.root)
        with patch.object(runner_module.build_proof, 'verify') as base, \
                patch.object(runner_module.profile_proof, 'verify') as supplement:
            binding.final_evidence(result, [('compiler-custody', operation)], [], self.root, Runner(), lambda: 1)
        base.assert_called_once_with(self.proof)
        supplement.assert_not_called()
        self.assertEqual(result['primaryError']['message'], 'dependency byte cap')
        self.assertEqual(result['evidenceErrors'], [])
        value = result['finalChecks']['compiler-custody']
        self.assertTrue(value['baseBuildAvailable'])
        self.assertFalse(value['profileBuildAvailable'])
        self.assertFalse(value['profileSupplementAvailable'])
        self.assertEqual(value['compilerProofSHA256'], self.context['proofHash'])

    def test_base_drift_still_reported_when_supplement_absent(self):
        self.receipt.write_text('changed proof receipt')
        with patch.object(runner_module.build_proof, 'verify'), \
                patch.object(runner_module.profile_proof, 'verify') as supplement, \
                self.assertRaisesRegex(ValueError, 'compiler proof drift'):
            runner_module.compiler_custody(self.proof, None, self.context, self.root)
        supplement.assert_not_called()

    def test_no_build_has_no_false_profile_or_verification(self):
        with patch.object(runner_module.build_proof, 'verify') as base:
            self.assertEqual(runner_module.compiler_custody(None, None, {}, self.root),
                             {'baseBuildAvailable': False, 'profileBuildAvailable': False})
        base.assert_not_called()

    def test_base_receipt_written_before_supplement_construction(self):
        text = (HERE / 'run-profile.py').read_text()
        self.assertLess(text.index("guard.save_json(receipts/'COMPILER-PROOF.json',proof)"),
                        text.index('supplement=profile_proof.make'))
        self.assertEqual(text.count("guard.save_json(receipts/'COMPILER-PROOF.json',proof)"), 1)


if __name__ == '__main__':
    unittest.main()
