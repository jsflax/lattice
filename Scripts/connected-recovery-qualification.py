#!/usr/bin/env python3
"""Hosted-only A + stock-TLS gate. Never run on a workstation or self-hosted runner.

Raw command output, keys and stores remain private and are not artifacts. Only
explicit, reconstructed JSON summaries enter public-evidence. This is a new
connected qualification, not the old full suite, a benchmark or release gate.
"""
import argparse
import base64
import contextlib
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import resource
import secrets
import shutil
import stat
import sys
import time

sys.dont_write_bytecode = True
SHA = re.compile(r'^[0-9a-f]{40}$')
HEX256 = re.compile(r'^[0-9a-f]{64}$')
CASE_NAMES = (
    'stockTLSAcceptsMatchingHostedCertificate',
    'stockTLSRejectsReachableWrongHostCertificate',
    'twoIndependentPublicReceiversRecoverOfflineEditsAcrossTwoChannels',
)
TLS_KEYS = {'stockOpens', 'stockErrors', 'stockTLS', 'serverListening', 'identityFailureObserved'}
A_KEYS = {'receiverCount', 'channelsPerReceiver', 'initialRowsPerReceiver',
          'finalSharedRowsPerReceiver', 'preservedSharedOriginals', 'heldCanonicalReads',
          'heldBarrierObserved', 'canonicalRoutesObserved', 'postRecoveryWriteObserved'}
SYSTEM_KEYCHAIN = '/Library/Keychains/System.keychain'
LINUX_BUNDLE = Path('/etc/ssl/certs/ca-certificates.crt')
CERT_RE = re.compile(rb'-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----', re.S)
OVERALL_SECONDS = 7800
CLEANUP_SECONDS = 300
TEST_SECONDS = 900
BUILD_SECONDS = 5400

# Exact finite schema for diagnostic-only records; never admission or a pass.
FAILURE_RECORD_KEYS = ('version',
 'name',
 'completed',
 'phase',
 'failure',
 'cleanupPhase',
 'cleanupFailure',
 'callbacks',
 'callbackOverflow',
 'facts')
FAILURE_RECORD_PHASES = ('started',
 'environmentMarkers',
 'environmentRoot',
 'environmentPrivateFiles',
 'environmentReceiptPath',
 'environmentReceiptRead',
 'environmentReceiptDecode',
 'environmentReceiptFields',
 'applicationEnvironment',
 'applicationCreate',
 'applicationTLS',
 'tlsDriver',
 'serverStartup',
 'serverAddress',
 'tlsConnect',
 'tlsTerminal',
 'tlsWrongHostOracle',
 'tlsMatchingOracle',
 'tlsClose',
 'applicationShutdown',
 'successReceipt',
 'directoryCreate',
 'sourceDirectoryCreate',
 'sourceSeed',
 'registrations',
 'relayConfigure',
 'bootstrapConnect',
 'bootstrapCatchup',
 'bootstrapContext',
 'bootstrapRetire',
 'receiverCreate',
 'receiverOpen',
 'initialRecovery',
 'receiverRetire',
 'offlineEdit',
 'recoveryReopen',
 'heldCanonicalRead',
 'heldBarrierOracle',
 'combinedRecovery',
 'postRecoveryWrite',
 'cleanup',
 'completed')
FAILURE_CLEANUP_PHASES = ('releaseHeldSend',
 'closeReceivers',
 'closeBootstrap',
 'retireAuthorization',
 'shutdownApplication',
 'waitRetirement',
 'removeHooks',
 'completed')
FAILURE_ERROR_KINDS = ('none',
 'identity',
 'tls',
 'transport',
 'protocolFailure',
 'cancelled',
 'fileSystem',
 'other',
 'environment',
 'deadline',
 'metadata',
 'receipt',
 'unexpectedOriginal',
 'invalidBounds',
 'ambiguousPolicy',
 'invalidPeer',
 'staleAuthorization',
 'administrationInProgress')
FAILURE_ERROR_DOMAINS = ('none',
 'url',
 'osStatus',
 'posix',
 'cocoa',
 'nioSSL',
 'nioSSLExtra',
 'nioWebSocket',
 'nioChannel',
 'fixture',
 'recoveryConfiguration')
FAILURE_CALLBACK_PHASES = ('trustEvaluation', 'completion', 'receive', 'send', 'connect')
FAILURE_RECORD_PREFIX = b'LATTICE_CONNECTED_FAILURE_V1 '


class GateFailure(Exception):
    """Only fixed stage/error class is published; exception text remains private."""


def require(value):
    if not value:
        raise GateFailure()


def read_file(path, limit):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= limit)
    return path.read_bytes()


def read_json(path, limit=16384):
    return json.loads(read_file(path, limit))


def write_json(path, value, *, replace=False):
    # Private state is atomically replaced; public first-result names are one-shot.
    data = (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
    temporary = path.with_name(path.name + '.new')
    with temporary.open('xb') as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    if not replace:
        require(not path.exists())
    os.replace(temporary, path)


def host_root(value):
    require(os.environ.get('GITHUB_ACTIONS') == 'true')
    require(os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted')
    require(os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch')
    require(os.environ.get('CONNECTED_WORKFLOW_SHA') == os.environ.get('GITHUB_SHA')
            and SHA.fullmatch(os.environ.get('GITHUB_SHA', '')))
    require(os.environ.get('GITHUB_REPOSITORY', '').lower() == 'jsflax/lattice')
    require(os.environ.get('LATTICE_CONNECTED_HOSTED_GATE') == '1')
    kind = platform.system()
    if kind == 'Linux':
        require(os.environ.get('LATTICE_CONNECTED_DISPOSABLE_CONTAINER') == '1')
        require(Path('/.dockerenv').is_file() and os.geteuid() == 0)
        require(os.environ.get('RUNNER_OS') == 'Linux')
    else:
        require(kind == 'Darwin' and os.environ.get('RUNNER_OS') == 'macOS')
    root = value.resolve(strict=True)
    allowed = (Path.home() / 'localdev').resolve(strict=True)
    require(root.is_relative_to(allowed) and root != allowed)
    require(root == value.absolute() and not value.is_symlink())
    require(root.name == 'connected-' + os.environ.get('GITHUB_RUN_ID', '') + '-'
            + os.environ.get('GITHUB_RUN_ATTEMPT', '') + '-' + os.environ.get('RUNNER_OS', ''))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    return root


def load_helpers(sdk):
    spec = importlib.util.spec_from_file_location('connected_guarded_runner', sdk / 'Scripts/run-development.py')
    require(spec is not None and spec.loader is not None)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def certificate_fingerprints(raw):
    require(len(raw) <= 16 * 1024 * 1024)
    found = CERT_RE.findall(raw)
    require(len(found) <= 4096)
    result = []
    for value in found:
        der = base64.b64decode(re.sub(rb'\s+', b'', value), validate=True)
        require(0 < len(der) <= 65536)
        result.append(hashlib.sha256(der).hexdigest())
    return result


def only_certificate(path):
    values = certificate_fingerprints(read_file(path, 65536))
    require(len(values) == 1)
    return values[0]


def mac_trust_snapshot():
    """Passive bounded child process; no trust mutation or private data output.

    SecTrustSettingsCopyCertificates owns its returned array. Each copied DER
    CFData and the array are released in finally. -25263 is the documented
    errSecNoTrustSettings, not a generic CLI failure interpreted as absence.
    Only the admin domain (1), modified by security -d, is inspected here.
    """
    require(platform.system() == 'Darwin' and Path(SYSTEM_KEYCHAIN).is_file())
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    pointer = ctypes.c_void_p
    security.SecTrustSettingsCopyCertificates.argtypes = [ctypes.c_uint32, ctypes.POINTER(pointer)]
    security.SecTrustSettingsCopyCertificates.restype = ctypes.c_int32
    security.SecCertificateCopyData.argtypes = [pointer]
    security.SecCertificateCopyData.restype = pointer
    cf.CFArrayGetCount.argtypes = [pointer]
    cf.CFArrayGetCount.restype = ctypes.c_long
    cf.CFArrayGetValueAtIndex.argtypes = [pointer, ctypes.c_long]
    cf.CFArrayGetValueAtIndex.restype = pointer
    cf.CFDataGetLength.argtypes = [pointer]
    cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [pointer]
    cf.CFDataGetBytePtr.restype = pointer
    cf.CFRelease.argtypes = [pointer]
    cf.CFRelease.restype = None
    def fingerprints(array):
        count = cf.CFArrayGetCount(array)
        require(0 <= count <= 4096)
        values = []
        for index in range(count):
            cert = cf.CFArrayGetValueAtIndex(array, index)
            require(cert)
            data = security.SecCertificateCopyData(cert)
            require(data)
            try:
                size = cf.CFDataGetLength(data)
                ptr = cf.CFDataGetBytePtr(data)
                require(0 < size <= 65536 and ptr)
                values.append(hashlib.sha256(ctypes.string_at(ptr, size)).hexdigest())
            finally:
                cf.CFRelease(data)
        return sorted(values)

    certificates = pointer()
    status = security.SecTrustSettingsCopyCertificates(1, ctypes.byref(certificates))
    admin = []
    try:
        if status == -25263:
            require(not certificates.value)
        else:
            require(status == 0 and certificates.value)
            admin = fingerprints(certificates)
    finally:
        if certificates.value:
            cf.CFRelease(certificates)

    # Read only the explicit System keychain; no default-search-list, unlocked
    # keychain, password, item addition or generic CLI failure-as-empty fallback.
    security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(pointer)]
    security.SecKeychainOpen.restype = ctypes.c_int32
    security.SecItemCopyMatching.argtypes = [pointer, ctypes.POINTER(pointer)]
    security.SecItemCopyMatching.restype = ctypes.c_int32
    cf.CFArrayCreate.argtypes = [pointer, ctypes.POINTER(pointer), ctypes.c_long, pointer]
    cf.CFArrayCreate.restype = pointer
    cf.CFDictionaryCreateMutable.argtypes = [pointer, ctypes.c_long, pointer, pointer]
    cf.CFDictionaryCreateMutable.restype = pointer
    cf.CFDictionarySetValue.argtypes = [pointer, pointer, pointer]
    cf.CFDictionarySetValue.restype = None
    def constant(library, name):
        value = pointer.in_dll(library, name).value
        require(value)
        return value
    def callbacks(name):
        # Address of the actual exported immutable callback structure, never a
        # Python callback or guessed C structure layout.
        return ctypes.addressof(ctypes.c_byte.in_dll(cf, name))
    keychain, matches = pointer(), pointer()
    query = search = None
    keychain_values = []
    try:
        status = security.SecKeychainOpen(SYSTEM_KEYCHAIN.encode(), ctypes.byref(keychain))
        require(status == 0 and keychain.value)
        search = cf.CFArrayCreate(None, (pointer * 1)(keychain.value), 1, callbacks('kCFTypeArrayCallBacks'))
        require(search)
        query = cf.CFDictionaryCreateMutable(None, 0, callbacks('kCFTypeDictionaryKeyCallBacks'),
                                            callbacks('kCFTypeDictionaryValueCallBacks'))
        require(query)
        for key, value in (
            ('kSecClass', constant(security, 'kSecClassCertificate')),
            ('kSecMatchSearchList', search),
            ('kSecMatchLimit', constant(security, 'kSecMatchLimitAll')),
            ('kSecReturnRef', constant(cf, 'kCFBooleanTrue')),
        ):
            cf.CFDictionarySetValue(query, constant(security, key), value)
        status = security.SecItemCopyMatching(query, ctypes.byref(matches))
        if status == -25300:  # Documented errSecItemNotFound, including empty keychain.
            require(not matches.value)
        else:
            require(status == 0 and matches.value)
            keychain_values = fingerprints(matches)
    finally:
        for value in (matches.value, query, search, keychain.value):
            if value:
                cf.CFRelease(value)
    print(json.dumps({'version': 1, 'adminSHA256': admin, 'keychainSHA256': keychain_values}))


class Commands:
    def __init__(self, helper, root, logs, env, interrupts, seconds):
        self.helper, self.root, self.logs = helper, root, logs
        self.runner = helper.GuardedRunner(root, logs, env, interrupts,
            overall_seconds=seconds, reserve=0, log_ceiling=128 * 2**20)
        self.counter = 0

    def run(self, name, argv, *, timeout=60, cwd=None, expected_failure=False, full=False):
        self.counter += 1
        label = '%03d-%s' % (self.counter, name)
        log = self.logs / (label + '.log')
        try:
            # GuardedRunner's emergency record can include argv. Keep all its
            # stdout/stderr private; publish a fixed bounded summary ourselves.
            with (self.logs / 'runner-output.log').open('a') as output:
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    self.runner.run(label, [str(x) for x in argv], cwd=cwd or self.root,
                                    timeout=timeout, require_full_timeout=full)
        except BaseException:
            if not expected_failure:
                raise
            record = read_json(self.logs / (label + '.json'), 1024 * 1024)
            require(record['started'] and type(record['exitCode']) is int and record['exitCode'] > 0
                    and record['primaryError'] is None and not record['stopReason']
                    and not record['receivedSignals'] and not record['evidenceErrors']
                    and record['cleanup']['groupGone'] and record['cleanup']['leaderReaped'])
        else:
            require(not expected_failure)
        return log

    def guarded(self, action, *args, **kwargs):
        with (self.logs / 'runner-output.log').open('a') as output:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                return action(self.runner, *args, **kwargs)


def child_environment(root):
    env = os.environ.copy()
    # Stock TLS must use actual platform roots, with no private CA override.
    require(not any(env.get(x) for x in ('SSL_CERT_FILE', 'SSL_CERT_DIR', 'DYLD_INSERT_LIBRARIES', 'LD_PRELOAD')))
    for key in ('GH_TOKEN', 'GITHUB_TOKEN'):
        env.pop(key, None)
    for key in ('TMPDIR', 'TMP', 'TEMP'):
        env[key] = str(root / 'tmp')
    env.update(CLANG_MODULE_CACHE_PATH=str(root / 'module-cache'),
               SWIFT_MODULECACHE_PATH=str(root / 'module-cache'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(root / 'module-cache'),
               XDG_CACHE_HOME=str(root / 'cache'), PYTHONDONTWRITEBYTECODE='1',
               LATTICE_TEST_LOG_PATH=str(root / 'private/native.log'),
               LATTICE_QUALIFICATION_ROOT=str(root),
               LATTICE_QUALIFICATION_LOG_DIRECTORY=str(root / 'private'),
               NO_PROXY='localhost,127.0.0.1', no_proxy='localhost,127.0.0.1')
    return env


def material(commands, root, openssl):
    tls = root / 'private/tls'
    tls.mkdir(mode=0o700)
    version = commands.run('openssl-version', [openssl, 'version']).read_text().strip()
    require(re.fullmatch(r'OpenSSL 3\.[^\n]{1,160}', version) is not None)
    tag = secrets.token_hex(16)
    ca = tls / 'ca.pem'
    commands.run('create-ca', [openssl, 'req', '-x509', '-newkey', 'rsa:3072', '-noenc', '-sha256',
        '-days', '1', '-subj', '/CN=lattice-connected-' + tag, '-keyout', tls / 'ca.key', '-out', ca,
        '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0',
        '-addext', 'keyUsage=critical,keyCertSign,cRLSign', '-addext', 'subjectKeyIdentifier=hash'])
    for name, san in (('matching', 'DNS:localhost,IP:127.0.0.1'),
                      ('wrong-host', 'DNS:lattice-wrong-host.invalid')):
        ext = tls / (name + '.cnf')
        ext.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
                       'extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
                       'subjectAltName=' + san + '\n')
        commands.run(name + '-csr', [openssl, 'req', '-new', '-newkey', 'rsa:3072', '-noenc', '-sha256',
            '-subj', '/CN=' + ('localhost' if name == 'matching' else 'lattice-wrong-host.invalid'),
            '-keyout', tls / (name + '.key'), '-out', tls / (name + '.csr')])
        commands.run(name + '-sign', [openssl, 'x509', '-req', '-in', tls / (name + '.csr'),
            '-CA', ca, '-CAkey', tls / 'ca.key', '-set_serial', str(secrets.randbits(127) + 1),
            '-days', '1', '-sha256', '-extfile', ext, '-out', tls / (name + '.pem')])
    for name in ('ca', 'matching', 'wrong-host'):
        key, cert = tls / (name + '.key'), tls / (name + '.pem')
        require(key.is_file() and not key.is_symlink() and key.stat().st_mode & 0o077 == 0)
        cert_pub = commands.run(name + '-cert-public', [openssl, 'x509', '-in', cert, '-pubkey', '-noout'])
        key_pub = commands.run(name + '-key-public', [openssl, 'pkey', '-in', key, '-pubout'])
        require(read_file(cert_pub, 16384) == read_file(key_pub, 16384))
        commands.run(name + '-validity', [openssl, 'x509', '-in', cert, '-checkend', '3600', '-noout'])
    for name in ('matching', 'wrong-host'):
        commands.run(name + '-chain', [openssl, 'verify', '-CAfile', ca, '-purpose', 'sslserver', tls / (name + '.pem')])
    commands.run('matching-ip', [openssl, 'verify', '-CAfile', ca, '-purpose', 'sslserver',
                                '-verify_ip', '127.0.0.1', tls / 'matching.pem'])
    bad = commands.run('wrong-host-ip', [openssl, 'verify', '-CAfile', ca, '-purpose', 'sslserver',
                                       '-verify_ip', '127.0.0.1', tls / 'wrong-host.pem'], expected_failure=True)
    errors = re.findall(r'error (\d+) at \d+ depth lookup: ([^\n]+)', read_file(bad, 16384).decode())
    require(errors == [('64', 'IP address mismatch')])
    sans = {}
    for name in ('matching', 'wrong-host'):
        output = commands.run(name + '-sans', [openssl, 'x509', '-in', tls / (name + '.pem'), '-noout', '-ext', 'subjectAltName'])
        lines = read_file(output, 16384).decode().strip().splitlines()
        require(len(lines) == 2 and lines[0].rstrip(' ') == 'X509v3 Subject Alternative Name:')
        sans[name] = [x.strip().replace('IP Address:', 'IP:') for x in lines[1].split(',')]
    require(sans == {'matching': ['DNS:localhost', 'IP:127.0.0.1'], 'wrong-host': ['DNS:lattice-wrong-host.invalid']})
    receipt = dict(version=1, caSHA256=only_certificate(ca), matchingSHA256=only_certificate(tls / 'matching.pem'),
        wrongHostSHA256=only_certificate(tls / 'wrong-host.pem'), matchingSANs=sans['matching'],
        wrongHostSANs=sans['wrong-host'], bothChainsVerified=True, matchingIPVerified=True,
        wrongHostIPRejected=True, keyMatches=True, validNow=True, minimumTLS='1.2')
    require(len({receipt['caSHA256'], receipt['matchingSHA256'], receipt['wrongHostSHA256']}) == 3)
    (tls / 'ca.key').unlink()  # Signing capability is unnecessary during the tests.
    write_json(root / 'receipts/tls-material.json', receipt)
    return tag, receipt, version


def trust_snapshot(commands, root):
    if platform.system() == 'Linux':
        bundle = certificate_fingerprints(read_file(LINUX_BUNDLE, 16 * 1024 * 1024))
        # Inspect every generated CA certificate, including symlinks, without
        # deleting anything based on this enumeration. Reject oversized inputs.
        entries = sorted(Path('/etc/ssl/certs').iterdir())
        require(len(entries) <= 8192)
        values = []
        for entry in entries:
            if entry.is_file() and entry.suffix in ('.pem', '.crt'):
                target = entry.resolve(strict=True)
                values.extend(certificate_fingerprints(read_file(target, 1024 * 1024)))
        return {'bundle': bundle, 'directory': values}
    settings = commands.run('admin-trust', [sys.executable, Path(__file__).resolve(), '--root', root, '--trust-snapshot'])
    state = read_json(settings, 1024 * 1024)
    require(set(state) == {'version', 'adminSHA256', 'keychainSHA256'}
            and type(state['version']) is int and state['version'] == 1)
    for key in ('adminSHA256', 'keychainSHA256'):
        require(type(state[key]) is list and len(state[key]) <= 4096
                and all(type(x) is str and HEX256.fullmatch(x) for x in state[key]))
    return {'keychain': state['keychainSHA256'], 'admin': state['adminSHA256']}


def snapshot_hashes(snapshot):
    return {name: hashlib.sha256(json.dumps(sorted(values)).encode()).hexdigest()
            for name, values in snapshot.items()}


def trust_install(commands, root, tag, receipt):
    fingerprint = receipt['caSHA256']
    before = trust_snapshot(commands, root)
    require(all(fingerprint not in values for values in before.values()))
    target = '/usr/local/share/ca-certificates/lattice-connected-' + tag + '.crt'
    if platform.system() == 'Linux':
        require(not Path(target).exists() and not Path(target).is_symlink())
    state = {'version': 1, 'platform': platform.system(), 'tag': tag, 'caSHA256': fingerprint,
             'originallyAbsent': True, 'installIntent': True, 'beforeInventory': snapshot_hashes(before)}
    # Persist recovery information before either trust mutation. Unknown command
    # settlement is resolved by exact current inspection, never by assumptions.
    write_json(root / 'private/trust-state.json', state)
    ca = root / 'private/tls/ca.pem'
    if platform.system() == 'Linux':
        # Do not interrupt our short exact-file publication between write and
        # close. A received signal is honored by the next owned command, after
        # cleanup can identify the complete fingerprint from persisted intent.
        with commands.runner.interrupts.hold():
            with Path(target).open('xb') as output:
                output.write(read_file(ca, 65536))
                output.flush()
                os.fsync(output.fileno())
            os.chmod(target, 0o644)
        commands.run('trust-install', ['update-ca-certificates'], timeout=60)
    else:
        commands.run('trust-install', ['sudo', '-n', 'security', 'add-trusted-cert', '-d', '-r', 'trustRoot',
                                     '-p', 'ssl', '-k', SYSTEM_KEYCHAIN, ca], timeout=60)
    after = trust_snapshot(commands, root)
    require(all(fingerprint in values for values in after.values()))
    return {'originallyAbsent': True, 'installedFingerprintObserved': True, 'caSHA256': fingerprint}


def cleanup_trust(commands, root):
    path = root / 'private/trust-state.json'
    result = {'trustIntentRecorded': path.exists(), 'trustAbsent': False, 'privateKeysAbsent': False}
    try:
        if path.exists():
            state = read_json(path)
            require(set(state) == {'version', 'platform', 'tag', 'caSHA256', 'originallyAbsent', 'installIntent', 'beforeInventory'})
            require(type(state['version']) is int and state['version'] == 1 and state['platform'] == platform.system()
                    and state['originallyAbsent'] is True and state['installIntent'] is True
                    and re.fullmatch('[0-9a-f]{32}', state['tag']) and HEX256.fullmatch(state['caSHA256']))
            ca = root / 'private/tls/ca.pem'
            fingerprint = only_certificate(ca)
            require(fingerprint == state['caSHA256'])
            if platform.system() == 'Linux':
                target = Path('/usr/local/share/ca-certificates/lattice-connected-' + state['tag'] + '.crt')
                if target.exists() or target.is_symlink():
                    require(not target.is_symlink() and only_certificate(target) == fingerprint)
                    target.unlink()
                # Also refresh when the owned file is already absent: a prior
                # interrupted removal can leave the generated bundle unchanged.
                commands.run('trust-remove', ['update-ca-certificates'], timeout=60)
                require(not target.exists() and not target.is_symlink())
            else:
                before = trust_snapshot(commands, root)
                errors = []
                if fingerprint in before['admin']:
                    try:
                        commands.run('trust-settings-remove', ['sudo', '-n', 'security', 'remove-trusted-cert', '-d', ca], timeout=60)
                    except BaseException as error:
                        errors.append(error)
                if fingerprint in before['keychain']:
                    try:
                        commands.run('trust-certificate-remove', ['sudo', '-n', 'security', 'delete-certificate',
                                     '-Z', fingerprint.upper(), SYSTEM_KEYCHAIN], timeout=60)
                    except BaseException as error:
                        errors.append(error)
                if errors:
                    # Preserve command failure even if a later independent
                    # cleanup pass resolves its unknown settlement.
                    raise errors[0]
            after = trust_snapshot(commands, root)
            require(all(fingerprint not in values for values in after.values()))
            require(snapshot_hashes(after) == state['beforeInventory'])
            result['caSHA256'] = fingerprint
        # With no intent file, this wrapper has not made a trust mutation.
        result['trustAbsent'] = True
    finally:
        for name in ('ca.key', 'matching.key', 'wrong-host.key'):
            key = root / 'private/tls' / name
            if key.exists() or key.is_symlink():
                require(not key.is_symlink() and key.is_file())
                key.unlink()
        result['privateKeysAbsent'] = all(not (root / 'private/tls' / x).exists()
                                        for x in ('ca.key', 'matching.key', 'wrong-host.key'))
    require(result['trustAbsent'] and result['privateKeysAbsent'])
    return result


def cleanup_fixtures(root):
    """Delete only this test's private UUID directories after process retirement.

    Ordinary source owners can outlive in-process session cleanup. No WAL,
    custody file or store is unlinked until the actual Swift process/group was
    reaped. Missing crash-time ownership evidence leaves stores untouched.
    """
    private = root / 'private'
    pattern = re.compile(r'connected-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}')
    def children(path, limit):
        result = []
        with os.scandir(path) as entries:
            for entry in entries:
                require(len(result) < limit)
                result.append(Path(entry.path))
        return result
    candidates = [x for x in children(private, 4096) if x.name.startswith('connected-')]
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


def validate_cases(root, log):
    # Swift Testing's final summary and each exact case are required in addition
    # to exit zero. XCTest's separate zero-test summary is not acceptance.
    raw = read_file(log, 128 * 1024 * 1024).decode(errors='replace')
    raw = re.sub(r'\x1b\[[0-9;]*m', '', raw)
    require(not re.search(r'(?im)^.*(?:[✘⊘]|Test .* skipped|Test run .* failed)', raw))
    passed = re.findall(r'(?m)^\s*✔ Test ([A-Za-z0-9_]+)\(\) passed after [^\n]+$', raw)
    require(sorted(passed) == sorted(CASE_NAMES))
    require(len(re.findall(r'(?m)^\s*✔ Test run with 3 tests(?: in 1 suite)? passed after [^\n]+$', raw)) == 1)
    receipt = read_json(root / 'receipts/connected-recovery-cases.json')
    require(set(receipt) == {'version', 'cases'} and type(receipt['version']) is int and receipt['version'] == 1
            and type(receipt['cases']) is list and len(receipt['cases']) == 3)
    names = []
    safe = []
    for case in receipt['cases']:
        require(set(case) == {'name', 'passed', 'scalarFacts'} and case['name'] in CASE_NAMES and case['passed'] is True)
        facts = case['scalarFacts']
        require(type(facts) is dict and set(facts) == (A_KEYS if case['name'] == CASE_NAMES[2] else TLS_KEYS))
        require(all(type(x) is bool or (type(x) is int and 0 <= x <= 1000000) for x in facts.values()))
        if case['name'] == CASE_NAMES[0]:
            require(facts == dict(stockOpens=1, stockErrors=0, stockTLS=True, serverListening=True, identityFailureObserved=False))
        elif case['name'] == CASE_NAMES[1]:
            require(facts['stockOpens'] == 0 and type(facts['stockErrors']) is int and facts['stockErrors'] >= 1
                    and facts['stockTLS'] is False and facts['serverListening'] is True and facts['identityFailureObserved'] is True)
        else:
            require(facts == dict(receiverCount=2, channelsPerReceiver=2, initialRowsPerReceiver=6,
                finalSharedRowsPerReceiver=6, preservedSharedOriginals=6, heldCanonicalReads=1,
                heldBarrierObserved=True, canonicalRoutesObserved=4, postRecoveryWriteObserved=True))
        for key, value in facts.items():
            require(type(value) is (bool if key in {'stockTLS', 'serverListening', 'identityFailureObserved', 'heldBarrierObserved',
                                                    'postRecoveryWriteObserved'} else int))
        names.append(case['name'])
        safe.append({'name': case['name'], 'passed': True, 'scalarFacts': facts})
    require(sorted(names) == sorted(CASE_NAMES))
    return {'version': 1, 'cases': safe}


# Exact reviewed literals from the fixture. Never emit arbitrary deadline/error
# text from a log; unknown text remains unclassified and the run remains failed.
FAILURE_PHASES = {
    'stock TLS terminal result': 'tls-terminal',
    'all real authorization and held-result retirement': 'cleanup-retirement',
    'real enrolled source metadata and authorized seeded catch-up': 'bootstrap-catchup',
    'bootstrap native registration retirement': 'bootstrap-retirement',
    'both fresh public receivers installed through both actual channels': 'initial-install',
    'all configured facades retired before offline edits': 'offline-retirement',
    'selected actual positive canonical manifest retained': 'held-manifest',
    'actual retained read publication': 'held-publication',
    'whole cohorts converge with original identities and local-only values': 'cohort-convergence',
    'new public write works after recovery and reaches the other receiver': 'post-write',
}


def case_outcomes(root):
    """Observation only; cannot promote an exit, timeout, skip or missing case.

    Read only the closed first test log with actual group/leader retirement
    proof. A killed wrapper lacking that proof reports unobserved, never copies
    a still-written raw log into artifacts. Max3 cases/16 locations/16 codes each.
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
            for literal in ('environment', 'metadata', 'receipt', 'unexpectedOriginal'):
                if re.search(r'Caught error: ' + literal + r'\s*$', detail):
                    code = {'environment': 'fixture-environment', 'metadata': 'fixture-metadata',
                            'receipt': 'fixture-receipt', 'unexpectedOriginal': 'original-oracle'}[literal]
                    if code not in case['failurePhaseCodes'] and len(case['failurePhaseCodes']) < 16:
                        case['failurePhaseCodes'].append(code)
    return result



def validate_failure_record(value):
    require(type(value) is dict and set(value) == set(FAILURE_RECORD_KEYS))
    require(type(value['version']) is int and value['version'] == 1)
    require(type(value['name']) is str and value['name'] in CASE_NAMES)
    require(type(value['phase']) is str and value['phase'] in FAILURE_RECORD_PHASES)
    require(type(value['completed']) is bool and type(value['callbackOverflow']) is bool)
    require(value['cleanupPhase'] is None or
            (type(value['cleanupPhase']) is str and value['cleanupPhase'] in FAILURE_CLEANUP_PHASES))

    def error_fact(error):
        require(type(error) is dict and set(error) == {'kind', 'domain', 'code'})
        require(type(error['kind']) is str and error['kind'] in FAILURE_ERROR_KINDS)
        require(type(error['domain']) is str and error['domain'] in FAILURE_ERROR_DOMAINS)
        code = error['code']
        require(code is None or (type(code) is int and -(2**31) <= code < 2**31))
        if code is not None:
            require(error['domain'] in ('url', 'osStatus', 'posix', 'cocoa', 'nioWebSocket'))
        return {'kind': error['kind'], 'domain': error['domain'], 'code': code}

    copied = {key: value[key] for key in ('version', 'name', 'completed', 'phase', 'cleanupPhase', 'callbackOverflow')}
    for key in ('failure', 'cleanupFailure'):
        copied[key] = None if value[key] is None else error_fact(value[key])
    require(type(value['callbacks']) is list and len(value['callbacks']) <= 8)
    copied['callbacks'] = []
    for callback in value['callbacks']:
        require(type(callback) is dict and set(callback) == {'phase', 'error', 'trustAccepted'})
        require(type(callback['phase']) is str and callback['phase'] in FAILURE_CALLBACK_PHASES)
        require(callback['trustAccepted'] is None or type(callback['trustAccepted']) is bool)
        require(callback['phase'] == 'trustEvaluation' or callback['trustAccepted'] is None)
        copied['callbacks'].append({'phase': callback['phase'], 'error': error_fact(callback['error']),
                                    'trustAccepted': callback['trustAccepted']})
    facts = value['facts']
    require(type(facts) is dict and set(facts) <= {
        'opens', 'errors', 'systemTLS', 'identityFailure', 'listenerPublished', 'mounts', 'bootstrapPeers', 'receivers'})
    copied['facts'] = {}
    for key, fact in facts.items():
        if key in ('systemTLS', 'identityFailure', 'listenerPublished'):
            require(type(fact) is bool)
        else:
            require(type(fact) is int and 0 <= fact <= (1000000 if key in ('opens', 'errors') else 2))
        copied['facts'][key] = fact
    return copied


def parse_failure_records(raw):
    """Pure bounded extraction. Partial observations remain partial, never passes."""
    require(type(raw) is bytes and len(raw) <= 128 * 1024 * 1024)

    def unique_members(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result)
            result[key] = value
        return result

    def no_constant(_):
        raise GateFailure()

    records = {}
    total = 0
    for line in raw.splitlines():
        if not line.startswith(FAILURE_RECORD_PREFIX):
            continue
        require(len(line) <= 4096 and len(records) < 3)
        total += len(line)
        require(total <= 16384)
        value = json.loads(line[len(FAILURE_RECORD_PREFIX):].decode('utf-8'),
                           object_pairs_hook=unique_members, parse_constant=no_constant)
        copied = validate_failure_record(value)
        require(copied['name'] not in records)
        records[copied['name']] = copied
    return [records[name] for name in CASE_NAMES if name in records]


def failure_evidence(root):
    # Match the existing first-log custody boundary. No inspection of a live
    # test process, private raw text export, or inferred successful outcome.
    result = {'version': 1, 'evidenceOnly': True, 'observation': 'not-started',
              'complete': False, 'records': [], 'missingCases': list(CASE_NAMES),
              'processExitCode': None, 'processRetired': False}
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
    raw = read_file(logs[0], 128 * 1024 * 1024)
    result['testLogSHA256'] = hashlib.sha256(raw).hexdigest()
    result['observation'] = 'closed-first-log'
    result['records'] = parse_failure_records(raw)
    found = {value['name'] for value in result['records']}
    result['missingCases'] = [name for name in CASE_NAMES if name not in found]
    result['complete'] = not result['missingCases']
    return result


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
    result['stage'] = 'tls-material'
    tag, tls, version = material(commands, root, openssl)
    result['opensslVersion'] = version
    result['stage'] = 'trust-install'
    result['trustInstall'] = trust_install(commands, root, tag, tls)
    env = commands.runner.env
    env.update(LATTICE_CONNECTED_RECOVERY_GATE='1', LATTICE_CONNECTED_RECOVERY_RUN_DIR=str(root),
               LATTICE_CONNECTED_RECOVERY_CA_CERT=str(root / 'private/tls/ca.pem'),
               LATTICE_CONNECTED_RECOVERY_TLS_CERT=str(root / 'private/tls/matching.pem'),
               LATTICE_CONNECTED_RECOVERY_TLS_KEY=str(root / 'private/tls/matching.key'),
               LATTICE_CONNECTED_RECOVERY_WRONG_HOST_CERT=str(root / 'private/tls/wrong-host.pem'),
               LATTICE_CONNECTED_RECOVERY_WRONG_HOST_KEY=str(root / 'private/tls/wrong-host.key'),
               LATTICE_CONNECTED_RECOVERY_TLS_RECEIPT=str(root / 'receipts/tls-material.json'))
    result['stage'] = 'connected-tests'
    test = commands.run('connected-tests', ['swift', 'test', *common, '--force-resolved-versions', '--skip-build',
                                            '--filter', 'PublicConnectedAutomaticRecoveryTests'],
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
    write_json(root / 'public-evidence/connected-recovery-cases.json', cases)
    write_json(root / 'public-evidence/source-bindings.json', {
        'version': 1, 'sdkCommit': sdk_sha, 'sdkTree': initial_sdk['tree'], 'coreCommit': core_sha, 'coreTree': core_tree,
        'trackedSDKFiles': initial_sdk['files'], 'trackedCoreFiles': initial_core['files'],
        'resolvedPins': original, 'effectiveRevisions': {x['identity']: x['revision'] for x in before},
        'compilerInputs': {str(Path(k).relative_to(core)): v for k, v in compiler['sourceFiles'].items()},
        'compilerInputProofSHA256': hashlib.sha256(json.dumps(compiler, sort_keys=True).encode()).hexdigest(),
        'testLogSHA256': helper.digest(test), 'testLogBytes': test.stat().st_size,
        'allOtherSourceAndPinsPreserved': True})
    result['threeCasesPassed'] = True


def public_commands(logs):
    paths = sorted(logs.glob('*.json'))
    require(len(paths) <= 1024)
    result = []
    for path in paths:
        value = read_json(path, 1024 * 1024)
        if type(value) is not dict or 'argv' not in value:
            continue
        require(re.fullmatch('[a-z0-9-]{1,96}', path.stem))
        row = {'label': path.stem}
        for key in ('started', 'success'):
            require(type(value[key]) is bool)
            row[key] = value[key]
        require(value['exitCode'] is None or type(value['exitCode']) is int)
        row['exitCode'] = value['exitCode']
        for key in ('elapsedSeconds', 'timeoutSeconds'):
            require(type(value[key]) in (int, float) and 0 <= value[key] <= OVERALL_SECONDS + 60)
            row[key] = value[key]
        for key in ('groupGone', 'leaderReaped'):
            require(type(value['cleanup'][key]) is bool)
            row[key] = value['cleanup'][key]
        if 'logSHA256' in value:
            require(HEX256.fullmatch(value['logSHA256']) and type(value['logBytes']) is int)
            row.update(logSHA256=value['logSHA256'], logBytes=value['logBytes'])
        if value['primaryError'] is not None:
            kind = value['primaryError']['type']
            require(type(kind) is str and re.fullmatch('[A-Za-z_]{1,64}', kind))
            row['errorClass'] = kind
        result.append(row)
    return {'version': 1, 'commands': result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--core-sha')
    parser.add_argument('--core-tree')
    parser.add_argument('--openssl', type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--cleanup-only', action='store_true')
    modes.add_argument('--trust-snapshot', action='store_true')
    args = parser.parse_args()
    root = host_root(args.root)
    if args.trust_snapshot:
        mac_trust_snapshot()
        return 0
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
        if not (root / 'public-evidence/connected-recovery-failures.json').exists():
            try:
                write_json(root / 'public-evidence/connected-recovery-failures.json', failure_evidence(root))
            except BaseException as error:
                result['failureEvidenceErrorClass'] = type(error).__name__
                result['success'] = False
        try:
            write_json(root / 'public-evidence/cleanup-always-commands.json', public_commands(logs))
        except BaseException as error:
            result['cleanupCommandEvidenceErrorClass'] = type(error).__name__
            result['success'] = False
        write_json(root / 'public-evidence/always-cleanup.json', result)
        print('connected gate always-cleanup success', result['success'], flush=True)
        return 0 if result['success'] else 1
    require(SHA.fullmatch(os.environ.get('GITHUB_SHA', '')) and SHA.fullmatch(args.core_sha or '')
            and SHA.fullmatch(args.core_tree or '') and args.openssl is not None)
    require(args.openssl.is_absolute() and args.openssl.is_file())
    for name in ('private', 'receipts', 'public-evidence', 'module-cache', 'cache', 'config', 'security', 'scratch'):
        (root / name).mkdir(mode=0o700, exist_ok=False)
    (root / 'tmp').mkdir(mode=0o700, exist_ok=True)
    logs = root / 'private/commands'
    logs.mkdir(mode=0o700)
    result = {'version': 1, 'scope': 'A plus stock TLS only', 'sdkCommit': os.environ['GITHUB_SHA'],
              'coreCommit': args.core_sha, 'coreTree': args.core_tree, 'platform': platform.system(),
              'integrationTimeoutSeconds': TEST_SECONDS, 'buildTimeoutSeconds': BUILD_SECONDS,
              'overallSeconds': OVERALL_SECONDS, 'cleanupReserveSeconds': CLEANUP_SECONDS,
              'success': False, 'threeCasesPassed': False, 'stage': 'initialization',
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
                result['success'] = (result['threeCasesPassed'] and not result.get('errorClass')
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
                    failures = failure_evidence(root)
                    write_json(root / 'public-evidence/connected-recovery-failures.json', failures)
                    result['diagnosticEvidenceComplete'] = failures['complete']
                    if not failures['complete']:
                        result['success'] = False
                except BaseException as error:
                    result['failureEvidenceErrorClass'] = type(error).__name__
                    result['success'] = False
                try:
                    write_json(root / 'public-evidence/cleanup-final-commands.json', public_commands(cleanup_logs))
                except BaseException as error:
                    result['cleanupCommandEvidenceErrorClass'] = type(error).__name__
                    result['success'] = False
                write_json(root / 'public-evidence/result.json', result)
    print('connected gate success', result['success'], 'stage', result['stage'], flush=True)
    return 0 if result['success'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as failure:
        # No exception text or traceback containing secret paths/configuration.
        print('connected gate inconclusive', type(failure).__name__, flush=True)
        sys.exit(1)
