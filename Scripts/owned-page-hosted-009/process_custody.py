"""macOS command descendants, including Swift-created process groups. No environments."""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


class BSDInfo(ctypes.Structure):
    # SDK sys/proc_info.h: struct proc_bsdinfo (PROC_PIDTBSDINFO = 3).
    _fields_ = [(name, ctypes.c_uint32) for name in
                ('flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid',
                 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in
                 ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64),
                ('start_usec', ctypes.c_uint64)]


def identity(pid):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.restype = ctypes.c_int
    info = BSDInfo()
    ctypes.set_errno(0)
    count = lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if count == 0 and ctypes.get_errno() == errno.ESRCH:
        return None
    if count != ctypes.sizeof(info) or info.pid != pid or info.uid != os.getuid():
        raise RuntimeError('unverifiable owned process identity: ' + str(pid))
    return {'pid': pid, 'ppid': info.ppid, 'pgid': info.pgid,
            'birth': [info.start_sec, info.start_usec], 'zombie': info.status == 5}


def same(left, right):
    return bool(left and right and left['pid'] == right['pid'] and left['birth'] == right['birth'])


def snapshot():
    # argv only. Never request -E, an environment, or another process's memory.
    value = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,command='],
                           capture_output=True, text=True, timeout=2, check=True)
    if len(value.stdout) > 16 * 2**20:
        raise RuntimeError('process snapshot exceeds bound')
    rows = {}
    for line in value.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) != 4 or not all(x.isdigit() for x in parts[:3]):
            raise RuntimeError('malformed process snapshot')
        pid, ppid, pgid = map(int, parts[:3])
        if pid in rows:
            raise RuntimeError('duplicate process snapshot PID')
        rows[pid] = {'pid': pid, 'ppid': ppid, 'pgid': pgid,
                     'commandSHA256': hashlib.sha256(parts[3].encode()).hexdigest(),
                     'command': parts[3]}
    return rows


def event(path, value):
    data = (json.dumps(value, sort_keys=True) + '\n').encode()
    if len(data) > 64 * 1024:
        raise RuntimeError('ownership event exceeds bound')
    with path.open('ab') as output:
        if output.tell() + len(data) > 16 * 2**20:
            raise RuntimeError('ownership ledger exceeds bound')
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


class Custody:
    def __init__(self, pid, runtime, events, *, parent_pid=None, get_identity=identity, take_snapshot=snapshot):
        self.get_identity, self.take_snapshot = get_identity, take_snapshot
        self.runtime, self.events = str(runtime), events
        self.root_pattern = re.compile(re.escape(str(runtime)) + r'(?=/|[\s"\']|$)')
        self.known, self.ambiguous = {}, {}
        first = get_identity(pid)
        if first is None or first['ppid'] != (os.getpid() if parent_pid is None else parent_pid):
            raise RuntimeError('direct command child identity unverified before custody')
        self.remember(first, None)

    def remember(self, node, parent):
        prior = self.known.get(node['pid'])
        if prior and not same(prior, node):
            raise RuntimeError('owned PID reused')
        if not prior:
            self.known[node['pid']] = dict(node)
            event(self.events, {'event': 'owned', 'identity': node, 'parentIdentity': parent})

    def refresh(self):
        rows = self.take_snapshot()
        live = {}
        for pid, saved in self.known.items():
            current = self.get_identity(pid)
            if current is not None and not same(saved, current):
                raise RuntimeError('owned PID reused before closure: ' + str(pid))
            if current is not None:
                live[pid] = current
        changed = True
        while changed:
            changed = False
            for pid, row in rows.items():
                if pid in live or row['ppid'] not in live:
                    continue
                parent = self.get_identity(row['ppid'])
                child = self.get_identity(pid)
                if (child is not None and child['ppid'] == row['ppid']
                        and same(parent, live[row['ppid']])):
                    self.remember(child, parent)
                    live[pid] = child
                    changed = True
        ambiguous = {}
        for pid, row in rows.items():
            if pid not in self.known and self.root_pattern.search(row['command']):
                # A path is a candidate for refusal, never permission to signal.
                node = self.get_identity(pid)
                if node is not None:
                    ambiguous[pid] = node | {'commandSHA256': row['commandSHA256']}
        if ambiguous != self.ambiguous:
            event(self.events, {'event': 'ambiguous', 'candidates': list(ambiguous.values())})
        self.ambiguous = ambiguous
        return live

    def signal(self, node, number):
        current = self.get_identity(node['pid'])
        if current is None or current['zombie']:
            return False
        if not same(node, current):
            raise RuntimeError('refusing signal to changed process identity')
        # Birth identity/ancestry, not executable text or a runtime path, grants ownership.
        try:
            os.kill(node['pid'], number)
        except ProcessLookupError:
            return False
        event(self.events, {'event': 'signal', 'identity': current,
                            'signal': signal.Signals(number).name})
        return True

    def close(self, process, deadline, grace):
        proof = {'signals': [], 'errors': [], 'ownedDescendantsGone': False,
                 'leaderReaped': False, 'ambiguous': [], 'proof': 'owned birth identities'}
        for number in (signal.SIGTERM, signal.SIGKILL):
            until = min(time.monotonic() + grace, deadline)
            signalled = set()
            while True:
                process.poll()
                try:
                    live = self.refresh()
                    # Parent-first stops the command's producers before leaf consumers.
                    def depth(node):
                        ancestors = set()
                        while node['ppid'] in live:
                            if node['ppid'] in ancestors:
                                raise RuntimeError('process ancestry cycle')
                            ancestors.add(node['ppid'])
                            node = live[node['ppid']]
                        return len(ancestors)
                    pending = sorted(live.values(), key=lambda x: (depth(x), x['pid']))
                    for node in pending:
                        key = (node['pid'], tuple(node['birth']))
                        if key not in signalled and self.signal(node, number):
                            signalled.add(key)
                            proof['signals'].append({'pid': node['pid'], 'signal': signal.Signals(number).name})
                    if not live and not self.ambiguous:
                        proof['ownedDescendantsGone'] = True
                        break
                except BaseException as error:
                    proof['errors'].append({'type': type(error).__name__, 'message': str(error)})
                    break
                if time.monotonic() >= until:
                    break
                time.sleep(min(0.05, max(0, until - time.monotonic())))
            if proof['ownedDescendantsGone']:
                break
        try:
            process.wait(timeout=max(0.01, min(2, deadline - time.monotonic())))
            proof['leaderReaped'] = True
            live = self.refresh()
            proof['ownedDescendantsGone'] = not live and not self.ambiguous
            proof['remaining'] = list(live.values())
            proof['ambiguous'] = list(self.ambiguous.values())
        except BaseException as error:
            proof['errors'].append({'type': type(error).__name__, 'message': str(error)})
        return proof
