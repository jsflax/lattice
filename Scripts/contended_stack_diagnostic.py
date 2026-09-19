"""Opt-in observation inside GuardedRunner; never launches or owns a Swift test.

Reuses the existing bounded sampler and macOS identity helpers. Diagnostic
claims do not authenticate CI, establish a hang, or qualify product latency.
"""
import importlib.util
import os
from pathlib import Path
import re
import secrets
import socket
import sys
import tempfile
import time

ENABLE = 'LATTICE_CONTENDED_STACK_DIAGNOSTIC'
SOCKET = 'LATTICE_CONTENDED_MARKER_SOCKET'
NONCE = 'LATTICE_CONTENDED_MARKER_NONCE'
LIMIT = 48
LINE_LIMIT = 512
STALL_SECONDS = 60.0
MARKER = re.compile(rb'CONTENDED_PHASE_V1 ([0-9a-f]{32}) ([1-9][0-9]{0,9}) ([1-9][0-9]?) ([a-z_]{1,40}) ([0-9]{1,20}) ([0-9]{1,10}) ([a-z_]{1,16}) ([A-Za-z0-9_.-]{1,32}) ([0-9]{1,10}) ([0-9]{1,10})\n')
PHASES = frozenset('marker_overflow test_begin test_end harness_begin harness_end warm_send_begin warm_send_end warm_poll_begin warm_poll_end holder_spawn_begin holder_spawn_end held_poll_begin held_poll_end pipe_held pipe_released pipe_eof upload_send_begin upload_send_end nack_poll_begin nack_poll_end release_attempt release_admitted release_duplicate stdin_write_begin stdin_write_end stdin_close_begin stdin_close_end wait_begin wait_end release_return deadline_wake deadline_release_begin deadline_release_end deadline_complete deadline_join_begin deadline_join_end post_checks_begin post_checks_end shutdown_begin shutdown_end durable_check_begin durable_check_end storage_cleanup_begin storage_cleanup_end'.split())


def expected_argv(root):
    common = []
    for flag, suffix in [('package', 'lattice'), ('scratch', 'scratch'), ('cache', 'cache'), ('config', 'config'), ('security', 'security')]:
        common += ['--' + flag + '-path', str(root / suffix)]
    return ['swift', 'test', *common, '--disable-sandbox', '--disable-experimental-prebuilts', '--force-resolved-versions', '--skip-build']


def admit(root, argv, timeout, env, platform):
    if (platform != 'darwin' or env.get(ENABLE) != '1' or
        env.get('GITHUB_ACTIONS') != 'true' or env.get('GITHUB_JOB') != 'development' or
        env.get('DEVELOPMENT_LEG') != 'macos' or
        not all(re.fullmatch(r'[1-9][0-9]*', env.get(k, '')) for k in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'))):
        raise ValueError('diagnostic requires explicit hosted macOS development admission claims')
    if timeout != 1800 or argv != expected_argv(root):
        raise ValueError('diagnostic requires unchanged 1800s full-suite argv')


def decode(data, nonce):
    match = MARKER.fullmatch(data) if len(data) <= LINE_LIMIT else None
    if match is None:
        raise ValueError('malformed or oversized phase marker')
    token, pid, seq, phase, ticks, holder, caller, value, drops, log_errors = match.groups()
    row = dict(pid=int(pid), sequence=int(seq), phase=phase.decode(), ticks=int(ticks),
               holderPID=int(holder), caller=caller.decode(), value=value.decode(),
               senderDrops=int(drops), senderLogErrors=int(log_errors))
    if (token.decode() != nonce or row['phase'] not in PHASES or not 1 <= row['sequence'] <= LIMIT or
        not 1 < row['pid'] <= 2147483647 or not 0 <= row['holderPID'] <= 2147483647 or
        row['ticks'] >= 2**64):
        raise ValueError('phase marker identity, phase, sequence or clock out of bounds')
    return row


class Diagnostic:
    def __init__(self, root, receipts, argv, timeout, env):
        admit(root, argv, timeout, env, sys.platform)
        self.root, self.receipts = root, receipts
        self.sock = self.socket_dir = self.directory = self.mac = self.helpers = None
        self.driver = self.chain = self.holder = self.capture = None
        self.due = None
        self.last_sequence = 0
        self.claimed = self.disabled = self.terminal = False
        self.event = {'schema': 'lattice.contended-owned-stack/1', 'enabled': True,
                      'markers': [], 'errors': [], 'sequenceGaps': [], 'targetChecks': [],
                      'holderChecks': [], 'capture': None, 'captureAttemptLimit': 1,
                      'markerLimit': LIMIT, 'markerByteLimit': LINE_LIMIT,
                      'stallSeconds': STALL_SECONDS, 'nativeLaunchedByDiagnostic': False,
                      'latencyQualified': False, 'ciClaimsAuthenticatedByDiagnostic': False,
                      'scope': 'owned thread stack after an unfinished case marker; not proof of a hang or all suspended async tasks',
                      'limits': ['Datagrams may be lost; missing terminal marker is not proof of a hung case.',
                                 'Attachment by PID is non-atomic despite birth and ancestry rechecks.',
                                 'Sampling can perturb scheduling and timing.',
                                 'Forced sampler termination leaves target resume state unknown.']}

    def error(self, where, error):
        if len(self.event['errors']) < 16:
            self.event['errors'].append({'where': where, 'error': (type(error).__name__ + ': ' + str(error))[:600]})
        else:
            self.event['errorsOmitted'] = True
        self.disabled = True
        self.due = None

    def prepare(self, env):
        # Default-off callers never construct this observer. Stale external
        # marker routing is not trusted, even on an explicitly enabled run.
        env = dict(env)
        env.pop(SOCKET, None); env.pop(NONCE, None)
        try:
            spec = importlib.util.spec_from_file_location('contended_sample_helpers', Path(__file__).with_name('capture-wrapper-live-stack.py'))
            self.helpers = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.helpers)
            self.directory = self.receipts / 'contended-stack'
            self.directory.mkdir(exist_ok=False)
            self.mac = self.helpers.Mac()
            self.event['helper'] = self.helpers.file_pin(str(Path(__file__).with_name('capture-wrapper-live-stack.py')), self.helpers.REPORT_LIMIT)
            self.event['samplerTool'] = self.helpers.file_pin(self.helpers.SAMPLE, self.helpers.REPORT_LIMIT)
            self.event['timebase'] = self.mac.timebase
            self.socket_dir = Path(tempfile.mkdtemp(prefix='contended-', dir=self.root / 'tmp'))
            path = str(self.socket_dir / 'm')
            if len(os.fsencode(path)) > 100:
                raise ValueError('owned marker socket exceeds macOS pathname bound')
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            self.sock.setblocking(False); self.sock.set_inheritable(False)
            self.sock.bind(path); os.chmod(path, 0o600)
            self.event['nonce'] = secrets.token_hex(16)
            self.event['setupTicks'] = self.mac.ticks()
            env[SOCKET], env[NONCE] = path, self.event['nonce']
        except Exception as exc:
            self.error('prepare', exc)
        return env

    def started(self, process):
        if not self.disabled:
            try:
                self.driver = self.mac.identity(process.pid)
                if self.driver['pgid'] != process.pid:
                    raise ValueError('Swift command is not the existing owned session leader')
                self.event['driver'] = self.driver
            except Exception as exc:
                self.error('owned driver', exc)

    def accept(self, row, receipt_ticks, now):
        if row['ticks'] < self.event['setupTicks'] or row['ticks'] > receipt_ticks:
            raise ValueError('marker clock outside observed run')
        if row['sequence'] <= self.last_sequence or self.terminal:
            raise ValueError('duplicate, reordered or post-terminal marker')
        if row['sequence'] != self.last_sequence + 1:
            self.event['sequenceGaps'].append([self.last_sequence + 1, row['sequence'] - 1])
        if self.chain is None:
            if row['sequence'] != 1 or row['phase'] != 'test_begin':
                raise ValueError('missing first test-begin marker; no attachment admission')
            self.chain = self.mac.ancestry(row['pid'], self.driver)
            if any(x['pgid'] != self.driver['pgid'] for x in self.chain):
                raise ValueError('test descendant outside owned process group')
            self.event['targetChecks'].append({'phase': 'begin', 'chain': self.chain})
            self.due = now + STALL_SECONDS
        elif row['pid'] != self.chain[0]['pid']:
            raise ValueError('marker changed test process')
        if row['holderPID'] and self.holder is None:
            chain = self.mac.ancestry(row['holderPID'], self.driver)
            if (len(chain) < 3 or chain[1]['pid'] != row['pid'] or
                any(x['pgid'] != self.driver['pgid'] for x in chain)):
                raise ValueError('holder is not the admitted test process child in the owned group')
            self.holder = chain[0]
            self.event['holderChecks'].append({'phase': 'admitted', 'identity': self.holder})
        elif row['holderPID'] and row['holderPID'] != self.holder['pid']:
            raise ValueError('marker changed holder PID')
        self.last_sequence = row['sequence']
        row['receiptTicks'] = receipt_ticks
        self.event['markers'].append(row)
        if row['phase'] == 'marker_overflow':
            raise ValueError('sender phase-marker bound exhausted')
        if row['phase'] == 'test_end':
            self.terminal = True
            self.due = None

    def holder_check(self, phase):
        if self.holder is None:
            return
        try:
            current = self.mac.identity(self.holder['pid'])
            self.event['holderChecks'].append({'phase': phase, 'identity': current,
                                              'sameBirthAndImage': current == self.holder})
        except Exception as exc:
            # A failed identity read does NOT prove absence (permissions and
            # zombies can also lack a readable executable image).
            row = {'phase': phase, 'identityUnavailable': str(exc)[:600], 'absenceProven': False}
            try:
                os.kill(self.holder['pid'], 0)  # existence probe, never a target signal
            except ProcessLookupError:
                row['absenceProven'] = True
            except OSError as probe_error:
                row['existenceProbeError'] = str(probe_error)[:600]
            self.event['holderChecks'].append(row)

    def tick(self, deadline):
        try:
            if self.sock is not None and not self.disabled:
                for _ in range(LIMIT + 1):
                    try:
                        data = self.sock.recv(LINE_LIMIT + 1)
                    except BlockingIOError:
                        break
                    if len(self.event['markers']) >= LIMIT:
                        raise ValueError('phase marker count exceeds bound')
                    self.accept(decode(data, self.event['nonce']), self.mac.ticks(), time.monotonic())
            if not self.disabled and self.due is not None and time.monotonic() >= self.due and not self.claimed:
                self.claimed = True; self.due = None
                if deadline - time.monotonic() < 5:
                    self.event['captureSkipped'] = 'existing command deadline cannot fit sampler budget'
                else:
                    chain = self.mac.ancestry(self.chain[0]['pid'], self.driver)
                    if not self.helpers.same_chain(chain, self.chain):
                        raise ValueError('test process identity/ancestry changed before capture')
                    self.event['targetChecks'].append({'phase': 'before-capture', 'chain': chain})
                    self.holder_check('before-capture')
                    self.capture = self.helpers.Capture(str(self.directory), self.chain[0]['pid'], self.mac)
            if self.capture is not None:
                self.capture.pump()
                if self.capture.finished and not self.capture.after_checked:
                    self.capture.check_after(self.driver, self.chain, self.event['targetChecks'])
                    self.holder_check('after-capture')
        except Exception as exc:
            self.error('observe', exc)
            if self.capture is not None and not self.capture.finished:
                self.capture.stop('diagnostic observation failed')

    def finish(self):
        try:
            # Drain already-sent terminal markers, but never launch a sampler
            # during owner finalization or extend its existing command deadline.
            self.tick(0)
            if self.capture is not None:
                if not self.capture.finished:
                    self.capture.stop('owned command is finalizing')
                    while not self.capture.finished and time.monotonic() < self.capture.end:
                        self.capture.pump()
                        time.sleep(.02)
                self.capture.check_after(self.driver, self.chain, self.event['targetChecks'])
                self.event['capture'] = self.capture.row
                self.event['targetIdentityStableAfterCapture'] = self.capture.identity_stable
                self.helpers.write_once(str(self.directory / 'sampler-diagnostics.bin'), bytes(self.capture.output))
                if (self.directory / 'sample.txt').exists():
                    self.event['report'] = self.helpers.file_pin(str(self.directory / 'sample.txt'), self.helpers.REPORT_LIMIT)
            self.event.update(terminalMarkerObserved=self.terminal, captureClaimConsumed=self.claimed,
                              senderDropsObserved=max((m['senderDrops'] for m in self.event['markers']), default=0),
                              senderLogErrorsObserved=max((m['senderLogErrors'] for m in self.event['markers']), default=0))
        except Exception as exc:
            self.error('finalize', exc)
        finally:
            if self.sock is not None:
                self.sock.close()
            if self.socket_dir is not None:
                try:
                    (self.socket_dir / 'm').unlink(missing_ok=True)
                    self.socket_dir.rmdir()
                except Exception as exc:
                    self.error('marker socket cleanup', exc)
        capture = self.event['capture']
        capture_clean = capture is None or (
            capture.get('spawned') and capture.get('reaped') and capture.get('groupAbsent') is True and
            capture.get('returncode') == 0 and capture.get('withinBudget') is True and
            not capture.get('forcedStop') and not capture.get('errors') and
            self.event.get('targetIdentityStableAfterCapture') is True)
        self.event['diagnosticComplete'] = bool(
            self.terminal and self.event['markers'] and not self.event['errors'] and
            not self.event['sequenceGaps'] and not self.event.get('senderDropsObserved', 1) and
            not self.event.get('senderLogErrorsObserved', 1) and capture_clean and
            not self.event.get('captureSkipped') and (not self.claimed or capture is not None))
        self.event['nativeOutcomeOwnedByGuardedRunner'] = True
        return self.event
