#!/usr/bin/env python3
"""Control-first diagnostic only. Never retry, serialize, or qualify a crash as green."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import shlex
import shutil
import sys
import time
import analyze
import crash_reports
import development_supervisor as guard

P = Path(__file__).resolve().parent


def packet(seal_sha):
    seal = P / 'SOURCE-SEAL.json'
    assert guard.digest(seal) == seal_sha, 'source seal differs from reviewed workflow input'
    data = json.loads(seal.read_text())
    assert data['scope'] == 'SDK46 macOS crash diagnostic source packet'
    for name, expected in data['files'].items():
        path = P / name
        assert path.resolve().is_relative_to(P) and not path.is_symlink()
        assert guard.digest(path) == expected, 'source packet drift: ' + name
    return data


def record(runner, label):
    return json.loads((runner.receipts / (label + '.json')).read_text())


def continued_arm_is_safe(row):
    # A failed assertion/process exit can still leave decisive full-suite evidence.
    # A timeout, signal from the guard or uncertain process ownership cannot.
    assert row['started'] and row['exitCode'] is not None
    assert not row.get('primaryError') and not row.get('evidenceErrors')
    assert not row.get('receivedSignals') and not row.get('stopReason')
    assert row['cleanup']['groupGone'] and row['cleanup']['leaderReaped']
    assert not row['cleanup'].get('signals') and not row['cleanup'].get('errors')


def build_identity(build_log, core, root):
    proof = guard.compiler_input_proof(build_log, core)
    objects = []
    for row in proof['samples']:
        argv = shlex.split(row['command'])
        assert '-O0' in argv and '-o' in argv, 'expected actual Debug Core/bridge compiler inputs'
        path = Path(argv[argv.index('-o') + 1]).resolve(strict=True)
        assert path.is_relative_to((root / 'scratch').resolve()) and not path.is_symlink()
        objects.append({'source': row['source'], 'path': str(path), 'sha256': guard.digest(path)})
    assert {x['source'] for x in objects} == set(proof['sourceFiles'])
    binaries = list((root / 'scratch').glob('*/debug/LatticePackageTests.xctest/Contents/MacOS/LatticePackageTests'))
    assert len(binaries) == 1 and binaries[0].is_file()
    proof.update(objects=objects, binaryPath=str(binaries[0]), binarySHA256=guard.digest(binaries[0]))
    return proof


def check_build(proof, proof_path, proof_sha):
    assert guard.digest(proof_path) == proof_sha, 'admitted compiler proof changed'
    assert guard.digest(Path(proof['binaryPath'])) == proof['binarySHA256'], 'admitted test bundle changed'
    for row in proof['objects']:
        assert guard.digest(Path(row['path'])) == row['sha256'], 'admitted compiler object changed'
    for path, expected in proof['sourceFiles'].items():
        assert guard.digest(Path(path)) == expected, 'admitted native source changed'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--source-seal-sha256', required=True)
    args = parser.parse_args()
    assert re.fullmatch('[0-9a-f]{64}', args.source_seal_sha256)
    source = packet(args.source_seal_sha256)
    config = json.loads((P / 'config.json').read_text())
    root = args.root.resolve()
    allowed = (Path.home() / 'localdev').resolve(strict=True)
    assert root.is_relative_to(allowed) and root != allowed and not root.exists()
    root.mkdir(parents=True, exist_ok=False)
    receipts = root / 'receipts'; receipts.mkdir()
    for name in ['tmp', 'module-cache', 'cache', 'config', 'security', 'scratch', 'test-logs', 'control']:
        (root / name).mkdir()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    env = os.environ.copy()
    env.update(TMPDIR=str(root / 'tmp'), TMP=str(root / 'tmp'), TEMP=str(root / 'tmp'),
        CLANG_MODULE_CACHE_PATH=str(root / 'module-cache'), SWIFT_MODULECACHE_PATH=str(root / 'module-cache'),
        SWIFTPM_MODULECACHE_OVERRIDE=str(root / 'module-cache'), PYTHONDONTWRITEBYTECODE='1',
        LATTICE_TEST_LOG_PATH=str(root / 'test-logs/native.log'),
        LATTICE_ACK_PATH_DIAGNOSTICS='1', LATTICE_OBSERVER_WORKER_DIAGNOSTICS='1',
        SWIFT_BACKTRACE=config['swiftBacktrace'])
    result = {'scope': 'diagnosis only; source unchanged; no release or crash-fix qualification',
        'sourceSealSHA256': args.source_seal_sha256, 'sourceFiles': source['files'],
        'sdkCommit': config['sdkCommit'], 'sdkTree': config['sdkTree'],
        'coreCommit': config['coreCommit'], 'coreTree': config['coreTree'],
        'workflowCommit': env.get('GITHUB_SHA'), 'workflowRepository': env.get('GITHUB_REPOSITORY'),
        'runID': env.get('GITHUB_RUN_ID'), 'attempt': env.get('GITHUB_RUN_ATTEMPT'),
        'host': {'os': platform.platform(), 'machine': platform.machine(), 'cpuCount': os.cpu_count()},
        'selectedEnvironment': {k: env[k] for k in ['SWIFT_BACKTRACE', 'LATTICE_ACK_PATH_DIAGNOSTICS', 'LATTICE_OBSERVER_WORKER_DIAGNOSTICS']},
        'coreDumpEnabled': False, 'controlAccepted': False, 'focusedAccepted': False,
        'fullSuiteAccepted': False, 'success': False, 'experimentCompleted': False,
        'releaseQualified': False, 'crashCauseEstablished': False, 'primaryError': None,
        'evidenceErrors': [], 'arms': {}}
    sdk, core = root / 'lattice', root / 'LatticeCore'
    initial_sdk = initial_core = original = proof = collector = None
    proof_path = receipts / 'compiler-input-proof.json'; proof_sha = None
    with guard.Interrupts() as interrupts:
        runner = guard.GuardedRunner(root, receipts, env, interrupts)
        try:
            assert platform.system() == 'Darwin' and platform.machine() == 'arm64'
            assert re.fullmatch('[0-9a-f]{40}', env.get('GITHUB_SHA', '')), 'missing exact workflow commit'
            version = runner.run('swift-version', ['swift', '--version'], cwd=root, timeout=30).read_text()
            assert re.search(r'\bSwift version ' + re.escape(config['swiftVersion']) + r'\b', version), 'unreviewed toolchain'
            # No SDK/Core checkout, resolve, or costly build is admitted before this gate.
            control_source = root / 'control/CrashControl.swift'
            shutil.copyfile(P / 'CrashControl.swift', control_source)
            control_binary = root / 'control/CrashControl'
            runner.run('control-compile', ['swiftc', '-Onone', '-g', '-module-name', 'SDK46CrashControl',
                str(control_source), '-o', str(control_binary)], cwd=root, timeout=60, require_full_timeout=True)
            control_error = None
            try:
                runner.run('control-signal', [str(control_binary)], cwd=root, timeout=10, require_full_timeout=True)
            except Exception as error:
                control_error = guard.error_record(error)
            admission = analyze.control(record(runner, 'control-signal'), (receipts / 'control-signal.log').read_text())
            admission.update(sourceSHA256=guard.digest(control_source), binarySHA256=guard.digest(control_binary),
                expectedCommandError=control_error, runtimeVersion=version, backtrace=env['SWIFT_BACKTRACE'])
            guard.save_json(receipts / 'CONTROL-ADMISSION.json', admission)
            result['controlAccepted'] = True
            for name, url, revision in [('sdk', config['sdkURL'], config['sdkCommit']), ('core', config['coreURL'], config['coreCommit'])]:
                checkout = sdk if name == 'sdk' else core
                runner.run(name + '-init', ['git', 'init', str(checkout)], cwd=root, timeout=60)
                runner.run(name + '-fetch', ['git', 'fetch', '--depth=1', url, revision], cwd=checkout, timeout=600)
                runner.run(name + '-checkout', ['git', 'checkout', '--detach', revision], cwd=checkout, timeout=60)
            initial_sdk = guard.authenticate_repository(runner, 'sdk-initial', sdk, config['sdkCommit'], initial=True)
            initial_core = guard.authenticate_repository(runner, 'core-initial', core, config['coreCommit'], initial=True)
            assert initial_sdk['tree'] == config['sdkTree'] and initial_core['tree'] == config['coreTree']
            development = json.loads((sdk / 'Scripts/development-core.json').read_text())
            assert development['coreCommit'] == config['coreCommit'] and development['coreTree'] == config['coreTree']
            original = guard.pins(sdk / 'Package.resolved'); assert len(original) == 34 and 'latticecore' in original
            for name in ['Package.resolved', 'Package.swift']:
                shutil.copyfile(sdk / name, receipts / (name + '.original'))
            help_text = runner.run('test-help', ['swift', 'test', '--help'], cwd=sdk, timeout=30).read_text()
            for option in ['--filter', '--xunit-output', '--list-tests', '--disable-xctest', '--enable-swift-testing']:
                assert option in help_text, 'required ordinary SwiftPM interface missing: ' + option
            common = ['--package-path', str(sdk), '--scratch-path', str(root / 'scratch'),
                '--cache-path', str(root / 'cache'), '--config-path', str(root / 'config'),
                '--security-path', str(root / 'security'), '--disable-sandbox', '--disable-experimental-prebuilts']
            runner.run('resolve-versioned', ['swift', 'package', *common, '--force-resolved-versions', 'resolve'], cwd=sdk)
            assert guard.pins(sdk / 'Package.resolved') == original
            runner.run('edit-core', ['swift', 'package', *common, 'edit', 'LatticeCore', '--path', str(core)], cwd=sdk)
            graph = runner.run('effective-graph-before', ['swift', 'package', *common, 'show-dependencies', '--format', 'json'], cwd=sdk)
            guard.verify_graph(runner, 'graph-before', guard.read_graph(graph), original, core, config['coreCommit'], root / 'scratch')
            build = runner.run('build-tests', ['swift', 'build', *common, '--force-resolved-versions', '--build-tests', '-j', '2', '-v'], cwd=sdk, timeout=5400, require_full_timeout=True)
            proof = build_identity(build, core, root); guard.save_json(proof_path, proof); proof_sha = guard.digest(proof_path)
            result.update(compilerProofSHA256=proof_sha, binarySHA256=proof['binarySHA256'])
            discovery = runner.run('test-discovery', ['swift', 'test', *common, '--force-resolved-versions', '--skip-build', '--disable-xctest', '--enable-swift-testing', '--list-tests'], cwd=sdk, timeout=180, require_full_timeout=True)
            identifiers = analyze.discovery(discovery.read_text(), config['focusedIdentifiers'])
            guard.save_json(receipts / 'FOCUSED-DISCOVERY.json', {'identifiers': identifiers, 'count': len(identifiers)})
            filter_value = '^(?:' + '|'.join(re.escape(item) for item in identifiers) + ')$'
            for arm in ['focused', 'full']:
                check_build(proof, proof_path, proof_sha)
                started_at = time.time()
                if collector is None:
                    collector = crash_reports.Collector(root, receipts / 'crash-reports', started_at)
                argv = ['swift', 'test', *common, '--force-resolved-versions', '--skip-build']
                if arm == 'focused':
                    argv += ['--disable-xctest', '--enable-swift-testing', '--filter', filter_value,
                             '--xunit-output', str(receipts / 'focused.xml')]
                # Full arm retains original selection, default concurrency and exact timeout.
                error = None
                try:
                    log = runner.run(arm + '-test', argv, cwd=sdk, timeout=1800, require_full_timeout=True)
                    if arm == 'focused':
                        observed = analyze.focused(record(runner, arm + '-test'), (receipts / 'focused.xml').read_text(), log.read_text(), identifiers)
                    else:
                        observed = analyze.full(record(runner, arm + '-test'), log.read_text())
                    result[('focusedAccepted' if arm == 'focused' else 'fullSuiteAccepted')] = True
                except Exception as failure:
                    error = guard.error_record(failure); observed = None
                    guard.save_json(receipts / ('crash-scan-' + arm + '.json'), collector.scan('after-' + arm))
                result['arms'][arm] = {'observed': observed, 'error': error, 'startedAtEpoch': started_at}
                check_build(proof, proof_path, proof_sha)
                continued_arm_is_safe(record(runner, arm + '-test'))
            result['experimentCompleted'] = True
        except BaseException as error:
            result['primaryError'] = guard.error_record(error)
        finally:
            with interrupts.hold():
                def evidence(name, action):
                    try:
                        return action()
                    except BaseException as error:
                        result['evidenceErrors'].append({'operation': name, **guard.error_record(error)})
                evidence('source packet final', lambda: packet(args.source_seal_sha256))
                if proof is not None:
                    evidence('admitted build final', lambda: check_build(proof, proof_path, proof_sha))
                if original is not None:
                    def final_graph():
                        graph = runner.run('effective-graph-final', ['swift', 'package', *common, 'show-dependencies', '--format', 'json'], cwd=sdk)
                        guard.verify_graph(runner, 'graph-final', guard.read_graph(graph), original, core, config['coreCommit'], root / 'scratch')
                        current = guard.pins(sdk / 'Package.resolved')
                        before = {k: v for k, v in original.items() if k != 'latticecore'}
                        after = {k: v for k, v in current.items() if k != 'latticecore'}
                        assert before == after and len(before) == 33
                        result.update(nonCorePinsUnchanged=True, nonCorePinCount=33)
                        shutil.copyfile(sdk / 'Package.resolved', receipts / 'Package.resolved.final')
                    evidence('final effective graph and lock', final_graph)
                for name, checkout, initial in [('sdk', sdk, initial_sdk), ('core', core, initial_core)]:
                    if initial is not None:
                        def check_source(name=name, checkout=checkout, initial=initial):
                            final = guard.authenticate_repository(runner, name + '-final', checkout, config[name + 'Commit'],
                                allowed_changes=('Package.resolved',) if name == 'sdk' else ())
                            before = {k: v for k, v in initial['files'].items() if name != 'sdk' or k != 'Package.resolved'}
                            assert final['files'] == before and final['tree'] == initial['tree']
                        evidence(name + ' final source', check_source)
                if collector is not None and any(x.get('error') for x in result['arms'].values()):
                    evidence('late crash reports', lambda: guard.save_json(receipts / 'crash-scan-late.json', collector.scan('after-final-authentication')))
                if collector is not None:
                    evidence('aggregate crash report custody', lambda: guard.save_json(receipts / 'crash-aggregate.json', collector.snapshot()))
                def final_resources():
                    measured = runner.measure(receipts / 'RESULT.json'); result['finalResource'] = measured
                    assert not runner.violation(measured), runner.violation(measured)
                    for row in runner.records:
                        saved = record(runner, row['label'])
                        if row['label'] == 'control-signal' and result['controlAccepted']:
                            analyze.control(saved, (receipts / 'control-signal.log').read_text())
                        elif row['label'] in ['focused-test', 'full-test']:
                            continued_arm_is_safe(saved)
                        else:
                            analyze.clean(saved)
                        path = receipts / (row['label'] + '.log')
                        assert guard.digest(path) == saved['logSHA256']
                    assert time.monotonic() <= runner.overall_deadline, 'overall deadline at final acceptance'
                evidence('final resources/commands/deadline', final_resources)
                result.update(commands=runner.records, receivedSignals=interrupts.received,
                    elapsedSeconds=time.monotonic() - runner.started)
                custody_ok = not result['primaryError'] and not result['evidenceErrors'] and not interrupts.received
                if not custody_ok:
                    result.update(experimentCompleted=False, focusedAccepted=False, fullSuiteAccepted=False)
                result['success'] = custody_ok and result['controlAccepted'] and result['experimentCompleted'] and result['focusedAccepted'] and result['fullSuiteAccepted']
                try:
                    guard.save_json(receipts / 'RESULT.json', result)
                except BaseException as error:
                    result.update(success=False, experimentCompleted=False, focusedAccepted=False, fullSuiteAccepted=False)
                    result['evidenceErrors'].append({'operation': 'RESULT write', **guard.error_record(error)})
                    print('FINAL_RESULT_WRITE_FAILED', json.dumps(result), flush=True)
    return 0 if result['success'] else 1


if __name__ == '__main__':
    sys.exit(main())
