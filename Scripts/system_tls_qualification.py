"""Explicit hosted stock-adapter TLS matrix; no full-suite/recovery acceptance."""
import json
import os
from pathlib import Path
import platform
import re
import secrets
import subprocess
import time
import xml.etree.ElementTree as ET
import system_tls_trust as trust

CASES = ['plain_ws_untrusted', 'trusted_wss_open_close', 'trusted_wss_reconnect',
         'hostname_mismatch', 'independent_unknown_ca', 'redirect_disqualified']
IDENTITY = 'LatticeTests.HostedSystemTLSQualificationTests/hostedSystemTrustMatrix()'
SOURCE = 'Tests/LatticeTests/SyncTests/HostedSystemTLSQualificationTests.swift'
PREFIX = 'LATTICE_HOSTED_TLS_CASE '
CLEANUP_SECONDS = 420


def save(path, value):
    trust.save(path, value)


def error_record(error):
    return {'type': type(error).__name__, 'message': str(error)}


def source_inventory(sdk):
    raw = trust.read(Path(sdk) / SOURCE, 65536)
    names = re.findall(rb'@Test[^\n]*\n\s*func (\w+)\(', raw)
    if names != [b'hostedSystemTrustMatrix'] or any(raw.count(('"' + name + '"').encode()) < 1 for name in CASES):
        raise ValueError('TLS fixture source inventory changed')
    return {'path': SOURCE, 'sha256': trust.sha(raw), 'identifiers': [IDENTITY], 'caseIDs': CASES}


def validate_cases(log, config, system):
    events = []
    starts = passes = summaries = 0
    with Path(log).open() as source:
        for line in iter(lambda: source.readline(65537), ''):
            if len(line) > 65536: raise ValueError('TLS output line bound')
            plain = re.sub(r'\x1b\[[0-9;]*m', '', line).strip()
            if plain.startswith(PREFIX):
                if len(plain) > 16384 or len(events) >= 12: raise ValueError('TLS event count/byte bound')
                events.append(json.loads(plain[len(PREFIX):]))
            if re.search(r'\bskipped\b|recorded an issue|unexpected signal|Exited with unexpected|^[✘×]', plain):
                raise ValueError('TLS framework failure/skip')
            if plain == '◇ Test hostedSystemTrustMatrix() started.': starts += 1
            if re.fullmatch(r'[✔✓] Test hostedSystemTrustMatrix\(\) passed after [0-9.]+ seconds?\.', plain): passes += 1
            if re.fullmatch(r'[✔✓] Test run with 1 test in 1 suite passed after [0-9.]+ seconds?\.', plain): summaries += 1
    if (starts, passes, summaries) != (1, 1, 1) or [(x.get('case'), x.get('phase')) for x in events] != [(name, phase) for name in CASES for phase in ('started', 'completed')]:
        raise ValueError('required TLS cases/framework did not execute exactly once')
    adapter = 'stock-NIO-system-roots' if system == 'Linux' else 'stock-URLSession-system-trust'
    for item in events:
        if item.get('nonce') != config['nonce'] or item.get('adapter') != adapter: raise ValueError('foreign TLS case receipt')
        if item['phase'] == 'started':
            if set(item) != {'nonce', 'adapter', 'case', 'phase'}: raise ValueError('unexpected start receipt')
            continue
        name = item['case']; plain = name == 'plain_ws_untrusted'
        if item.get('proofBeforeClose') is not (name in ('trusted_wss_open_close', 'trusted_wss_reconnect')):
            raise ValueError('TLS live proof differs from expected actual adapter state')
        expected = 'none' if plain else config['unknownCertificateSHA256' if name == 'independent_unknown_ca' else 'trustedCertificateSHA256']
        if item.get('certificateSHA256') != expected or item.get('serverShutdown') is not True or item.get('proofAfterClose') is not False:
            raise ValueError('TLS certificate/shutdown proof differs')
        for key in ('port', 'opens', 'errors', 'serverOpens', 'redirects'):
            if type(item.get(key)) is not int or item[key] < 0: raise ValueError('invalid TLS numeric receipt')
        if not 0 < item['port'] < 65536: raise ValueError('invalid ephemeral TLS port')
        host = '127.0.0.1' if plain or name == 'hostname_mismatch' else 'localhost'
        route = 'redirect' if name == 'redirect_disqualified' else 'tls'
        if item.get('url') != f'{"ws" if plain else "wss"}://{host}:{item["port"]}/{route}': raise ValueError('TLS URL differs from owned fixture')
        if name in ('hostname_mismatch', 'independent_unknown_ca'):
            if item['opens'] or item['serverOpens'] or item['errors'] < 1 or item['redirects']: raise ValueError('negative TLS control failed')
        elif name == 'redirect_disqualified':
            if item['redirects'] != 1 or item['errors'] + item['opens'] < 1: raise ValueError('redirect was not actually exercised')
        else:
            count = 2 if name == 'trusted_wss_reconnect' else 1
            if (item['opens'], item['serverOpens'], item['errors'], item['redirects']) != (count, count, 0, 0): raise ValueError('positive TLS control failed')
    return events


def validate_xml(path):
    root = ET.fromstring(trust.read(path, 1048576))
    if root.tag not in ('testsuites', 'testsuite') or any(list(root.iter(tag)) for tag in ('error', 'failure', 'skipped')):
        raise ValueError('nonpassing TLS xunit report')
    cases = list(root.iter('testcase'))
    if [case.get('classname', '') + '/' + case.get('name', '') for case in cases] != [IDENTITY]: raise ValueError('TLS xunit case identity differs')
    for suite in root.iter('testsuite'):
        for key in ('failures', 'errors', 'skipped'):
            if int(suite.get(key, '0')) != 0: raise ValueError('nonzero TLS xunit status')


def owned_commands_gone(runner):
    for item in runner.records:
        if not item['label'].startswith('system-tls-'): continue
        record = json.loads(trust.read(runner.receipts / (item['label'] + '.json'), 1048576))
        cleanup = record.get('cleanup', {})
        if cleanup.get('groupGone') is not True or cleanup.get('leaderReaped') is not True:
            raise RuntimeError('cannot mutate trust/delete keys without TLS process retirement proof')


def cleanup_command(runner, sdk, root):
    """Narrow cleanup-only escape, never clears signals or resumes normal work."""
    trust.hosted(root)
    state = json.loads(trust.read(root / 'OWNERSHIP.json', 16384))
    if state['overallDeadline'] != runner.overall_deadline: raise ValueError('cleanup deadline differs from original runner')
    argv = ['python3', str(sdk / 'Scripts/system_tls_trust.py'), 'cleanup', '--root', str(root)]
    label = 'system-tls-trust-cleanup'
    log = runner.receipts / (label + '.log')
    record = {'argv': argv, 'cwd': str(sdk), 'started': False, 'success': False, 'cleanupOnly': True,
              'originalOverallDeadline': runner.overall_deadline, 'requestedTimeoutSeconds': CLEANUP_SECONDS,
              'primaryError': None, 'evidenceErrors': []}
    process = output = None; primary = None
    started = time.monotonic(); deadline = min(started + CLEANUP_SECONDS, runner.overall_deadline - 12)
    try:
        if deadline <= started: raise RuntimeError('TLS cleanup deadline exhausted')
        with runner.interrupts.hold():
            output = log.open('xb')
            process = subprocess.Popen(argv, cwd=sdk, env=runner.env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            record.update(started=True, pid=process.pid, ownedPGID=process.pid)
            while process.poll() is None:
                if time.monotonic() >= deadline or log.stat().st_size > 1048576: raise RuntimeError('TLS cleanup time/log bound')
                time.sleep(0.1)
            if process.returncode != 0: raise RuntimeError('TLS trust restoration helper failed')
    except BaseException as error:
        primary = error; record['primaryError'] = error_record(error)
    finally:
        with runner.interrupts.hold():
            try:
                record['cleanup'] = runner.cleanup(process) if process is not None else {'groupGone': True, 'leaderReaped': True, 'proof': 'not started'}
                if process is not None: record['exitCode'] = process.returncode
            except BaseException as error:
                record['cleanup'] = {'groupGone': False, 'leaderReaped': False}; record['evidenceErrors'].append(error_record(error))
            try:
                if output is not None: output.close()
            except BaseException as error: record['evidenceErrors'].append(error_record(error))
            try:
                if log.exists(): record['logSHA256'] = trust.sha(trust.read(log, 1048576 + 65536))
                record['finalResources'] = runner.measure(log)
                violation = runner.violation(record['finalResources'])
                if violation: record['evidenceErrors'].append({'message': violation})
            except BaseException as error: record['evidenceErrors'].append(error_record(error))
            record.update(receivedSignals=list(runner.interrupts.received), elapsedSeconds=time.monotonic() - started)
            record['success'] = (record['started'] and primary is None and not record['evidenceErrors'] and
                                 record['cleanup']['groupGone'] and record['cleanup']['leaderReaped'] and time.monotonic() <= runner.overall_deadline)
            try: save(runner.receipts / (label + '.json'), record)
            except BaseException as error:
                record['success'] = False; record['evidenceErrors'].append(error_record(error))
                print('TLS_CLEANUP_RECEIPT_WRITE_FAILED', json.dumps(record), flush=True)
            runner.records.append({'label': label, 'success': record['success']})
    if primary is not None: raise primary
    if not record['success']: raise RuntimeError('TLS cleanup unqualified')


def qualify(runner, sdk, core, root, common):
    from recovery_refresh_qualification import test_image
    root, sdk, core = Path(root), Path(sdk), Path(core)
    tls = root / 'system-tls'
    tls.mkdir(exist_ok=False); (tls / 'receipts').mkdir()
    identity = trust.hosted(tls)
    if not (core / 'Sources/LatticeServerExportTestSupport/include/platform_tls_fixture.hpp').is_file():
        raise ValueError('accepted paired Core graph with actual TLS fixture is required')
    if runner.work_deadline - time.monotonic() < 840 or runner.overall_deadline - runner.work_deadline < CLEANUP_SECONDS + 12:
        raise RuntimeError('unchanged work/finalization budget cannot admit TLS scope')
    inventory, image = source_inventory(sdk), test_image(root / 'scratch')
    nonce = secrets.token_hex(16)
    state = {'identity': identity, 'platform': platform.system(), 'nonce': nonce,
             'workDeadline': runner.work_deadline, 'overallDeadline': runner.overall_deadline}
    save(tls / 'OWNERSHIP.json', state); save(tls / 'receipts/source-inventory.json', inventory)
    original_env = {key: runner.env.get(key) for key in ('LATTICE_SYSTEM_TLS_QUALIFICATION', 'LATTICE_SYSTEM_TLS_NONCE', 'LATTICE_SYSTEM_TLS_CONFIG', 'LATTICE_TEST_LOG_PATH')}
    primary = None; errors = []; actual = None
    try:
        runner.run('system-tls-prepare', ['python3', str(sdk / 'Scripts/system_tls_trust.py'), 'prepare', '--root', str(tls)], cwd=sdk, timeout=300, require_full_timeout=True)
        config = json.loads(trust.read(tls / 'fixture.json', 16384))
        runner.env.update(LATTICE_SYSTEM_TLS_QUALIFICATION='1', LATTICE_SYSTEM_TLS_NONCE=nonce,
                          LATTICE_SYSTEM_TLS_CONFIG=str(tls / 'fixture.json'), LATTICE_TEST_LOG_PATH=str(root / 'test-logs/system-tls.log'))
        listing = runner.run('system-tls-discovery', ['swift', 'test', *common, '--force-resolved-versions', '--skip-build', 'list'], cwd=sdk, timeout=60, require_full_timeout=True)
        names = [line.strip() for line in trust.read(listing).decode().splitlines() if line.strip().startswith('LatticeTests.HostedSystemTLSQualificationTests/')]
        if names != [IDENTITY]: raise ValueError('TLS discovery omitted or duplicated required test')
        for flag in ('--disable-xctest', '--enable-swift-testing', '--xunit-output'):
            if flag not in trust.read(runner.receipts / 'test-help.log').decode(): raise ValueError('required TLS test runner option missing')
        runner.run('system-tls-install', ['python3', str(sdk / 'Scripts/system_tls_trust.py'), 'install', '--root', str(tls)], cwd=sdk, timeout=180, require_full_timeout=True)
        xml = tls / 'receipts/cases.xml'
        log = runner.run('system-tls-fixtures', ['swift', 'test', *common, '--force-resolved-versions', '--skip-build', '--disable-xctest', '--enable-swift-testing',
                         '--filter', '^' + re.escape(IDENTITY) + r'(?:/|$)', '--xunit-output', str(xml)], cwd=sdk, timeout=300, require_full_timeout=True)
        validate_xml(xml); actual = validate_cases(log, config, platform.system())
        if source_inventory(sdk) != inventory or test_image(root / 'scratch') != image: raise ValueError('TLS source/test image changed')
        armed = json.loads(trust.read(tls / 'ARMED.json'))
        if trust.sha(trust.read(tls / 'fixture.json', 16384)) != armed['fixtureSHA256']: raise ValueError('TLS fixture config changed')
        for name in ('trusted', 'unknown'):
            if trust.sha(trust.read(Path(config[name + 'Certificate']), 16384)) != config[name + 'CertificatePEMSHA256']: raise ValueError('TLS server certificate changed')
    except BaseException as error:
        primary = error
    finally:
        with runner.interrupts.hold():
            try:
                owned_commands_gone(runner)
                if (tls / 'ARMED.json').exists():
                    cleanup_command(runner, sdk, tls)
                    restored = json.loads(trust.read(tls / 'receipts/RESTORED.json', 16384))
                    if restored.get('success') is not True or restored.get('nonce') != nonce: raise ValueError('missing exact TLS restoration receipt')
            except BaseException as error: errors.append(error_record(error))
            try:
                owned_commands_gone(runner)
                for name in ('trusted-ca.key', 'trusted-leaf.key', 'unknown-ca.key', 'unknown-leaf.key'):
                    path = tls / 'private' / name
                    if path.exists():
                        if path.is_symlink() or not path.is_file(): raise ValueError('unowned fixture key path')
                        path.unlink()
            except BaseException as error: errors.append(error_record(error))
            for key, value in original_env.items():
                if value is None: runner.env.pop(key, None)
                else: runner.env[key] = value
            success = primary is None and not errors and actual is not None and not runner.interrupts.received
            report = {'success': success, 'primaryError': error_record(primary) if primary else None, 'cleanupErrors': errors,
                 'receivedSignals': list(runner.interrupts.received), 'cases': actual, 'testImage': image, 'sourceInventory': inventory,
                 'scope': 'stock hosted TLS adapter component qualification only', 'fullSuiteAccepted': False, 'receiverAuthorityAccepted': False,
                 'performanceAccepted': False, 'releaseAccepted': False}
            try: save(tls / 'receipts/RESULT.json', report)
            except BaseException as error:
                success = False; errors.append(error_record(error))
                print('TLS_RESULT_WRITE_FAILED', json.dumps(report), flush=True)
    if primary is not None: raise primary
    if not success: raise RuntimeError('TLS qualification/cleanup failed; preserve first receipts')
