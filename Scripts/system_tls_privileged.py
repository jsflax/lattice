"""Hosted macOS only: own and retire one fixed Security command at its UID.

Importing this module performs no process, framework, certificate or trust work.
The caller owns the stdin pipe; EOF cancels work if that caller exits. The work
deadline is fixed before sudo starts. Cleanup uses only the original reserve.
"""
import argparse
import json
import os
from pathlib import Path
import pwd
import select
import signal
import stat
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import system_tls_trust as trust

PRESERVED_ENV = ('GITHUB_ACTIONS,RUNNER_ENVIRONMENT,GITHUB_RUN_ID,GITHUB_RUN_ATTEMPT,'
                 'GITHUB_JOB,GITHUB_REPOSITORY,GITHUB_SHA,DEVELOPMENT_LEG')
RETIRE_SECONDS = 4


def command(root, label, armed):
    certificate = str(root / 'private/trusted-ca.pem')
    if label == 'install':
        return [trust.SECURITY, 'add-trusted-cert', '-d', '-r', 'trustRoot', '-p', 'ssl', '-s', 'localhost', '-k', trust.KEYCHAIN, certificate]
    if label == 'remove-trust':
        return [trust.SECURITY, 'remove-trusted-cert', '-d', certificate]
    if label == 'remove-certificate':
        return [trust.SECURITY, 'delete-certificate', '-Z', armed['caSHA256'], trust.KEYCHAIN]
    raise ValueError('unreviewed privileged TLS command')


def group_present(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False


def retire(process, deadline):
    result = {'groupGone': process is None, 'leaderReaped': process is None, 'signals': [], 'errors': []}
    if process is None:
        return result
    # The Popen child creates a fresh session. Keep its leader unreaped until
    # the final group signal so its PID/PGID cannot be reassigned meanwhile.
    for number in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, number)
            result['signals'].append(int(number))
        except ProcessLookupError:
            break
        except BaseException as error:
            result['errors'].append({'type': type(error).__name__, 'message': str(error)})
            break
    try:
        remaining = deadline - time.monotonic()
        if remaining > 0:
            process.wait(timeout=remaining)
            result['leaderReaped'] = True
        while time.monotonic() < deadline:
            if not group_present(process.pid):
                result['groupGone'] = True
                break
            time.sleep(0.02)
    except BaseException as error:
        result['errors'].append({'type': type(error).__name__, 'message': str(error)})
    return result


def write_receipt(path, value, uid, gid):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump(value, output, sort_keys=True, indent=2); output.write('\n')
        output.flush(); os.fchown(output.fileno(), uid, gid); os.fsync(output.fileno())


def supervise(request_path):
    request_path = Path(request_path)
    raw = trust.read(request_path, trust.CERT_BYTES)
    request = json.loads(raw)
    root = Path(request['root'])
    uid, gid = int(os.environ['SUDO_UID']), int(os.environ['SUDO_GID'])
    if os.geteuid() != 0 or uid <= 0 or os.uname().sysname != 'Darwin':
        raise ValueError('privileged TLS helper requires the actual hosted macOS sudo caller')
    identity = trust.hosted(root, runner_home=Path(pwd.getpwuid(uid).pw_dir))
    info = request_path.lstat()
    if (request_path.parent != root / 'receipts' or request_path.resolve(strict=True) != request_path or
            info.st_uid != uid or not stat.S_ISREG(info.st_mode) or request_path.name != request['name'] + '-request.json'):
        raise ValueError('privileged TLS request ownership differs')
    state = json.loads(trust.read(root / 'OWNERSHIP.json', trust.CERT_BYTES))
    armed = json.loads(trust.read(root / 'ARMED.json'))
    if state['identity'] != identity or armed['state'] != state or request['nonce'] != state['nonce']:
        raise ValueError('privileged TLS request identity differs')
    label = request['label']
    if type(request['number']) is not int or not 1 <= request['number'] <= 40:
        raise ValueError('privileged TLS command count exceeds finite cap')
    if not ((request['phase'] == 'install' and label == 'install') or
            (request['phase'] in ('cleanup-1', 'cleanup-2') and label in ('remove-trust', 'remove-certificate'))):
        raise ValueError('privileged TLS command outside its phase')
    if request['name'] != request['phase'] + '-' + format(request['number'], '02') + '-' + label + '-privileged':
        raise ValueError('privileged TLS receipt identity differs')
    deadline, retirement = request['deadline'], request['retirementDeadline']
    original = state['workDeadline'] if label == 'install' else state['overallDeadline']
    started = time.monotonic()
    if not (started < deadline <= started + 30 and deadline < retirement <= deadline + RETIRE_SECONDS and retirement <= original):
        raise ValueError('privileged TLS deadline differs from original admission')
    if trust.sha(trust.read(root / 'private/trusted-ca.pem', trust.CERT_BYTES)) != armed['caPEMSHA256']:
        raise ValueError('privileged TLS certificate changed')
    if not hasattr(os, 'waitid'):
        raise RuntimeError('privileged TLS supervision requires nonreaping waitid')
    argv = command(root, label, armed)
    record = {'nonce': state['nonce'], 'requestSHA256': trust.sha(raw), 'argv': argv,
              'deadline': deadline, 'retirementDeadline': retirement, 'started': False,
              'success': False, 'primaryError': None, 'supervisorPID': os.getpid()}
    process = None; received = []
    def interrupted(number, _frame): received.append(number)
    previous = {number: signal.signal(number, interrupted) for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    try:
        # No arbitrary executable, shell, caller flag or environment is accepted.
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, start_new_session=True)
        record.update(started=True, pid=process.pid, ownedPGID=process.pid)
        # waitid WNOWAIT observes completion without releasing the leader PID.
        # poll()/wait() must not reap it before its group has been retired.
        while True:
            status = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if status is not None:
                if status.si_code != os.CLD_EXITED or status.si_status != 0:
                    raise RuntimeError('privileged TLS command failed')
                break
            if received or (select.select([0], [], [], 0)[0] and os.read(0, 1) == b''):
                raise RuntimeError('privileged TLS caller exited or interrupted')
            if time.monotonic() >= deadline or os.fstat(1).st_size > trust.COMMAND_LOG_BYTES:
                raise RuntimeError('privileged TLS command exceeded original time/output bound')
            time.sleep(0.02)
    except BaseException as error:
        record['primaryError'] = {'type': type(error).__name__, 'message': str(error)}
    finally:
        record['cleanup'] = retire(process, retirement)
        if process is not None: record['exitCode'] = process.returncode
        record['receivedSignals'] = received
        record['success'] = (record['started'] and record['primaryError'] is None and not received and
                             record['cleanup']['groupGone'] and record['cleanup']['leaderReaped'] and
                             not record['cleanup']['errors'] and time.monotonic() <= retirement)
        for number, handler in previous.items(): signal.signal(number, handler)
        write_receipt(root / 'receipts' / (request['name'] + '-result.json'), record, uid, gid)
    return record['success']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--request', type=Path, required=True)
    sys.exit(0 if supervise(parser.parse_args().request) else 1)
