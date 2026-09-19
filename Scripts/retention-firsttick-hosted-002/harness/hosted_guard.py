"""One in-process aggregate guard per stage; never supervise another runner."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import time

from guarded_runner import GuardedRunner, allocated, error_record

AGGREGATE_BYTES = 1536 * 2**20
AGGREGATE_SECONDS = 240 * 60
PACKET_BYTES = 512 * 2**20
LOG_BYTES = 32 * 2**20
FREE_BYTES = int(12.5 * 2**30)
RESERVE = 30
ARTIFACT_RESERVE = 300
ORDER = ['toolchain', 'baseline-fetch', 'baseline-prepare', 'baseline-build', 'baseline-run',
         'bounded-fetch', 'bounded-prepare', 'bounded-build', 'bounded-run', 'finalize']
ACTIVE = None

def require(ok, message):
    if not ok: raise ValueError(message)

def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()

def read(path):
    require(path.is_file() and not path.is_symlink(), 'regular receipt required: '+str(path))
    return json.loads(path.read_text())

def save(path, value):
    # No replacement or retry. A partial/failed write remains failure evidence.
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')

def packet_check(packet, expected):
    require(re.fullmatch(r'[0-9a-f]{64}', expected or '') and
            digest(packet/'PACKET-SEAL.json') == expected, 'reviewed packet seal required')
    seal = read(packet/'PACKET-SEAL.json')
    actual = {str(path.relative_to(packet)) for path in packet.rglob('*') if path.is_file() or path.is_symlink()}
    require(actual == set(seal['files']) | {'PACKET-SEAL.json'}, 'unexpected packet input')
    for name, fact in seal['files'].items():
        path = packet/name
        require(path.resolve().is_relative_to(packet) and not path.is_symlink() and
                path.is_file() and path.stat().st_size == fact['bytes'] and
                digest(path) == fact['sha256'], 'sealed packet drift: '+name)
    required = {'hosted.py', 'harness/hosted_guard.py', 'harness/run.py', 'harness/guarded_runner.py',
                'harness/prepare.py', 'harness/validate.py', 'harness/supervise.py', 'harness/probe.cpp',
                'harness/CMakeLists.txt', 'CONFIG.json', 'PRESERVATION.json'}
    require(required <= set(seal['files']), 'missing executable seal input')
    return seal

def context():
    require(__debug__ and platform.system() == 'Linux' and platform.machine() == 'x86_64',
            'nonoptimized Python on x86_64 Linux required')
    root = Path(os.environ['RETENTION_HOSTED_ROOT'])
    metadata = {'runID':os.environ['GITHUB_RUN_ID'], 'attempt':os.environ['GITHUB_RUN_ATTEMPT'],
                'workflowCommit':os.environ['GITHUB_SHA'], 'repository':os.environ['GITHUB_REPOSITORY']}
    require(re.fullmatch(r'[0-9]+',metadata['runID']) and metadata['attempt'] == '1' and
            re.fullmatch(r'[0-9a-f]{40}',metadata['workflowCommit']), 'one-shot hosted metadata required')
    expected = Path.home()/'localdev'/('lattice-retention-firsttick-'+metadata['runID']+'-1')
    require(root == expected and root.resolve() == root and root.is_dir(), 'owned fresh localdev root required')
    packet = root/'packet'
    seal = os.environ['RETENTION_PACKET_SEAL_SHA256']
    packet_check(packet, seal)
    config = read(packet/'CONFIG.json')
    boot = read(root/'BOOTSTRAP.json')
    require(boot['hosted'] == metadata and boot['root'] == str(root), 'bootstrap identity drift')
    require(boot['bootID'] == Path('/proc/sys/kernel/random/boot_id').read_text().strip(), 'host boot changed')
    require(type(boot['startedMonotonic']) in (float,int) and
            0 < boot['startedMonotonic'] <= time.monotonic(), 'invalid admission start')
    admission_path = root/'ADMISSION.json'
    raw = admission_path.read_bytes()
    require(not admission_path.is_symlink() and len(raw) <= 32768 and
            hashlib.sha256(raw).hexdigest() == os.environ['RETENTION_ADMISSION_SHA256'], 'admission byte drift')
    wanted = {'schemaVersion':1, 'packetSealSHA256':seal, 'workflowCommit':metadata['workflowCommit'],
              'attempt':'1', 'executionAdmitted':True, 'sources':config['sources'],
              'aggregate':config['aggregate'], 'perPacket':config['perPacket'],
              'protocolParentReviewSHA256':config['protocolParentReviewSHA256']}
    require(json.loads(raw) == wanted, 'exact separate root admission required')
    require(config['aggregate'] == {'bytes':AGGREGATE_BYTES,'seconds':AGGREGATE_SECONDS,
            'cleanupReserveSeconds':RESERVE,'artifactReserveSeconds':ARTIFACT_RESERVE},
            'aggregate limits changed')
    if (root/'TOOLCHAIN-INPUTS.json').exists():
        for name,fact in read(root/'TOOLCHAIN-INPUTS.json').items():
            path=Path(name)
            require(str(path.resolve(strict=True))==fact['resolved'] and
                    path.stat().st_size==fact['bytes'] and digest(path)==fact['sha256'], 'tool input changed')
    return root, {'seal':seal, 'bootstrapSHA256':digest(root/'BOOTSTRAP.json'),
                  'admissionSHA256':digest(admission_path), 'started':boot['startedMonotonic'],
                  'deadline':boot['startedMonotonic']+AGGREGATE_SECONDS-ARTIFACT_RESERVE,
                  'aggregateDeadline':boot['startedMonotonic']+AGGREGATE_SECONDS, 'hosted':metadata}

def verify_arm(root, arm):
    require(arm in ['baseline','bounded'], 'unknown source arm')
    packet = root/arm; template = root/'packet'
    for name in ['SOURCE-CONFIG.json','SOURCE-MANIFEST.json']:
        require(digest(packet/name) == digest(template/'sources'/arm/name), 'source binding drift: '+arm+'/'+name)
    manifest = read(packet/'HARNESS-SOURCE.json')
    config = read(packet/'SOURCE-CONFIG.json')
    require(manifest['source'] == config['source'] and manifest['tree'] == config['tree'], 'harness source identity')
    actual = {str(p.relative_to(packet/'harness')) for p in (packet/'harness').rglob('*') if p.is_file()}
    require(actual == set(manifest['files']), 'harness file inventory drift')
    for name, fact in manifest['files'].items():
        path = packet/'harness'/name
        require(not path.is_symlink() and path.stat().st_size == fact['bytes'] and
                digest(path) == fact['sha256'] == digest(template/'harness'/name), 'harness drift: '+name)

def verify_materialized_source(root, arm):
    source=root/arm/'source'
    if not source.exists(): return
    expected=read(root/arm/'SOURCE-MANIFEST.json')['files']
    actual={str(p.relative_to(source)) for p in source.rglob('*') if p.is_file() or p.is_symlink()}
    require(actual==set(expected),'complete exported source inventory drift')
    for name,fact in expected.items():
        path=source/name
        require(not path.is_symlink() and path.stat().st_size==fact['bytes'] and
                digest(path)==fact['sha256'],'exported source drift: '+arm+'/'+name)

def limits(sample):
    if sample['freeBytes'] < FREE_BYTES: return 'disk floor'
    if sample['aggregateBytes'] > AGGREGATE_BYTES: return 'aggregate artifact ceiling'
    if any(value > PACKET_BYTES for value in sample.get('armBytes',{}).values()): return 'source packet ceiling'
    return None

class AggregateRunner(GuardedRunner):
    def __init__(self, *args, **kwargs):
        require(ACTIVE is not None, 'active authenticated stage required')
        super().__init__(*args, **kwargs)
        self.aggregate_root, self.binding = ACTIVE.root, ACTIVE.binding
        require(self.root in [self.aggregate_root/'control',self.aggregate_root/'baseline',self.aggregate_root/'bounded'],
                'runner outside owned packet roots')
        require(self.free_floor == FREE_BYTES and self.packet_ceiling == PACKET_BYTES and
                self.log_ceiling == LOG_BYTES, 'original resource limits changed')
        self.overall_deadline = min(self.overall_deadline, self.binding['deadline'])
        self.work_deadline = min(self.work_deadline, self.binding['deadline']-RESERVE)
        ACTIVE.runners.append(self)

    def measure(self, log):
        sample = super().measure(log)
        sample['aggregateBytes'] = allocated(self.aggregate_root)
        sample['armBytes'] = {arm:allocated(self.aggregate_root/arm) for arm in ['baseline','bounded']}
        return sample

    def violation(self, sample):
        return super().violation(sample) or limits(sample)

    def run(self, label, argv, *, cwd, timeout=3600, require_full_timeout=False):
        # Never shorten a native command because the shared envelope is nearly
        # exhausted. Refuse it before launch, preserving the original timeout.
        return super().run(label, argv, cwd=cwd, timeout=timeout, require_full_timeout=True)

def prior_stages(receipts, name):
    index = ORDER.index(name); bound = {}
    expected = set(ORDER[:index])
    ends = {p.name.removesuffix('-END.json') for p in receipts.glob('*-END.json')}
    starts = {p.name.removesuffix('-START.json') for p in receipts.glob('*-START.json')}
    require(ends == starts == expected, 'stage order, incomplete predecessor or retry refused')
    for prior in ORDER[:index]:
        path = receipts/(prior+'-END.json'); value = read(path)
        require(value['stage'] == prior and value['success'] and value['primaryError'] is None and
                not value['evidenceErrors'] and not value['receivedSignals'], 'failed predecessor: '+prior)
        for command in value['commands']:
            require(digest(Path(command['receipt'])) == command['sha256'], 'predecessor command receipt drift')
            require(digest(Path(command['log'])) == command['logSHA256'], 'predecessor command log drift')
        bound[prior] = digest(path)
    return bound

class Stage:
    def __init__(self, name):
        self.name = name; self.runners = []; self.root = None; self.binding = None

    def __enter__(self):
        global ACTIVE
        require(ACTIVE is None and self.name in ORDER, 'no nested supervisor or unknown stage')
        self.root, self.binding = context()
        self.receipts = self.root/'hosted-receipts'; self.receipts.mkdir(exist_ok=True)
        self.prior = prior_stages(self.receipts,self.name)
        require(time.monotonic() < self.binding['deadline']-RESERVE, 'aggregate admission deadline')
        for arm in ['baseline','bounded']: verify_arm(self.root,arm)
        save(self.receipts/(self.name+'-START.json'), {'stage':self.name,'binding':self.binding,
             'priorStages':self.prior,'startedMonotonic':time.monotonic()})
        ACTIVE = self
        return self

    def __exit__(self, kind, error, traceback):
        global ACTIVE
        result = {'stage':self.name, 'binding':self.binding, 'priorStages':self.prior,
                  'success':False, 'primaryError':error_record(error) if error else None,
                  'evidenceErrors':[], 'commands':[], 'receivedSignals':[]}
        def check(name, action):
            try: action()
            except BaseException as caught: result['evidenceErrors'].append({'check':name,'error':error_record(caught)})
        def commands():
            for runner in self.runners:
                result['receivedSignals'].extend(runner.interrupts.received)
                for item in runner.records:
                    path = runner.receipts/(item['label']+'.json'); record = read(path)
                    cleanup = record['cleanup']
                    log = runner.receipts/(item['label']+'.log')
                    result['commands'].append({'receipt':str(path),'sha256':digest(path),
                        'log':str(log),'logSHA256':record.get('logSHA256')})
                    require(record['success'] and record['exitCode'] == 0 and not record['primaryError'] and
                            not record['evidenceErrors'] and not record['receivedSignals'] and
                            not record.get('stopReason') and cleanup['groupGone'] and cleanup['leaderReaped'] and
                            not cleanup['errors'] and not cleanup['signals'], 'unclean command: '+item['label'])
                    require(digest(log) == record['logSHA256'], 'command log changed')
        def resources():
            import shutil
            sample = {'freeBytes':shutil.disk_usage(self.root).free,'aggregateBytes':allocated(self.root),
                      'armBytes':{arm:allocated(self.root/arm) for arm in ['baseline','bounded']}}
            result['finalResources'] = sample
            require(limits(sample) is None, 'final aggregate/perpacket resource refusal')
            result['completedMonotonic'] = time.monotonic()
            deadline = min([self.binding['deadline']]+[r.overall_deadline for r in self.runners])
            result['finalDeadline'] = deadline
            require(result['completedMonotonic'] <= deadline, 'final absolute/stage deadline')
        def custody():
            root, binding = context(); require(root == self.root and binding == self.binding, 'stage binding changed')
            for arm in ['baseline','bounded']:
                verify_arm(root,arm); verify_materialized_source(root,arm)
            for prior,digest_ in self.prior.items():
                require(digest(self.receipts/(prior+'-END.json')) == digest_, 'predecessor result changed')
        try:
            check('commands',commands); check('sourceAndAdmission',custody); check('resources',resources)
            result['success'] = error is None and not result['evidenceErrors'] and not result['receivedSignals']
            save(self.receipts/(self.name+'-END.json'),result)
        finally: ACTIVE = None
        if error is None: require(result['success'],'hosted stage final evidence failed')
        return False
