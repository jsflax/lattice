#!/usr/bin/env python3
"""Exact A/B WASM compilation and JS unit checks; never browser qualification."""
import argparse
from collections import Counter
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import time

HERE = Path(__file__).resolve().parent
# Import only after authenticating the exact reviewed supervisor bytes.
import hashlib
supervisor = HERE / 'development_supervisor.py'
config = json.loads((HERE / 'config.json').read_text())
assert hashlib.sha256(supervisor.read_bytes()).hexdigest() == config['supervisorSHA256']
spec = importlib.util.spec_from_file_location('development_supervisor', supervisor)
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


def source_proof(runner, label, repository, expected):
    identity = runner.run(label + '-identity', ['git', 'show', '--no-patch', '--format=%H %T', 'HEAD'], cwd=repository, timeout=60).read_text().strip().split()
    if len(identity) != 2 or identity[0] != expected:
        raise ValueError('wrong exact source: ' + label)
    status = runner.run(label + '-tracked-status', ['git', 'status', '--porcelain=v1', '--untracked-files=no'], cwd=repository, timeout=60).read_text()
    if status:
        raise ValueError('tracked source changed: ' + label + ': ' + status)
    names = runner.run(label + '-tracked-files', ['git', 'ls-files', '-s', '-z'], cwd=repository, timeout=60).read_text().split('\0')
    files = {}
    for entry in filter(None, names):
        prefix, name = entry.split('\t', 1)
        mode, obj, stage = prefix.split()
        if stage != '0':
            raise ValueError('unmerged source')
        path = repository / name
        if mode == '160000':
            files[name] = {'gitlink': obj}  # Never silently use this Core submodule.
        elif path.is_symlink():
            files[name] = {'symlink': os.readlink(path)}
        else:
            files[name] = {'sha256': support.digest(path), 'bytes': path.stat().st_size}
    proof = {'commit': identity[0], 'tree': identity[1], 'files': files}
    support.save_json(runner.receipts / (label + '-source.json'), proof)
    return proof


def fetch(runner, label, path, repository, commit):
    if path.exists() or not support.SHA.fullmatch(commit):
        raise ValueError('fresh exact checkout required: ' + label)
    runner.run(label + '-init', ['git', 'init', str(path)], cwd=runner.root, timeout=60)
    runner.run(label + '-fetch', ['git', 'fetch', '--depth=1', repository, commit], cwd=path, timeout=300)
    runner.run(label + '-checkout', ['git', 'checkout', '--detach', commit], cwd=path, timeout=60)
    return source_proof(runner, label + '-initial', path, commit)


def compiler_proof(log, build, core):
    expected = {p.resolve() for folder in ['Sources/LatticeCore/src', 'Sources/LatticeSwiftCppBridge/src', 'Sources/LatticeCAPI/src'] for p in (core / folder).rglob('*.cpp')}
    commands = json.loads((build / 'compile_commands.json').read_text())
    configured = {Path(c['file']).resolve() for c in commands if '/Sources/' in c['file'] and c['file'].endswith('.cpp')}
    # JS bindings are outside Sources. All configured shared C++ source must be this Core.
    if configured != expected or not expected:
        raise ValueError('configured Core/bridge/CAPI inputs differ from exact override')
    observed = set()
    for line in log.read_text(errors='replace').splitlines():
        if ' -c ' not in line:
            continue
        try:
            argv = shlex.split(line)
        except ValueError:
            continue
        if '-c' not in argv:
            continue
        source = Path(argv[argv.index('-c') + 1]).resolve()
        if source in expected:
            observed.add(source)
        elif any(x in str(source) for x in ['/Sources/LatticeCore/src/', '/Sources/LatticeSwiftCppBridge/src/', '/Sources/LatticeCAPI/src/']):
            raise ValueError('compiler consumed an unexpected Core source')
    if observed != expected:
        raise ValueError('missing actual verbose compiler input evidence: ' + str(sorted(str(p) for p in expected - observed)))
    return {'corePath': str(core), 'files': {str(p.relative_to(core)): support.digest(p) for p in sorted(expected)}, 'compileCommandsSHA256': support.digest(build / 'compile_commands.json')}


def qualify_arm(runner, arm, core_sha, result):
    root, receipts = runner.root, runner.receipts
    js, core = root / ('js-' + arm), root / ('core-' + arm)
    before_js = fetch(runner, arm + '-js', js, config['jsRepository'], config['jsCommit'])
    before_core = fetch(runner, arm + '-core', core, 'https://github.com/jsflax/LatticeCore.git', core_sha)
    if arm == 'A' and before_js['files']['LatticeCore']['gitlink'] != core_sha:
        raise ValueError('baseline differs from actual JS gitlink')
    if arm == 'B' and before_core['tree'] != config['candidateCoreTree']:
        raise ValueError('candidate tree mismatch')
    runner.env['LATTICECORE_DIR'] = str(core)
    build = js / 'wasm/build'
    runner.run(arm + '-configure', ['emcmake', 'cmake', '-S', str(js / 'wasm'), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', '-DFETCHCONTENT_BASE_DIR=' + str(root / ('cache/sqlite-' + arm)), '-DLATTICE_CPP_DIR=' + str(core)], cwd=js, timeout=600)
    build_log = runner.run(arm + '-wasm-build', ['cmake', '--build', str(build), '--parallel', '2', '--verbose'], cwd=js, timeout=900)
    support.save_json(receipts / (arm + '-compiler-input-proof.json'), compiler_proof(build_log, build, core))
    shutil.copyfile(build / 'CMakeCache.txt', receipts / (arm + '-CMakeCache.txt'))
    shutil.copyfile(build / 'compile_commands.json', receipts / (arm + '-compile_commands.json'))
    sizes = {'lattice.wasm': (1000000, 20000000), 'lattice.js': (50000, 20000000)}
    artifacts = {}
    for name, (minimum, maximum) in sizes.items():
        file = build / name
        if not minimum <= file.stat().st_size <= maximum:
            raise ValueError('missing or suspicious artifact: ' + name)
        artifacts[name] = {'bytes': file.stat().st_size, 'sha256': support.digest(file)}
        shutil.copyfile(file, receipts / (arm + '-' + name))
    sqlite_sources = list((root / ('cache/sqlite-' + arm)).rglob('sqlite3.c'))
    if len(sqlite_sources) != 1:
        raise ValueError('SQLite amalgamation provenance is ambiguous')
    runner.run(arm + '-npm-ci', ['npm', 'ci', '--cache', str(root / 'cache/npm')], cwd=js, timeout=600)
    runner.run(arm + '-typescript-build', ['npm', 'run', 'build:ts'], cwd=js, timeout=300)
    report = receipts / (arm + '-vitest-report.json')
    runner.run(arm + '-vitest', [str(js / 'node_modules/.bin/vitest'), 'run', '--maxWorkers=2', '--minWorkers=2', '--reporter=json', '--outputFile=' + str(report)], cwd=js, timeout=300)
    tests = json.loads(report.read_text())
    assertions = [case for suite in tests.get('testResults', []) for case in suite.get('assertionResults', [])]
    if not tests.get('success') or not assertions or any(case.get('status') != 'passed' for case in assertions):
        raise ValueError('Vitest missing, failed, skipped or pending cases')
    counts = Counter(case.get('status') for case in assertions)
    names = sorted(case.get('fullName') or case.get('title') for case in assertions)
    final_js = source_proof(runner, arm + '-js-final', js, config['jsCommit'])
    final_core = source_proof(runner, arm + '-core-final', core, core_sha)
    if before_js != final_js or before_core != final_core:
        raise ValueError('tracked sources changed during qualification')
    result.update(success=True, core=before_core['commit'], coreTree=before_core['tree'], js=before_js['commit'], jsTree=before_js['tree'], artifacts=artifacts, sqliteSHA256=support.digest(sqlite_sources[0]), nodeTestCounts=dict(counts), nodeTestNames=names, browserCompatibility=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    if not root.is_relative_to((Path.home() / 'localdev').resolve(strict=True)) or root == (Path.home() / 'localdev').resolve() or re.search(r'\s', str(root)):
        raise ValueError('fresh whitespace-free owned localdev root required')
    receipts = root / 'receipts'; receipts.mkdir(exist_ok=False)
    env = os.environ.copy()
    for name in ['tmp', 'cache/npm', 'cache/emscripten', 'module-cache']:
        (root / name).mkdir(parents=True, exist_ok=True)
    env.update(TMPDIR=str(root / 'tmp'), TMP=str(root / 'tmp'), TEMP=str(root / 'tmp'), npm_config_cache=str(root / 'cache/npm'), EM_CACHE=str(root / 'cache/emscripten'), CLANG_MODULE_CACHE_PATH=str(root / 'module-cache'), PYTHONDONTWRITEBYTECODE='1')
    result = {'scope': config['scope'], 'browserCompatibility': False, 'releaseGraphAccepted': False, 'success': False, 'arms': {}, 'primaryError': None, 'evidenceErrors': [], 'workflowCommit': env.get('GITHUB_SHA'), 'runID': env.get('GITHUB_RUN_ID'), 'runAttempt': env.get('GITHUB_RUN_ATTEMPT'), 'runnerOS': platform.platform(), 'configSHA256': support.digest(HERE / 'config.json'), 'runnerSHA256': support.digest(Path(__file__)), 'supervisorSHA256': support.digest(supervisor)}
    primary = None
    with support.Interrupts() as interrupts:
        runner = support.GuardedRunner(root, receipts, env, interrupts, free_floor=config['freeFloorBytes'], packet_ceiling=config['packetCeilingBytes'], log_ceiling=config['perCommandLogCeilingBytes'], overall_seconds=config['overallSeconds'], reserve=config['finalizationReserveSeconds'])
        try:
            sdk = root / 'emsdk'
            fetch(runner, 'emsdk', sdk, 'https://github.com/emscripten-core/emsdk.git', config['emsdkCommit'])
            tags = json.loads((sdk / 'emscripten-releases-tags.json').read_text())
            if tags['releases'][config['emsdkVersion']] != config['emscriptenReleaseRevision']:
                raise ValueError('official emsdk tool bundle mismatch')
            runner.run('emsdk-install', [str(sdk / 'emsdk'), 'install', config['emsdkVersion']], cwd=sdk, timeout=600)
            runner.run('emsdk-activate', [str(sdk / 'emsdk'), 'activate', config['emsdkVersion']], cwd=sdk, timeout=120)
            runner.run('node-install', [str(sdk / 'emsdk'), 'install', 'node-' + config['nodeVersion'] + '-64bit'], cwd=sdk, timeout=300)
            node_bin = sdk / ('node/' + config['nodeVersion'] + '_64bit/bin')
            if not (node_bin / 'node').is_file() or not (node_bin / 'npm').is_file():
                raise ValueError('exact emsdk Node20 layout is unavailable')
            runner.env.update(PATH=str(node_bin) + os.pathsep + str(sdk / 'upstream/emscripten') + os.pathsep + env['PATH'], EMSDK=str(sdk), EM_CONFIG=str(sdk / '.emscripten'))
            node_version = runner.run('node-version', ['node', '--version'], cwd=root, timeout=60).read_text().strip()
            if node_version != 'v' + config['nodeVersion']:
                raise ValueError('wrong Node runtime')
            emcc_version = runner.run('emcc-version', ['emcc', '--version'], cwd=root, timeout=60).read_text()
            if not re.search(r'\b' + re.escape(config['emsdkVersion']) + r'\b', emcc_version):
                raise ValueError('wrong emcc version')
            runner.run('npm-version', ['npm', '--version'], cwd=root, timeout=60)
            runner.run('cmake-version', ['cmake', '--version'], cwd=root, timeout=60)
            shutil.copyfile(sdk / '.emscripten', receipts / 'emscripten-config.txt')
            support.save_json(receipts / 'toolchain.json', {'emsdkCommit':config['emsdkCommit'],'releaseRevision':config['emscriptenReleaseRevision'],'nodeVersion':node_version,'emccVersion':emcc_version,'manifestSHA256':support.digest(sdk / 'emsdk_manifest.json')})
            for arm, sha in [('A', config['baselineCore']), ('B', config['candidateCore'])]:
                arm_result = {'success':False,'browserCompatibility':False,'core':sha}
                result['arms'][arm] = arm_result
                try:
                    qualify_arm(runner, arm, sha, arm_result)
                except BaseException as error:
                    arm_result['error'] = support.error_record(error)
                    primary = primary or error
                    if interrupts.received or runner.violation(runner.measure(receipts / 'PARTIAL-RESULT.json')) or time.monotonic() >= runner.work_deadline:
                        raise
                finally:
                    support.save_json(receipts / (arm + '-PARTIAL-RESULT.json'), arm_result)
            if all(arm.get('success') for arm in result['arms'].values()) and len(result['arms']) == 2:
                if result['arms']['A']['nodeTestNames'] != result['arms']['B']['nodeTestNames']:
                    raise ValueError('A/B named Node test discovery differs')
                result['success'] = True
        except BaseException as error:
            primary = primary or error
        finally:
            with interrupts.hold():
                result['primaryError'] = support.error_record(primary) if primary else None
                result.update(commands=runner.records, receivedSignals=interrupts.received, elapsedSeconds=time.monotonic()-runner.started)
                try:
                    result['finalResources'] = runner.measure(receipts / 'PARTIAL-RESULT.json')
                    violation = runner.violation(result['finalResources'])
                    if violation: raise RuntimeError(violation)
                except BaseException as error:
                    result['evidenceErrors'].append(support.error_record(error))
                result['success'] = result['success'] and primary is None and not interrupts.received and not result['evidenceErrors'] and all(c['success'] for c in runner.records) and time.monotonic() <= runner.overall_deadline
                support.save_json(receipts / 'PARTIAL-RESULT.json', result)
                print('PARTIAL_SCOPE_RESULT', json.dumps({'success':result['success'],'browserCompatibility':False,'releaseGraphAccepted':False}), flush=True)
    if not result['success']:
        raise RuntimeError('WASM compile/TS/Vitest partial gate failed; retain both arm receipts')

if __name__ == '__main__':
    main()
