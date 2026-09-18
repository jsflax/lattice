#!/usr/bin/env python3
"""Exact Linux framing red/green probe; not full Core or CI-cause evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import time

from guarded_runner import GuardedRunner, Interrupts, digest, error_record, save_json

FILES = ['Sources/LatticeCore/src/ipc.cpp',
         'Sources/LatticeCore/include/lattice/ipc.hpp',
         'Sources/LatticeCore/include/lattice/network.hpp',
         'Sources/LatticeCore/include/lattice/log.hpp']
FIXTURE = 'Tests/LatticeCoreTests/IPCFramingRegressionTests.cpp'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    home_localdev = (Path.home() / 'localdev').resolve()
    if not root.is_relative_to(home_localdev) or root == home_localdev:
        raise ValueError('owned root must be strictly below ~/localdev')
    if platform.system() != 'Linux':
        raise ValueError('this signal qualification requires Linux')
    scripts = Path(__file__).resolve().parent
    manifest = json.loads((scripts / 'source-manifest.json').read_text())
    if digest(scripts / 'guarded_runner.py') != manifest['guardedRunnerSHA256']:
        raise ValueError('reviewed process supervisor hash mismatch')
    for field in ['baseline', 'candidate', 'baselineTree', 'candidateTree']:
        if not re.fullmatch('[0-9a-f]{40}', manifest[field]):
            raise ValueError('invalid exact source identity')
    receipts = root / 'receipts'
    receipts.mkdir(exist_ok=False)
    for name in ['tmp', 'cache', 'runtime', 'build', 'sources']:
        (root / name).mkdir(exist_ok=True)
    env = dict(os.environ, TMPDIR=str(root / 'tmp'), TMP=str(root / 'tmp'),
               TEMP=str(root / 'tmp'), XDG_RUNTIME_DIR=str(root / 'runtime'),
               XDG_CACHE_HOME=str(root / 'cache'), PYTHONDONTWRITEBYTECODE='1',
               CCACHE_DISABLE='1', GIT_CONFIG_NOSYSTEM='1')
    result = {'success': False, 'scope': 'Linux IPC framing baseline-red/candidate-green only',
              'fullCoreQualification': False, 'originalCICrashAttributed': False,
              'source': manifest, 'platform': platform.platform(),
              'workflow': {name: os.environ.get(name) for name in
                  ['GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT']},
              'scripts': {p.name: digest(p) for p in sorted(scripts.glob('*')) if p.is_file()},
              'cases': [], 'error': None}
    primary = None
    with Interrupts() as interrupts:
        runner = GuardedRunner(root, receipts, env, interrupts, free_floor=12 * 2**30,
                               packet_ceiling=512 * 2**20, log_ceiling=8 * 2**20,
                               overall_seconds=600, reserve=30, poll_seconds=0.1,
                               signal_grace=2)
        try:
            runner.run('compiler-identity', ['g++', '--version'], cwd=root, timeout=10)
            runner.run('kernel-identity', ['uname', '-a'], cwd=root, timeout=10)
            source_hashes = {}
            for arm, key in [('baseline', 'preimages'), ('candidate', 'postimages')]:
                sha = manifest[arm]
                commit_file = receipts / (arm + '-remote-commit.json')
                runner.run(arm + '-remote-identity', ['curl', '--fail', '--silent', '--show-error',
                    '--location', '--max-time', '30', '--max-filesize', '1048576',
                    '-o', str(commit_file), 'https://api.github.com/repos/jsflax/LatticeCore/git/commits/' + sha],
                    cwd=root, timeout=35)
                remote = json.loads(commit_file.read_text())
                if remote['sha'] != sha or remote['tree']['sha'] != manifest[arm + 'Tree']:
                    raise ValueError('remote commit/tree mismatch: ' + arm)
                if arm == 'candidate' and [x['sha'] for x in remote['parents']] != [manifest['baseline']]:
                    raise ValueError('candidate is not the exact reviewed baseline child')
                for index, name in enumerate(FILES + ([FIXTURE] if arm == 'candidate' else [])):
                    path = root / 'sources' / arm / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    runner.run(arm + '-source-' + str(index), ['curl', '--fail', '--silent', '--show-error',
                        '--location', '--max-time', '30', '--max-filesize', '1048576', '-o', str(path),
                        'https://raw.githubusercontent.com/jsflax/LatticeCore/' + sha + '/' + name],
                        cwd=root, timeout=35)
                    actual = digest(path)
                    if actual != manifest[key][name]:
                        raise ValueError('exact source hash mismatch: ' + arm + '/' + name)
                    source_hashes[arm + '/' + name] = actual
            save_json(receipts / 'source-hashes-before.json', source_hashes)
            fixture = root / 'sources/candidate' / FIXTURE
            binaries = {}
            for arm in ['baseline', 'candidate']:
                source = root / 'sources' / arm
                binary = root / 'build' / ('ipc-' + arm)
                runner.run(arm + '-compile', ['g++', '-std=c++20', '-O0', '-g0', '-pthread',
                    '-DLATTICE_IPC_STANDALONE_TEST_MAIN', '-I', str(source / 'Sources/LatticeCore/include'),
                    str(source / FILES[0]), str(fixture), '-o', str(binary)],
                    cwd=root, timeout=120, require_full_timeout=True)
                binaries[arm] = {'path': str(binary), 'sha256': digest(binary), 'bytes': binary.stat().st_size}
            result['binaries'] = binaries
            for arm in ['baseline', 'candidate']:
                for case in ['header', 'payload', 'roundtrip', 'pipe']:
                    expected = -13 if arm == 'baseline' and case in ['header', 'payload'] else 0
                    label = arm + '-' + case
                    case_receipt = receipts / (label + '-child.json')
                    runner.run(label, [sys.executable, str(scripts / 'case-check.py'),
                        '--binary', binaries[arm]['path'], '--case', case, '--expected', str(expected),
                        '--receipt', str(case_receipt)], cwd=root, timeout=12, require_full_timeout=True)
                    result['cases'].append(json.loads(case_receipt.read_text()))
            after = {name: digest(root / 'sources' / name) for name in source_hashes}
            save_json(receipts / 'source-hashes-after.json', after)
            if after != source_hashes:
                raise ValueError('source changed during qualification')
            result['success'] = True
        except BaseException as error:
            primary = error
            result['error'] = error_record(error)
        finally:
            with interrupts.hold():
                result.update(commands=runner.records, receivedSignals=interrupts.received,
                              elapsedSeconds=time.monotonic() - runner.started)
                try:
                    result['resources'] = runner.measure(receipts / 'RESULT.json')
                    violation = runner.violation(result['resources'])
                    if violation:
                        result['resourceFailure'] = violation
                        result['success'] = False
                except BaseException as error:
                    result['finalResourceError'] = error_record(error)
                    result['success'] = False
                result['success'] = (result['success'] and primary is None and not interrupts.received
                    and len(result['cases']) == 8 and all(x['success'] for x in runner.records)
                    and time.monotonic() <= runner.overall_deadline)
                save_json(receipts / 'RESULT.json', result)
    if not result['success']:
        if primary is not None:
            raise primary
        raise RuntimeError('IPC probe did not qualify; inspect preserved receipts')


if __name__ == '__main__':
    main()
