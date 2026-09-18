#!/usr/bin/env python3
"""Preparation: same-allocation VM A/A/B; frozen physical-host gate stays false."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

PACKET = Path(__file__).resolve().parent


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--candidate-sdk-sha', required=True)
    args = parser.parse_args()
    guard = load_module('guarded_runner', PACKET / 'guarded_runner.py')
    report = load_module('frozen_reporter', PACKET / 'perf_refinement_report.py')
    config = json.loads((PACKET / 'benchmark-sources.json').read_text())
    root = args.root.resolve(strict=True)
    allowed = (Path.home() / 'localdev').resolve(strict=True)
    if not root.is_relative_to(allowed) or root == allowed:
        raise ValueError('benchmark root must be an owned child of ~/localdev')
    if not guard.SHA.fullmatch(args.candidate_sdk_sha) or not guard.SHA.fullmatch(os.environ.get('GITHUB_SHA', '')):
        raise ValueError('exact candidate and workflow SDK commits required')
    for name, expected in config['frozenFiles'].items():
        if guard.digest(PACKET / name) != expected:
            raise ValueError('frozen packet input changed: ' + name)
    if config['measuredSamples'] != 100 or config['warmups'] != 5 or config['settlingSeconds'] != 60 or config['baselineProductPatchesAllowed']:
        raise ValueError('frozen defaults or original-baseline policy changed')
    if config.get('variants') != ['local']:
        raise ValueError('this separate runner requires explicit local-only scope')
    receipts = root / 'receipts'
    receipts.mkdir(exist_ok=False)
    (root / 'runs').mkdir(exist_ok=False)
    (root / 'test-logs').mkdir(exist_ok=False)
    (root / 'tmp').mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update(PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(root / 'tmp'), TMP=str(root / 'tmp'),
               TEMP=str(root / 'tmp'), LATTICE_TEST_LOG_PATH=str(root / 'test-logs/native.log'),
               LATTICE_PERF_REFINEMENT='0')
    # Background diagnostics are not part of the frozen measured workload.
    for name in ('LATTICE_ACK_PATH_DIAGNOSTICS', 'LATTICE_OBSERVER_WORKER_DIAGNOSTICS'):
        env.pop(name, None)
    result = {'schemaVersion': 1, 'scope': 'exploratory same-VM-allocation A/A/B',
              'qualifiesFrozenPhysicalHostGate': False, 'physicalHostIdentityVerified': False,
              'performanceTargetClaimed': False, 'baselineCorrectnessPatchApplied': False,
              'variantScope': 'local-only', 'attachedQualificationClaimed': False,
              'fullContractQualified': False,
              'candidateSDK': args.candidate_sdk_sha, 'workflowCommit': env['GITHUB_SHA'],
              'config': config, 'success': False, 'primaryError': None, 'evidenceErrors': [],
              'completedMeasurementLabels': [], 'currentPhase': 'setup'}
    primary = None
    contexts = {}
    with guard.Interrupts() as interrupts:
        runner = guard.GuardedRunner(root, receipts, env, interrupts,
                                     free_floor=config['freeFloorBytes'], packet_ceiling=config['packetCeilingBytes'],
                                     overall_seconds=config['overallSeconds'], reserve=config['finalizationReserveSeconds'])
        def command(label, argv, cwd, **kwargs):
            return runner.run(label, argv, cwd=cwd, **kwargs)
        def fetch(label, repo_url, sha, destination):
            if destination.exists():
                raise ValueError('source destination already exists: ' + str(destination))
            command(label + '-init', ['git', 'init', str(destination)], root)
            command(label + '-fetch', ['git', 'fetch', '--depth=1', repo_url, sha], destination)
            command(label + '-checkout', ['git', 'checkout', '--detach', sha], destination)
            return guard.authenticate_repository(runner, label, destination, sha, initial=True)
        def common(context):
            home = context['home']
            return ['--package-path', str(context['sdk']), '--scratch-path', str(home / 'scratch'),
                    '--cache-path', str(home / 'cache'), '--config-path', str(home / 'config'),
                    '--security-path', str(home / 'security'), '--disable-sandbox', '--disable-experimental-prebuilts']
        def apply_env(context):
            runner.env = dict(env, CLANG_MODULE_CACHE_PATH=str(context['home'] / 'module-cache'),
                              SWIFT_MODULECACHE_PATH=str(context['home'] / 'module-cache'),
                              SWIFTPM_MODULECACHE_OVERRIDE=str(context['home'] / 'module-cache'))
        def graph(context, phase):
            label = context['label'] + '-' + phase
            log = command(label + '-graph', ['swift', 'package', *common(context), 'show-dependencies', '--format', 'json'], context['sdk'])
            parsed = guard.read_graph(log)
            if context['label'] == 'candidate':
                return guard.verify_graph(runner, label, parsed, context['pins'], context['core'],
                                          config['candidateCore'], context['home'] / 'scratch')
            # Baseline permits no edits, including Core. Verify every real checkout.
            nodes = guard.graph_nodes(parsed)
            state = json.loads((context['home'] / 'scratch/workspace-state.json').read_text())
            entries = state['object']['dependencies']
            dependencies = {entry['packageRef']['identity']: entry for entry in entries}
            if len(entries) != len(dependencies) or set(nodes) != set(context['pins']) or set(dependencies) != set(nodes):
                raise ValueError('original baseline graph identity inventory changed')
            proof = []
            for identity in sorted(nodes):
                pin, node, entry = context['pins'][identity], nodes[identity], dependencies[identity]
                path = Path(node['path']).resolve(strict=True)
                expected_path = (context['home'] / 'scratch/checkouts' / entry['subpath']).resolve(strict=True)
                if (entry['state']['name'] != 'sourceControlCheckout' or entry['state']['checkoutState'] != pin['state']
                        or path != expected_path or not path.is_relative_to((context['home'] / 'scratch/checkouts').resolve())
                        or guard.url_key(node['url']) != guard.url_key(pin['location'])
                        or guard.url_key(entry['packageRef']['location']) != guard.url_key(pin['location'])):
                    raise ValueError('original baseline effective graph changed: ' + identity)
                head = command(label + '-' + identity + '-head', ['git', 'rev-parse', 'HEAD'], path, timeout=60).read_text().strip()
                dirty = command(label + '-' + identity + '-status', ['git', 'status', '--porcelain=v1', '--untracked-files=all'], path, timeout=60).read_text()
                if head != pin['state']['revision'] or dirty:
                    raise ValueError('original baseline checkout changed: ' + identity)
                proof.append({'identity': identity, 'path': str(path), 'revision': head})
                if identity == 'latticecore':
                    context['core'] = path
            guard.save_json(receipts / (label + '.json'), proof)
            return proof
        def validate_sources(context, phase):
            if guard.digest(context['sdk'] / config['baselineOverlayPath']) != config['frozenFiles']['PerfRefinementBenchmarks.swift']:
                raise ValueError('benchmark harness changed')
            allowed_paths = ('Package.resolved', config['baselineOverlayPath']) if context['label'] == 'baseline' else ('Package.resolved',)
            final = guard.authenticate_repository(runner, context['label'] + '-' + phase, context['sdk'],
                                                   context['sdkSHA'], allowed_changes=allowed_paths)
            expected = {k: v for k, v in context['source']['files'].items() if k not in allowed_paths}
            if final['files'] != expected:
                raise ValueError('measured product source changed: ' + context['label'])
            current = guard.pins(context['sdk'] / 'Package.resolved')
            if context['label'] == 'baseline':
                if current != context['pins']:
                    raise ValueError('original baseline complete lock changed')
            elif {k: v for k, v in current.items() if k != 'latticecore'} != {k: v for k, v in context['pins'].items() if k != 'latticecore'}:
                raise ValueError('candidate non-Core lock changed')
        def binaries(context):
            outputs = {}
            for candidate in (context['home'] / 'scratch').rglob('*.xctest'):
                members = candidate.rglob('*') if candidate.is_dir() else [candidate]
                for path in members:
                    if path.is_file() and not path.is_symlink():
                        outputs[str(path.relative_to(context['home']))] = guard.digest(path)
            if not outputs:
                raise ValueError('no actual Release test binary/bundle found')
            return outputs
        def host_sample(label):
            if platform.system() == 'Darwin':
                boot = command(label + '-boot', ['sysctl', '-n', 'kern.bootsessionuuid'], root, timeout=60).read_text().strip()
            else:
                boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
            sample = {'bootSession': boot, 'hostname': platform.node(), 'operatingSystem': platform.platform(),
                      'cpuCount': os.cpu_count(), 'loadAverage': os.getloadavg(), 'monotonic': time.monotonic(),
                      'physicalHostIdentityVerified': False, 'identityScope': 'one hosted VM allocation/boot only'}
            guard.save_json(receipts / (label + '-host.json'), sample)
            return sample
        try:
            result['currentPhase'] = 'authenticate-original-and-candidate-sources'
            original_sdk = root / 'original-baseline-sdk'
            original_core = root / 'original-baseline-Core'
            original_source = fetch('original-baseline-sdk', 'https://github.com/jsflax/Lattice.git', config['baselineSDK'], original_sdk)
            original_core_source = fetch('original-baseline-core', 'https://github.com/jsflax/LatticeCore.git', config['baselineCore'], original_core)
            if original_source['tree'] != config['baselineSDKTree'] or original_core_source['tree'] != config['baselineCoreTree']:
                raise ValueError('original baseline tree mismatch')
            baseline_pins = guard.pins(original_sdk / 'Package.resolved')
            if len(baseline_pins) != 34 or baseline_pins['latticecore']['state']['revision'] != config['baselineCore']:
                raise ValueError('original baseline lock mismatch')
            # Retain the original checkout unchanged; overlay only a separate measured copy.
            for label in ('baseline', 'candidate'):
                home = root / label
                home.mkdir(exist_ok=False)
                for name in ('scratch', 'cache', 'config', 'security', 'module-cache'):
                    (home / name).mkdir(exist_ok=False)
                sdk = home / 'lattice'
                if label == 'baseline':
                    command('baseline-clone', ['git', 'clone', '--no-hardlinks', str(original_sdk), str(sdk)], root)
                    source = guard.authenticate_repository(runner, 'measured-baseline-pristine', sdk, config['baselineSDK'], initial=True)
                    harness = sdk / config['baselineOverlayPath']
                    if harness.exists():
                        raise ValueError('baseline overlay unexpectedly replaces an existing file')
                    shutil.copyfile(PACKET / 'PerfRefinementBenchmarks.swift', harness)
                    sha = config['baselineSDK']
                else:
                    source = fetch('candidate-sdk', 'https://github.com/jsflax/Lattice.git', args.candidate_sdk_sha, sdk)
                    sha = args.candidate_sdk_sha
                    if guard.digest(sdk / config['baselineOverlayPath']) != config['frozenFiles']['PerfRefinementBenchmarks.swift']:
                        raise ValueError('candidate must carry byte-identical frozen harness')
                locked = guard.pins(sdk / 'Package.resolved')
                if {k: v for k, v in locked.items() if k != 'latticecore'} != {k: v for k, v in baseline_pins.items() if k != 'latticecore'}:
                    raise ValueError('non-Core dependency graph differs between original and candidate')
                contexts[label] = {'label': label, 'home': home, 'sdk': sdk, 'sdkSHA': sha, 'source': source, 'pins': locked}
                shutil.copyfile(sdk / 'Package.resolved', receipts / (label + '-Package.resolved.original'))
            candidate = contexts['candidate']
            candidate['core'] = candidate['home'] / 'LatticeCore'
            candidate_core = fetch('candidate-core', 'https://github.com/jsflax/LatticeCore.git', config['candidateCore'], candidate['core'])
            if candidate_core['tree'] != config['candidateCoreTree']:
                raise ValueError('candidate Core tree mismatch')
            toolchain_log = command('swift-version', ['swift', '--version'], root)
            command('test-help', ['swift', 'test', '--help'], root)
            if platform.system() == 'Darwin':
                command('macos-sdk-version', ['xcrun', '--sdk', 'macosx', '--show-sdk-version'], root)
                command('developer-path', ['xcode-select', '-p'], root)
            initial_host = host_sample('initial')
            host_id = 'unverified-physical:github-vm:' + ':'.join(env.get(k, '') for k in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB')) + ':' + initial_host['bootSession']
            guard.save_json(receipts / 'host-allocation.json', {'hostIdentityLabel': host_id, 'initial': initial_host,
                            'physicalHostIdentityVerified': False, 'frozenPhysicalHostGate': 'not satisfied',
                            'claim': 'same Actions job and boot; provider physical placement is not observable'})
            # Build both variants before A/A/B so no compilation is interleaved with measurements.
            for label, context in contexts.items():
                result['currentPhase'] = label + '-Release-build'
                apply_env(context)
                command(label + '-resolve', ['swift', 'package', *common(context), '--force-resolved-versions', 'resolve'], context['sdk'])
                if guard.pins(context['sdk'] / 'Package.resolved') != context['pins']:
                    raise ValueError('versioned resolution changed original complete pins')
                if label == 'candidate':
                    command('candidate-edit-core', ['swift', 'package', *common(context), 'edit', 'LatticeCore', '--path', str(context['core'])], context['sdk'])
                graph(context, 'before')
                context['flags'] = ['-Xswiftc', '-DLATTICE_PERF_SELECTED_BATCH'] if label == 'candidate' else []
                # swift test builds Release with testability; disabled opt-in prevents workload execution here.
                command_args = ['swift', 'test', *common(context), '-c', 'release', '--force-resolved-versions',
                                '--filter', 'PerfRefinementBenchmarks/releaseRead100AndUpdate11', '-j', '2', '-v', *context['flags']]
                build = command(label + '-build-release-disabled-benchmark', command_args, context['sdk'], timeout=config['buildTimeoutSeconds'])
                proof = guard.compiler_input_proof(build, context['core'])
                guard.save_json(receipts / (label + '-compiler-inputs.json'), proof)
                validate_sources(context, 'after-build')
                context['binaryHashes'] = binaries(context)
                context['buildReceipt'] = {'sdk': context['sdkSHA'], 'sdkTree': context['source']['tree'],
                    'core': config['baselineCore'] if label == 'baseline' else config['candidateCore'],
                    'harnessSHA256': config['frozenFiles']['PerfRefinementBenchmarks.swift'],
                    'toolchainLogSHA256': guard.digest(toolchain_log), 'configuration': 'release',
                    'swiftFlags': context['flags'], 'argv': command_args, 'binaryHashes': context['binaryHashes'],
                    'originalLock': context['pins'], 'compilerInputProofSHA256': guard.digest(receipts / (label + '-compiler-inputs.json'))}
                build_receipt_path = receipts / (label + '-build-identity.json')
                guard.save_json(build_receipt_path, context['buildReceipt'])
                context['buildIdentity'] = 'sha256:' + guard.digest(build_receipt_path)
            loaded = {}
            for run_label, implementation in [('A', 'baseline'), ('A2', 'baseline'), ('B', 'candidate')]:
                result['currentPhase'] = run_label + '-measurement'
                context = contexts[implementation]
                apply_env(context)
                # Fixed settling policy is recorded, never asserted to prove an idle physical host.
                command(run_label + '-settle', [sys.executable, '-c', 'import time; time.sleep(60)'], root, timeout=90)
                observed_host = host_sample(run_label)
                for key in ('bootSession', 'hostname', 'operatingSystem', 'cpuCount'):
                    if observed_host[key] != initial_host[key]:
                        raise ValueError('allocation continuity changed before ' + run_label)
                if binaries(context) != context['binaryHashes']:
                    raise ValueError('Release test binary changed before ' + run_label)
                run_directory = root / 'runs' / run_label
                core_sha = config['baselineCore'] if implementation == 'baseline' else config['candidateCore']
                runner.env.update(LATTICE_PERF_REFINEMENT='1', LATTICE_PERF_RUN_DIR=str(run_directory),
                                  LATTICE_PERF_SOURCE_REVISION='git:' + context['sdkSHA'] + ';harness:' + config['frozenFiles']['PerfRefinementBenchmarks.swift'],
                                  LATTICE_PERF_CORE_REVISION='git:' + core_sha,
                                  LATTICE_PERF_BUILD_IDENTITY=context['buildIdentity'], LATTICE_PERF_HOST_ID=host_id,
                                  LATTICE_PERF_SAMPLES='100', LATTICE_PERF_WARMUPS='5',
                                  LATTICE_PERF_VARIANTS='local')
                command(run_label + '-benchmark', ['swift', 'test', *common(context), '-c', 'release', '--force-resolved-versions',
                         '--skip-build', '--filter', 'PerfRefinementBenchmarks/releaseRead100AndUpdate11', *context['flags']],
                        context['sdk'], timeout=config['measurementTimeoutSeconds'], require_full_timeout=True)
                # A command exit0 without the complete frozen result is not a valid measurement.
                loaded[run_label] = report.load_run(run_directory / 'result.json', expected_variants=('local',))
                wanted_write = report.SELECTED_BATCH_WRITES if implementation == 'candidate' else report.LEGACY_WRITES
                if loaded[run_label]['manifest']['writeImplementation'] != wanted_write:
                    raise ValueError('compiled write implementation differs from build receipt')
                guard.save_json(receipts / (run_label + '-exploratory-single-report.json'),
                                {'physicalHostGateSatisfied': False, 'scope': 'hosted VM exploratory data', 'run': loaded[run_label]})
                result['completedMeasurementLabels'].append(run_label)
            # The explicit variant inventory differs; frozen per-sample verifier and comparison math remain unchanged.
            comparison = report.comparison(loaded['A'], loaded['A2'], loaded['B'])
            guard.save_json(receipts / 'EXPLORATORY-COMPARISON.json', {'schemaVersion': 1,
                'qualifiesFrozenPhysicalHostGate': False, 'physicalHostIdentityVerified': False,
                'performanceTargetClaimed': False, 'scope': 'local-only descriptive same-VM-allocation A/A/B; not physical-host qualification',
                'variantScope': 'local-only', 'attachedQualificationClaimed': False, 'fullContractQualified': False,
                'hostAllocationReceipt': 'host-allocation.json', 'runs': loaded,
                'writeImplementations': report.write_comparison(loaded['A'], loaded['A2'], loaded['B']), 'comparison': comparison})
            for context in contexts.values():
                apply_env(context)
                graph(context, 'after')
                validate_sources(context, 'final')
            # The retained original baseline is independently checked again, without its overlay.
            if guard.authenticate_repository(runner, 'original-sdk-final', original_sdk, config['baselineSDK']) != original_source:
                raise ValueError('retained original SDK changed')
            if guard.authenticate_repository(runner, 'original-core-final', original_core, config['baselineCore']) != original_core_source:
                raise ValueError('retained original Core changed')
            result['success'] = True
        except BaseException as error:
            primary = error
            result['primaryError'] = guard.error_record(error)
            result['stopPolicy'] = 'first failure stops A/A/B; no source correction, skipped invariants, retry or fallback baseline'
        finally:
            with interrupts.hold():
                # Preserve partial directories as-is; never fabricate complete results or rewrite paths.
                for label, context in contexts.items():
                    for name, source in [('lock', context['sdk'] / 'Package.resolved'),
                                         ('workspace', context['home'] / 'scratch/workspace-state.json')]:
                        try:
                            shutil.copyfile(source, receipts / (label + '-' + name + '.final.json'))
                        except BaseException as error:
                            result['evidenceErrors'].append({'operation': label + '-' + name, **guard.error_record(error)})
                try:
                    final_resources = runner.measure(receipts / 'RESULT.json')
                    result['finalResources'] = final_resources
                    if runner.violation(final_resources):
                        raise ValueError('final resource guard')
                except BaseException as error:
                    result['evidenceErrors'].append(guard.error_record(error))
                result.update(commands=runner.records, signals=interrupts.received, elapsedSeconds=time.monotonic() - runner.started)
                result['success'] = (result['success'] and primary is None and not result['evidenceErrors']
                                     and not interrupts.received and all(x['success'] for x in runner.records)
                                     and time.monotonic() <= runner.overall_deadline)
                try:
                    guard.save_json(receipts / 'RESULT.json', result)
                except BaseException as error:
                    result['success'] = False
                    print('RESULT_WRITE_FAILED', json.dumps({'result': result, 'error': guard.error_record(error)}), flush=True)
    if not result['success']:
        if primary is not None:
            raise primary
        raise RuntimeError('incomplete exploratory benchmark; no qualifying comparison')


if __name__ == '__main__':
    main()
