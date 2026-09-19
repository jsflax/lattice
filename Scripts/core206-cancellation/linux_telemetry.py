"""Bounded read-only Linux scheduling observations in the existing runner poll.

No task completion claim, thread attribution to Swift Tasks, signaling, subprocess,
background thread, debugger, or environment collection. Caps/missing counters
make the diagnostic incomplete; they never change the test verdict.
"""
import json
import os
from pathlib import Path
import time

MAX_SAMPLES = 10804
MAX_BYTES = 96 * 2**20
MAX_PROCESSES = 2048
MAX_THREADS = 512
MAX_READ = 8192
POLL_BUDGET_NS = 50_000_000  # checked between reads; not a hard I/O deadline


def stat_fields(raw):
    head, separator, tail = raw.rpartition(') ')
    values = tail.split()
    if not separator or len(values) < 20:
        raise ValueError('short proc stat')
    return {'id': int(head.split('(', 1)[0]), 'state': values[0],
            'parent': int(values[1]), 'group': int(values[2]), 'session': int(values[3]),
            'cpuTicks': int(values[11]) + int(values[12]), 'birthTicks': int(values[19])}


def sched_fields(raw):
    values = raw.split()
    if len(values) != 3:
        raise ValueError('unexpected schedstat fields')
    return dict(zip(('runNs', 'runqueueNs', 'timeslices'), map(int, values)))


def numeric_names(path, cap):
    found = []
    with os.scandir(path) as entries:
        for entry in entries:
            if entry.name.isdecimal():
                found.append(entry.name)
                if len(found) > cap:
                    return sorted(found[:cap], key=int), True
    return sorted(found, key=int), False


class LinuxTelemetry:
    def __init__(self, path, *, proc=Path('/proc'), cgroup=Path('/sys/fs/cgroup')):
        self.path, self.proc, self.cgroup_root = path, proc, cgroup
        self.output = path.open('xb')
        self.samples = self.bytes = 0
        self.capped = False
        self.previous = {}
        self.group_birth = None
        self.errors = []
        self.cgroup_path = None
        try:
            # v2 only. A missing/unrepresentable namespace path is unknown.
            entries = self.read(proc / 'self/cgroup').splitlines()
            matches = [entry[3:] for entry in entries if entry.startswith('0::')]
            if len(matches) != 1:
                raise ValueError('cgroup v2 membership unavailable')
            relative = Path(matches[0].lstrip('/'))
            if '..' in relative.parts:
                raise ValueError('cgroup path escapes mount')
            candidate = (cgroup / relative).resolve()
            if not candidate.is_relative_to(cgroup.resolve()):
                raise ValueError('cgroup path escapes mount')
            self.cgroup_path = candidate
        except (OSError, ValueError) as error:
            self.errors.append(type(error).__name__ + ': cgroup counters unavailable')

    @staticmethod
    def read(path):
        with path.open('rb') as source:
            raw = source.read(MAX_READ + 1)
        if len(raw) > MAX_READ:
            raise ValueError('bounded proc read exceeded')
        return raw.decode('ascii', errors='replace')

    def poll(self, group):
        if self.capped:
            return
        began = time.monotonic_ns()
        row = {'monotonicNs': began, 'wallNs': time.time_ns(), 'group': group,
               'clockTicksPerSecond': os.sysconf('SC_CLK_TCK'), 'gaps': []}
        try:
            leader = stat_fields(self.read(self.proc / str(group) / 'stat'))
            if leader['id'] != group or leader['group'] != group or leader['session'] != group:
                raise ValueError('launch session identity differs')
            if self.group_birth is None:
                self.group_birth = leader['birthTicks']
            if self.group_birth != leader['birthTicks']:
                raise ValueError('launch PID birth changed')
            row['leaderBirthTicks'] = self.group_birth
        except (OSError, ValueError) as error:
            row['gaps'].append('leader unavailable: ' + type(error).__name__)
            self.emit(row, began)
            return
        for key, path in [('loadavg', self.proc / 'loadavg'),
                          ('hostCpuPressure', self.proc / 'pressure/cpu'),
                          ('schedstatsEnabled', self.proc / 'sys/kernel/sched_schedstats'),
                          ('cgroupCpuMax', self.cgroup_path / 'cpu.max' if self.cgroup_path else None),
                          ('cgroupCpuStat', self.cgroup_path / 'cpu.stat' if self.cgroup_path else None),
                          ('cgroupCpuPressure', self.cgroup_path / 'cpu.pressure' if self.cgroup_path else None)]:
            try:
                row[key] = self.read(path) if path is not None else None
            except (OSError, ValueError) as error:
                row[key] = None
                row['gaps'].append(key + ': ' + type(error).__name__)
        try:
            row['affinityCPUs'] = sorted(os.sched_getaffinity(0))
        except (AttributeError, OSError):
            row['affinityCPUs'] = None
        current, threads, processes, disappeared = {}, [], 0, 0
        try:
            pids, capped = numeric_names(self.proc, MAX_PROCESSES)
            if capped:
                row['gaps'].append('process enumeration cap')
            for pid in pids:
                if time.monotonic_ns() - began >= POLL_BUDGET_NS:
                    row['gaps'].append('poll elapsed budget')
                    break
                try:
                    process = stat_fields(self.read(self.proc / pid / 'stat'))
                    if process['group'] != group or process['session'] != group:
                        continue
                    processes += 1
                    tids, capped = numeric_names(self.proc / pid / 'task', MAX_THREADS - len(threads))
                    if capped:
                        row['gaps'].append('thread enumeration cap')
                    for tid in tids:
                        if len(threads) >= MAX_THREADS or time.monotonic_ns() - began >= POLL_BUDGET_NS:
                            row['gaps'].append('thread/poll budget')
                            break
                        try:
                            entry = stat_fields(self.read(self.proc / pid / 'task' / tid / 'stat'))
                            if entry['group'] != group or entry['session'] != group:
                                continue
                            key = (int(pid), process['birthTicks'], int(tid), entry['birthTicks'])
                            try:
                                entry.update(sched_fields(self.read(self.proc / pid / 'task' / tid / 'schedstat')))
                            except (OSError, ValueError):
                                row['gaps'].append('schedstat unavailable')
                            current[key] = entry
                            old = self.previous.get(key)
                            delta = None
                            if old and all(name in entry and name in old for name in ('runNs', 'runqueueNs', 'timeslices')):
                                delta = {name: entry[name] - old[name] for name in ('runNs', 'runqueueNs', 'timeslices')}
                                if min(delta.values()) < 0:
                                    delta = None
                                    row['gaps'].append('schedstat counter decreased')
                            threads.append({'pid': int(pid), 'processBirthTicks': process['birthTicks'],
                                            'tid': int(tid), 'threadBirthTicks': entry['birthTicks'],
                                            'state': entry['state'], 'cpuTicks': entry['cpuTicks'],
                                            'cpuTicksDelta': entry['cpuTicks'] - old['cpuTicks'] if old and entry['cpuTicks'] >= old['cpuTicks'] else None,
                                            'schedDelta': delta})
                        except FileNotFoundError:
                            disappeared += 1
                    if len(threads) >= MAX_THREADS:
                        row['gaps'].append('total thread cap')
                        break
                except FileNotFoundError:
                    disappeared += 1
        except (OSError, ValueError) as error:
            row['gaps'].append('census: ' + type(error).__name__)
        self.previous = current
        # Preserve bounded aggregate totals and top delays. These are OS-thread
        # samples, not the complete raw census or Swift-task identities.
        row.update(processesObserved=processes, threadsObserved=len(threads), disappeared=disappeared,
                   runnableThreads=sum(t['state'] == 'R' for t in threads),
                   waitingThreads=sum(t['state'] in ('S', 'D') for t in threads),
                   runDeltaNs=sum((t['schedDelta'] or {}).get('runNs', 0) for t in threads),
                   queueDeltaNs=sum((t['schedDelta'] or {}).get('runqueueNs', 0) for t in threads),
                   threadsWithDelta=sum(t['schedDelta'] is not None for t in threads),
                   cpuTicksDelta=sum(t['cpuTicksDelta'] or 0 for t in threads),
                   threadsWithCPUDelta=sum(t['cpuTicksDelta'] is not None for t in threads),
                   topCPU=sorted(threads, key=lambda t: t['cpuTicksDelta'] if t['cpuTicksDelta'] is not None else -1, reverse=True)[:8],
                   topQueueDelay=sorted(threads, key=lambda t: (t['schedDelta'] or {}).get('runqueueNs', -1), reverse=True)[:8])
        self.emit(row, began)

    def emit(self, row, began):
        row['collectionNs'] = time.monotonic_ns() - began
        row['gaps'] = sorted(set(row['gaps']))
        raw = (json.dumps(row, sort_keys=True, separators=(',', ':')) + '\n').encode()
        if self.samples >= MAX_SAMPLES or self.bytes + len(raw) > MAX_BYTES:
            self.capped = True
            return
        self.output.write(raw)
        self.output.flush()
        self.samples += 1
        self.bytes += len(raw)

    def close(self):
        self.output.close()
        return {'samples': self.samples, 'bytes': self.bytes, 'capped': self.capped,
                'setupGaps': self.errors, 'scope': 'observed launch session/group only; no escaped descendants or Swift Task completion proof'}
