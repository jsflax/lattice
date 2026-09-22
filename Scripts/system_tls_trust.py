"""Hosted-only fixture trust lifecycle. Never imports/executes OS trust during pure tests."""
import argparse
import base64
import ctypes
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import subprocess
import sys
import time

MAX_BYTES = 16 * 2**20
CERT_BYTES = 16384
COMMAND_LOG_BYTES = 2**20
BUNDLE = Path('/etc/ssl/certs/ca-certificates.crt')
KEYCHAIN = '/Library/Keychains/System.keychain'
SECURITY = '/usr/bin/security'
NO_TRUST_SETTINGS = -25263


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def read(path, cap=MAX_BYTES):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > cap:
        raise ValueError('nonregular or oversized TLS input: ' + str(path))
    with path.open('rb') as source:
        raw = source.read(cap + 1)
    if len(raw) > cap:
        raise ValueError('TLS input grew beyond bound')
    return raw


def save(path, value):
    with Path(path).open('x') as output:
        json.dump(value, output, sort_keys=True, indent=2)
        output.write('\n')
        output.flush(); os.fsync(output.fileno())


def hosted(root, env=None, system=None, runner_home=None):
    env = os.environ if env is None else env
    system = platform.system() if system is None else system
    if env.get('GITHUB_ACTIONS') != 'true' or env.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise ValueError('TLS qualification requires an explicitly hosted GitHub job')
    expected_leg = {'Darwin': 'macos', 'Linux': 'linux'}.get(system)
    if not expected_leg or env.get('DEVELOPMENT_LEG') != expected_leg:
        raise ValueError('unreviewed TLS platform/leg')
    for name in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'):
        if not re.fullmatch('[1-9][0-9]{0,19}', env.get(name, '')):
            raise ValueError('missing hosted run identity')
    for name in ('GITHUB_JOB', 'GITHUB_REPOSITORY'):
        if not re.fullmatch('[A-Za-z0-9_./-]{1,200}', env.get(name, '')):
            raise ValueError('missing hosted job identity')
    if not re.fullmatch('[0-9a-f]{40}', env.get('GITHUB_SHA', '')):
        raise ValueError('missing exact SDK revision')
    expected = (Path.home() if runner_home is None else runner_home) / 'localdev' / ('lattice-development-' + env['GITHUB_RUN_ID'] + '-' + env['GITHUB_RUN_ATTEMPT'] + '-' + expected_leg) / 'system-tls'
    root = Path(root)
    if root != expected or root.parent.resolve(strict=True) != expected.parent or root.is_symlink() or (root.exists() and root.resolve(strict=True) != expected):
        raise ValueError('TLS root differs from exact fresh hosted localdev root')
    return {name: env[name] for name in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB', 'GITHUB_REPOSITORY', 'GITHUB_SHA', 'DEVELOPMENT_LEG')}


def canonical(value, depth=0, budget=None):
    budget = [200000] if budget is None else budget
    budget[0] -= 1
    if depth > 32 or budget[0] < 0: raise ValueError('trust plist structural bound')
    if isinstance(value, bytes):
        return {'data': base64.b64encode(value).decode()}
    if isinstance(value, datetime.datetime):
        return {'date': value.isoformat()}
    if isinstance(value, dict):
        return {key: canonical(item, depth + 1, budget) for key, item in sorted(value.items())}
    if isinstance(value, list):
        return [canonical(item, depth + 1, budget) for item in value]
    if isinstance(value, float) and not math.isfinite(value): raise ValueError('nonfinite trust plist scalar')
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise ValueError('unexpected trust plist value')


def classify_trust(status, raw):
    # Apple SecBase.h and SecTrustSettingsCreateExternalRepresentation: only
    # this typed status is absence. No generic CLI/read failure becomes empty.
    if status == NO_TRUST_SETTINGS and raw is None:
        return {'status': status, 'inventory': {}}
    if status != 0 or raw is None or len(raw) > MAX_BYTES:
        raise ValueError('trust snapshot failed: OSStatus ' + str(status))
    value = plistlib.loads(raw)
    if not isinstance(value, dict) or set(value) != {'trustVersion', 'trustList'} or value['trustVersion'] != 1 or not isinstance(value['trustList'], dict):
        raise ValueError('unreviewed trust-settings serialization')
    return {'status': 0, 'inventory': canonical(value['trustList']), 'rawSHA256': sha(raw)}


def mac_export(domain):
    # Called only in the guarded hosted helper process. No compile, import of
    # this module, or pure test loads Security.framework.
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    security.SecTrustSettingsCreateExternalRepresentation.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
    security.SecTrustSettingsCreateExternalRepresentation.restype = ctypes.c_int32
    cf.CFDataGetLength.argtypes = [ctypes.c_void_p]; cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]; cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]; cf.CFRelease.restype = None
    output = ctypes.c_void_p()
    status = security.SecTrustSettingsCreateExternalRepresentation(domain, ctypes.byref(output))
    try:
        if status != 0:
            return classify_trust(status, None), None
        if not output.value:
            raise ValueError('successful trust export omitted data')
        size = cf.CFDataGetLength(output)
        if size < 0 or size > MAX_BYTES:
            raise ValueError('trust export byte bound')
        raw = ctypes.string_at(cf.CFDataGetBytePtr(output), size)
        return classify_trust(status, raw), raw
    finally:
        if output.value:
            cf.CFRelease(output)


def certificates(raw):
    if len(raw) > MAX_BYTES:
        raise ValueError('certificate inventory bound')
    pattern = rb'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)-----END CERTIFICATE-----'
    matches = list(re.finditer(pattern, raw))
    if len(matches) > 10000 or re.sub(pattern, b'', raw).strip():
        raise ValueError('certificate inventory is not exact PEM sequence')
    return [base64.b64decode(re.sub(rb'\s', b'', match[1]), validate=True) for match in matches]


def logical_snapshot(snapshot):
    return {'certificates': snapshot['certificates'], 'trust': {key: value['inventory'] for key, value in snapshot['trust'].items()},
            'selection': snapshot['selection']}


class Commands:
    def __init__(self, root, phase, deadline):
        self.root, self.phase, self.deadline = Path(root), phase, deadline
        self.number = 0

    def run(self, label, argv):
        self.number += 1
        if self.number > 40 or time.monotonic() + 30 > self.deadline:
            raise RuntimeError('finite TLS command/deadline admission refused')
        prefix = self.root / 'receipts' / f'{self.phase}-{self.number:02}-{label}'
        log = prefix.with_suffix('.log')
        record = {'argv': argv, 'timeoutSeconds': 30, 'success': False}
        process = None; primary = None; privileged = None
        try:
            with log.open('xb') as output:
                until = time.monotonic() + 30
                if argv[:3] == ['sudo', '-n', SECURITY]:
                    import system_tls_privileged as helper
                    if not hasattr(os, 'waitid'): raise RuntimeError('hosted privileged TLS supervision requires Python 3.13 or newer')
                    armed = json.loads(read(self.root / 'ARMED.json'))
                    if argv[2:] != helper.command(self.root, label, armed): raise ValueError('privileged TLS argv differs')
                    retirement = until + helper.RETIRE_SECONDS
                    if retirement > self.deadline: raise RuntimeError('original TLS reserve cannot admit privileged command cleanup')
                    name = prefix.name + '-privileged'
                    request = {'root': str(self.root), 'name': name, 'nonce': armed['state']['nonce'],
                               'phase': self.phase, 'number': self.number, 'label': label,
                               'deadline': until, 'retirementDeadline': retirement}
                    request_path = self.root / 'receipts' / (name + '-request.json')
                    save(request_path, request)
                    privileged = (request_path, retirement)
                    record['privilegedRequest'] = str(request_path)
                    launch = ['sudo', '-n', '--preserve-env=' + helper.PRESERVED_ENV, sys.executable, '-I', '-B',
                              str(Path(__file__).resolve().with_name('system_tls_privileged.py')), '--request', str(request_path)]
                    process = subprocess.Popen(launch, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                else:
                    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT)
                record['pid'] = process.pid
                while process.poll() is None:
                    if time.monotonic() >= until or log.stat().st_size > COMMAND_LOG_BYTES:
                        raise RuntimeError('TLS command exceeded time/output bound')
                    time.sleep(0.05)
                record['exitCode'] = process.returncode
                if process.returncode != 0:
                    raise RuntimeError('TLS command failed: ' + label)
                if privileged:
                    proof = privileged_result(privileged[0])
                    if not proof['success']: raise RuntimeError('privileged TLS command or cleanup failed')
            raw = read(log, COMMAND_LOG_BYTES)
            record['success'] = True
            return raw
        except BaseException as error:
            primary = error
            record['error'] = {'type': type(error).__name__, 'message': str(error)}
            raise
        finally:
            failures = []
            try:
                if privileged:
                    # Closing the ownership pipe cancels the root supervisor.
                    # It owns signalling its root child; never kill only sudo
                    # and leave that child outside this helper's authority.
                    if process is not None:
                        if process.stdin is not None: process.stdin.close()
                        if process.poll() is None:
                            remaining = privileged[1] - time.monotonic()
                            if remaining <= 0: raise RuntimeError('privileged TLS retirement deadline exhausted')
                            process.wait(timeout=remaining)
                    record['privilegedCleanup'] = privileged_result(privileged[0])
                    if process is None: raise RuntimeError('privileged TLS launch lacks retirement proof')
                    import system_tls_privileged as helper
                    record['privilegedWrapperGroupGone'] = not helper.group_present(process.pid)
                    if not record['privilegedWrapperGroupGone']: raise RuntimeError('privileged TLS wrapper group is still live')
                elif process is not None and process.poll() is None:
                    process.kill(); process.wait(timeout=2)
                if log.exists():
                    record['logBytes'] = log.stat().st_size
                    if record['logBytes'] <= COMMAND_LOG_BYTES: record['logSHA256'] = sha(read(log, COMMAND_LOG_BYTES))
                    else: failures.append({'message': 'oversized command log; digest not read'})
            except BaseException as error: failures.append({'type': type(error).__name__, 'message': str(error)})
            if failures: record['success'] = False
            record['evidenceErrors'] = failures
            try: save(prefix.with_suffix('.json'), record)
            except BaseException as error:
                record['success'] = False; failures.append({'type': type(error).__name__, 'message': str(error)})
                print('TLS_COMMAND_RECEIPT_WRITE_FAILED', json.dumps(record), flush=True)
            if failures and primary is None: raise RuntimeError('TLS command evidence/cleanup failed')


def privileged_result(request_path):
    request_path = Path(request_path); raw = read(request_path, CERT_BYTES); request = json.loads(raw)
    result = json.loads(read(request_path.with_name(request['name'] + '-result.json'), CERT_BYTES))
    import system_tls_privileged as helper
    armed = json.loads(read(Path(request['root']) / 'ARMED.json'))
    if (result.get('requestSHA256') != sha(raw) or result.get('nonce') != request['nonce'] or
            result.get('argv') != helper.command(Path(request['root']), request['label'], armed) or
            result.get('deadline') != request['deadline'] or result.get('retirementDeadline') != request['retirementDeadline']):
        raise ValueError('privileged TLS completion belongs to another request')
    cleanup = result.get('cleanup', {})
    if cleanup.get('groupGone') is not True or cleanup.get('leaderReaped') is not True or cleanup.get('errors'):
        raise RuntimeError('privileged TLS command has no retirement proof')
    return result


def privileged_commands_gone(root):
    paths = sorted((Path(root) / 'receipts').glob('*-privileged-request.json'))
    if len(paths) > 120: raise RuntimeError('privileged TLS command inventory exceeds finite cap')
    for path in paths:
        proof = privileged_result(path)
        request = json.loads(read(path, CERT_BYTES))
        receipt = path.with_name(request['name'].removesuffix('-privileged') + '.json')
        command = json.loads(read(receipt, 4 * CERT_BYTES))
        if (command.get('privilegedRequest') != str(path) or command.get('privilegedCleanup') != proof or
                command.get('privilegedWrapperGroupGone') is not True):
            raise RuntimeError('privileged TLS wrapper has no bound retirement proof')


def mac_snapshot(root, commands, name):
    trust = {}
    for domain, key in enumerate(('user', 'admin', 'system')):
        value, raw = mac_export(domain)
        if raw is not None:
            with (root / 'receipts' / f'{name}-{key}.plist').open('xb') as output: output.write(raw)
        trust[key] = value
    certs = certificates(commands.run(name + '-certificates', [SECURITY, 'find-certificate', '-a', '-p', KEYCHAIN]))
    selection = {}
    for label, args in [('search', ['list-keychains', '-d', 'user']), ('default', ['default-keychain', '-d', 'user']), ('system-search', ['list-keychains', '-d', 'system'])]:
        selection[label] = commands.run(name + '-' + label, [SECURITY, *args]).decode().strip()
    result = {'trust': trust, 'certificates': sorted(sha(cert) for cert in certs), 'selection': selection}
    save(root / 'receipts' / (name + '.json'), result)
    return result


def bundle_metadata(path=BUNDLE):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_size > MAX_BYTES:
        raise ValueError('unreviewed Linux system bundle')
    return {'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid}


def replace_bundle(raw, metadata, nonce):
    temporary = BUNDLE.parent / ('.lattice-system-tls-' + nonce)
    with temporary.open('xb') as output:
        output.write(raw); output.flush(); os.fsync(output.fileno())
        os.fchown(output.fileno(), metadata['uid'], metadata['gid']); os.fchmod(output.fileno(), metadata['mode']); os.fsync(output.fileno())
    os.replace(temporary, BUNDLE)
    directory = os.open(BUNDLE.parent, os.O_RDONLY)
    try: os.fsync(directory)
    finally: os.close(directory)


def prepare(root, state, commands):
    if state['platform'] == 'Darwin' and not hasattr(os, 'waitid'):
        raise RuntimeError('hosted privileged TLS supervision requires Python 3.13 or newer before trust preparation')
    private = root / 'private'
    private.mkdir(mode=0o700, exist_ok=False)
    commands.run('openssl-version', ['openssl', 'version', '-a'])
    # Host-only OpenSSL generation; no global CA paths or external fetches.
    for name in ('trusted', 'unknown'):
        ca = private / (name + '-ca')
        leaf = private / (name + '-leaf')
        ca_config = private / (name + '-ca.cnf')
        ca_config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ca\nprompt=no\n[dn]\nCN=Lattice-' + state['nonce'] + '-' + name + '\n[ca]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n')
        leaf_config = private / (name + '-leaf.cnf')
        leaf_config.write_text('[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=localhost\n[server]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n')
        commands.run(name + '-ca', ['openssl', 'req', '-new', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '2', '-config', str(ca_config), '-keyout', str(ca) + '.key', '-out', str(ca) + '.pem'])
        commands.run(name + '-csr', ['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-config', str(leaf_config), '-keyout', str(leaf) + '.key', '-out', str(leaf) + '.csr'])
        commands.run(name + '-leaf', ['openssl', 'x509', '-req', '-in', str(leaf) + '.csr', '-CA', str(ca) + '.pem', '-CAkey', str(ca) + '.key', '-set_serial', str(int.from_bytes(os.urandom(16), 'big') or 1), '-days', '2', '-sha256', '-extfile', str(leaf_config), '-extensions', 'server', '-out', str(leaf) + '.pem'])
        for suffix in ('.key', '.pem'):
            read(Path(str(ca) + suffix), CERT_BYTES); read(Path(str(leaf) + suffix), CERT_BYTES)
        Path(str(ca) + '.key').chmod(0o600); Path(str(leaf) + '.key').chmod(0o600)
        for kind, path in [('ca', Path(str(ca) + '.pem')), ('leaf', Path(str(leaf) + '.pem'))]:
            (root / 'receipts' / (name + '-' + kind + '.pem')).write_bytes(read(path, CERT_BYTES))
            commands.run(name + '-' + kind + '-description', ['openssl', 'x509', '-in', str(path), '-noout', '-text', '-fingerprint', '-sha256'])
    cert = read(private / 'trusted-ca.pem', CERT_BYTES)
    der = certificates(cert)
    if len(der) != 1: raise ValueError('fixture must have one CA')
    ca_sha = sha(der[0]); ca_sha1 = hashlib.sha1(der[0]).hexdigest().upper()
    unknown = certificates(read(private / 'unknown-ca.pem', CERT_BYTES))
    if len(unknown) != 1 or sha(unknown[0]) == ca_sha: raise ValueError('independent unknown fixture CA required')
    unknown_sha = sha(unknown[0])
    config = {'nonce': state['nonce']}
    for name in ('trusted', 'unknown'):
        config[name + 'Certificate'] = str(private / (name + '-leaf.pem'))
        config[name + 'Key'] = str(private / (name + '-leaf.key'))
        pem = read(private / (name + '-leaf.pem'), CERT_BYTES); leaf_der = certificates(pem)
        if len(leaf_der) != 1: raise ValueError('fixture must have one server leaf')
        config[name + 'CertificateSHA256'] = sha(leaf_der[0])
        config[name + 'CertificatePEMSHA256'] = sha(pem)
    save(root / 'fixture.json', config)
    if state['platform'] == 'Linux':
        if os.geteuid() != 0: raise ValueError('reviewed Linux hosted container must own system bundle as root')
        metadata = bundle_metadata(); original = read(BUNDLE)
        if {ca_sha, unknown_sha} & {sha(value) for value in certificates(original)}: raise ValueError('fixture CA already installed')
        (private / 'bundle.before').write_bytes(original)
        installed = original + b'\n' + cert
        if len(installed) > MAX_BYTES: raise ValueError('installed Linux bundle bound')
        baseline = {'sha256': sha(original), 'metadata': metadata, 'installedSHA256': sha(installed)}
    else:
        commands.run('noninteractive-privilege', ['sudo', '-n', 'true'])
        baseline = mac_snapshot(root, commands, 'before')
        if {ca_sha, unknown_sha} & set(baseline['certificates']) or ca_sha1 in baseline['trust']['admin']['inventory']: raise ValueError('fixture CA already installed')
    save(root / 'receipts/CERTIFICATES.json', {'trustedCADER_SHA256': ca_sha, 'unknownCADER_SHA256': unknown_sha,
                                            'trustedLeafDER_SHA256': config['trustedCertificateSHA256'], 'unknownLeafDER_SHA256': config['unknownCertificateSHA256']})
    save(root / 'ARMED.json', {'state': state, 'baseline': baseline, 'caSHA256': ca_sha, 'caSHA1': ca_sha1,
                              'caPEMSHA256': sha(cert), 'fixtureSHA256': sha(read(root / 'fixture.json', CERT_BYTES))})


def install(root, armed, commands):
    state, baseline = armed['state'], armed['baseline']
    cert = read(root / 'private/trusted-ca.pem', CERT_BYTES)
    if sha(cert) != armed['caPEMSHA256']: raise ValueError('fixture CA changed')
    if state['platform'] == 'Linux':
        original = read(root / 'private/bundle.before')
        if sha(original) != baseline['sha256'] or sha(read(BUNDLE)) != baseline['sha256'] or bundle_metadata() != baseline['metadata']:
            raise ValueError('Linux bundle changed before install')
        replace_bundle(original + b'\n' + cert, baseline['metadata'], state['nonce'])
        if sha(read(BUNDLE)) != baseline['installedSHA256']: raise ValueError('Linux installed bytes differ')
    else:
        commands.run('install', ['sudo', '-n', SECURITY, 'add-trusted-cert', '-d', '-r', 'trustRoot', '-p', 'ssl', '-s', 'localhost', '-k', KEYCHAIN, str(root / 'private/trusted-ca.pem')])
        actual = mac_snapshot(root, commands, 'installed-state')
        expected = logical_snapshot(baseline); stripped = logical_snapshot(actual)
        if stripped['certificates'].count(armed['caSHA256']) != 1: raise ValueError('unique fixture certificate missing')
        stripped['certificates'].remove(armed['caSHA256'])
        if stripped['trust']['admin'].pop(armed['caSHA1'], None) is None: raise ValueError('fixture admin trust missing')
        if stripped != expected: raise ValueError('unrelated macOS trust state changed during install')
    save(root / 'receipts/INSTALLED.json', {'success': True, 'nonce': state['nonce']})


def cleanup(root, armed, commands):
    state, baseline = armed['state'], armed['baseline']
    if state['platform'] == 'Linux':
        actual = sha(read(BUNDLE))
        if actual not in (baseline['sha256'], baseline['installedSHA256']): raise ValueError('foreign Linux bundle drift; refusing overwrite')
        original = read(root / 'private/bundle.before')
        if sha(original) != baseline['sha256']: raise ValueError('original Linux bytes changed')
        temporary = BUNDLE.parent / ('.lattice-system-tls-' + state['nonce'])
        if temporary.exists():
            if temporary.is_symlink() or not temporary.is_file(): raise ValueError('unowned Linux temporary file')
            temporary.unlink()
        if actual != baseline['sha256']: replace_bundle(original, baseline['metadata'], state['nonce'])
        if sha(read(BUNDLE)) != baseline['sha256'] or bundle_metadata() != baseline['metadata'] or temporary.exists(): raise ValueError('Linux restoration proof failed')
        proof = {'restoration': 'exact-bundle-bytes-and-mode-uid-gid', 'sha256': baseline['sha256']}
    else:
        actual = mac_snapshot(root, commands, commands.phase + '-before')
        certificate = root / 'private/trusted-ca.pem'
        if sha(read(certificate, CERT_BYTES)) != armed['caPEMSHA256']: raise ValueError('cleanup certificate changed')
        if armed['caSHA1'] in actual['trust']['admin']['inventory']:
            commands.run('remove-trust', ['sudo', '-n', SECURITY, 'remove-trusted-cert', '-d', str(certificate)])
        if armed['caSHA256'] in actual['certificates']:
            commands.run('remove-certificate', ['sudo', '-n', SECURITY, 'delete-certificate', '-Z', armed['caSHA256'], KEYCHAIN])
        after = mac_snapshot(root, commands, commands.phase + '-after')
        if logical_snapshot(after) != logical_snapshot(baseline): raise ValueError('macOS logical trust restoration proof failed')
        proof = {'restoration': 'exact-logical-certificates-trust-and-selection', 'rawKeychainBytesRestored': False}
    result = {'success': True, 'nonce': state['nonce'], **proof}
    receipt = root / 'receipts/RESTORED.json'
    if receipt.exists():
        if json.loads(read(receipt, CERT_BYTES)) != result: raise ValueError('prior restoration receipt differs')
        receipt = root / 'receipts/RESTORED-RECHECK.json'
    save(receipt, result)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=('prepare', 'install', 'cleanup'))
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    identity = hosted(args.root)
    state = json.loads(read(args.root / 'OWNERSHIP.json', CERT_BYTES))
    if state['identity'] != identity or state['platform'] != platform.system() or not re.fullmatch('[0-9a-f]{32}', state['nonce']): raise ValueError('foreign TLS lifecycle identity')
    deadline = state['overallDeadline'] if args.phase == 'cleanup' else state['workDeadline']
    command_phase = args.phase
    if args.phase == 'cleanup':
        for attempt in (1, 2):
            marker = args.root / 'receipts' / f'CLEANUP-BEGIN-{attempt}.json'
            if not marker.exists():
                save(marker, {'nonce': state['nonce'], 'originalOverallDeadline': deadline})
                command_phase = f'cleanup-{attempt}'
                break
        else: raise ValueError('finite cleanup attempts exhausted')
    commands = Commands(args.root, command_phase, deadline)
    if args.phase == 'prepare': prepare(args.root, state, commands)
    else:
        armed = json.loads(read(args.root / 'ARMED.json'))
        if armed['state'] != state: raise ValueError('TLS armed state mismatch')
        (install if args.phase == 'install' else cleanup)(args.root, armed, commands)


if __name__ == '__main__':
    main()
