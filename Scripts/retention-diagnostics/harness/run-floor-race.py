#!/usr/bin/env python3
"""Four owned floor-race cases; run only under the reviewed outer 120s guard.

Diagnostic completion and reproduction are distinct from product acceptance.
A reproduced baseline safety failure deliberately exits 1 after all four cases.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import time

# This is the same reviewed helper copied by the hosting phase packet.
from guarded_runner import Interrupts, RunnerInterrupted

CORE = '7b11c282800d2bd6478538edb4e87de81953d315'
TREE = '18b482a47df9413e151887ef77a9dc5abb6be041'
FREE_FLOOR = int(12.5 * 2**30)
OUTPUT_CAP = 2**20
CASE_NAMES = [(a, b) for a in ('age', 'compact') for b in ('register', 'reset')]


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, data):
    with path.open('x') as stream:
        json.dump(data, stream, indent=2, sort_keys=True)
        stream.write('\n')


def fail(message):
    raise RuntimeError(message)


def check(condition, message):
    if not condition:
        fail(message)


def facts(path):
    return {'bytes': path.stat().st_size, 'sha256': digest(path)}


class Children:
    """Children inherit this supervisor's outer-owned process group.

    We only signal still-unreaped Popen-owned direct children here. The outer
    guard owns and proves absence of the entire group, including descendants.
    """
    def __init__(self, root, probe, interrupts, deadline):
        self.root, self.probe, self.interrupts, self.deadline = root, probe, interrupts, deadline
        self.selector = selectors.DefaultSelector()
        self.processes, self.buffers, self.logs, self.events = {}, {}, {}, []
        self.output_bytes = 0
        self.cleanup = {}

    def spawn(self, name, role, database, variant):
        check(name not in self.processes, 'duplicate role name')
        argv = [str(self.probe), role, str(database), variant]
        log = (self.root / (name + '.log')).open('xb')
        self.logs[name] = log
        # Deferral spans creation AND ownership publication: TERM/INT cannot
        # leave a successfully spawned child unrecorded after Popen returns.
        with self.interrupts.hold():
            process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=False)
            self.processes[name] = process
            self.buffers[name] = b''
            self.selector.register(process.stdout, selectors.EVENT_READ, name)
            self.events.append({'kind': 'spawn', 'role': name, 'pid': process.pid,
                                'argv': argv, 'supervisorNS': time.monotonic_ns()})
        if self.interrupts.received:
            raise RunnerInterrupted(self.interrupts.received[-1])

    def records(self, name, kind):
        return [e['value'] for e in self.events
                if e['kind'] == 'child' and e['role'] == name and e['value']['kind'] == kind]

    def one(self, name, kind):
        found = self.records(name, kind)
        check(len(found) == 1, 'missing/duplicate ' + name + ':' + kind)
        return found[0]

    def pump_until(self, predicate, description):
        stage_deadline = min(self.deadline, time.monotonic() + 10)
        while not predicate():
            remaining = stage_deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(description + ' (10s stage/100s overall)')
            check(shutil.disk_usage(self.root).free >= FREE_FLOOR, 'disk floor')
            for key, _ in self.selector.select(min(remaining, 0.25)):
                name = key.data
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    self.selector.unregister(key.fileobj)
                    check(not self.buffers[name], 'unterminated output line')
                    continue
                self.output_bytes += len(data)
                check(self.output_bytes <= OUTPUT_CAP, '1MiB aggregate output cap')
                self.logs[name].write(data); self.logs[name].flush()
                self.buffers[name] += data
                check(len(self.buffers[name]) <= 65536, '64KiB line cap')
                while b'\n' in self.buffers[name]:
                    line, self.buffers[name] = self.buffers[name].split(b'\n', 1)
                    value = json.loads(line)
                    check(isinstance(value, dict) and isinstance(value.get('kind'), str), 'invalid event')
                    self.events.append({'kind': 'child', 'role': name, 'value': value,
                                        'supervisorNS': time.monotonic_ns()})
                    check(value['kind'] not in ('failure', 'barrierPremiseFailed'), 'child failure: ' + name)
            for name, process in self.processes.items():
                code = process.poll()
                check(code in (None, 0), 'child exit ' + name + ':' + str(code))

    def finished(self, name):
        registered = {entry.data for entry in self.selector.get_map().values()}
        return self.processes[name].poll() is not None and name not in registered

    def wait_finished(self, name):
        self.pump_until(lambda: self.finished(name), 'finish ' + name)
        check(self.processes[name].wait(timeout=0) == 0, 'nonzero child ' + name)

    def release(self, name):
        process = self.processes[name]
        check(process.poll() is None, 'pruner exited before release')
        self.events.append({'kind': 'release', 'role': name, 'supervisorNS': time.monotonic_ns()})
        process.stdin.write(b'G'); process.stdin.flush()
        process.stdin.close()

    def close(self):
        errors = []
        with self.interrupts.hold():
            for name, process in self.processes.items():
                entry = {'signals': [], 'errors': [], 'reaped': False, 'exitCode': None}
                for number in (signal.SIGTERM, signal.SIGKILL):
                    if process.poll() is not None:
                        break
                    try:
                        process.send_signal(number); entry['signals'].append(signal.Signals(number).name)
                    except ProcessLookupError:
                        pass
                    except BaseException as error:
                        entry['errors'].append(repr(error))
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        pass
                    except BaseException as error:
                        entry['errors'].append(repr(error))
                try:
                    entry['exitCode'] = process.wait(timeout=0)
                    entry['reaped'] = True
                except BaseException as error:
                    entry['errors'].append(repr(error))
                for pipe in (process.stdin, process.stdout):
                    try:
                        if pipe is not None:
                            pipe.close()
                    except BaseException as error:
                        entry['errors'].append(repr(error))
                self.cleanup[name] = entry
                if not entry['reaped'] or entry['errors']:
                    errors.append({'role': name, **entry})
            self.selector.close()
            for log in self.logs.values():
                try:
                    log.close()
                except BaseException as error:
                    errors.append({'logClose': repr(error)})
        return errors


def evaluate(seed, changed, pruned, final):
    before = seed['state']; pending = changed['after']['pending']; after = final['state']
    expected_ids = list(range(1, 13))
    check([r['id'] for r in before['audit']] == expected_ids, 'seed IDs')
    check(len({r['globalId'] for r in before['audit']}) == 12 and
          all(isinstance(r['globalId'], str) and r['globalId'] for r in before['audit']), 'seed global IDs')
    check(changed['before']['audit'] == before['audit'] == changed['after']['audit'] == pending,
          'mutation did not preserve exact pending audit IDs')
    check(before['modelRows'] == [{'id': i, 'value': i} for i in expected_ids], 'seed model values')
    check(before['modelRows'] == changed['before']['modelRows'] == changed['after']['modelRows'] == after['modelRows'],
          'model values changed')
    check(before['sequence'] == changed['after']['sequence'] == after['sequence'] == 12, 'audit sequence changed')
    check(changed['after']['targetRegistered'] and after['targetRegistered'] and
          changed['after']['targetFloor'] == after['targetFloor'] == 0, 'zero floor not durable')
    check(pruned['deleted'] in (0, 12), 'unexpected delete cardinality')
    survivors = after['audit']; pending_after = after['pending']
    accepted = pruned['deleted'] == 0 and survivors == pending_after == pending
    reproduced = pruned['deleted'] == 12 and survivors == pending_after == []
    check(accepted or reproduced, 'neither precise safety pass nor expected loss signature')
    return {'safetyAccepted': accepted, 'reproductionConfirmed': reproduced,
            'deleted': pruned['deleted'], 'pendingBefore': pending, 'pendingAfter': pending_after,
            'modelAndSequenceUnchanged': True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--packet', type=Path, required=True)
    parser.add_argument('--build-proof', type=Path, required=True)
    args = parser.parse_args()
    probe, packet, proof_path = args.probe.resolve(), args.packet.resolve(), args.build_proof.resolve()
    check(probe.is_file() and proof_path.is_file(), 'binary/proof missing')
    check(not packet.exists() and packet.parent.is_dir(), 'fresh owned result directory required')
    check(shutil.disk_usage(packet.parent).free >= FREE_FLOOR, 'prelaunch disk floor')
    proof = json.loads(proof_path.read_text())
    check(proof['source'] == CORE and proof['tree'] == TREE and proof['uniformO3'] is True, 'wrong source/build')
    binary = proof['binaries']['RetentionFloorRaceProbe']
    check(Path(binary['path']).resolve() == probe and binary['sha256'] == digest(probe), 'binary proof mismatch')
    check(bool(binary['linkArgv']) and len(binary['mapSHA256']) == 64, 'incomplete binary link proof')
    # Driver never self-selects a different source, compiler, mode, or retry.
    packet.mkdir()
    report = {'schemaVersion': 1, 'source': CORE, 'tree': TREE,
              'buildProofSHA256': digest(proof_path), 'binarySHA256': digest(probe),
              'driverSHA256': digest(Path(__file__).resolve()),
              'success': False, 'experimentCompleted': False, 'safetyAccepted': False,
              'reproductionConfirmed': False, 'cases': [], 'error': None, 'cleanupErrors': [],
              'groupAbsenceProof': 'outer GuardedRunner receipt required; not inferred from direct-child reaping'}
    deadline = time.monotonic() + 100
    with Interrupts() as interrupts:
        children = Children(packet, probe, interrupts, deadline)
        try:
            for operation, mutation in CASE_NAMES:
                label = operation + '-' + mutation
                case = packet / label; case.mkdir(); database = case / 'fixture.sqlite'
                names = {role: label + '-' + role for role in ('seed', 'prune', 'mutate', 'inspect')}
                children.spawn(names['seed'], 'seed', database, mutation)
                children.wait_finished(names['seed'])
                seed = children.one(names['seed'], 'seed')
                children.spawn(names['prune'], 'prune', database, operation)
                children.pump_until(lambda: len(children.records(names['prune'], 'floorBarrier')) == 1, 'floor barrier')
                barrier = children.one(names['prune'], 'floorBarrier')
                check(barrier == {'kind': 'floorBarrier', 'floorCount': 1, 'floorValue': 12,
                                  'floorFinalized': True, 'autocommit': True,
                                  'transactionState': 0, 'beginCount': 0}, 'barrier premise receipt')
                children.spawn(names['mutate'], 'mutate', database, mutation)
                children.wait_finished(names['mutate'])
                changed = children.one(names['mutate'], 'mutated')
                # The mutator has committed, reported exact pending IDs and
                # exited before the pruner may begin its deletion transaction.
                check(changed['after']['targetFloor'] == 0 and len(changed['after']['pending']) == 12, 'pre-release pending state')
                children.release(names['prune'])
                children.wait_finished(names['prune'])
                pruned = children.one(names['prune'], 'pruned')
                children.spawn(names['inspect'], 'inspect', database, 'final')
                children.wait_finished(names['inspect'])
                final = children.one(names['inspect'], 'inspected')
                result = {'name': label, 'operation': operation, 'mutation': mutation,
                          'barrier': barrier, 'seed': seed, 'mutated': changed,
                          'pruned': pruned, 'final': final, **evaluate(seed, changed, pruned, final)}
                save(case / 'RESULT.json', result)
                report['cases'].append(result)
            check(digest(probe) == report['binarySHA256'], 'binary changed during experiment')
            report['experimentCompleted'] = len(report['cases']) == 4
            report['reproductionConfirmed'] = all(c['reproductionConfirmed'] for c in report['cases'])
            report['safetyAccepted'] = all(c['safetyAccepted'] for c in report['cases'])
        except BaseException as error:
            report['error'] = {'type': type(error).__name__, 'message': str(error)}
        finally:
            try:
                report['cleanupErrors'] = children.close()
            except BaseException as error:
                report['cleanupErrors'].append({'cleanupException': repr(error)})
            report['children'] = children.cleanup
            report['events'] = children.events
            report['receivedSignals'] = interrupts.received
            try:
                check(shutil.disk_usage(packet).free >= FREE_FLOOR, 'final disk floor')
                report['files'] = {str(p.relative_to(packet)): facts(p) for p in sorted(packet.rglob('*')) if p.is_file()}
            except BaseException as error:
                report['cleanupErrors'].append({'finalEvidence': repr(error)})
            if (report['error'] or report['cleanupErrors'] or report['receivedSignals'] or
                    any(not c['reaped'] or c['exitCode'] != 0 or c['signals'] for c in report['children'].values())):
                report['experimentCompleted'] = report['reproductionConfirmed'] = report['safetyAccepted'] = False
            report['success'] = report['experimentCompleted'] and report['safetyAccepted']
            # A failed write cannot become a success: an exception exits nonzero,
            # while all previously written logs/case receipts remain on disk.
            try:
                save(packet / 'RESULT.json', report)
            except BaseException as error:
                # Preserve the primary failure in the outer raw log if result
                # finalization itself fails; never print a success substitute.
                print(json.dumps({'success': False, 'primaryError': report['error'],
                                  'cleanupErrors': report['cleanupErrors'],
                                  'resultWriteError': repr(error)}), file=sys.stderr, flush=True)
                raise
    return 0 if report['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
