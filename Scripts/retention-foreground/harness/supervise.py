#!/usr/bin/env python3
"""One owned fresh sample. Must run inside the reviewed outer GuardedRunner PG."""
import argparse, hashlib, json, os, selectors, shutil, subprocess, time
from pathlib import Path

def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()

def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')

def bundle(path):
    result = {}
    for suffix in ['', '-wal', '-shm']:
        file = Path(str(path)+suffix)
        result[suffix or 'main'] = ({'bytes':file.stat().st_size, 'sha256':digest(file)}
                                  if file.exists() else None)
    return result

def run(args):
    started = time.monotonic(); deadline = started + 115
    sample = Path(args.sample).resolve(); master = Path(args.master).resolve()
    probe = Path(args.probe).resolve(); receipt = Path(args.receipt).resolve()
    assert not sample.exists() and not receipt.exists()
    assert master.is_file() and probe.is_file()
    master_files = bundle(master)
    for suffix in ['-wal', '-shm']:
        sidecar = Path(str(master) + suffix)
        if suffix == '-wal': assert not sidecar.exists() or sidecar.stat().st_size == 0
    sample.mkdir(); database = sample / 'sample.sqlite'; shutil.copyfile(master, database)
    children = {}; buffers = {}; events = []; sampler = []; exits = {}; selector = selectors.DefaultSelector()
    total_output = 0; phase = 'initial'; success = False; last_sample = 0; error = None
    def spawn(name, role, arm=None):
        assert name not in children
        argv = [str(probe), role, str(database)] + ([arm] if arm else [])
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=False)
        children[name] = process; buffers[name] = b''
        selector.register(process.stdout, selectors.EVENT_READ, name)
        events.append({'supervisorNS': time.monotonic_ns(), 'kind': 'spawn', 'role': name, 'pid': process.pid, 'argv': argv})
    def signal(name):
        process = children[name]; assert process.poll() is None
        process.stdin.write(b'G'); process.stdin.flush()
    def has(name, kind): return any(x.get('role') == name and x.get('kind') == kind for x in events)
    def ended(name): return name in exits
    def receive(name, value):
        assert isinstance(value, dict) and 'kind' in value
        if value['kind'] == 'failure': raise RuntimeError(f'{name}: {value}')
        value = {**value, 'role': name, 'supervisorNS': time.monotonic_ns()}; events.append(value)
        if name == 'writer' and value['kind'] == 'ready': signal('writer')
        if name == 'writer' and value['kind'] == 'writerPaused': signal('maintenance')
        if name == 'maintenance' and value['kind'] == 'tickEntering' and args.mode != 'claim': signal('writer')
    try:
        if args.mode == 'claim':
            spawn('claim1', 'claim', 'B'); spawn('claim2', 'claim', 'B')
        else:
            spawn('maintenance', 'maintenance', args.arm)
            if args.mode == 'held-reader': spawn('reader', 'reader')
        while True:
            now = time.monotonic()
            if now >= deadline: raise TimeoutError('sample driver115s deadline (outer120s unchanged)')
            if now - last_sample >= .005:
                sizes = {}
                for suffix in ['', '-wal', '-shm']:
                    path = Path(str(database) + suffix)
                    try: sizes[suffix or 'main'] = path.stat().st_size
                    except FileNotFoundError: sizes[suffix or 'main'] = None
                sampler.append({'supervisorNS': time.monotonic_ns(), 'phase':phase, 'bytes': sizes}); last_sample = now
            for key, _ in selector.select(.005):
                name = key.data; chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    if buffers[name]: raise RuntimeError('unterminated child output')
                    continue
                total_output += len(chunk)
                if total_output > 32 * 2**20: raise RuntimeError('child output cap')
                buffers[name] += chunk
                if len(buffers[name]) > 2**20: raise RuntimeError('single child line exceeds1MiB')
                while b'\n' in buffers[name]:
                    raw, buffers[name] = buffers[name].split(b'\n', 1)
                    receive(name, json.loads(raw))
            # Do not consider a child complete until all of its pipe bytes have
            # been drained; an exit notification can precede the final receipt.
            registered = {key.data for key in selector.get_map().values()}
            for name, process in children.items():
                code = process.poll()
                if code is not None and name not in registered and name not in exits:
                    exits[name] = process.wait()
                    if code != 0: raise RuntimeError(f'{name} exited{code}')
            if args.mode == 'claim':
                if phase == 'initial' and has('claim1','ready') and has('claim2','ready'):
                    signal('claim1'); signal('claim2'); phase = 'claims-entering'
                if phase == 'claims-entering' and has('claim1','claimBarrier') and has('claim2','claimBarrier'):
                    signal('claim1'); signal('claim2'); phase = 'work'
                if phase == 'work' and ended('claim1') and ended('claim2'):
                    ticks = [x for x in events if x['kind'] == 'tickDone']
                    assert len(ticks) == 2 and sum(x['claims'] for x in ticks) == 2 and sum(x['prunes'] for x in ticks) == 1
                    spawn('validate', 'validate-claim', 'B'); phase = 'validating'
            else:
                if phase == 'initial' and has('maintenance','ready') and (args.mode != 'held-reader' or has('reader','readerPinned')):
                    spawn('writer', 'writer'); phase = 'work'
                if phase == 'work' and ended('writer') and ended('maintenance'):
                    writes = [x for x in events if x['kind'] == 'write']
                    ticks = [x for x in events if x['kind'] == 'tickDone']
                    assert len(writes) == 1000 and [x['index'] for x in writes] == list(range(1000)) and len(ticks) == 1
                    assert all(x['endNS'] >= x['startNS'] for x in writes)
                    tick = ticks[0]
                    overlaps = sum(x['startNS'] < tick['endNS'] and x['endNS'] > tick['startNS'] for x in writes)
                    if args.arm == 'B' and overlaps == 0: raise RuntimeError('no observed B writer/tick overlap; nonqualifying, no retry')
                    events.append({'kind':'overlap','writes':overlaps})
                    spawn('validate', 'validate', args.arm); phase = 'validating'
            if phase == 'validating' and ended('validate'):
                assert has('validate','validated')
                spawn('checkpoint-before-release', 'checkpoint'); phase = 'checkpointing'
            if phase == 'checkpointing' and ended('checkpoint-before-release'):
                results = [x['result'] for x in events if x.get('role') == 'checkpoint-before-release' and x['kind'] == 'checkpoint']
                assert len(results) == 1
                if args.mode == 'held-reader':
                    assert results[0]['busy'] != 0, 'held snapshot unexpectedly allowed complete truncate'
                    signal('reader'); phase = 'releasing'
                else:
                    assert results[0]['rc'] == 0 and results[0]['busy'] == 0
                    phase = 'done'
            if phase == 'releasing' and ended('reader'):
                assert has('reader','readerReleased')
                spawn('checkpoint-after-release', 'checkpoint'); phase = 'post-checkpoint'
            if phase == 'post-checkpoint' and ended('checkpoint-after-release'):
                result = [x['result'] for x in events if x.get('role') == 'checkpoint-after-release' and x['kind'] == 'checkpoint']
                assert len(result) == 1 and result[0]['rc'] == 0 and result[0]['busy'] == 0
                phase = 'done'
            if phase == 'done':
                assert all(process.poll() == 0 for process in children.values())
                assert bundle(master) == master_files
                success = True; break
    except BaseException as caught:
        error = {'type': type(caught).__name__, 'message': str(caught)}
        raise
    finally:
        # Children share this supervisor's guarded process group. Local direct
        # child cleanup reduces residual work; outer GuardedRunner independently
        # proves group absence, including interruption at any point here.
        cleanup = {}; cleanup_errors = []
        for name, process in children.items():
            try:
                if process.poll() is None: process.terminate()
            except ProcessLookupError: pass
            except BaseException as caught: cleanup_errors.append(str(caught))
        grace = time.monotonic() + 2
        for name, process in children.items():
            try:
                try: process.wait(timeout=max(.001, grace-time.monotonic()))
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=2)
                cleanup[name] = {'pid':process.pid, 'exitCode':process.returncode, 'reaped':True}
                process.stdin.close(); process.stdout.close()
            except BaseException as caught:
                cleanup_errors.append(str(caught))
                cleanup[name] = {'pid':process.pid, 'exitCode':process.poll(), 'reaped':False}
        selector.close()
        success = success and not cleanup_errors and all(x['reaped'] and x['exitCode']==0 for x in cleanup.values())
        files = {}
        try:
            files = {x.name:{'bytes':x.stat().st_size,'sha256':digest(x)} for x in sample.iterdir() if x.is_file()}
        except BaseException as caught:
            cleanup_errors.append('closed-file-evidence: '+str(caught))
        success = success and not cleanup_errors
        result = {'success':success,'error':error,'mode':args.mode,'arm':args.arm,
             'masterFiles':master_files,'events':events,'fileSizeSamples':sampler,'closedSampleFiles':files,
             'cleanup':cleanup,'cleanupErrors':cleanup_errors,'elapsedSeconds':time.monotonic()-started,
             'claim':'same-source behavior characterization;5ms WAL maxima are sampled lower bounds'}
        try:
            save(receipt, result)
        except BaseException as caught:
            success = False
            cleanup_errors.append('receipt-write: '+str(caught))
            result['success'] = False
            print('SAMPLE_RECEIPT_WRITE_FAILED '+json.dumps(result,sort_keys=True),flush=True)
        # Do not mask an original test/runtime failure with a secondary evidence
        # failure. New cleanup failures still fail an otherwise passing sample.
        if cleanup_errors and error is None:
            raise RuntimeError('sample finalization failed: '+repr(cleanup_errors))

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    for key in ['probe','master','sample','receipt']: parser.add_argument('--'+key,required=True)
    parser.add_argument('--mode',choices=['paired','held-reader','claim'],required=True)
    parser.add_argument('--arm',choices=['A1','A2','B'],required=True)
    run(parser.parse_args())
