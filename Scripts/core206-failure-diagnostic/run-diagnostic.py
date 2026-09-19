#!/usr/bin/env python3
"""Run a bounded, exact edited development graph; never release qualification."""
import argparse
import contextlib
import hashlib
import json
from linux_telemetry import LinuxTelemetry
import t1_child_logs
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import subprocess
import time


FREE_FLOOR = 12 * 2**30
PACKET_CEILING = 30 * 2**30
LOG_CEILING = 512 * 2**20
OVERALL_SECONDS = 210 * 60
FINALIZATION_RESERVE = 10 * 60
OVERLAY_MANIFEST = Path(__file__).parent / 'overlays.json'
FOCUSED_NAMES = ('bulkUpdate_boundedDrainTasks_allObserversDeliver',
                 'nilIsolation_deliversViaDrainerWithoutTaskStorm',
                 'coalescedDelivery_readsLatestState',
                 't1TrapWatchdog_trapImpossibilityUnderConcurrentDeleteBursts')
FOCUSED_FILTER = r'(?:^|[./])(?:' + '|'.join(FOCUSED_NAMES) + r')(?:\(.*\))?$'

SHA = re.compile(r'^[0-9a-f]{40}$')


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def error_record(error):
    return {'type': type(error).__name__, 'message': str(error)}


def save_json(path, value):
    # Evidence names are one-shot; failed/incomplete writes are not overwritten.
    with path.open('x') as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')


class RunnerInterrupted(Exception):
    pass


class Interrupts:
    def __init__(self):
        self.received = []
        self.deferred = 0
        self.previous = {}

    def handle(self, number, _frame):
        self.received.append(signal.Signals(number).name)
        if not self.deferred and len(self.received) == 1:
            raise RunnerInterrupted(self.received[-1])

    def __enter__(self):
        for number in (signal.SIGTERM, signal.SIGINT):
            self.previous[number] = signal.signal(number, self.handle)
        return self

    def __exit__(self, *_):
        for number, previous in self.previous.items():
            signal.signal(number, previous)

    @contextlib.contextmanager
    def hold(self):
        self.deferred += 1
        try:
            yield
        finally:
            self.deferred -= 1


def allocated(root):
    total = 0
    for directory, _, names in os.walk(root):
        for name in names:
            try:
                total += (Path(directory) / name).lstat().st_blocks * 512
            except FileNotFoundError:
                pass
    return total


class GuardedRunner:
    """Owns only sessions it creates. Limits are sampled, with final checks."""
    def __init__(self, root, receipts, env, interrupts, *, free_floor=FREE_FLOOR,
                 packet_ceiling=PACKET_CEILING, log_ceiling=LOG_CEILING,
                 overall_seconds=OVERALL_SECONDS, reserve=FINALIZATION_RESERVE,
                 poll_seconds=0.5, signal_grace=5):
        self.root, self.receipts, self.env = root, receipts, env
        self.interrupts = interrupts
        self.free_floor, self.packet_ceiling, self.log_ceiling = free_floor, packet_ceiling, log_ceiling
        self.started = time.monotonic()
        self.work_deadline = self.started + overall_seconds - reserve
        self.overall_deadline = self.started + overall_seconds
        self.poll_seconds, self.signal_grace = poll_seconds, signal_grace
        self.records = []
        self.aggregate_root = root

    def measure(self, log):
        return {'freeBytes': shutil.disk_usage(self.root).free,
                'packetBytes': allocated(self.aggregate_root),
                'logBytes': log.stat().st_size if log.exists() else 0}

    def violation(self, sample):
        if sample['freeBytes'] < self.free_floor:
            return 'disk floor'
        if sample['packetBytes'] > self.packet_ceiling or sample['logBytes'] > self.log_ceiling:
            return 'artifact ceiling'
        return None

    @staticmethod
    def group_state(pid):
        try:
            os.killpg(pid, 0)
            return True, None, 'killpg alive'
        except ProcessLookupError:
            return False, None, 'killpg ESRCH'
        except OSError as error:
            diagnostic = error_record(error)
            # macOS may report EPERM while a just-killed group disappears. A
            # bounded process-table read can prove absence without signalling
            # any other PID/group. Preserve only matching group members.
            try:
                table = subprocess.run(['ps', '-axo', 'pid=,pgid='],
                                       capture_output=True, text=True, timeout=2, check=True)
                rows = [line.split() for line in table.stdout.splitlines() if line.strip()]
                if any(len(row) != 2 or not all(cell.isdigit() for cell in row) for row in rows):
                    raise ValueError('unparseable ps group membership')
                members = [int(row[0]) for row in rows if int(row[1]) == pid]
                diagnostic['ownedGroupMembers'] = members
                return bool(members), diagnostic, 'ps owned-group membership'
            except BaseException as fallback_error:
                diagnostic['fallbackError'] = error_record(fallback_error)
                return None, diagnostic, 'missing group-absence proof'

    def cleanup(self, process):
        proof = {'signals': [], 'errors': [], 'groupGone': False,
                 'leaderReaped': False, 'proof': 'unknown'}
        for number in (signal.SIGTERM, signal.SIGKILL):
            # Reap the leader even while residual children keep the group alive.
            process.poll()
            exists, error, method = self.group_state(process.pid)
            if error:
                proof['errors'].append(error)
            if exists is False:
                proof.update(groupGone=True, proof=method)
                break
            try:
                os.killpg(process.pid, number)
                proof['signals'].append(signal.Signals(number).name)
            except ProcessLookupError:
                # The group may disappear between liveness check and signal.
                pass
            except OSError as error:
                proof['errors'].append(error_record(error))
            until = min(time.monotonic() + self.signal_grace, self.overall_deadline)
            while time.monotonic() < until:
                process.poll()
                exists, error, method = self.group_state(process.pid)
                if error:
                    proof['errors'].append(error)
                    break
                if exists is False:
                    proof.update(groupGone=True, proof=method)
                    break
                time.sleep(min(0.1, max(0, until - time.monotonic())))
            if proof['groupGone']:
                break
        try:
            process.wait(timeout=max(0.01, min(2, self.overall_deadline - time.monotonic())))
            proof['leaderReaped'] = True
        except (subprocess.TimeoutExpired, OSError) as error:
            proof['errors'].append(error_record(error))
        exists, error, method = self.group_state(process.pid)
        if error:
            proof['errors'].append(error)
        proof['groupGone'] = exists is False
        proof['proof'] = method if exists is False else 'missing group-absence proof'
        return proof

    def run(self, label, argv, *, cwd, timeout=3600, require_full_timeout=False):
        if self.interrupts.received:
            raise RunnerInterrupted('runner has already received interruption')
        log = self.receipts / (label + '.log')
        record = {'label': label, 'argv': argv, 'cwd': str(cwd), 'timeoutSeconds': timeout,
                  'started': False, 'temporaryDirectory': self.env.get('TMPDIR'),
                  'freeFloor': self.free_floor,
                  'packetCeiling': self.packet_ceiling, 'logCeiling': self.log_ceiling,
                  'primaryError': None, 'evidenceErrors': []}
        process = None
        output = None
        telemetry = None
        started = time.monotonic()
        deadline = min(started + timeout, self.work_deadline)
        primary = None
        try:
            sample = self.measure(log)
            record.update(initial=sample, minFreeBytes=sample['freeBytes'], peakPacketBytes=sample['packetBytes'])
            record['stopReason'] = self.violation(sample)
            remaining = self.work_deadline - time.monotonic()
            if remaining <= 0 or (require_full_timeout and remaining < timeout):
                record['stopReason'] = 'overall budget cannot admit unchanged command timeout'
            if record['stopReason']:
                raise RuntimeError(record['stopReason'])
            output = log.open('xb')
            if label in ('full-test', 'focused-test'):
                telemetry = LinuxTelemetry(self.receipts / (label + '-linux-scheduling.jsonl'))
            # Defer TERM/INT until Popen returns and ownership is recorded:
            # the OS child can exist before the Python assignment completes.
            with self.interrupts.hold():
                process = subprocess.Popen(argv, cwd=cwd, env=self.env, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                record.update(started=True, pid=process.pid, ownedPGID=process.pid)
            if self.interrupts.received:
                raise RunnerInterrupted('interrupted during owned process launch')
            while process.poll() is None:
                sample = self.measure(log)
                record['minFreeBytes'] = min(record['minFreeBytes'], sample['freeBytes'])
                record['peakPacketBytes'] = max(record['peakPacketBytes'], sample['packetBytes'])
                record['stopReason'] = self.violation(sample)
                if not record['stopReason'] and time.monotonic() >= deadline:
                    record['stopReason'] = 'command timeout' if deadline < self.work_deadline else 'overall work budget'
                if record['stopReason']:
                    raise RuntimeError(record['stopReason'])
                if telemetry is not None:
                    telemetry.poll(process.pid)
                time.sleep(self.poll_seconds)
        except BaseException as error:
            primary = error
            record['primaryError'] = error_record(error)
        finally:
            # A second TERM/INT cannot interrupt cleanup or overwrite the first error.
            with self.interrupts.hold():
                if process is not None:
                    try:
                        record['cleanup'] = self.cleanup(process)
                    except BaseException as error:
                        record['cleanup'] = {'groupGone': False, 'leaderReaped': False,
                                             'proof': 'cleanup raised; proof missing', 'errors': [error_record(error)]}
                    record['exitCode'] = process.returncode
                else:
                    record['cleanup'] = {'groupGone': True, 'leaderReaped': True, 'proof': 'no process started'}
                    record['exitCode'] = None
                if telemetry is not None:
                    try:
                        record['linuxTelemetry'] = telemetry.close()
                        record['linuxTelemetry'].update(sha256=digest(telemetry.path), path=str(telemetry.path))
                    except BaseException as error:
                        record['evidenceErrors'].append(error_record(error))
                if output is not None:
                    try:
                        output.close()
                    except BaseException as error:
                        record['evidenceErrors'].append(error_record(error))
                try:
                    sample = self.measure(log)
                    record['final'] = sample
                    record['minFreeBytes'] = min(record.get('minFreeBytes', sample['freeBytes']), sample['freeBytes'])
                    record['peakPacketBytes'] = max(record.get('peakPacketBytes', 0), sample['packetBytes'])
                    final_violation = self.violation(sample)
                    if not record.get('stopReason') and final_violation:
                        record['stopReason'] = final_violation
                    if not record.get('stopReason') and time.monotonic() >= deadline:
                        record['stopReason'] = 'deadline exceeded before final acceptance'
                    if log.exists():
                        record.update(logSHA256=digest(log), logBytes=log.stat().st_size)
                except BaseException as error:
                    record['evidenceErrors'].append(error_record(error))
                record.update(elapsedSeconds=time.monotonic() - started,
                              receivedSignals=list(self.interrupts.received))
                record['success'] = (record['started'] and record['exitCode'] == 0 and primary is None
                                     and not record.get('stopReason') and not record['evidenceErrors']
                                     and not self.interrupts.received and record['cleanup']['groupGone']
                                     and record['cleanup']['leaderReaped'])
                try:
                    save_json(self.receipts / (label + '.json'), record)
                except BaseException as error:
                    record['success'] = False
                    record['evidenceErrors'].append(error_record(error))
                    print('RECEIPT_WRITE_FAILED', label, json.dumps(record), flush=True)
                self.records.append({'label': label, 'success': record['success']})
        print(label, 'success', record['success'], 'exit', record['exitCode'], flush=True)
        if primary is not None:
            raise primary
        if not record['success']:
            raise RuntimeError('unqualified command: ' + label)
        return log


def pins(path):
    entries = json.loads(path.read_text())['pins']
    result = {entry['identity']: entry for entry in entries}
    if len(entries) != len(result) or any(not SHA.fullmatch(x['state']['revision']) for x in entries):
        raise ValueError('invalid complete resolved pin records')
    return result


def tracked_manifest(repository, names):
    result = {}
    for name in names:
        if not name:
            continue
        path = repository / name
        if path.is_symlink():
            result[name] = {'symlink': os.readlink(path)}
        else:
            result[name] = {'sha256': digest(path), 'bytes': path.stat().st_size}
    return result


def authenticate_repository(runner, label, repository, expected, *, allowed_changes=(), initial=False):
    def git(suffix, *argv):
        return runner.run(label + '-' + suffix, ['git', *argv], cwd=repository, timeout=60).read_bytes()
    actual = git('identity', 'show', '--no-patch', '--format=%H %T', 'HEAD').decode().strip().split()
    if len(actual) != 2 or actual[0] != expected:
        raise ValueError(label + ': checkout does not match exact expected commit')
    status_args = ['status', '--porcelain=v1', '-z', '--untracked-files=all']
    if initial:
        status_args.append('--ignored')
    status = git('status', *status_args).decode().split('\0')
    for entry in filter(None, status):
        if entry[3:] not in allowed_changes:
            raise ValueError(label + ': unexpected tracked/index/untracked/ignored change: ' + repr(entry))
    names = git('files', 'ls-files', '-z').decode().split('\0')
    manifest = tracked_manifest(repository, [name for name in names if name not in allowed_changes])
    result = {'commit': actual[0], 'tree': actual[1], 'path': str(repository.resolve()), 'files': manifest}
    save_json(runner.receipts / (label + '-manifest.json'), result)
    return result


def read_graph(log):
    raw = log.read_text()
    return json.loads(raw[raw.index('{'):])


def graph_nodes(graph):
    stack, found = list(graph.get('dependencies', [])), {}
    while stack:
        node = stack.pop()
        identity = node.get('identity', node.get('name', '')).lower()
        signature = {key: node.get(key) for key in ['path', 'url', 'version']}
        if identity in found and signature != {key: found[identity].get(key) for key in signature}:
            raise ValueError('one dependency identity resolves to different graph nodes: ' + identity)
        found[identity] = node
        stack.extend(node.get('dependencies', []))
    return found


def url_key(url):
    return url.rstrip('/').removesuffix('.git')


def verify_graph(runner, label, graph, original, core, core_sha, scratch):
    nodes = graph_nodes(graph)
    if set(nodes) != set(original):
        raise ValueError('effective graph identities do not equal all committed lock identities')
    state = json.loads((scratch / 'workspace-state.json').read_text())
    entries = state['object']['dependencies']
    dependencies = {entry['packageRef']['identity']: entry for entry in entries}
    if len(dependencies) != len(entries) or set(dependencies) != set(original):
        raise ValueError('workspace state identities do not equal committed lock identities')
    rows = []
    for identity in sorted(original):
        pin, node, entry = original[identity], nodes[identity], dependencies[identity]
        path = Path(node['path']).resolve(strict=True)
        if identity == 'latticecore':
            if path != core.resolve() or entry['state']['name'] != 'edited':
                raise ValueError('Core is not the sole explicit edited checkout')
            expected_revision = core_sha
        else:
            if entry['state']['name'] != 'sourceControlCheckout':
                raise ValueError('unexpected edited/local dependency: ' + identity)
            if entry['state']['checkoutState'] != pin['state']:
                raise ValueError('workspace revision/version differs from committed pin: ' + identity)
            expected_path = (scratch / 'checkouts' / entry['subpath']).resolve(strict=True)
            if not expected_path.is_relative_to((scratch / 'checkouts').resolve()) or path != expected_path:
                raise ValueError('dependency graph uses an unexpected checkout path: ' + identity)
            if url_key(node['url']) != url_key(pin['location']):
                raise ValueError('dependency graph URL differs from committed pin: ' + identity)
            expected_revision = pin['state']['revision']
        if url_key(entry['packageRef']['location']) != url_key(pin['location']):
            raise ValueError('workspace source location differs from committed pin: ' + identity)
        # Git proves actual checked-out source, not only a JSON version label.
        head = runner.run(label + '-' + identity + '-head', ['git', 'rev-parse', 'HEAD'], cwd=path, timeout=60).read_text().strip()
        dirty = runner.run(label + '-' + identity + '-status', ['git', 'status', '--porcelain=v1', '--untracked-files=all'], cwd=path, timeout=60).read_text()
        if head != expected_revision or dirty:
            raise ValueError('effective checkout revision/source mismatch: ' + identity)
        rows.append({'identity': identity, 'path': str(path), 'revision': head,
                     'location': pin['location'], 'workspaceState': entry['state']})
    save_json(runner.receipts / (label + '.json'), rows)
    return rows


def compiler_input_proof(log, core):
    expected = {p.resolve() for folder in ['Sources/LatticeCore/src', 'Sources/LatticeSwiftCppBridge/src']
                for p in (core / folder).rglob('*.cpp')}
    found, samples = set(), []
    with log.open() as lines:
        for line in lines:
            if ' -c ' not in line:
                continue
            try:
                argv = shlex.split(line)
            except ValueError:
                continue
            if not argv or Path(argv[0]).name not in ('clang', 'clang++') or '-c' not in argv:
                continue
            source = Path(argv[argv.index('-c') + 1])
            if any(part in str(source) for part in ['/Sources/LatticeCore/src/', '/Sources/LatticeSwiftCppBridge/src/']):
                source = source.resolve()
                if source not in expected:
                    raise ValueError('compiler consumed Core source outside the exact override: ' + str(source))
                found.add(source)
                if len(samples) < 40:
                    samples.append({'source': str(source), 'command': line.rstrip()[:12000]})
    if found != expected or not expected:
        raise ValueError('missing actual compiler input proof: ' + str(sorted(str(p) for p in expected - found)))
    return {'kind': 'verbose clang -c inputs', 'corePath': str(core.resolve()),
            'sourceFiles': {str(p): digest(p) for p in sorted(found)}, 'samples': samples}


def load_binding(path):
    binding = json.loads(path.read_text())
    if (binding.get('schema') != 1
            or binding.get('sdkCommit') != '0461b210aa028f3c4bb6165fed895e0f4385b565'
            or binding.get('sdkTree') != 'a1faa2850ebf2bf7dca152feffa461a24755a154'
            or binding.get('sdkVersion') != '2.0.0'
            or (binding.get('coreVersion'), binding.get('coreCommit'), binding.get('coreTree')) !=
                ('2.0.6', 'db6bf8b97d7af22db4c1224f17bbdea80a43cc57', '781cf09659a06475d88c1f33122c2130142e93c1')):
        raise ValueError('diagnostic successor is limited to SDK0461 with exact Coredb6')
    for key in ('coreCommit', 'coreTree'):
        if not isinstance(binding.get(key), str) or not SHA.fullmatch(binding[key]):
            raise ValueError('unbound exact maintenance Core identity: ' + key)
    for key in ('sdkManifestSHA256', 'sdkLockSHA256', 'sdkBindingsSHA256'):
        if not re.fullmatch(r'[0-9a-f]{64}', str(binding.get(key, ''))):
            raise ValueError('missing authenticated published SDK input: ' + key)
    return binding


def verify_sdk_binding(sdk, binding):
    for name, key in [('Package.swift', 'sdkManifestSHA256'),
                      ('Package.resolved', 'sdkLockSHA256'),
                      ('Scripts/wrapper-expected-bindings.json', 'sdkBindingsSHA256')]:
        if digest(sdk / name) != binding[key]:
            raise ValueError('published SDK input differs from reviewed bytes: ' + name)


def load_overlays():
    rows = json.loads(OVERLAY_MANIFEST.read_text())
    expected = {'Tests/LatticeTests/ChangeStreamLifecycleTests.swift',
                'Sources/Lattice/Model.swift', 'Tests/LatticeTests/NotificationCoalescingTests.swift'}
    if not isinstance(rows, list) or len(rows) != 3 or {r.get('path') for r in rows} != expected:
        raise ValueError('exact three diagnostic overlay paths required')
    for row in rows:
        for key in ('beforeSHA256', 'afterSHA256'):
            if not re.fullmatch(r'[0-9a-f]{64}', str(row.get(key, ''))):
                raise ValueError('unbound diagnostic overlay hash')
    return rows


def verify_overlay(sdk):
    rows = load_overlays()
    for row in rows:
        if digest(sdk / row['path']) != row['afterSHA256']:
            raise ValueError('diagnostic overlay postimage changed: ' + row['path'])
    return rows


def apply_overlay(sdk, receipts):
    rows = load_overlays()
    for row in rows:
        source = Path(__file__).parent / 'overlay' / row['path']
        if digest(sdk / row['path']) != row['beforeSHA256'] or digest(source) != row['afterSHA256']:
            raise ValueError('diagnostic overlay preimage/postimage mismatch: ' + row['path'])
    for row in rows:
        (sdk / row['path']).write_bytes((Path(__file__).parent / 'overlay' / row['path']).read_bytes())
    save_json(receipts / 'sdk-diagnostic-overlay.json', {
        'files': rows, 'publishedSDKModifiedForDiagnostic': True, 'releaseSDKSourceChanged': False,
        'scope': 'bounded notification stage accounting plus retained cancellation emit-on-pass; original oracles and membership preserved'})
    verify_overlay(sdk)


def configure_aggregate_root(runner, root, aggregate_root):
    aggregate = aggregate_root.resolve(strict=True)
    allowed = (Path.home() / 'localdev').resolve(strict=True)
    if (aggregate == allowed or not aggregate.is_relative_to(allowed)
            or root == aggregate or not root.is_relative_to(aggregate)):
        raise ValueError('run must be a strict child of an owned aggregate localdev root')
    runner.aggregate_root = aggregate


def settled_for_diagnostic_followup(record, label):
    if not isinstance(record, dict) or not isinstance(record.get('cleanup'), dict):
        return False
    cleanup = record['cleanup']
    return (record.get('label') == label and record.get('started') is True
            and type(record.get('exitCode')) is int and record['exitCode'] in (0, 1)
            and record.get('success') is (record['exitCode'] == 0)
            and not record.get('primaryError') and not record.get('stopReason')
            and not record.get('evidenceErrors') and not record.get('receivedSignals')
            and cleanup.get('groupGone') is True and cleanup.get('leaderReaped') is True
            and not cleanup.get('signals') and not cleanup.get('errors'))


def run_test_invocations(runner, common, sdk, root, outcomes):
    """One full then one focused invocation; first error remains the result.

    An ordinary assertion exit may admit the second diagnostic, but only after
    existing ownership and resource guards prove it is safe. This is not retry.
    """
    first_error = None
    for label, suffix in [('full-test', []), ('focused-test', ['--filter', FOCUSED_FILTER])]:
        entry = {'label': label, 'expectedParentTests': 693 if label == 'full-test' else 4,
                 'expectedKnownSkips': 5 if label == 'full-test' else 0,
                 'raisedError': None, 'evidenceErrors': [], 'testAccepted': False}
        outcomes.append(entry)
        tmp = root / (label + '-tmp')
        saved_env = runner.env
        try:
            tmp.mkdir(exist_ok=False)
            runner.env = dict(saved_env, TMPDIR=str(tmp), TMP=str(tmp), TEMP=str(tmp),
                              LATTICE_TEST_LOG_PATH=str(root / 'test-logs' / (label + '.log')))
            runner.run(label, ['swift', 'test', *common, '--force-resolved-versions', '--skip-build', *suffix],
                       cwd=sdk, timeout=5400, require_full_timeout=True)
        except BaseException as error:
            entry['raisedError'] = error_record(error)
            if first_error is None:
                first_error = error
        finally:
            runner.env = saved_env
        record = None
        try:
            receipt = runner.receipts / (label + '.json')
            record = json.loads(receipt.read_text())
            if not isinstance(record, dict) or record.get('temporaryDirectory') != str(tmp):
                raise ValueError(label + ': actual receipt does not bind the invocation TMPDIR')
            entry.update(commandReceiptSHA256=digest(receipt), testAccepted=record['success'],
                         temporaryDirectory=str(tmp))
            capture = t1_child_logs.collect(tmp, runner.receipts / (label + '-child-logs'),
                                            record, expected_label=label)
            capture_path = runner.receipts / (label + '-child-logs.json')
            save_json(capture_path, capture)
            entry['childLogManifestSHA256'] = digest(capture_path)
            if not capture['complete']:
                raise ValueError(label + ': incomplete watchdog child logs')
        except BaseException as error:
            entry['evidenceErrors'].append(error_record(error))
            if first_error is None:
                first_error = error
        safe = record is not None and settled_for_diagnostic_followup(record, label)
        expected_error = {'type': 'RuntimeError', 'message': 'unqualified command: ' + label}
        safe = safe and (entry['raisedError'] is None if record['exitCode'] == 0
                         else entry['raisedError'] == expected_error)
        entry['ownershipAcceptedForFollowup'] = safe
        if not safe or runner.interrupts.received or entry['evidenceErrors']:
            entry['sequenceStopped'] = 'incomplete settlement, interruption, or diagnostic custody'
            return first_error or RuntimeError(entry['sequenceStopped']), False
    return first_error, True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--binding', type=Path, required=True)
    parser.add_argument('--test-timeout', type=int, choices=(1800, 5400), required=True)
    parser.add_argument('--aggregate-root', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Linux' or args.test_timeout != 5400:
        raise ValueError('this diagnostic successor is Linux-only with unchanged 5400s allowance')
    root = args.root.resolve(strict=True)
    allowed = (Path.home() / 'localdev').resolve(strict=True)
    if not root.is_relative_to(allowed) or root == allowed:
        raise ValueError('development root must be a child of ~/localdev')
    binding = load_binding(args.binding)
    sdk_sha, core_sha = binding['sdkCommit'], binding['coreCommit']
    workflow_sha = os.environ.get('GITHUB_SHA', '')
    if not SHA.fullmatch(workflow_sha):
        raise ValueError('workflow GITHUB_SHA must be an exact lower-case commit SHA')
    sdk, core, receipts = root / 'lattice', root / 'LatticeCore', root / 'receipts'
    receipts.mkdir(exist_ok=False)
    env = os.environ.copy()
    env.update(TMPDIR=str(root / 'tmp'), TMP=str(root / 'tmp'), TEMP=str(root / 'tmp'),
               CLANG_MODULE_CACHE_PATH=str(root / 'module-cache'),
               SWIFT_MODULECACHE_PATH=str(root / 'module-cache'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(root / 'module-cache'),
               LATTICE_TEST_LOG_PATH=str(root / 'test-logs/native.log'),
               LATTICE_ACK_PATH_DIAGNOSTICS='1', LATTICE_OBSERVER_WORKER_DIAGNOSTICS='1',
               PYTHONDONTWRITEBYTECODE='1')
    monotonic = time.get_clock_info('monotonic')
    result = {'scope': 'one candidate full then focused diagnostic; focused pass cannot qualify a failed full suite',
              'coreCommit': core_sha, 'sdkCommit': sdk_sha,
              'runnerOS': platform.platform(), 'machine': platform.machine(), 'cpuCount': os.cpu_count(),
              'monotonicClock': {'implementation': monotonic.implementation,
                                 'monotonic': monotonic.monotonic, 'adjustable': monotonic.adjustable,
                                 'resolutionSeconds': monotonic.resolution},
              'runID': env.get('GITHUB_RUN_ID'), 'attempt': env.get('GITHUB_RUN_ATTEMPT'),
              'job': env.get('GITHUB_JOB'), 'workflowCommit': workflow_sha,
              'bindingSHA256': digest(args.binding),
              'scriptSHA256': digest(Path(__file__)), 'success': False,
              'telemetrySHA256': digest(Path(__file__).parent / 'linux_telemetry.py'),
              'diagnosticOverlayManifestSHA256': digest(OVERLAY_MANIFEST),
              'childLogHelperSHA256': digest(Path(__file__).parent / 't1_child_logs.py'),
              'testInvocations': [], 'focusedFilter': FOCUSED_FILTER,
              'aggregateRoot': str(args.aggregate_root),
              'primaryError': None, 'evidenceErrors': [], 'releaseGraphAccepted': False,
              'overallSeconds': OVERALL_SECONDS, 'finalizationReserveSeconds': FINALIZATION_RESERVE}
    original = sdk_inputs = core_inputs = None
    primary = None
    test_started_at = None
    with Interrupts() as interrupts:
        runner = GuardedRunner(root, receipts, env, interrupts)
        configure_aggregate_root(runner, root, args.aggregate_root)
        result.update(effectiveWorkDeadline=runner.work_deadline, effectiveOverallDeadline=runner.overall_deadline)
        try:
            # Reusing edited workspace/cache state would invalidate graph authentication.
            if core.exists() or sdk.exists():
                raise ValueError('SDK and Core destinations must not already exist')
            for name in ['module-cache', 'cache', 'config', 'security', 'scratch', 'test-logs']:
                (root / name).mkdir(exist_ok=False)
            (root / 'tmp').mkdir(exist_ok=True)
            runner.run('sdk-init', ['git', 'init', str(sdk)], cwd=root)
            runner.run('sdk-fetch', ['git', 'fetch', '--depth=1', 'https://github.com/jsflax/lattice.git', sdk_sha], cwd=sdk)
            runner.run('sdk-checkout', ['git', 'checkout', '--detach', sdk_sha], cwd=sdk)
            sdk_inputs = authenticate_repository(runner, 'sdk-initial', sdk, sdk_sha, initial=True)
            if sdk_inputs['tree'] != binding['sdkTree']:
                raise ValueError('SDK tree differs from published source')
            verify_sdk_binding(sdk, binding)
            apply_overlay(sdk, receipts)
            original = pins(sdk / 'Package.resolved')
            if len(original) != 34 or 'latticecore' not in original:
                raise ValueError('reviewed development graph requires exactly 34 committed identities including Core')
            shutil.copyfile(sdk / 'Package.resolved', receipts / 'Package.resolved.original')
            shutil.copyfile(sdk / 'Package.swift', receipts / 'Package.swift.original')
            runner.run('published-sdk-bindings', ['python3', '-B', 'Scripts/verify-wrapper-bindings.py',
                       '--expected', 'Scripts/wrapper-expected-bindings.json',
                       '--resolved', str(receipts / 'Package.resolved.original')], cwd=sdk)
            runner.run('swift-version', ['swift', '--version'], cwd=sdk)
            runner.run('test-help', ['swift', 'test', '--help'], cwd=sdk)
            runner.run('core-init', ['git', 'init', str(core)], cwd=root)
            runner.run('core-fetch', ['git', 'fetch', '--depth=1', 'https://github.com/jsflax/LatticeCore.git', core_sha], cwd=core)
            runner.run('core-checkout', ['git', 'checkout', '--detach', core_sha], cwd=core)
            core_inputs = authenticate_repository(runner, 'core-initial', core, core_sha, initial=True)
            if core_inputs['tree'] != binding['coreTree']:
                raise ValueError('Core tree differs from committed development graph')
            common = ['--package-path', str(sdk), '--scratch-path', str(root / 'scratch'),
                      '--cache-path', str(root / 'cache'), '--config-path', str(root / 'config'),
                      '--security-path', str(root / 'security'), '--disable-sandbox', '--disable-experimental-prebuilts']
            runner.run('resolve-versioned', ['swift', 'package', *common, '--force-resolved-versions', 'resolve'], cwd=sdk)
            if pins(sdk / 'Package.resolved') != original:
                raise ValueError('versioned resolution changed complete pin records')
            runner.run('edit-core', ['swift', 'package', *common, 'edit', 'LatticeCore', '--path', str(core)], cwd=sdk)
            graph = runner.run('effective-graph-before', ['swift', 'package', *common, 'show-dependencies', '--format', 'json'], cwd=sdk)
            verify_graph(runner, 'graph-before', read_graph(graph), original, core, core_sha, root / 'scratch')
            build = runner.run('build-tests', ['swift', 'build', *common, '--force-resolved-versions', '--build-tests', '-j', '2', '-v'], cwd=sdk, timeout=5400, require_full_timeout=True)
            save_json(receipts / 'compiler-input-proof.json', compiler_input_proof(build, core))
            # Do not shorten or silently consume the original platform test allowance.
            test_started_at = time.time()
            test_error, sequence_safe = run_test_invocations(runner, common, sdk, root, result['testInvocations'])
            if not sequence_safe:
                raise test_error
            # Retain post-run graph proof even when a safely settled test failed.
            if test_error is not None:
                primary = test_error
                result['primaryError'] = error_record(test_error)
            graph = runner.run('effective-graph-after', ['swift', 'package', *common, 'show-dependencies', '--format', 'json'], cwd=sdk)
            verify_graph(runner, 'graph-after', read_graph(graph), original, core, core_sha, root / 'scratch')
            final_sdk = authenticate_repository(runner, 'sdk-final', sdk, sdk_sha, allowed_changes=('Package.resolved', *(r['path'] for r in load_overlays())))
            final_core = authenticate_repository(runner, 'core-final', core, core_sha)
            initial_sdk_files = {k: v for k, v in sdk_inputs['files'].items() if k not in ('Package.resolved', *(r['path'] for r in load_overlays()))}
            if final_sdk['files'] != initial_sdk_files or final_core != core_inputs:
                raise ValueError('tracked source changed during qualification')
            verify_overlay(sdk)
            result['success'] = True
        except BaseException as error:
            if primary is None:
                primary = error
                result['primaryError'] = error_record(error)
            else:
                result['evidenceErrors'].append({'operation': 'post-test qualification', **error_record(error)})
        finally:
            with interrupts.hold():
                # Final evidence failures never erase the primary build/test/cleanup failure.
                def evidence(name, operation):
                    try:
                        return operation()
                    except BaseException as error:
                        result['evidenceErrors'].append({'operation': name, **error_record(error)})
                        return None
                def final_lock():
                    current = pins(sdk / 'Package.resolved')
                    if original is None:
                        raise ValueError('initial lock authentication missing')
                    before = {k: v for k, v in original.items() if k != 'latticecore'}
                    after = {k: v for k, v in current.items() if k != 'latticecore'}
                    result.update(nonCorePinsUnchanged=before == after, nonCorePinCount=len(before))
                    if before != after:
                        raise ValueError('unapproved non-Core dependency drift')
                    shutil.copyfile(sdk / 'Package.resolved', receipts / 'Package.resolved.final')
                if platform.system() == 'Darwin' and test_started_at is not None and primary is not None:
                    def crash_evidence():
                        import development_crashes
                        captured = development_crashes.collect(root, receipts / 'crash-reports', test_started_at)
                        save_json(receipts / 'crash-reports.json', captured)
                    evidence('macOS test crash reports', crash_evidence)
                if sdk_inputs is not None:
                    evidence('diagnostic overlay final bytes', lambda: save_json(receipts / 'sdk-overlay-at-exit.json', verify_overlay(sdk)))
                evidence('final lock', final_lock)
                evidence('final workspace state', lambda: shutil.copyfile(root / 'scratch/workspace-state.json', receipts / 'workspace-state.final.json'))
                for label, repository, initial in [('sdk', sdk, sdk_inputs), ('core', core, core_inputs)]:
                    if initial is not None:
                        evidence(label + ' final file snapshot', lambda label=label, repository=repository, initial=initial:
                                 save_json(receipts / (label + '-files-at-exit.json'), tracked_manifest(repository, initial['files'])))
                def final_resources():
                    measurement = runner.measure(receipts / 'RESULT.json')
                    result['finalResources'] = measurement
                    violation = runner.violation(measurement)
                    if violation:
                        raise RuntimeError('final evidence resource guard: ' + violation)
                evidence('final resources', final_resources)
                result.update(commands=runner.records, receivedSignals=interrupts.received,
                              elapsedSeconds=time.monotonic() - runner.started)
                result['success'] = (result['success'] and primary is None and not result['evidenceErrors']
                                     and not interrupts.received and all(x['success'] for x in runner.records)
                                     and time.monotonic() <= runner.overall_deadline)
                try:
                    save_json(receipts / 'RESULT.json', result)
                except BaseException as error:
                    result['success'] = False
                    result['evidenceErrors'].append({'operation': 'RESULT.json', **error_record(error)})
                    print('FINAL_RESULT_WRITE_FAILED', json.dumps(result), flush=True)
    if not result['success']:
        if primary is not None:
            raise primary
        raise RuntimeError('development graph was not qualified; inspect RESULT.json')


if __name__ == '__main__':
    main()
