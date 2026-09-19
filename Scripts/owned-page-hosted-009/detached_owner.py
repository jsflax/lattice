"""One detached SDK007 owner; no scheduler, respawn, or arbitrary command API."""
import argparse
import json
import hashlib
import os
from pathlib import Path
import resource
import signal
import sys
import time
import uuid

import process_custody as custody

P = Path(__file__).resolve().parent


def exclusive(path, value):
    temporary=path.with_name(path.name+'.writing')
    with temporary.open('x') as output:
        json.dump(value, output, sort_keys=True, indent=2)
        output.write('\n'); output.flush(); os.fsync(output.fileno())
    os.link(temporary,path)  # Atomic complete publication, refusing an existing destination.
    temporary.unlink()


def launch(directory, body, description, *, overall_seconds):
    """Return after durable detached-owner acknowledgement; never retry ambiguity."""
    directory.mkdir()  # Exclusive one-shot intent; not the fresh qualifier runtime.
    nonce = str(uuid.uuid4())
    started = time.monotonic()
    exclusive(directory / 'INTENT.json', {'nonce': nonce, 'description': description,
              'startedMonotonic': started, 'overallDeadline': started + overall_seconds})
    child = os.fork()
    if child == 0:
        try:
            os.setsid()
            second = os.fork()
            if second:
                os._exit(0)
            incoming = os.open('/dev/null', os.O_RDONLY)
            outgoing = os.open(directory / 'owner.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.dup2(incoming, 0); os.dup2(outgoing, 1); os.dup2(outgoing, 2)
            os.closerange(3, resource.getrlimit(resource.RLIMIT_NOFILE)[0])
            # Unbuffered text survives a terminal exception after tool detachment.
            sys.stdout = os.fdopen(os.dup(1), 'w', buffering=1)
            sys.stderr = os.fdopen(os.dup(2), 'w', buffering=1)
            os.environ['SDK007_OWNER_DIRECTORY'] = str(directory)
            owner = {'nonce': nonce, 'identity': custody.identity(os.getpid()),
                     'description': description, 'executable': str(Path(sys.executable).resolve()),
                     'argv': list(sys.argv), 'startedMonotonic': started,
                     'overallDeadline': started + overall_seconds}
            exclusive(directory / 'OWNER.json', owner)
            code, error = 1, None
            try:
                code = body()
            except BaseException as caught:
                error = {'type': type(caught).__name__, 'message': str(caught)}
            result_path = Path(description['runtimeRoot']) / 'receipts/RESULT.json'
            result_hash = None
            if result_path.exists():
                if result_path.is_symlink() or not result_path.is_file():
                    raise RuntimeError('terminal result is not an owned regular file')
                digest = hashlib.sha256()
                with result_path.open('rb') as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b''):
                        digest.update(chunk)
                result_hash = digest.hexdigest()
            exclusive(directory / 'TERMINAL.json', {'nonce': nonce,
                      'resultPath': str(result_path), 'resultSHA256': result_hash,
                      'identity': owner['identity'], 'exitCode': code, 'error': error,
                      'completedMonotonic': time.monotonic()})
            os._exit(code if isinstance(code, int) and 0 <= code <= 255 else 1)
        except BaseException as caught:
            try:
                exclusive(directory / 'LAUNCH-FAILURE.json', {
                    'type': type(caught).__name__, 'message': str(caught)})
            finally:
                os._exit(1)
    status = None
    until = min(started + 5, started + overall_seconds)
    while time.monotonic() < until:
        reaped, observed = os.waitpid(child, os.WNOHANG)
        if reaped:
            status = observed
            break
        time.sleep(0.05)
    if status is None:
        raise RuntimeError('detachment wait uncertain; no relaunch allowed')
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise RuntimeError('detachment child failed; no relaunch allowed')
    until = min(started + 5, started + overall_seconds)
    while time.monotonic() < until:
        if (directory / 'OWNER.json').exists():
            owner = json.loads((directory / 'OWNER.json').read_text())
            current = custody.identity(owner['identity']['pid'])
            if owner['nonce'] != nonce or not custody.same(current, owner['identity']):
                raise RuntimeError('detached owner identity unverified; no relaunch allowed')
            return owner
        if (directory / 'LAUNCH-FAILURE.json').exists():
            raise RuntimeError('detached owner failed; no relaunch allowed')
        time.sleep(0.05)
    raise RuntimeError('owner acknowledgement uncertain; no relaunch allowed')


class Control:
    def __init__(self):
        value = os.environ.get('SDK007_OWNER_DIRECTORY')
        self.directory = Path(value) if value else None
        self.owner = json.loads((self.directory / 'OWNER.json').read_text()) if value else None
        self.last = 0
        if self.owner and not custody.same(self.owner['identity'], custody.identity(os.getpid())):
            raise RuntimeError('detached owner context does not match current process')

    def check(self, phase):
        if not self.directory:
            return
        stop = self.directory / 'STOP.json'
        if stop.exists():
            if stop.is_symlink() or stop.stat().st_size > 4096:
                raise RuntimeError('invalid stop control')
            value = json.loads(stop.read_text())
            if value != {'nonce': self.owner['nonce'], 'identity': self.owner['identity']}:
                raise RuntimeError('stop control identity mismatch')
            raise RuntimeError('authorized owner stop requested')
        now = time.monotonic()
        if now > self.owner['overallDeadline']:
            raise RuntimeError('detached owner absolute deadline')
        if now - self.last >= 2:
            temporary = self.directory / 'STATUS.next'
            with temporary.open('w') as output:
                json.dump({'nonce': self.owner['nonce'], 'identity': self.owner['identity'],
                           'phase': phase, 'monotonic': now}, output)
                output.flush(); os.fsync(output.fileno())
            temporary.replace(self.directory / 'STATUS.json')
            self.last = now


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reviewed-sdk-owned-page-qualification', required=True, action='store_true')
    parser.add_argument('--source-ready-sha256', required=True)
    args = parser.parse_args()
    import qualify
    config = qualify.source_packet(args.source_ready_sha256, no_runtime=True, prelaunch=True)
    root = Path(config['runtimeRoot'])
    directory = root.with_name(root.name + '-owner')
    def body():
        sys.argv = [str(P / 'qualify.py'), '--reviewed-sdk-owned-page-qualification',
                    '--source-ready-sha256', args.source_ready_sha256]
        return qualify.main()
    owner = launch(directory, body, {'sourceReadySHA256': args.source_ready_sha256,
                   'runtimeRoot': str(root), 'qualifier': str(P / 'qualify.py')},
                   overall_seconds=config['proposedLimits']['overallSeconds'])
    print(json.dumps({'owner': owner, 'directory': str(directory), 'nativeQualificationAccepted': False}))


if __name__ == '__main__':
    main()
