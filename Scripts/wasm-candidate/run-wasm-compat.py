#!/usr/bin/env python3
"""Exact corrected candidate WASM compilation and strict JS unit checks; never browser qualification."""
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
    if arm != 'B':
        raise ValueError('Only the corrected candidate is authorized for this build')
    root, receipts = runner.root, runner.receipts
    js, core = root / 'js-B', root / 'core-B'
    before_js = fetch(runner, 'B-js', js, config['jsRepository'], config['jsCommit'])
    before_core = fetch(runner, 'B-core', core, 'https://github.com/jsflax/LatticeCore.git', core_sha)
    if before_js['tree'] != config['jsTree'] or before_core['tree'] != config['candidateCoreTree']:
        raise ValueError('Candidate source tree mismatch')
    result.update(core=core_sha, coreTree=before_core['tree'], js=before_js['commit'], jsTree=before_js['tree'],
                  buildArtifactsReady=False, wasmBuildSucceeded=False, typescriptBuildSucceeded=False,
                  nodeAllNamedCasesPassed=False, finalSourceVerified=False, evidenceErrors=[])
    primary = None
    try:
        runner.env['LATTICECORE_DIR'] = str(core)
        build = js / 'wasm/build'
        runner.run('B-configure', ['emcmake', 'cmake', '-S', str(js / 'wasm'), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', '-DFETCHCONTENT_BASE_DIR=' + str(root / 'cache/sqlite-B'), '-DLATTICE_CPP_DIR=' + str(core)], cwd=js, timeout=600)
        build_log = runner.run('B-wasm-build', ['cmake', '--build', str(build), '--parallel', '2', '--verbose'], cwd=js, timeout=900)
        proof = compiler_proof(build_log, build, core)
        binding = (js / 'wasm/bindings.cpp').resolve()
        entries = json.loads((build / 'compile_commands.json').read_text())
        if not any(Path(entry['file']).resolve() == binding for entry in entries):
            raise ValueError('Configured JS binding input is missing')
        binding_observed = False
        for line in build_log.read_text(errors='replace').splitlines():
            if ' -c ' not in line: continue
            try: argv = shlex.split(line)
            except ValueError: continue
            if '-c' in argv and Path(argv[argv.index('-c') + 1]).resolve() == binding:
                binding_observed = True
        if not binding_observed: raise ValueError('Actual JS binding compiler input is missing')
        proof['jsBinding'] = {'path': str(binding), 'sha256': support.digest(binding)}
        support.save_json(receipts / 'B-compiler-input-proof.json', proof)
        shutil.copyfile(build / 'CMakeCache.txt', receipts / 'B-CMakeCache.txt')
        shutil.copyfile(build / 'compile_commands.json', receipts / 'B-compile_commands.json')
        artifacts = {}
        for name, minimum in [('lattice.wasm', 1000000), ('lattice.js', 50000)]:
            file = build / name
            if not minimum <= file.stat().st_size <= 20000000:
                raise ValueError('Missing or suspicious artifact: ' + name)
            artifacts[name] = {'bytes': file.stat().st_size, 'sha256': support.digest(file), 'zipMember': 'B-' + name}
            shutil.copyfile(file, receipts / ('B-' + name))
        sqlite_sources = list((root / 'cache/sqlite-B').rglob('sqlite3.c'))
        if len(sqlite_sources) != 1: raise ValueError('SQLite provenance is ambiguous')
        result.update(wasmBuildSucceeded=True, artifacts=artifacts, sqliteSHA256=support.digest(sqlite_sources[0]))
        runner.run('B-npm-ci', ['npm', 'ci', '--cache', str(root / 'cache/npm')], cwd=js, timeout=600)
        runner.run('B-typescript-build', ['npm', 'run', 'build:ts'], cwd=js, timeout=300)
        result['typescriptBuildSucceeded'] = True
        report = receipts / 'B-vitest-report.json'
        runner.run('B-vitest', [str(js / 'node_modules/.bin/vitest'), 'run', '--maxWorkers=2', '--minWorkers=2', '--reporter=json', '--outputFile=' + str(report)], cwd=js, timeout=300)
        tests = json.loads(report.read_text())
        assertions = [case for suite in tests.get('testResults', []) for case in suite.get('assertionResults', [])]
        result.update(nodeReportSuccess=tests.get('success'), nodeTestCounts=dict(Counter(case.get('status') for case in assertions)),
                      nodeTestNames=sorted(case.get('fullName') or case.get('title') for case in assertions),
                      nodeNonPassing=[{'name':case.get('fullName') or case.get('title'),'status':case.get('status')} for case in assertions if case.get('status') != 'passed'])
        result['nodeAllNamedCasesPassed'] = bool(tests.get('success') and assertions and all(case.get('status') == 'passed' for case in assertions))
        if not result['nodeAllNamedCasesPassed']:
            # Preserve the original strict gate. Known browser-only skips do
            # not become Node passes; compile assets can still be inspected.
            raise ValueError('Vitest missing, failed, skipped or pending cases')
    except BaseException as error:
        primary = error
    finally:
        final = {}
        for name, repository, expected, before in [('js', js, config['jsCommit'], before_js), ('core', core, core_sha, before_core)]:
            try:
                final[name] = source_proof(runner, 'B-' + name + '-final', repository, expected)
                if final[name] != before: raise ValueError('Tracked candidate source changed: ' + name)
            except BaseException as error:
                result['evidenceErrors'].append(support.error_record(error))
        result['finalSourceVerified'] = len(final) == 2 and not result['evidenceErrors']
        result['buildArtifactsReady'] = result['wasmBuildSucceeded'] and result['typescriptBuildSucceeded'] and result['finalSourceVerified']
        result['success'] = result['buildArtifactsReady'] and result['nodeAllNamedCasesPassed'] and primary is None
    if primary: raise primary
    if result['evidenceErrors']: raise RuntimeError('Candidate source evidence incomplete')


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
    result = {'scope': config['scope'], 'browserCompatibility': False, 'fullABCompatibility': False, 'baselineRerun': False, 'releaseGraphAccepted': False, 'success': False, 'arms': {}, 'primaryError': None, 'evidenceErrors': [], 'workflowCommit': env.get('GITHUB_SHA'), 'runID': env.get('GITHUB_RUN_ID'), 'runAttempt': env.get('GITHUB_RUN_ATTEMPT'), 'runnerOS': platform.platform(), 'configSHA256': support.digest(HERE / 'config.json'), 'runnerSHA256': support.digest(Path(__file__)), 'supervisorSHA256': support.digest(supervisor)}
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
            for arm, sha in [('B', config['candidateCore'])]:
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
            if set(result['arms']) == {'B'} and result['arms']['B'].get('success'):
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
        raise RuntimeError('Corrected WASM compile/TS/Vitest strict partial gate failed; retain candidate receipts')

if __name__ == '__main__':
    main()
