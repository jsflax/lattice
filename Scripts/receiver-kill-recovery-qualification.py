#!/usr/bin/env python3
"""Hosted-only receiver kill/reopen C gate, separate from A and all release gates.

Imports the immutable reviewed host/runner/trust/cleanup helpers without changing
any shared global. Raw logs, keys and stores remain private on disposable hosts.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shlex
import stat
import sys
import time

sys.dont_write_bytecode = True
COMMON_SHA256 = '59cd4bfd9d0690dbea9baffce0af066ec9777543d1c49f687dd640b30cf03759'
CASE_NAMES = ('killedReceiverReopensFromDurableQ', 'killedReceiverReopensFromCommittedPartialRange')
# Exact fixed interface frozen with the two C scenarios. No receipt alone
# establishes a passing test or grants process/native authority.
PHASES = frozenset(('environment', 'bootstrap', 'initial', 'offline', 'cut', 'kill', 'snapshot',
    'retirement', 'reopen', 'recovery', 'postWrite', 'finalSnapshot', 'cleanup', 'complete'))
EXPECTED_FACTS = {
    'receiverCount': 2, 'channelsPerReceiver': 2, 'childSpawnCount': 2,
    'preservedSharedOriginals': 3, 'sharedRowsBeforePostWrite': 6, 'sharedRowsAfterPostWrite': 7,
    'killedByOwnedSIGKILL': True, 'exactReapBeforeSnapshot': True, 'durableCutValidated': True,
    'sameSavedConfiguration': True, 'freshPhysicalIncarnation': True, 'oldConnectionRetired': True,
    'staleSendRefused': True, 'heldResultDrained': True, 'sourceAndBStayedLive': True,
    'finalInstallLinksValidated': True, 'postRecoveryWriteObserved': True, 'matchedQ': True,
    'distinctChildInstances': True, 'exactRowsPreserved': True, 'localOnlyPreserved': True,
    'finalCommittedOpen': True, 'allChildrenReaped': True, 'descriptorsClosed': True,
    'sourceAuthorizationRetired': True, 'heldCallbacksReleased': True,
}
BOOL_KEYS = frozenset(k for k, v in EXPECTED_FACTS.items() if type(v) is bool) | {
    'matchedManifest', 'matchedPage', 'actualResumeObserved', 'actualRefreezeObserved'}
INT_KEYS = frozenset(k for k, v in EXPECTED_FACTS.items() if type(v) is int) | {'observedReadIndex'}
HASH_KEYS = frozenset(('configurationSHA256', 'executableSHA256'))
STRING_KEYS = frozenset(('cut', 'observedCanonicalKind'))
ALL_KEYS = BOOL_KEYS | INT_KEYS | HASH_KEYS | STRING_KEYS
FAILURE_PHASES = {
    'C source authorization retirement': 'cleanup',
    'C actual source metadata and authorized seeded catch-up': 'bootstrap',
    'C bootstrap registration retirement': 'bootstrap',
    'C selected actual retained source cut': 'cut',
    'C old A setups retired with B still enrolled': 'retirement',
    'C stale held READY send refused': 'retirement',
    'C post-write canonical round on both channels': 'postWrite',
}
CHILD_SOURCES = {
    'RecoveryProcessChild': ('Sources/RecoveryProcessChild/RecoveryProcessChild.swift',),
    'RecoveryProcessSupport': ('Sources/RecoveryProcessSupport/RecoveryProcessConfiguration.swift',
        'Sources/RecoveryProcessSupport/RecoveryProcessWire.swift',
        'Sources/RecoveryProcessSupport/RecoveryProcessPOSIX.swift',
        'Sources/RecoveryProcessSupport/RecoveryProcessReceiver.swift'),
}


def load_common():
    path = Path(__file__).resolve().with_name('connected-recovery-qualification.py')
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise RuntimeError('shared-wrapper-source')
    if hashlib.sha256(path.read_bytes()).hexdigest() != COMMON_SHA256:
        raise RuntimeError('shared-wrapper-source')
    spec = importlib.util.spec_from_file_location('receiver_kill_shared_host_helpers', path)
    if spec is None or spec.loader is None:
        raise RuntimeError('shared-wrapper-loader')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COMMON = load_common()
require = COMMON.require
read_file, read_json, write_json = COMMON.read_file, COMMON.read_json, COMMON.write_json
load_helpers, child_environment, Commands = COMMON.load_helpers, COMMON.child_environment, COMMON.Commands
material, trust_install, cleanup_all = COMMON.material, COMMON.trust_install, COMMON.cleanup_all
public_commands = COMMON.public_commands
SHA, HEX256 = COMMON.SHA, COMMON.HEX256
OVERALL_SECONDS, CLEANUP_SECONDS = COMMON.OVERALL_SECONDS, COMMON.CLEANUP_SECONDS
TEST_SECONDS, BUILD_SECONDS = COMMON.TEST_SECONDS, COMMON.BUILD_SECONDS


def host_root(value):
    require(os.environ.get('LATTICE_RECEIVER_KILL_HOSTED_GATE') == '1')
    return COMMON.host_root(value)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def case_receipt(root):
    path = root / 'receipts/receiver-kill-recovery-cases.json'
    value = json.loads(read_file(path, 16384), object_pairs_hook=unique_object)
    require(type(value) is dict and set(value) == {'version', 'cases'}
            and type(value['version']) is int and value['version'] == 1
            and type(value['cases']) is list and 1 <= len(value['cases']) <= 2)
    child = read_json(root / 'public-evidence/child-executable.json', 16384)
    expected_binary = child['executableSHA256']
    require(type(expected_binary) is str and HEX256.fullmatch(expected_binary))
    cases, seen = [], set()
    for case in value['cases']:
        require(type(case) is dict and set(case) == {'name', 'passed', 'phase', 'scalarFacts'}
                and type(case['name']) is str and case['name'] in CASE_NAMES and case['name'] not in seen
                and type(case['passed']) is bool and type(case['phase']) is str and case['phase'] in PHASES)
        seen.add(case['name'])
        facts = case['scalarFacts']
        require(type(facts) is dict and set(facts) <= ALL_KEYS)
        for key, observed in facts.items():
            if key in BOOL_KEYS:
                require(type(observed) is bool)
            elif key in INT_KEYS:
                require(type(observed) is int and 0 <= observed <= 256)
            elif key in HASH_KEYS:
                require(type(observed) is str and HEX256.fullmatch(observed))
            elif key == 'cut':
                require(type(observed) is str and observed in ('request', 'partial'))
            elif key == 'observedCanonicalKind':
                require(type(observed) is str and observed in ('request', 'manifest', 'content_page', 'receipt_page', 'end'))
        partial = case['name'] == CASE_NAMES[1]
        if 'cut' in facts:
            require(facts['cut'] == ('partial' if partial else 'request'))
        if 'executableSHA256' in facts:
            require(facts['executableSHA256'] == expected_binary)
        if case['passed']:
            expected_keys = ALL_KEYS if partial else ALL_KEYS - {'observedReadIndex'}
            require(case['phase'] == 'complete' and set(facts) == expected_keys
                    and all(facts[k] == v for k, v in EXPECTED_FACTS.items())
                    and facts['matchedManifest'] is partial and facts['matchedPage'] is partial
                    and facts['actualResumeObserved'] != facts['actualRefreezeObserved'])
            if partial:
                require(facts['observedReadIndex'] == 2
                        and facts['observedCanonicalKind'] in ('content_page', 'receipt_page', 'end'))
            else:
                require(facts['observedCanonicalKind'] == 'request')
        # A failure during final receipt publication may honestly retain the
        # complete phase. It remains a failure; never rewrite or discard it.
        cases.append({'name': case['name'], 'passed': case['passed'], 'phase': case['phase'],
                      'scalarFacts': {k: facts[k] for k in sorted(facts)}})
    return {'version': 1, 'cases': cases}


def publish_case_observation(root):
    output = root / 'public-evidence/receiver-kill-recovery-cases.json'
    if output.exists() or not (root / 'receipts/receiver-kill-recovery-cases.json').exists():
        return
    write_json(output, case_receipt(root))


def validate_cases(root, log):
    raw = read_file(log, 128 * 1024 * 1024).decode(errors='replace')
    raw = re.sub(r'\x1b\[[0-9;]*m', '', raw)
    require(not re.search(r'(?im)^.*(?:[✘↷⊘]|Test .* skipped|Test run .* failed)', raw))
    passed = re.findall(r'(?m)^\s*✔ Test ([A-Za-z0-9_]+)\(\) passed after [^\n]+$', raw)
    require(sorted(passed) == sorted(CASE_NAMES))
    require(len(re.findall(r'(?m)^\s*✔ Test run with 2 tests(?: in 1 suite)? passed after [^\n]+$', raw)) == 1)
    receipt = case_receipt(root)
    require(sorted(x['name'] for x in receipt['cases']) == sorted(CASE_NAMES)
            and all(x['passed'] is True for x in receipt['cases']))
    return receipt


def case_outcomes(root):
    """Observation only; cannot promote an exit, timeout, skip or missing case.

    Read only the closed first test log with actual group/leader retirement
    proof. A killed wrapper lacking that proof reports unobserved, never copies
    a still-written raw log into artifacts. Max2 cases/16 locations/16 codes.
    """
    cases = {name: {'name': name, 'outcome': 'unobserved', 'started': False,
                    'failureLocations': [], 'failurePhaseCodes': []} for name in CASE_NAMES}
    result = {'version': 1, 'evidenceOnly': True, 'observation': 'not-started',
              'cases': list(cases.values()), 'processExitCode': None, 'processRetired': False}
    records = list((root / 'private/commands').glob('*-connected-tests.json'))
    logs = list((root / 'private/commands').glob('*-connected-tests.log'))
    if len(records) != 1 or len(logs) != 1 or records[0].stem != logs[0].stem:
        result['observation'] = 'unobserved-process-proof' if records or logs else 'not-started'
        return result
    record = read_json(records[0], 1024 * 1024)
    require(type(record['started']) is bool and (record['exitCode'] is None or type(record['exitCode']) is int))
    result['processExitCode'] = record['exitCode']
    result['processRetired'] = (record['cleanup']['groupGone'] is True and record['cleanup']['leaderReaped'] is True)
    if not result['processRetired']:
        result['observation'] = 'unobserved-process-proof'
        return result
    if not record['started']:
        result['observation'] = 'command-not-started'
        return result
    if logs[0].is_symlink() or not logs[0].is_file() or logs[0].stat().st_size > 128 * 1024 * 1024:
        result['observation'] = 'unobserved-log-bound'
        return result
    result['observation'] = 'closed-first-log'
    result['testLogSHA256'] = hashlib.sha256(read_file(logs[0], 128 * 1024 * 1024)).hexdigest()
    raw = read_file(logs[0], 128 * 1024 * 1024).decode(errors='replace')
    raw = re.sub(r'\x1b\[[0-9;]*m', '', raw)
    for line in raw.splitlines():
        # No unbounded log line, error description, payload or user data is
        # copied out. These regex captures only choose fixed scalar values.
        if len(line) > 16384:
            continue
        event = re.fullmatch(r'\s*([✔✘◇↷⊘]) Test ([A-Za-z0-9_]+)\(\) (.*)', line)
        if not event or event.group(2) not in cases:
            continue
        mark, name, detail = event.groups()
        case = cases[name]
        if mark == '◇' and detail == 'started.':
            case['started'] = True
        if mark == '✔' and detail.startswith('passed after ') and case['outcome'] == 'unobserved':
            case['outcome'] = 'passed'
        if mark in ('↷', '⊘') and detail.startswith('skipped') and case['outcome'] != 'failed':
            case['outcome'] = 'skipped'
        if mark == '✘' and (detail.startswith('failed after ') or detail.startswith('recorded an issue')):
            case['outcome'] = 'failed'
            location = re.search(r'(?:^|[/ ])(PublicAutomaticRecoveryIntegrationTests\.swift):([1-9][0-9]{0,5}):([1-9][0-9]{0,4}):', detail)
            if location:
                value = {'file': 'PublicAutomaticRecoveryIntegrationTests.swift',
                         'line': int(location.group(2)), 'column': int(location.group(3))}
                if value not in case['failureLocations'] and len(case['failureLocations']) < 16:
                    case['failureLocations'].append(value)
            for literal, code in FAILURE_PHASES.items():
                if 'deadline("' + literal + '")' in detail and code not in case['failurePhaseCodes'] and len(case['failurePhaseCodes']) < 16:
                    case['failurePhaseCodes'].append(code)
            for literal in ('environment', 'metadata', 'bounds', 'state', 'deadline', 'cleanup', 'configuration', 'correlation', 'io', 'publicOpen', 'publicState', 'publicWrite', 'publicClose'):
                if re.search(r'Caught error: ' + literal + r'\s*$', detail):
                    code = 'fixture-' + literal
                    if code not in case['failurePhaseCodes'] and len(case['failurePhaseCodes']) < 16:
                        case['failurePhaseCodes'].append(code)
    return result



def bounded_owned_path(path, parent):
    # This is a read-only evidence boundary, not a process/store capability.
    require(path.is_absolute() and path == path.resolve(strict=True)
            and path != parent and path.is_relative_to(parent))
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1)
    return info


def executable_identity(path, scratch, deadline):
    initial = bounded_owned_path(path, scratch)
    require(initial.st_mode & 0o111 and not initial.st_mode & 0o022
            and 0 < initial.st_size <= 512 * 1024 * 1024)
    identity = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_uid, x.st_nlink,
                          x.st_size, x.st_mtime_ns, x.st_ctime_ns)
    digest = hashlib.sha256()
    count = 0
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        require(identity(os.fstat(fd)) == identity(initial))
        while True:
            require(time.monotonic() < deadline)
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            count += len(chunk)
            require(count <= initial.st_size)
            digest.update(chunk)
        require(count == initial.st_size and identity(os.fstat(fd)) == identity(initial)
                and identity(path.lstat()) == identity(initial))
    finally:
        os.close(fd)
    return {'sha256': digest.hexdigest(), 'bytes': count, 'identity': identity(initial)}


def expand_link_objects(argv, scratch):
    """Expand only bounded, owned SwiftPM object-list files; never execute text."""
    expanded = []
    lists = 0
    for argument in argv:
        if not argument.startswith('@'):
            expanded.append(argument)
            continue
        path = Path(argument[1:])
        lists += 1
        require(lists <= 4 and path.name == 'Objects.LinkFileList')
        info = bounded_owned_path(path, scratch)
        require(info.st_size <= 1024 * 1024)
        tokens = shlex.split(read_file(path, 1024 * 1024).decode('utf-8'))
        require(len(tokens) <= 8192 and all(not x.startswith('@') for x in tokens))
        expanded.extend(tokens)
    require(len(expanded) <= 32768)
    return expanded


def child_compiler_proof(build, sdk, scratch, binary, deadline):
    """Actual verbose compile inputs and child link, separate from Core proof.

    Unsupported/missing command forms refuse qualification. A filename mentioned
    in diagnostics or a response file alone cannot establish compiler execution.
    """
    expected = {str(sdk / path): (module, path)
                for module, paths in CHILD_SOURCES.items() for path in paths}
    found, compile_lines, link_lines = set(), set(), set()
    expected_objects = {str(binary.parent / (module + '.build') / (Path(path).name + '.o'))
                        for module, paths in CHILD_SOURCES.items() for path in paths}
    require(build.stat().st_size <= 128 * 1024 * 1024)
    with build.open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            require(time.monotonic() < deadline)
            # Bound token materialization; other compiler lines remain private.
            if len(line) > 1024 * 1024:
                continue
            try:
                argv = shlex.split(line)
            except ValueError:
                continue
            if not argv:
                continue
            tool = Path(argv[0]).name
            if tool == 'swift-frontend' and '-c' in argv and '-module-name' in argv:
                index = argv.index('-module-name')
                require(index + 1 < len(argv))
                module = argv[index + 1]
                if module in CHILD_SOURCES:
                    primary = {argv[i + 1] for i, arg in enumerate(argv[:-1]) if arg == '-primary-file'}
                    selected = primary if primary else set(argv)
                    observed = {x for x in selected if x in expected and expected[x][0] == module}
                    found.update(observed)
                    if observed:
                        compile_lines.add(hashlib.sha256(line.encode()).hexdigest())
            if tool not in ('swiftc', 'clang', 'clang++') or '-o' not in argv or '-c' in argv:
                continue
            index = argv.index('-o')
            if index + 1 >= len(argv) or argv[index + 1] != str(binary):
                continue
            expanded = expand_link_objects(argv, scratch)
            if expected_objects <= set(expanded):
                link_lines.add(hashlib.sha256(line.encode()).hexdigest())
    require(found == set(expected) and 1 <= len(link_lines) <= 8 and 1 <= len(compile_lines) <= 32)
    sources = {}
    for absolute in sorted(found):
        info = bounded_owned_path(Path(absolute), sdk)
        require(info.st_size <= 1024 * 1024)
        module, relative = expected[absolute]
        sources[relative] = {'module': module, 'sha256': hashlib.sha256(read_file(Path(absolute), 1024 * 1024)).hexdigest()}
    return {'sourceFiles': sources, 'compileCommandSHA256': sorted(compile_lines),
            'linkCommandSHA256': sorted(link_lines)}


def prepare_child_proof(commands, root, common, build):
    sdk, scratch = root / 'lattice', root / 'scratch'
    path_log = commands.run('child-bin-path', ['swift', 'build', *common, '--force-resolved-versions', '--show-bin-path'], cwd=sdk)
    lines = read_file(path_log, 16384).decode('utf-8').splitlines()
    # A warning or unsupported output shape cannot silently select another file.
    require(len(lines) == 1 and 0 < len(lines[0].encode()) <= 4096)
    folder = Path(lines[0])
    require(folder.is_absolute() and folder == folder.resolve(strict=True)
            and folder != scratch and folder.is_relative_to(scratch))
    binary = folder / 'RecoveryProcessChild'
    proof = child_compiler_proof(build, sdk, scratch, binary, commands.runner.work_deadline)
    identity = executable_identity(binary, scratch, commands.runner.work_deadline)
    public = {'version': 1, 'stage': 'verified-child-before-tests', 'target': 'RecoveryProcessChild',
              'executableSHA256': identity['sha256'], 'executableBytes': identity['bytes'],
              'compilerInputs': proof, 'buildLogSHA256': hashlib.sha256(read_file(build, 128 * 1024 * 1024)).hexdigest(),
              'proofSHA256': hashlib.sha256(json.dumps(proof, sort_keys=True).encode()).hexdigest()}
    write_json(root / 'public-evidence/child-executable.json', public)
    return binary, identity


def finish_child_proof(commands, root, binary, before):
    after = executable_identity(binary, root / 'scratch', commands.runner.work_deadline)
    require(before == after)
    write_json(root / 'public-evidence/child-executable-final.json', {
        'version': 1, 'stage': 'verified-child-after-tests', 'target': 'RecoveryProcessChild',
        'executableSHA256': after['sha256'], 'executableBytes': after['bytes'],
        'sameIdentityAndBytes': True})


def source_and_tests(commands, helper, root, sdk_sha, core_sha, core_tree, openssl, result):
    sdk, core = root / 'lattice', root / 'LatticeCore'
    result['stage'] = 'exact-source-graph'
    initial_sdk = commands.guarded(helper.authenticate_repository, 'sdk-initial', sdk, sdk_sha, initial=True)
    config = read_json(sdk / 'Scripts/development-core.json')
    require(config['coreCommit'] == core_sha and config['coreTree'] == core_tree)
    original = helper.pins(sdk / 'Package.resolved')
    require(len(original) == 34 and 'latticecore' in original)
    require(not core.exists())
    commands.run('swift-version', ['swift', '--version'])
    commands.run('core-init', ['git', '-c', 'core.hooksPath=/dev/null', 'init', core])
    commands.run('core-fetch', ['git', '-c', 'core.hooksPath=/dev/null', 'fetch', '--depth=1',
                               'https://github.com/jsflax/LatticeCore.git', core_sha], cwd=core, timeout=600)
    commands.run('core-checkout', ['git', '-c', 'core.hooksPath=/dev/null', 'checkout', '--detach', core_sha], cwd=core)
    initial_core = commands.guarded(helper.authenticate_repository, 'core-initial', core, core_sha, initial=True)
    require(initial_core['tree'] == core_tree)
    write_json(root / 'public-evidence/source-inputs.json', {
        'version': 1, 'stage': 'verified-inputs', 'sdkCommit': sdk_sha, 'sdkTree': initial_sdk['tree'],
        'coreCommit': core_sha, 'coreTree': core_tree, 'trackedSDKFiles': initial_sdk['files'],
        'trackedCoreFiles': initial_core['files'], 'resolvedPins': original})
    common = ['--package-path', str(sdk), '--scratch-path', str(root / 'scratch'), '--cache-path', str(root / 'cache'),
              '--config-path', str(root / 'config'), '--security-path', str(root / 'security'),
              '--disable-sandbox', '--disable-experimental-prebuilts']
    commands.run('resolve-versioned', ['swift', 'package', *common, '--force-resolved-versions', 'resolve'], cwd=sdk, timeout=900)
    require(helper.pins(sdk / 'Package.resolved') == original)
    commands.run('edit-core', ['swift', 'package', *common, 'edit', 'LatticeCore', '--path', core], cwd=sdk)
    graph = commands.run('effective-graph-before', ['swift', 'package', *common, 'show-dependencies', '--format', 'json'], cwd=sdk)
    before = commands.guarded(helper.verify_graph, 'graph-before', helper.read_graph(graph), original, core, core_sha, root / 'scratch')
    write_json(root / 'public-evidence/source-graph.json', {
        'version': 1, 'stage': 'verified-initial-effective-graph', 'sdkCommit': sdk_sha, 'coreCommit': core_sha,
        'effectiveRevisions': {x['identity']: x['revision'] for x in before}, 'completeIdentityCount': len(before)})
    result['stage'] = 'build'
    build = commands.run('build-tests', ['swift', 'build', *common, '--force-resolved-versions', '--build-tests', '-j', '2', '-v'],
                         cwd=sdk, timeout=BUILD_SECONDS)
    compiler = helper.compiler_input_proof(build, core)
    write_json(root / 'public-evidence/compiler-inputs.json', {
        'version': 1, 'stage': 'verified-actual-compiler-inputs', 'coreCommit': core_sha, 'coreTree': core_tree,
        'sourceFiles': {str(Path(k).relative_to(core)): v for k, v in compiler['sourceFiles'].items()},
        'proofSHA256': hashlib.sha256(json.dumps(compiler, sort_keys=True).encode()).hexdigest(),
        'buildLogSHA256': helper.digest(build)})
    result['stage'] = 'child-executable'
    binary, binary_before = prepare_child_proof(commands, root, common, build)
    result['stage'] = 'tls-material'
    tag, tls, version = material(commands, root, openssl)
    result['opensslVersion'] = version
    result['stage'] = 'trust-install'
    result['trustInstall'] = trust_install(commands, root, tag, tls)
    env = commands.runner.env
    env.update(LATTICE_CONNECTED_RECOVERY_GATE='1', LATTICE_RECEIVER_KILL_RECOVERY_GATE='1', LATTICE_CONNECTED_RECOVERY_RUN_DIR=str(root),
               LATTICE_CONNECTED_RECOVERY_CA_CERT=str(root / 'private/tls/ca.pem'),
               LATTICE_CONNECTED_RECOVERY_TLS_CERT=str(root / 'private/tls/matching.pem'),
               LATTICE_CONNECTED_RECOVERY_TLS_KEY=str(root / 'private/tls/matching.key'),
               LATTICE_CONNECTED_RECOVERY_WRONG_HOST_CERT=str(root / 'private/tls/wrong-host.pem'),
               LATTICE_CONNECTED_RECOVERY_WRONG_HOST_KEY=str(root / 'private/tls/wrong-host.key'),
               LATTICE_CONNECTED_RECOVERY_TLS_RECEIPT=str(root / 'receipts/tls-material.json'))
    result['stage'] = 'connected-tests'
    test = commands.run('connected-tests', ['swift', 'test', *common, '--force-resolved-versions', '--skip-build',
                                            '--filter', 'PublicReceiverKillRecoveryTests'],
                        cwd=sdk, timeout=TEST_SECONDS, full=True)
    finish_child_proof(commands, root, binary, binary_before)
    cases = validate_cases(root, test)
    result['stage'] = 'final-source-graph'
    graph = commands.run('effective-graph-after', ['swift', 'package', *common, 'show-dependencies', '--format', 'json'], cwd=sdk)
    after = commands.guarded(helper.verify_graph, 'graph-after', helper.read_graph(graph), original, core, core_sha, root / 'scratch')
    require(before == after)
    final_sdk = commands.guarded(helper.authenticate_repository, 'sdk-final', sdk, sdk_sha, allowed_changes=('Package.resolved',))
    final_core = commands.guarded(helper.authenticate_repository, 'core-final', core, core_sha)
    require(final_core == initial_core)
    require(final_sdk['files'] == {k: v for k, v in initial_sdk['files'].items() if k != 'Package.resolved'})
    final_pins = helper.pins(sdk / 'Package.resolved')
    require({k: v for k, v in final_pins.items() if k != 'latticecore'} == {k: v for k, v in original.items() if k != 'latticecore'})
    # Reconstruct, never copy arbitrary logs or directory trees to artifacts.
    write_json(root / 'public-evidence/tls-material.json', tls)
    write_json(root / 'public-evidence/receiver-kill-recovery-cases.json', cases)
    write_json(root / 'public-evidence/source-bindings.json', {
        'version': 1, 'sdkCommit': sdk_sha, 'sdkTree': initial_sdk['tree'], 'coreCommit': core_sha, 'coreTree': core_tree,
        'trackedSDKFiles': initial_sdk['files'], 'trackedCoreFiles': initial_core['files'],
        'resolvedPins': original, 'effectiveRevisions': {x['identity']: x['revision'] for x in before},
        'compilerInputs': {str(Path(k).relative_to(core)): v for k, v in compiler['sourceFiles'].items()},
        'compilerInputProofSHA256': hashlib.sha256(json.dumps(compiler, sort_keys=True).encode()).hexdigest(),
        'testLogSHA256': helper.digest(test), 'testLogBytes': test.stat().st_size,
        'childExecutableSHA256': binary_before['sha256'], 'childExecutablePreserved': True,
        'allOtherSourceAndPinsPreserved': True})
    result['twoCasesPassed'] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--core-sha')
    parser.add_argument('--core-tree')
    parser.add_argument('--openssl', type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--cleanup-only', action='store_true')
    args = parser.parse_args()
    root = host_root(args.root)
    helper = load_helpers(root / 'lattice')
    if args.cleanup_only:
        logs = root / 'private/cleanup-always'
        logs.mkdir(mode=0o700, exist_ok=False)
        result = {'version': 1, 'success': False, 'stage': 'always-cleanup'}
        try:
            with helper.Interrupts() as interrupts:
                commands = Commands(helper, root, logs, child_environment(root), interrupts, CLEANUP_SECONDS)
                commands.runner.free_floor = 0
                commands.runner.packet_ceiling = 2**63 - 1
                with interrupts.hold():
                    result['cleanup'] = cleanup_all(commands, root)
            # A killed main process must never become passing solely because
            # cleanup succeeded. This mode reports cleanup; main result stands.
            result['success'] = result['cleanup']['success']
        except BaseException as error:
            result['errorClass'] = type(error).__name__
        if not (root / 'public-evidence/case-outcomes.json').exists():
            try:
                write_json(root / 'public-evidence/case-outcomes.json', case_outcomes(root))
            except BaseException as error:
                result['caseEvidenceErrorClass'] = type(error).__name__
                result['success'] = False
        try:
            publish_case_observation(root)
        except BaseException as error:
            result['receiptEvidenceErrorClass'] = type(error).__name__
            result['success'] = False
        write_json(root / 'public-evidence/always-cleanup.json', result)
        print('receiver kill gate always-cleanup success', result['success'], flush=True)
        return 0 if result['success'] else 1
    require(SHA.fullmatch(os.environ.get('GITHUB_SHA', '')) and SHA.fullmatch(args.core_sha or '')
            and SHA.fullmatch(args.core_tree or '') and args.openssl is not None)
    require(args.openssl.is_absolute() and args.openssl.is_file())
    for name in ('private', 'receipts', 'public-evidence', 'module-cache', 'cache', 'config', 'security', 'scratch'):
        (root / name).mkdir(mode=0o700, exist_ok=False)
    (root / 'tmp').mkdir(mode=0o700, exist_ok=True)
    logs = root / 'private/commands'
    logs.mkdir(mode=0o700)
    result = {'version': 1, 'scope': 'C receiver kill/reopen only', 'sdkCommit': os.environ['GITHUB_SHA'],
              'coreCommit': args.core_sha, 'coreTree': args.core_tree, 'platform': platform.system(),
              'integrationTimeoutSeconds': TEST_SECONDS, 'buildTimeoutSeconds': BUILD_SECONDS,
              'overallSeconds': OVERALL_SECONDS, 'cleanupReserveSeconds': CLEANUP_SECONDS,
              'success': False, 'twoCasesPassed': False, 'stage': 'initialization',
              'fullSuiteAccepted': False, 'performanceAccepted': False, 'releaseAccepted': False}
    started = time.monotonic()
    with helper.Interrupts() as interrupts:
        commands = Commands(helper, root, logs, child_environment(root), interrupts, OVERALL_SECONDS - CLEANUP_SECONDS)
        try:
            source_and_tests(commands, helper, root, os.environ['GITHUB_SHA'], args.core_sha, args.core_tree, args.openssl, result)
        except BaseException as error:
            result['errorClass'] = type(error).__name__
        finally:
            with interrupts.hold():
                cleanup_logs = root / 'private/cleanup-final'
                cleanup_logs.mkdir(mode=0o700)
                # Independent bounded cleanup remains available after timeout,
                # low-space refusal or signal. No tests run in this allowance.
                cleanup_interrupts = helper.Interrupts()
                cleanup = Commands(helper, root, cleanup_logs, child_environment(root), cleanup_interrupts, CLEANUP_SECONDS)
                # The standard disk floor is a work-admission fence; removing
                # our trust/keys must still proceed under low disk space.
                cleanup.runner.free_floor = 0
                cleanup.runner.packet_ceiling = 2**63 - 1
                try:
                    result['cleanup'] = cleanup_all(cleanup, root)
                except BaseException as error:
                    result['cleanupErrorClass'] = type(error).__name__
                result['signalsReceived'] = list(interrupts.received)
                result['elapsedSeconds'] = time.monotonic() - started
                result['success'] = (result['twoCasesPassed'] and not result.get('errorClass')
                    and not result.get('cleanupErrorClass') and not result['signalsReceived']
                    and result['cleanup']['success'])
                try:
                    write_json(root / 'public-evidence/case-outcomes.json', case_outcomes(root))
                except BaseException as error:
                    result['caseEvidenceErrorClass'] = type(error).__name__
                    result['success'] = False
                try:
                    write_json(root / 'public-evidence/commands.json', public_commands(logs))
                except BaseException as error:
                    result['evidenceErrorClass'] = type(error).__name__
                    result['success'] = False
                try:
                    publish_case_observation(root)
                except BaseException as error:
                    result['receiptEvidenceErrorClass'] = type(error).__name__
                    result['success'] = False
                write_json(root / 'public-evidence/result.json', result)
    print('receiver kill gate success', result['success'], 'stage', result['stage'], flush=True)
    return 0 if result['success'] else 1

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as failure:
        print('receiver kill gate early failure', type(failure).__name__, flush=True)
        sys.exit(1)
