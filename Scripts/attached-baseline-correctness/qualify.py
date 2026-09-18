#!/usr/bin/env python3
"""One-shot original/corrected attached correctness. No benchmark workload."""
from pathlib import Path
import argparse
import json
import os
import platform
import shutil
import sys
import time
import guarded_runner as guard
import analyze
import build_proof

P = Path(__file__).resolve().parent
load = lambda p: json.loads(p.read_text())

def finalize_acceptance(result):
    result['success'] = bool(result['success'] and result['primaryError'] is None
        and not result['evidenceErrors'] and not result.get('receivedSignals'))
    if not result['success']:
        result.update(experimentCompleted=False, correctedFocusedAccepted=False)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--packet-seal-sha256', required=True)
    parser.add_argument('--sdk-seed', type=Path)
    parser.add_argument('--core-seed', type=Path)
    args = parser.parse_args()
    seal_path = P / 'PACKET-SEAL.json'
    def inputs():
        assert guard.digest(seal_path) == args.packet_seal_sha256
        for name, digest in load(seal_path)['files'].items():
            assert guard.digest(P / name) == digest, 'prepared input changed: ' + name
    inputs()
    config = load(P / 'config.json')
    root = args.root.absolute()
    allowed = (Path.home() / 'localdev').resolve(strict=True)
    assert root.parent.resolve(strict=True).is_relative_to(allowed) and not root.exists()
    root.mkdir(exist_ok=False); root = root.resolve(strict=True)
    receipts = root / 'receipts'; receipts.mkdir(); (root / 'tmp').mkdir()
    env = {k: os.environ[k] for k in ('HOME', 'USER', 'LOGNAME') if k in os.environ}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8',
        DEVELOPER_DIR=config['developerDirectory'], TMPDIR=str(root / 'tmp'),
        TMP=str(root / 'tmp'), TEMP=str(root / 'tmp'), PYTHONDONTWRITEBYTECODE='1',
        LATTICE_PERF_REFINEMENT='0', LATTICE_ATTACHED_CORRECTNESS='0')
    result = {'success': False, 'experimentCompleted': False, 'originalSafetyAccepted': False,
        'correctedFocusedAccepted': False, 'reproductionConfirmed': False,
        'performanceQualified': False, 'fullContractQualified': False,
        'legacyChecksQualified': False, 'scope': config['scope'], 'arms': {},
        'packetSealSHA256': args.packet_seal_sha256, 'primaryError': None, 'evidenceErrors': []}
    contexts = {}; expected_nonzero = set(); baseline_sources = {}
    with guard.Interrupts() as interrupts:
        runner = guard.GuardedRunner(root, receipts, env, interrupts,
            free_floor=config['freeFloorBytes'], packet_ceiling=config['packetCeilingBytes'],
            log_ceiling=config['logCeilingBytes'], overall_seconds=config['overallSeconds'],
            reserve=config['reserveSeconds'], poll_seconds=.5, signal_grace=3)
        def command(label, argv, cwd=root, timeout=60):
            log = runner.run(label, argv, cwd=cwd, timeout=timeout, require_full_timeout=True)
            analyze.command(load(receipts / (label + '.json')))
            return log
        def clone(label, source, destination, commit, tree):
            command(label + '-clone', ['git', 'clone', '--no-hardlinks', '--no-checkout', str(source), str(destination)])
            command(label + '-checkout', ['git', 'checkout', '--detach', commit], destination)
            proof = guard.authenticate_repository(runner, label + '-pristine', destination, commit, initial=True)
            assert proof['tree'] == tree
            return proof
        def pristine(label, seed, repository, destination, commit, tree):
            if seed is not None:
                seed = seed.resolve(strict=True)
                assert seed.is_dir()
                return clone(label, seed, destination, commit, tree)
            command(label + '-init', ['git', 'init', str(destination)])
            command(label + '-fetch', ['git', 'fetch', '--depth=1', repository, commit], destination, timeout=600)
            command(label + '-checkout', ['git', 'checkout', '--detach', commit], destination)
            proof = guard.authenticate_repository(runner, label + '-pristine', destination, commit, initial=True)
            assert proof['tree'] == tree
            return proof
        def common(context):
            home = context['home']
            return ['--package-path', str(context['sdk']), '--scratch-path', str(home / 'scratch'),
                '--cache-path', str(home / 'cache'), '--config-path', str(home / 'config'),
                '--security-path', str(home / 'security'), '--disable-sandbox', '--disable-experimental-prebuilts']
        def use(context, *, enabled=False):
            home = context['home']
            runner.env = dict(env, TMPDIR=str(home / 'tmp'), TMP=str(home / 'tmp'), TEMP=str(home / 'tmp'),
                CLANG_MODULE_CACHE_PATH=str(home / 'module-cache'), SWIFT_MODULECACHE_PATH=str(home / 'module-cache'),
                SWIFTPM_MODULECACHE_OVERRIDE=str(home / 'module-cache'),
                LATTICE_TEST_LOG_PATH=str(home / 'logs/native.log'),
                LATTICE_ATTACHED_CORRECTNESS='1' if enabled else '0',
                LATTICE_ATTACHED_CORRECTNESS_ROOT=str(home / 'case-run-001'))
        def sources(context, phase):
            allowed_changes = [config['overlay'], 'Package.resolved']
            if context['arm'] == 'corrected': allowed_changes.append(config['productFile'])
            current = guard.authenticate_repository(runner, context['arm'] + '-' + phase + '-sdk',
                context['sdk'], config['sdkCommit'], allowed_changes=tuple(allowed_changes))
            original = {k: v for k, v in context['pristine']['files'].items() if k not in allowed_changes}
            assert current['files'] == original
            assert guard.digest(context['sdk'] / config['overlay']) == guard.digest(P / 'AttachedBaselineCorrectnessTests.swift')
            expected_product = config['productBeforeSHA256'] if context['arm'] == 'original' else config['productAfterSHA256']
            assert guard.digest(context['sdk'] / config['productFile']) == expected_product
            assert guard.pins(context['sdk'] / 'Package.resolved') == context['pins']
            return {'sdkCommit': config['sdkCommit'], 'sdkTree': config['sdkTree'],
                'actualSDKFiles': guard.tracked_manifest(context['sdk'], context['pristine']['files']),
                'overlaySHA256': guard.digest(context['sdk'] / config['overlay']),
                'productSHA256': expected_product, 'completePins': context['pins']}
        def graph(context, phase):
            label = context['arm'] + '-' + phase
            log = command(label + '-dependency-graph', [config['swift'], 'package', *common(context), 'show-dependencies', '--format', 'json'], context['sdk'])
            nodes = guard.graph_nodes(guard.read_graph(log))
            state_path = context['home'] / 'scratch/workspace-state.json'
            entries = load(state_path)['object']['dependencies']
            entries_by_id = {x['packageRef']['identity']: x for x in entries}
            assert len(entries_by_id) == len(entries) == config['expectedPins']
            assert set(nodes) == set(entries_by_id) == set(context['pins'])
            proof = []
            for identity in sorted(nodes):
                node, entry, pin = nodes[identity], entries_by_id[identity], context['pins'][identity]
                path = Path(node['path']).resolve(strict=True)
                expected = (context['home'] / 'scratch/checkouts' / entry['subpath']).resolve(strict=True)
                assert path == expected and path.is_relative_to((context['home'] / 'scratch/checkouts').resolve())
                assert entry['state']['name'] == 'sourceControlCheckout' and entry['state']['checkoutState'] == pin['state']
                assert guard.url_key(node['url']) == guard.url_key(pin['location']) == guard.url_key(entry['packageRef']['location'])
                head = command(label + '-' + identity + '-head', ['git', 'rev-parse', 'HEAD'], path).read_text().strip()
                dirty = command(label + '-' + identity + '-status', ['git', 'status', '--porcelain=v1', '--untracked-files=all'], path).read_text()
                assert not dirty and head == pin['state']['revision']
                proof.append({'identity': identity, 'path': str(path), 'revision': head})
                if identity == 'latticecore':
                    context['core'] = path
                    core_source = guard.authenticate_repository(runner, label + '-core-source', path, config['coreCommit'])
                    assert core_source['tree'] == config['coreTree']
                    assert core_source['files'] == baseline_sources['core']['files']
                    context['coreSource'] = core_source
            guard.save_json(receipts / (label + '-graph-proof.json'), {'dependencies': proof,
                'workspaceStateSHA256': guard.digest(state_path), 'lock': context['pins']})
        def verify_build(context):
            arm = context['arm']; identity = context['buildIdentity']
            assert load(receipts / (arm + '-build-result.json')) == identity
            for suffix, key in [('source-proof', 'sourceProofSHA256'),
                    ('compiler-proof', 'compilerProofSHA256'), ('release-build', 'commandReceiptSHA256')]:
                assert guard.digest(receipts / (arm + '-' + suffix + '.json')) == identity[key]
            analyze.command(load(receipts / (arm + '-release-build.json')))
            assert load(receipts / (arm + '-compiler-proof.json')) == context['compilerProof']
            assert context['compilerProof']['binarySHA256'] == identity['binarySHA256']
            build_proof.verify(context['compilerProof'])
        try:
            assert platform.system() == 'Darwin' and platform.machine() == 'arm64'
            guard.save_json(receipts / 'invocation.json', {'environment': env, 'config': config,
                'packetSealSHA256': args.packet_seal_sha256, 'nativeExecutionBeforeInvocation': False})
            command('local-swift-version', [config['swift'], '--version'])
            command('local-macos-sdk', ['xcrun', '--sdk', 'macosx', '--show-sdk-version'])
            baseline_sdk = root / 'pristine-sdk'; baseline_core = root / 'pristine-core'
            baseline_sources['sdk'] = pristine('pristine-sdk', args.sdk_seed, config['sdkRepository'], baseline_sdk, config['sdkCommit'], config['sdkTree'])
            baseline_sources['core'] = pristine('pristine-core', args.core_seed, config['coreRepository'], baseline_core, config['coreCommit'], config['coreTree'])
            pins = guard.pins(baseline_sdk / 'Package.resolved')
            assert len(pins) == config['expectedPins'] and pins['latticecore']['state']['revision'] == config['coreCommit']
            for arm in ('original', 'corrected'):
                home = root / arm; home.mkdir()
                for name in ('tmp', 'scratch', 'cache', 'config', 'security', 'module-cache', 'logs'):
                    (home / name).mkdir()
                sdk = home / 'lattice'
                pristine = clone(arm + '-sdk', baseline_sdk, sdk, config['sdkCommit'], config['sdkTree'])
                assert pristine['files'] == baseline_sources['sdk']['files']
                context = {'arm': arm, 'home': home, 'sdk': sdk, 'pristine': pristine, 'pins': pins}
                contexts[arm] = context
                overlay = sdk / config['overlay']; assert not overlay.exists()
                shutil.copyfile(P / 'AttachedBaselineCorrectnessTests.swift', overlay)
                if arm == 'corrected': command('corrected-product-overlay', ['git', 'apply', '--whitespace=error-all', str(P / 'product.patch')], sdk)
                use(context)
                command(arm + '-resolve', [config['swift'], 'package', *common(context), '--force-resolved-versions', 'resolve'], sdk, timeout=600)
                assert guard.pins(sdk / 'Package.resolved') == pins
                graph(context, 'before-build')
                source = sources(context, 'before-build')
                guard.save_json(receipts / (arm + '-source-proof.json'), source)
                argv = [config['swift'], 'build', *common(context), '-c', 'release', '--force-resolved-versions', '--build-tests', '-Xswiftc', '-enable-testing', '-j', str(config['j']), '-v']
                log = command(arm + '-release-build', argv, sdk, timeout=config['buildSeconds'])
                proof = build_proof.make(log, sdk, context['core'], home / 'scratch', config['overlay'])
                guard.save_json(receipts / (arm + '-compiler-proof.json'), proof)
                assert sources(context, 'after-build') == source
                graph(context, 'after-build')
                context['compilerProof'] = proof
                context['buildIdentity'] = {'success': True, 'sourceProofSHA256': guard.digest(receipts / (arm + '-source-proof.json')),
                    'compilerProofSHA256': guard.digest(receipts / (arm + '-compiler-proof.json')),
                    'commandReceiptSHA256': guard.digest(receipts / (arm + '-release-build.json')),
                    'packetSealSHA256': args.packet_seal_sha256, 'binarySHA256': proof['binarySHA256']}
                guard.save_json(receipts / (arm + '-build-result.json'), context['buildIdentity'])
            # Both fresh builds are finished before either correctness arm runs.
            for arm, context in contexts.items():
                inputs(); use(context, enabled=True)
                verify_build(context)
                assert sources(context, 'before-tests') == load(receipts / (arm + '-source-proof.json'))
                expected = load(P / 'expected-tests.json')
                log = command(arm + '-discovery', [config['swift'], 'test', *common(context), '-c', 'release', '--skip-build', 'list'], context['sdk'])
                discovered = analyze.discover(log.read_text(), expected)
                guard.save_json(receipts / (arm + '-selected-discovery.json'), {'actual': discovered})
                cases = context['home'] / 'case-run-001'; cases.mkdir(exist_ok=False)
                xml = receipts / (arm + '-testing-cases.xml')
                label = arm + '-focused-tests'
                argv = [config['swift'], 'test', *common(context), '-c', 'release', '--skip-build', '--force-resolved-versions',
                    '--disable-xctest', '--enable-swift-testing', '--filter', '^LatticeTests.AttachedBaselineCorrectnessTests/', '--xunit-output', str(xml)]
                caught = None
                try: runner.run(label, argv, cwd=context['sdk'], timeout=config['testSeconds'], require_full_timeout=True)
                except BaseException as error: caught = error
                record = load(receipts / (label + '.json'))
                analyze.command(record, 1 if arm == 'original' else 0)
                actual = analyze.framework(xml.read_text(), (receipts / (label + '.log')).read_text(), arm)
                case_data = analyze.case_receipts(cases, arm)
                physical = analyze.physical_postimages(cases, arm)
                if arm == 'original':
                    assert caught is not None
                    expected_nonzero.add(label); result['reproductionConfirmed'] = True
                else: assert caught is None
                arm_result = {'experimentCompleted': True, 'success': arm == 'corrected',
                    'safetyAccepted': arm == 'corrected', 'expectedRedConfirmed': arm == 'original',
                    'actual': actual, 'buildIdentity': context['buildIdentity'], 'physical': physical,
                    'xmlSHA256': guard.digest(xml), 'caseReceipts': {name: guard.digest(cases / name / 'RESULT.json') for name in case_data}}
                guard.save_json(receipts / (arm + '-correctness-result.json'), arm_result)
                result['arms'][arm] = arm_result
                build_proof.verify(context['compilerProof'])
                assert sources(context, 'after-tests') == load(receipts / (arm + '-source-proof.json'))
                graph(context, 'after-tests')
            assert guard.authenticate_repository(runner, 'pristine-sdk-final', baseline_sdk, config['sdkCommit']) == baseline_sources['sdk']
            assert guard.authenticate_repository(runner, 'pristine-core-final', baseline_core, config['coreCommit']) == baseline_sources['core']
            result.update(experimentCompleted=True, correctedFocusedAccepted=True)
            # Original safety remains red. This exit/overall success is not a
            # benchmark, release, or original-baseline qualification.
            result['success'] = True
        except BaseException as error:
            result['primaryError'] = guard.error_record(error)
        finally:
            with interrupts.hold():
                try:
                    inputs()
                    for entry in runner.records:
                        analyze.command(load(receipts / (entry['label'] + '.json')), 1 if entry['label'] in expected_nonzero else 0)
                    for context in contexts.values():
                        if 'buildIdentity' in context: verify_build(context)
                        elif 'compilerProof' in context: build_proof.verify(context['compilerProof'])
                    result['finalResources'] = runner.measure(receipts / 'final-resource-probe-unused.log')
                    assert not runner.violation(result['finalResources']) and not interrupts.received
                    assert time.monotonic() < runner.overall_deadline
                except BaseException as error:
                    result['evidenceErrors'].append(guard.error_record(error)); result['success'] = False
                result.update(receivedSignals=list(interrupts.received), commandRecords=runner.records,
                    elapsedSeconds=time.monotonic() - runner.started)
                finalize_acceptance(result)
                try: guard.save_json(receipts / 'qualification-result.json', result)
                except BaseException as error:
                    result['success'] = False; result['evidenceErrors'].append(guard.error_record(error))
                    finalize_acceptance(result)
                    print('QUALIFICATION_RECEIPT_FAILED', json.dumps(result), flush=True)
    print(json.dumps(result), flush=True)
    return 0 if result['success'] else 1

if __name__ == '__main__': sys.exit(main())
