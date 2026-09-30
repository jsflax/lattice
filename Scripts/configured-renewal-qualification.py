#!/usr/bin/env python3
"""Hosted-only normal public configured renewal gate; production remains disabled.

Imports the immutable reviewed host/runner/trust/cleanup helpers without changing
any shared global. Raw logs, keys and stores remain private on disposable hosts.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import stat
import sys
import time

sys.dont_write_bytecode = True
COMMON_SHA256 = '59cd4bfd9d0690dbea9baffce0af066ec9777543d1c49f687dd640b30cf03759'
CASE_NAMES = (
    'publicConfiguredStockRenewalDeliversCommittedEdit',
    'publicConfiguredWrongHostFailureRetiresStockAttempt',
)
TEST_SUPPORT_INPUTS = (
    'Sources/LatticeServerExportTestSupport/src/configured_recovery_qualification.cpp',
    'Sources/LatticeServerExportTestSupport/src/platform_retirement_fixture.cpp',
    'Sources/LatticeServerExportTestSupport/src/server_export_fixture.cpp',
)
PHASES = frozenset(['environment', 'opening', 'initial', 'replacement', 'delivery', 'cleanup', 'facts', 'receipt',
    'sourceMount', 'sourceStartup', 'sourceAddress', 'bootstrapConnect', 'bootstrapMetadata',
    'bootstrapContext', 'bootstrapRetirement', 'wrongApplication', 'wrongStartup', 'wrongAddress',
    'receiverCreate', 'receiverOpen'])
EXPECTED_FACTS = {
    CASE_NAMES[0]: {'freshAuthorizedConnections': 4, 'retiredConnectionsDrained': 4,
        'lateConnectedReplays': 4, 'committedOriginals': 1, 'peerVisibleRows': 6,
        'actualCollectedAttempts': 8, 'actualChildClosesAndSchedulerJoins': 4},
    CASE_NAMES[1]: {'actualFailedAttempts': 2, 'unauthorizedUpgrades': 0,
        'actualCollectedAttempts': 2, 'actualChildClosesAndSchedulerJoins': 2},
}
FAILURE_PHASES = {
    'configured real source metadata': 'bootstrap',
    'configured bootstrap closed': 'bootstrap-retirement',
    'configured wrong-host first attempts retired': 'first-failure-retirement',
    'configured first public cohorts': 'initial-recovery',
    'configured fresh authenticated cohorts': 'replacement',
    'configured public late-listener replay': 'connected-replay',
    'configured committed edit ACK and peer delivery': 'committed-edit',
    'configured actual owner cleanup receipts': 'owner-cleanup',
    'configured source and bootstrap retirement': 'source-cleanup',
}


def load_common():
    path = Path(__file__).resolve().with_name('connected-recovery-qualification.py')
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise RuntimeError('shared-wrapper-source')
    if hashlib.sha256(path.read_bytes()).hexdigest() != COMMON_SHA256:
        raise RuntimeError('shared-wrapper-source')
    spec = importlib.util.spec_from_file_location('configured_renewal_shared_host_helpers', path)
    if spec is None or spec.loader is None:
        raise RuntimeError('shared-wrapper-loader')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COMMON = load_common()
require = COMMON.require
read_file, read_json, write_json = COMMON.read_file, COMMON.read_json, COMMON.write_json
load_helpers, child_environment, Commands = COMMON.load_helpers, COMMON.child_environment, COMMON.Commands
material, trust_install, cleanup_trust = COMMON.material, COMMON.trust_install, COMMON.cleanup_trust
public_commands = COMMON.public_commands
SHA, HEX256 = COMMON.SHA, COMMON.HEX256
OVERALL_SECONDS, CLEANUP_SECONDS = COMMON.OVERALL_SECONDS, COMMON.CLEANUP_SECONDS
TEST_SECONDS, BUILD_SECONDS = COMMON.TEST_SECONDS, COMMON.BUILD_SECONDS


def host_root(value):
    require(os.environ.get('LATTICE_CONFIGURED_RENEWAL_HOSTED_GATE') == '1')
    return COMMON.host_root(value)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def case_receipt(root, name):
    require(name in CASE_NAMES)
    value = json.loads(read_file(root / ('receipts/' + name + '.json'), 4096), object_pairs_hook=unique_object)
    require(type(value) is dict and set(value) == {'version', 'name', 'passed', 'phase', 'scalarFacts', 'failure'}
            and type(value['version']) is int and value['version'] == 2
            and value['name'] == name and type(value['passed']) is bool
            and type(value['phase']) is str and value['phase'] in PHASES)
    facts = value['scalarFacts']
    require(type(facts) is dict and set(facts) <= set(EXPECTED_FACTS[name]))
    require(all(type(v) is int and 0 <= v <= 1024 for v in facts.values()))
    if value['passed']:
        require(value['phase'] == 'cleanup' and facts == EXPECTED_FACTS[name] and value['failure'] is None)
    else:
        error = value['failure']
        require(type(error) is dict and set(error) == {'kind', 'domain', 'code', 'category'})
        require(type(error['kind']) is str and error['kind'] in COMMON.FAILURE_ERROR_KINDS)
        require(type(error['domain']) is str and error['domain'] in COMMON.FAILURE_ERROR_DOMAINS)
        code, category = error['code'], error['category']
        require(code is None or (type(code) is int and -(2**31) <= code < 2**31))
        if code is not None:
            require(error['domain'] in ('url', 'osStatus', 'posix', 'cocoa', 'nioWebSocket'))
        require(category is None or (type(category) is str and category in COMMON.FAILURE_ERROR_CATEGORIES))
        if category is not None:
            require(error['kind'] == 'tls' and error['domain'] == 'nioSSL' and code is None)
    # Only reviewed scalar fields are exported, never raw errors or source data.
    return {'version': 2, 'name': name, 'passed': value['passed'], 'phase': value['phase'],
            'scalarFacts': {k: facts[k] for k in sorted(facts)}, 'failure': value['failure']}


def publish_case_observation(root):
    # Preserve each first receipt independently, including partial failure.
    # Missing cases remain missing; cleanup cannot create a positive receipt.
    for name in CASE_NAMES:
        output = root / ('public-evidence/' + name + '.json')
        if output.exists() or not (root / ('receipts/' + name + '.json')).exists():
            continue
        write_json(output, case_receipt(root, name))


def validate_cases(root, log):
    raw = read_file(log, 128 * 1024 * 1024).decode(errors='replace')
    raw = re.sub(r'\x1b\[[0-9;]*m', '', raw)
    require(not re.search(r'(?im)^.*(?:[✘↷⊘]|Test .* skipped|Test run .* failed)', raw))
    passed = re.findall(r'(?m)^\s*✔ Test ([A-Za-z0-9_]+)\(\) passed after [^\n]+$', raw)
    require(sorted(passed) == sorted(CASE_NAMES))
    require(len(re.findall(r'(?m)^\s*✔ Test run with 2 tests(?: in 1 suite)? passed after [^\n]+$', raw)) == 1)
    receipts = [case_receipt(root, name) for name in CASE_NAMES]
    require(all(value['passed'] is True for value in receipts))
    return {'version': 1, 'cases': receipts}


def case_outcomes(root):
    """Observation only; cannot promote an exit, timeout, skip or missing case.

    Read only the closed first test log with actual group/leader retirement
    proof. A killed wrapper lacking that proof reports unobserved, never copies
    a still-written raw log into artifacts. Max2 cases/16 locations/16 codes per case.
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
            for literal in ('environment', 'metadata', 'receipt', 'unexpectedOriginal', 'opening', 'initial', 'replacement', 'delivery', 'cleanup', 'facts'):
                if re.search(r'Caught error: \.?' + literal + r'\s*$', detail):
                    code = {'environment': 'fixture-environment', 'metadata': 'fixture-metadata',
                            'receipt': 'fixture-receipt', 'unexpectedOriginal': 'original-oracle',
                            'opening': 'public-opening', 'initial': 'initial-recovery', 'replacement': 'replacement',
                            'delivery': 'committed-edit', 'cleanup': 'cleanup', 'facts': 'facts'}[literal]
                    if code not in case['failurePhaseCodes'] and len(case['failurePhaseCodes']) < 16:
                        case['failurePhaseCodes'].append(code)
    return result


def build_diagnostic_code(message):
    """Return only a fixed compiler category; never export diagnostic text."""
    patterns = (
        ('missing-scope-name', r"cannot find .+ in scope$"),
        ('missing-type', r"(?:cannot find type .+ in scope|unknown type name .+)$"),
        ('missing-member', r"(?:value of type .+ has no member .+|type .+ has no member .+|no member named .+)$"),
        ('undeclared-identifier', r"use of undeclared identifier .+$"),
        ('generic-inference', r"generic parameter .+ could not be inferred$"),
        ('type-conversion', r"(?:cannot convert .+|no viable conversion .+|incompatible .+)$"),
        ('call-overload', r"(?:no matching .+|ambiguous use .+|call to .+ is ambiguous|candidate .+)$"),
        ('access-control', r".+ is (?:inaccessible|a private member|a protected member).*$"),
        ('missing-import', r"(?:no such module .+|could not build .+|.+ file not found)$"),
        ('concurrency', r".*(?:actor-isolated|Sendable|sendable|data races|async context|concurrent).*$"),
        ('argument-shape', r"(?:missing argument .+|extra argument .+|extraneous argument .+|incorrect argument label .+)$"),
        ('declaration-shape', r"(?:expected .+|invalid redeclaration .+|redefinition .+|conflicting .+)$"),
        ('link-failure', r"(?:link command failed .+|undefined reference .+|Undefined symbols .+)$"),
        ('compiler-process-failed', r"(?:compile command failed .+|emit-module command failed .+|fatalError)$"),
    )
    for code, pattern in patterns:
        if re.fullmatch(pattern, message):
            return code
    return 'unclassified'


def build_diagnostics(root):
    """Bounded locations/categories from a proved closed first build log.

    This is observation only, including on a failed build. It exports no raw
    message, source line, command, path, identifier or environment value. Exact
    source-relative paths come only from authenticated source-inputs, with their
    source hashes. Unknown diagnostics retain location numbers and line hashes.
    No diagnostic receipt can imply successful compilation or passing tests.
    """
    result = {'version': 1, 'evidenceOnly': True, 'observation': 'not-started',
              'processExitCode': None, 'processRetired': False, 'diagnostics': [],
              'diagnosticCount': 0, 'omittedDiagnosticCount': 0,
              'oversizedLineCount': 0, 'retainedUnmappedLocationCount': 0,
              'retainedErrorCount': 0, 'retainedNoteCount': 0,
              'categoryCounts': {}, 'compileSuccessInferred': False}
    records = list((root / 'private/commands').glob('*-build-tests.json'))
    logs = list((root / 'private/commands').glob('*-build-tests.log'))
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
    log = logs[0]
    if log.is_symlink() or not log.is_file() or log.stat().st_size > 128 * 1024 * 1024:
        result['observation'] = 'unobserved-log-bound'
        return result
    inputs = read_json(root / 'public-evidence/source-inputs.json', 4 * 1024 * 1024)
    sources = {}
    for key, component, directory in (('trackedSDKFiles', 'sdk', 'lattice'), ('trackedCoreFiles', 'core', 'LatticeCore')):
        files = inputs[key]
        require(type(files) is dict and len(files) <= 8192)
        for name, identity in files.items():
            require(type(name) is str and len(name) <= 1024 and not name.startswith('/')
                    and '..' not in PurePosixPath(name).parts and str(PurePosixPath(name)) == name
                    and re.fullmatch(r'[A-Za-z0-9_./+@ -]+', name))
            require(type(identity) is dict and type(identity['bytes']) is int and identity['bytes'] >= 0
                    and HEX256.fullmatch(identity['sha256']))
            sources[str(root / directory / name)] = {'component': component, 'path': name,
                                                     'sourceSHA256': identity['sha256']}
    total, number, digest = 0, 0, hashlib.sha256()
    with log.open('rb') as stream:
        while True:
            raw = stream.readline(16385)
            if not raw:
                break
            number += 1
            offset = total
            total += len(raw)
            digest.update(raw)
            require(total <= 128 * 1024 * 1024)
            if len(raw) > 16384:
                result['oversizedLineCount'] += 1
                while raw and not raw.endswith(b'\n'):
                    raw = stream.readline(16385)
                    total += len(raw)
                    digest.update(raw)
                    require(total <= 128 * 1024 * 1024)
                continue
            text = re.sub(r'\x1b\[[0-9;]*m', '', raw.decode('utf-8', errors='replace')).rstrip('\r\n')
            location = re.fullmatch(r'(.+):([1-9][0-9]{0,6}):([1-9][0-9]{0,5}): (fatal error|error|note): (.*)', text)
            driver = re.fullmatch(r'(?:clang(?:\+\+)?|swift(?:-frontend)?|ld)?(?:: )?(fatal error|error): (.*)', text)
            if not location and not driver:
                continue
            severity = location.group(4) if location else driver.group(1)
            message = location.group(5) if location else driver.group(2)
            code = build_diagnostic_code(message)
            result['diagnosticCount'] += 1
            result['categoryCounts'][code] = result['categoryCounts'].get(code, 0) + 1
            count_key = 'retainedNoteCount' if severity == 'note' else 'retainedErrorCount'
            if result[count_key] >= (64 if severity == 'note' else 192):
                result['omittedDiagnosticCount'] += 1
                continue
            result[count_key] += 1
            entry = {'logLine': number, 'byteOffset': offset, 'rawLineBytes': len(raw),
                     'rawLineSHA256': hashlib.sha256(raw).hexdigest(), 'severity': severity, 'category': code}
            if location:
                entry.update(line=int(location.group(2)), column=int(location.group(3)))
                source = sources.get(location.group(1))
                if source is None:
                    result['retainedUnmappedLocationCount'] += 1
                    entry['source'] = 'unmapped'
                else:
                    entry['source'] = source
            else:
                entry['source'] = 'driver'
            result['diagnostics'].append(entry)
    require(total == record['logBytes'] and digest.hexdigest() == record['logSHA256'])
    result.update(observation='closed-first-log', buildLogBytes=total, buildLogSHA256=digest.hexdigest())
    return result


def cleanup_fixtures(root):
    """Delete only this test's private UUID directories after process retirement.

    Ordinary source owners can outlive in-process session cleanup. No WAL,
    custody file or store is unlinked until the actual Swift process/group was
    reaped. Missing crash-time ownership evidence leaves stores untouched.
    """
    private = root / 'private'
    pattern = re.compile(r'configured-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}')
    def children(path, limit):
        result = []
        with os.scandir(path) as entries:
            for entry in entries:
                require(len(result) < limit)
                result.append(Path(entry.path))
        return result
    candidates = [x for x in children(private, 4096) if x.name.startswith('configured-')]
    require(len(candidates) <= 16)
    require(all(pattern.fullmatch(x.name) and x.is_dir() and not x.is_symlink() for x in candidates))
    logs = list((private / 'commands').glob('*-connected-tests.log'))
    records = list((private / 'commands').glob('*-connected-tests.json'))
    require(len(logs) <= 1 and len(records) <= 1)
    if not logs and not records:
        require(not candidates)
        return {'success': True, 'process': 'not-started', 'removedDirectories': 0, 'removedFiles': 0}
    require(len(logs) == len(records) == 1 and logs[0].stem == records[0].stem)
    record = read_json(records[0], 1024 * 1024)
    require(record['cleanup']['groupGone'] is True and record['cleanup']['leaderReaped'] is True)
    require(record['started'] is True or not candidates)
    # Validate the complete bounded inventory before deleting anything. The
    # caller owns the fresh root, and its only fixture writer has now retired.
    inventory, total_bytes = [], 0
    for candidate in sorted(candidates):
        pending = [candidate]
        while pending:
            path = pending.pop()
            info = path.lstat()
            require(stat.S_ISDIR(info.st_mode) or (stat.S_ISREG(info.st_mode) and info.st_nlink == 1))
            inventory.append((path, info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns))
            require(len(inventory) <= 4096)
            if stat.S_ISDIR(info.st_mode):
                pending.extend(children(path, 4096 - len(inventory) - len(pending)))
            else:
                total_bytes += info.st_size
                require(total_bytes <= 1024 * 1024 * 1024)
    files = 0
    for path, device, inode, mode, size, modified in sorted(inventory, key=lambda x: len(x[0].parts), reverse=True):
        current = path.lstat()
        require((current.st_dev, current.st_ino, current.st_mode) == (device, inode, mode))
        if stat.S_ISDIR(mode):
            path.rmdir()
        else:
            require(current.st_size == size and current.st_mtime_ns == modified and current.st_nlink == 1)
            path.unlink()
            files += 1
    require(all(not path.exists() for path in candidates))
    return {'success': True, 'process': 'reaped-group-absent', 'removedDirectories': len(candidates), 'removedFiles': files}

def cleanup_all(commands, root):
    result = {'success': False, 'trustAbsent': False, 'privateKeysAbsent': False}
    try:
        result['fixtures'] = cleanup_fixtures(root)
    except BaseException as error:
        result['fixtureErrorClass'] = type(error).__name__
    # A store-cleanup refusal must never suppress removal of our trust/keys.
    try:
        result.update(cleanup_trust(commands, root))
    except BaseException as error:
        result['trustErrorClass'] = type(error).__name__
    result['success'] = (not result.get('fixtureErrorClass') and not result.get('trustErrorClass')
                         and result['trustAbsent'] and result['privateKeysAbsent'])
    return result


def test_support_compiler_inputs(log, core, tracked_files):
    """Actual direct compiler inputs, never a filename/linker mention as proof.

    Uses the reviewed020/021 saved-log parser's direct-clang, single-canonical
    -c input and no-response-file/shell-composition rules. This live gate already
    owns a closed successful build log and an authenticated initial Core tree.
    Only fixed metadata and line hashes leave the private log. At most16 actual
    commands per input are retained; any uncertain command refuses acceptance.
    """
    require(core.is_absolute() and core.resolve(strict=True) == core and not core.is_symlink())
    expected = {str(core / name): name for name in TEST_SUPPORT_INPUTS}
    observations = {}
    for name in TEST_SUPPORT_INPUTS:
        path = core / name
        require(path.resolve(strict=True) == path and name in tracked_files)
        source = read_file(path, 1024 * 1024)
        frozen = tracked_files[name]
        require(set(frozen) == {'bytes', 'sha256'} and frozen['bytes'] == len(source)
                and frozen['sha256'] == hashlib.sha256(source).hexdigest())
        observations[name] = {'status': 'unobserved', 'source': dict(frozen), 'commands': [],
                              'uncertainCommandCount': 0, 'otherMentionCount': 0, 'refusalCodes': []}
    require(log.is_file() and not log.is_symlink() and log.stat().st_size <= 128 * 1024 * 1024)
    total, log_hash = 0, hashlib.sha256()
    with log.open('rb') as lines:
        for number, raw in enumerate(lines, 1):
            offset = total
            total += len(raw)
            require(total <= 128 * 1024 * 1024)
            log_hash.update(raw)
            mentioned = [name for name in TEST_SUPPORT_INPUTS if PurePosixPath(name).name.encode() in raw]
            if not mentioned:
                continue
            reason, category, selected = None, 'uncertainCommandCount', None
            try:
                text = raw.decode('utf-8')
                argv = shlex.split(text)
                lexer = shlex.shlex(text, posix=True, punctuation_chars=';&|<>()')
                lexer.whitespace_split = True
                lexer.commenters = ''
                tokens = list(lexer)
            except (UnicodeDecodeError, ValueError):
                reason = 'unparseable-command'
            else:
                if not argv or PurePosixPath(argv[0]).name not in ('clang', 'clang++') or '-c' not in argv:
                    reason = 'not-direct-clang-compile'
                    if '-c' not in argv:
                        category = 'otherMentionCount'
                elif argv.count('-c') != 1 or argv.index('-c') + 1 >= len(argv):
                    reason = 'ambiguous-or-missing-input'
                elif any(value.startswith('@') for value in argv) or any(
                        value and all(c in ';&|<>()' for c in value) for value in tokens):
                    reason = 'response-file-or-shell-composition'
                else:
                    source = argv[argv.index('-c') + 1]
                    if not (source.startswith('/') and '\x00' not in source
                            and '..' not in PurePosixPath(source).parts and str(PurePosixPath(source)) == source):
                        reason = 'noncanonical-input'
                    elif source not in expected:
                        reason = 'input-outside-exact-targets'
                    else:
                        selected = observations[expected[source]]
                        if len(selected['commands']) >= 16:
                            selected['uncertainCommandCount'] += 1
                            if 'command-count-bound' not in selected['refusalCodes']:
                                selected['refusalCodes'].append('command-count-bound')
                        else:
                            selected['commands'].append({'line': number, 'byteOffset': offset,
                                'rawLineBytes': len(raw), 'rawLineSHA256': hashlib.sha256(raw).hexdigest(),
                                'compiler': PurePosixPath(argv[0]).name})
            if reason is not None:
                for name in mentioned:
                    value = observations[name]
                    value[category] += 1
                    if category == 'uncertainCommandCount' and reason not in value['refusalCodes']:
                        value['refusalCodes'].append(reason)
    for value in observations.values():
        if value['commands'] and not value['uncertainCommandCount']:
            value['status'] = 'compiler_input_observed'
    return {'version': 1, 'kind': 'exact direct TestSupport clang -c inputs',
            'buildLogSHA256': log_hash.hexdigest(), 'buildLogBytes': total,
            'compileSuccessInferredFromCommands': False, 'sources': observations}


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
    support = test_support_compiler_inputs(build, core, initial_core['files'])
    write_json(root / 'public-evidence/compiler-inputs.json', {
        'version': 1, 'stage': 'verified-actual-compiler-inputs', 'coreCommit': core_sha, 'coreTree': core_tree,
        'sourceFiles': {str(Path(k).relative_to(core)): v for k, v in compiler['sourceFiles'].items()},
        'proofSHA256': hashlib.sha256(json.dumps(compiler, sort_keys=True).encode()).hexdigest(),
        'buildLogSHA256': helper.digest(build), 'testSupportInputs': support})
    require(all(value['status'] == 'compiler_input_observed' for value in support['sources'].values()))
    result['stage'] = 'tls-material'
    tag, tls, version = material(commands, root, openssl)
    result['opensslVersion'] = version
    result['stage'] = 'trust-install'
    result['trustInstall'] = trust_install(commands, root, tag, tls)
    env = commands.runner.env
    env.update(LATTICE_CONNECTED_RECOVERY_GATE='1', LATTICE_CONFIGURED_RENEWAL_GATE='1', LATTICE_CONNECTED_RECOVERY_RUN_DIR=str(root),
               LATTICE_CONNECTED_RECOVERY_CA_CERT=str(root / 'private/tls/ca.pem'),
               LATTICE_CONNECTED_RECOVERY_TLS_CERT=str(root / 'private/tls/matching.pem'),
               LATTICE_CONNECTED_RECOVERY_TLS_KEY=str(root / 'private/tls/matching.key'),
               LATTICE_CONNECTED_RECOVERY_WRONG_HOST_CERT=str(root / 'private/tls/wrong-host.pem'),
               LATTICE_CONNECTED_RECOVERY_WRONG_HOST_KEY=str(root / 'private/tls/wrong-host.key'),
               LATTICE_CONNECTED_RECOVERY_TLS_RECEIPT=str(root / 'receipts/tls-material.json'))
    result['stage'] = 'connected-tests'
    test = commands.run('connected-tests', ['swift', 'test', *common, '--force-resolved-versions', '--skip-build',
                                            '--filter', 'PublicConfiguredStockRenewalTests'],
                        cwd=sdk, timeout=TEST_SECONDS, full=True)
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
    write_json(root / 'public-evidence/configured-renewal-cases.json', cases)
    write_json(root / 'public-evidence/source-bindings.json', {
        'version': 1, 'sdkCommit': sdk_sha, 'sdkTree': initial_sdk['tree'], 'coreCommit': core_sha, 'coreTree': core_tree,
        'trackedSDKFiles': initial_sdk['files'], 'trackedCoreFiles': initial_core['files'],
        'resolvedPins': original, 'effectiveRevisions': {x['identity']: x['revision'] for x in before},
        'compilerInputs': {str(Path(k).relative_to(core)): v for k, v in compiler['sourceFiles'].items()},
        'compilerInputProofSHA256': hashlib.sha256(json.dumps(compiler, sort_keys=True).encode()).hexdigest(),
        'testSupportCompilerInputs': support,
        'testLogSHA256': helper.digest(test), 'testLogBytes': test.stat().st_size,
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
        if not (root / 'public-evidence/build-diagnostics.json').exists():
            try:
                write_json(root / 'public-evidence/build-diagnostics.json', build_diagnostics(root))
            except BaseException as error:
                result['buildEvidenceErrorClass'] = type(error).__name__
                result['success'] = False
        try:
            publish_case_observation(root)
        except BaseException as error:
            result['receiptEvidenceErrorClass'] = type(error).__name__
            result['success'] = False
        try:
            write_json(root / 'public-evidence/cleanup-always-commands.json', public_commands(logs))
        except BaseException as error:
            result['cleanupCommandEvidenceErrorClass'] = type(error).__name__
            result['success'] = False
        write_json(root / 'public-evidence/always-cleanup.json', result)
        print('configured renewal gate always-cleanup success', result['success'], flush=True)
        return 0 if result['success'] else 1
    require(SHA.fullmatch(os.environ.get('GITHUB_SHA', '')) and SHA.fullmatch(args.core_sha or '')
            and SHA.fullmatch(args.core_tree or '') and args.openssl is not None)
    require(args.openssl.is_absolute() and args.openssl.is_file())
    for name in ('private', 'receipts', 'public-evidence', 'module-cache', 'cache', 'config', 'security', 'scratch'):
        (root / name).mkdir(mode=0o700, exist_ok=False)
    (root / 'tmp').mkdir(mode=0o700, exist_ok=True)
    logs = root / 'private/commands'
    logs.mkdir(mode=0o700)
    result = {'version': 1, 'scope': 'normal public configured renewal only; no product enablement', 'sdkCommit': os.environ['GITHUB_SHA'],
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
                    write_json(root / 'public-evidence/build-diagnostics.json', build_diagnostics(root))
                except BaseException as error:
                    result['buildEvidenceErrorClass'] = type(error).__name__
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
                try:
                    write_json(root / 'public-evidence/cleanup-final-commands.json', public_commands(cleanup_logs))
                except BaseException as error:
                    result['cleanupCommandEvidenceErrorClass'] = type(error).__name__
                    result['success'] = False
                write_json(root / 'public-evidence/result.json', result)
    print('configured renewal gate success', result['success'], 'stage', result['stage'], flush=True)
    return 0 if result['success'] else 1

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as failure:
        print('configured renewal gate early failure', type(failure).__name__, flush=True)
        sys.exit(1)
