"""Pure admission/source/refusal checks; never invokes a compiler or network."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

import binding

PACKET = Path(__file__).resolve().parent


class BindingTests(unittest.TestCase):
    def setUp(self):
        root = PACKET.parent / 'pure-test-tmp'
        root.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=root)
        self.root = Path(self.tmp.name).resolve()
        self.config = json.loads((PACKET / 'benchmark-sources.json').read_text())

    def tearDown(self):
        self.tmp.cleanup()

    def admission(self):
        return {'scope': 'same-hosted-allocation-corrected-A-A2-B',
                'baselineLegacyAssessmentSHA256': self.config['baselineLegacyAssessmentSHA256'],
                'physicalHostQualified': False,
                'candidateQualification': {
                    k: {'commit': self.config['candidate' + prefix], 'tree': self.config['candidate' + prefix + 'Tree'],
                        'accepted': True, 'run': 123, 'assessmentSHA256': 'a' * 64}
                    for k, prefix in [('sdk', 'SDK'), ('core', 'Core')]}}

    def check_admission(self, value):
        path = self.root / 'admission.json'
        path.write_text(json.dumps(value))
        return binding.admission_check(path, binding.digest(path), self.config)

    def test_exact_config(self):
        binding.config_check(self.config, PACKET)

    def test_reviewed_packet_seal_and_drift(self):
        packet = self.root / 'packet'
        packet.mkdir()
        required = ['run-release-benchmark.py', 'binding.py', 'guarded_runner.py', 'build_proof.py',
                    'perf_refinement_report.py', 'benchmark-sources.json', 'PerfRefinementBenchmarks.swift',
                    'baseline-product.patch', 'TableResults.corrected.swift', 'baseline-focused-assessment.json',
                    'baseline-legacy-assessment.json', 'manifests/baseline-sdk-pristine.json',
                    'manifests/baseline-sdk-effective.json', 'manifests/baseline-core.json',
                    'manifests/candidate-sdk.json', 'manifests/candidate-core.json', 'manifests/dependency-pins.json']
        for name in required:
            path = packet / name
            path.parent.mkdir(exist_ok=True)
            path.write_text('sealed')
        seal = packet / 'PACKET-SEAL.json'
        seal.write_text(json.dumps({'files': {name: binding.digest(packet / name) for name in required}}))
        expected = binding.digest(seal)
        binding.packet_check(packet, expected)
        with self.assertRaises(ValueError):
            binding.packet_check(packet, '0' * 64)
        (packet / 'baseline-product.patch').write_text('changed')
        with self.assertRaises(ValueError):
            binding.packet_check(packet, expected)

    def test_changed_frozen_policy_refused(self):
        for key, value in [('measuredSamples', 99), ('warmups', 4), ('settlingSeconds', 0),
                           ('variants', ['local']), ('baselineProductPatchesAllowed', True),
                           ('measurementTimeoutSeconds', 1800), ('candidateSwiftDefine', 'OTHER')]:
            config = copy.deepcopy(self.config)
            config[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                binding.config_check(config, PACKET)

    def test_exact_admission_and_pending_or_wrong_source(self):
        self.check_admission(self.admission())
        for key, value in [('accepted', False), ('accepted', None), ('commit', '0' * 40),
                           ('tree', '0' * 40), ('assessmentSHA256', ''), ('run', None)]:
            admission = self.admission()
            admission['candidateQualification']['sdk'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check_admission(admission)

    def test_fake_physical_host_and_old_baseline_gate_refused(self):
        for key, value in [('physicalHostQualified', True), ('baselineLegacyAssessmentSHA256', 'b' * 64),
                           ('scope', 'local-only')]:
            admission = self.admission()
            admission[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check_admission(admission)

    def source_fixture(self):
        sdk = self.root / 'SDK'
        sdk.mkdir()
        path = sdk / 'a.swift'
        path.write_text('original')
        expected = {'a.swift': {'sha256': binding.digest(path), 'bytes': path.stat().st_size}}
        return sdk, expected

    def test_exact_sources_and_untracked_or_modified_refused(self):
        sdk, expected = self.source_fixture()
        binding.complete_sources(sdk, expected)
        extra = sdk / 'ignored.cpp'
        extra.write_text('unreviewed')
        with self.assertRaises(ValueError):
            binding.complete_sources(sdk, expected)
        extra.unlink()
        (sdk / 'a.swift').write_text('changed')
        with self.assertRaises(ValueError):
            binding.complete_sources(sdk, expected)

    def test_only_exact_core_edit_link_allowed(self):
        sdk, expected = self.source_fixture()
        core = self.root / 'Core'
        core.mkdir()
        (sdk / 'Packages').mkdir()
        (sdk / 'Packages/LatticeCore').symlink_to(core)
        binding.complete_sources(sdk, expected, edited_core=core)
        with self.assertRaises(ValueError):
            binding.complete_sources(sdk, expected)
        (sdk / 'outside').symlink_to(core)
        with self.assertRaises(ValueError):
            binding.complete_sources(sdk, expected, edited_core=core)

    def test_nested_swiftpm_not_hidden(self):
        sdk, expected = self.source_fixture()
        (sdk / 'sub/.swiftpm').mkdir(parents=True)
        (sdk / 'sub/.swiftpm/extra.swift').write_text('unreviewed')
        with self.assertRaises(ValueError):
            binding.complete_sources(sdk, expected)

    def test_command_cleanup_signal_or_changed_log_refused(self):
        log = self.root / 'test.log'
        log.write_text('test pass')
        record = {'success': True, 'started': True, 'exitCode': 0, 'primaryError': None,
                  'evidenceErrors': [], 'receivedSignals': [], 'logSHA256': binding.digest(log),
                  'cleanup': {'groupGone': True, 'leaderReaped': True, 'signals': [], 'errors': []}}
        receipt = self.root / 'test.json'
        receipt.write_text(json.dumps(record))
        binding.command_check(self.root, 'test')
        record['cleanup']['signals'] = ['SIGTERM']
        receipt.write_text(json.dumps(record))
        with self.assertRaises(ValueError):
            binding.command_check(self.root, 'test')
        record['cleanup']['signals'] = []
        receipt.write_text(json.dumps(record))
        log.write_text('changed')
        with self.assertRaises(ValueError):
            binding.command_check(self.root, 'test')

    def test_actual_compiler_private_define_and_batch_mismatch_refused(self):
        log = self.root / 'compile.log'
        base = '\n'.join('/tools/swiftc -module-name ' + name + ' -output-file-map /owned/map.json FLAG'
                         for name in ('Lattice', 'LatticeTests'))
        proof = {'nativeObjects': {'a': {'expandedArguments': ['clang++', '-O2']}}}
        expand = lambda args, scratch: (args, {})
        log.write_text(base.replace('FLAG', ''))
        binding.compiler_flags(proof, log, self.root, expand, False)
        with self.assertRaises(ValueError):
            binding.compiler_flags(proof, log, self.root, expand, True)
        log.write_text(base.replace('FLAG', '-DLATTICE_PERF_SELECTED_BATCH'))
        binding.compiler_flags(proof, log, self.root, expand, True)
        for forbidden in binding.FORBIDDEN:
            changed = copy.deepcopy(proof)
            changed['nativeObjects']['a']['expandedArguments'].append('-D' + forbidden)
            with self.subTest(forbidden=forbidden), self.assertRaises(ValueError):
                binding.compiler_flags(changed, log, self.root, expand, True)

    def test_target_miss_and_noise_not_promoted(self):
        comparison = {variant: {phase: {'p95': {'candidateMs': 6, 'baselineMs': 10, 'repeatMs': 12,
                        'candidateBelowBothByMoreThanAADifference': False}}
                       for phase in ('read.total', 'update.total')} for variant in ('local', 'attached')}
        candidate = {'variants': {variant: {'phases': {'read.cold_page_identity_anchor': {
                      'sqlStatements': {'max': 8}}}} for variant in ('local', 'attached')}}
        observed = binding.target_observations(comparison, candidate)
        self.assertFalse(observed['performanceGoalAchieved'])
        self.assertFalse(observed['observations']['local']['coldSQLAtMostThree'])
        self.assertFalse(observed['observations']['local']['latency']['read.total']['atLeastTwoTimesFasterThanBothBaselines'])
        self.assertFalse(observed['observations']['local']['latency']['read.total']['exceedsObservedAADifference'])


if __name__ == '__main__':
    unittest.main()
