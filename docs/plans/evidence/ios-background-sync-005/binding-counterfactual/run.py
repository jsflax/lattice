#!/usr/bin/env python3
"""Small portable binding regression; all outputs remain beside this script.

Reuse the existing enclosing-Lattice stub and Swift Testing runner. Compile
actual policy/scheduler/binding plus the updated real binding test file. The
counterfactual uses HEAD's detached worker with the SAME asynchronous fixtures.
No production source is reverted and no package/native dependencies are built.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
SDK = Path('/Users/jason/localdev/lattice-sync-handoff-bgtasks-20261101')
STUBS = Path('/Users/jason/localdev/lattice-bg-sync-evidence-20261101/probes/config-actor/scheduler')
FRAMEWORKS = Path('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks')
PLUGIN = Path('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib')


def execute(command, directory, stem, env, timeout):
    started = time.monotonic()
    with (directory / (stem + '.log')).open('w') as log:
        try:
            result = subprocess.run(command, cwd=directory, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
    receipt = {'command': [str(arg) for arg in command], 'exit': code,
               'seconds': time.monotonic() - started,
               'LIBDISPATCH_COOPERATIVE_POOL_STRICT': env.get('LIBDISPATCH_COOPERATIVE_POOL_STRICT')}
    (directory / (stem + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'mode': directory.name, 'step': stem, **receipt}), flush=True)
    return code


def run(mode):
    directory = ROOT / mode
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'tmp').mkdir(exist_ok=True)
    env = dict(os.environ, TMPDIR=str(directory / 'tmp'), LIBDISPATCH_COOPERATIVE_POOL_STRICT='1')
    copied = []
    for source in [STUBS / 'BindingLatticeStub.swift', STUBS / 'TestMain.swift',
                   SDK / 'Sources/Lattice/BackgroundSyncPolicy.swift',
                   SDK / 'Sources/Lattice/BackgroundTaskScheduler.swift',
                   SDK / 'Tests/LatticeTests/BackgroundSyncBindingTests.swift']:
        destination = directory / source.name
        destination.write_text(source.read_text().replace('@testable import Lattice\n', ''))
        copied.append(destination)
    binding = directory / 'BackgroundSyncBinding.swift'
    if mode == 'old-detached':
        original = subprocess.check_output(['git', '-C', str(SDK), 'show',
                    'HEAD:Sources/Lattice/BackgroundSyncBinding.swift'], text=True)
        if 'let result = try await Task.detached' not in original:
            raise RuntimeError('HEAD no longer contains the counterfactual detached worker; select its explicit revision')
        binding.write_text(original)
    else:
        binding.write_text((SDK / 'Sources/Lattice/BackgroundSyncBinding.swift').read_text())
        if 'withCheckedThrowingContinuation' not in binding.read_text():
            raise RuntimeError('New continuation worker is not ready')
    copied.append(binding)
    (directory / 'source-hashes.json').write_text(json.dumps({path.name:
        hashlib.sha256(path.read_bytes()).hexdigest() for path in copied}, indent=2) + '\n')
    executable = directory / 'binding-tests'
    command = ['xcrun', 'swiftc', '-load-plugin-library', str(PLUGIN), '-swift-version', '6',
               '-strict-concurrency=complete', '-parse-as-library', '-whole-module-optimization',
               '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(ROOT / 'cache'),
               '-F', str(FRAMEWORKS), '-Xlinker', '-rpath', '-Xlinker', str(FRAMEWORKS),
               *map(str, copied), '-o', str(executable)]
    if execute(command, directory, 'compile', env, 45) != 0:
        return False
    code = execute([str(executable)], directory, 'strict-tests', env, 45)
    # A matching failure proves the strict setting exercises the original
    # blocked cooperative worker; success from old code is NOT a useful proof.
    log = (directory / 'strict-tests.log').read_text()
    if mode == 'old-detached':
        return code != 0 and code != 124 and ('Cancellation did not reach native work' in log or
                                             'Manual work was not cancelled' in log or
                                             'The native fake must start' in log)
    return code == 0


if __name__ == '__main__':
    modes = sys.argv[1:] or ['old-detached', 'new-dispatch']
    if any(mode not in ['old-detached', 'new-dispatch'] for mode in modes):
        raise SystemExit('Use old-detached and/or new-dispatch')
    outcomes = {mode: run(mode) for mode in modes}
    (ROOT / 'result.json').write_text(json.dumps(outcomes, indent=2) + '\n')
    raise SystemExit(0 if all(outcomes.values()) else 1)
