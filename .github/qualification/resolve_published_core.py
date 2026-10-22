"""Resolve one actual published Core into an exact copied Swift consumer; no product build/test."""
from pathlib import Path, PurePosixPath
import argparse, datetime, hashlib, json, os, pwd, re, signal, stat, subprocess, time
import urllib.request

SDK_REPOSITORY = 'jsflax/lattice'
SDK_COMMIT = '6c3598f2d8d4994c88d7119c457dd0a15345a842'
CORE_COMMIT = '89e758ba4e9710596afe569ebd1817ada0dc3162'
CORE_VERSION = '2.2.4'
CORE_RELEASE_ID = 421199598
CORE_PUBLISHED_AT = '2026-10-22T21:02:13Z'
MANIFEST_SHA = '8a2916d44e88d18053620b4da21173595d8243b178c5b62dad6f6819d7bf5cdb'
LOCK_SHA = '674e1bfcfd681f4b03b51ebd96f01f15ba81c5807b2e57164887bfefef420294'
COLD_TEST = 'Tests/LatticeTests/SyncTests/ColdIPCVectorInitializationTests.swift'
COLD_SHA = 'a74a163247c87b50783584406ccd63e8390e0edeb0023c35502ee834bca41631'
OLD_REQUIREMENT = '        .package(url: "https://github.com/jsflax/LatticeCore.git", from: "2.2.2"),\n'
NEW_REQUIREMENT = ('        // 2.2.4 initializes cold vector indexes atomically so first vector reads\n'
                   '        // include synced rows without reopening the store.\n'
                   '        .package(url: "https://github.com/jsflax/LatticeCore.git", from: "2.2.4"),\n')
GLOBAL_SECONDS = 1200
RESOLVE_SECONDS = 600
SOURCE_BYTES = 128 * 1024 * 1024
FLOOR = 12 * 1024**3
GROWTH = 16 * 1024**3
LOG_CEILING = 1024**3


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def file_fact(path):
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError('regular observed body required: ' + str(path))
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            h.update(chunk)
    after = path.lstat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode):
        raise RuntimeError('observed body changed: ' + str(path))
    return dict(path=str(path), bytes=after.st_size, sha256=h.hexdigest(), mode=oct(stat.S_IMODE(after.st_mode)))


def secure_directory(path):
    if not path.is_absolute() or path != Path(os.path.normpath(path)):
        raise RuntimeError('normalized actual directory required')
    current = Path('/')
    for part in path.parts[1:]:
        current /= part
        s = current.lstat()
        if not stat.S_ISDIR(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_uid not in (0, os.geteuid()) or s.st_mode & 0o022:
            raise RuntimeError('actual directory ancestry owner/mode differs')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        raise RuntimeError('unexpected API redirect refused')


def api_json(path, output):
    request = urllib.request.Request('https://api.github.com/repos/' + path, headers={
        'Authorization': 'Bearer ' + os.environ['RESOLUTION_CONTENTS_TOKEN'],
        'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'lattice-core-resolution'})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
        if response.status != 200:
            raise RuntimeError('actual API response is not complete success')
        raw = response.read(2*1024*1024 + 1)
    if len(raw) > 2*1024*1024:
        raise RuntimeError('actual API evidence exceeds finite ceiling')
    with output.open('xb') as stream:
        stream.write(raw)
    return json.loads(raw)


def group_state(pgid):
    try:
        os.killpg(pgid, 0)
        return dict(absent=False, error=None)
    except ProcessLookupError:
        return dict(absent=True, error=None)
    except OSError as error:
        return dict(absent=None, error=dict(errno=error.errno, message=str(error)))

def run_stage(out, name, command, work, env, cap, floor, growth, log_ceiling, purpose):
    started = time.monotonic()
    row = dict(stage=name, purpose=purpose, command=command, cwd=str(work), capSeconds=cap, signals=[], signalErrors=[],
               stopReason=None, nativeTestBodiesIssued=False, nativeDiscoveryIssued=False,
               globalDescendantEndingNotClaimed=True, leaderReaped=False, processGroupAbsent=None)
    process = None
    disk = os.statvfs(out)
    first_free = disk.f_bavail * disk.f_frsize
    row['minimumFreeBytes'] = first_free
    stdout_path, stderr_path = out/(name+'.stdout'), out/(name+'.stderr')
    with stdout_path.open('xb') as stdout, stderr_path.open('xb') as stderr:
        try:
            if first_free < floor:
                raise RuntimeError('disk admission floor before original child launch')
            process = subprocess.Popen(command, cwd=work, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
            row.update(pid=process.pid, nativeTestBodiesIssued=(purpose in ('installed-role','data-tests')),
                       nativeDiscoveryIssued=('--gtest_list_tests' in command),
                       nativeDiscoveryMayBeIssuedByBuild=(purpose=='build'))
            row.update(pgid=os.getpgid(process.pid),sid=os.getsid(process.pid))
            row['actualOriginalSessionGroup'] = row['pid'] == row['pgid'] == row['sid']
            if not row['actualOriginalSessionGroup']:
                raise RuntimeError('actual original session/group identity differs')
            write_json(out/'CURRENT.json', row)
            while process.poll() is None:
                disk = os.statvfs(out)
                free = disk.f_bavail * disk.f_frsize
                row['minimumFreeBytes'] = min(row['minimumFreeBytes'], free)
                if free < floor:
                    row['stopReason'] = 'disk floor'
                    break
                if first_free-free > growth:
                    row['stopReason'] = 'admitted free-space growth ceiling'
                    break
                if stdout_path.stat().st_size+stderr_path.stat().st_size > log_ceiling:
                    row['stopReason'] = 'retained log growth ceiling'
                    break
                if time.monotonic()-started >= cap:
                    row['stopReason'] = 'original stage deadline'
                    break
                time.sleep(0.25)
        except BaseException as error:
            row['stopReason'] = row['stopReason'] or repr(error)
        finally:
            if process is not None:
                # Match the proven supplied run_stage custody semantics:
                # returncode None means the actual child is still unreaped,
                # reserving its PID even if it exits just before this signal.
                # Once wait/poll reaps it, no further group signal is allowed.
                if row['stopReason'] and row.get('actualOriginalSessionGroup') and process.returncode is None:
                    for sig in (signal.SIGTERM,signal.SIGKILL):
                        if process.returncode is not None:
                            break
                        try:
                            os.killpg(process.pid, sig)
                            row['signals'].append(int(sig))
                        except OSError as error:
                            row['signalErrors'].append(dict(signal=int(sig), errno=error.errno, message=str(error)))
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            pass
                try:
                    row['exitCode'] = process.wait(timeout=5)
                    row['leaderReaped'] = True
                except subprocess.TimeoutExpired:
                    row['exitCode'] = None
                if row['leaderReaped'] and row.get('actualOriginalSessionGroup'):
                    end = time.monotonic()+5
                    state = group_state(row['pgid'])
                    while state['absent'] is False and time.monotonic() < end:
                        time.sleep(0.05)
                        state = group_state(row['pgid'])
                    row['processGroupAbsent'], row['groupQueryError'] = state['absent'], state['error']
                    if state['absent'] is not True:
                        row['stopReason'] = row['stopReason'] or 'original group ending unproved; no post-reap signal'
            else:
                row.update(exitCode=None, noChildIssued=True)
    row['knownEnding'] = bool(row['leaderReaped'] and row.get('actualOriginalSessionGroup') and row['processGroupAbsent'] is True)
    if row['knownEnding'] or process is None:
        disk = os.statvfs(out)
        free = disk.f_bavail * disk.f_frsize
        row['minimumFreeBytes'] = min(row['minimumFreeBytes'],free)
        row['finalFreeBytes'] = free
        if free < floor or first_free-free > growth or stdout_path.stat().st_size+stderr_path.stat().st_size > log_ceiling:
            row['stopReason'] = row['stopReason'] or 'actual final disk/log admission exceeded'
    row['elapsedSeconds'] = time.monotonic()-started
    row['stageSucceeded'] = bool(row['knownEnding'] and row['exitCode'] == 0 and not row['stopReason'])
    row['nativeOwnedOriginalEndingsUnproved'] = process is not None and purpose in ('real-installer','installed-role') and not row['stageSucceeded']
    # A live/unknown group may still own output. Preserve paths without reading,
    # hashing or parsing it; Root must settle that exact original before reuse.
    if (row['knownEnding'] and not row['nativeOwnedOriginalEndingsUnproved']) or process is None:
        row['stdout'], row['stderr'] = file_fact(stdout_path), file_fact(stderr_path)
    write_json(out/(name+'.json'), row)
    return row


def pins_by_identity(lock):
    if not isinstance(lock, dict) or not isinstance(lock.get('pins'), list) or len(lock['pins']) != 34:
        raise RuntimeError('exact raw34-pin lock required')
    pins = lock['pins']
    if any(not isinstance(pin, dict) or not isinstance(pin.get('identity'), str) for pin in pins):
        raise RuntimeError('complete actual pin objects required')
    indexed = {pin['identity']: pin for pin in pins}
    if len(indexed) != 34 or 'latticecore' not in indexed:
        raise RuntimeError('exact34 unique pin identities required')
    return indexed


def source_snapshot(root, expected, overrides=None, frozen=False):
    overrides = overrides or {}
    actual = set()
    for path in root.rglob('*'):
        relative = str(path.relative_to(root))
        if relative == '.git' or relative.startswith('.git/'):
            continue
        if path.is_symlink():
            raise RuntimeError('source symlink differs from closed regular inventory')
        if path.is_file():
            actual.add(relative)
    if actual != set(expected):
        raise RuntimeError('complete original/copied source census changed')
    result = []
    for name, row in sorted(expected.items()):
        fact = file_fact(root/name)
        wanted = overrides.get(name, row['sha256'])
        mode = '0o444' if frozen else oct(int(row['gitMode'], 8) & 0o777)
        if fact['sha256'] != wanted or fact['mode'] != mode:
            raise RuntimeError('complete original/copied source body/mode changed: ' + name)
        result.append(dict(logicalPath=name, **fact))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, required=True)
    project = parser.parse_args().project_root
    home = Path(pwd.getpwuid(os.geteuid()).pw_dir)
    secure_directory(home)
    if os.uname().sysname != 'Darwin':
        raise RuntimeError('actual Darwin hosted resolution required')
    if not project.is_relative_to(home/'localdev'):
        raise RuntimeError('actual getpwuid-home/localdev project required')
    secure_directory(project)
    if stat.S_IMODE(project.stat().st_mode) != 0o700:
        raise RuntimeError('fresh private actual project required')
    evidence = project/'evidence'
    secure_directory(evidence)
    bootstrap = json.loads((project/'BOOTSTRAP.json').read_text())
    if bootstrap['actualUid'] != os.geteuid() or bootstrap['actualHome'] != str(home) or bootstrap['projectRoot'] != str(project) or bootstrap['repository'] != SDK_REPOSITORY:
        raise RuntimeError('actual bootstrap account/source identity differs')
    if bootstrap['controllerSHA256'] != file_fact(Path(__file__))['sha256']:
        raise RuntimeError('actual exact fetched controller differs')
    result = dict(state='RESOLUTION_INCOMPLETE_UNQUALIFIED', sourceCommit=SDK_COMMIT,
                  expectedPublishedCoreCommit=CORE_COMMIT, coreVersion=CORE_VERSION,
                  workflowRepository=bootstrap['repository'], workflowCommit=bootstrap['workflowCommit'],
                  runId=bootstrap['runId'], runAttempt=bootstrap['runAttempt'],
                  actualHost=list(os.uname()), actualHome=str(home), actualUid=os.geteuid(),
                  productBuildRequested=False, productTestsRequested=False, productGraphAccepted=False,
                  swiftPMManifestEvaluationExpected=True, globalDescendantEndingNotClaimed=True,
                  passed=False, stages=[])
    started = time.monotonic()
    env = os.environ.copy()
    env.pop('RESOLUTION_CONTENTS_TOKEN', None)
    overrides = {key: str(project/'tmp') for key in ('TMPDIR', 'TMP', 'TEMP', 'TEMPDIR', 'SQLITE_TMPDIR')}
    overrides.update({key: str(project/'module-cache') for key in ('CLANG_MODULE_CACHE_PATH', 'SWIFT_MODULECACHE_PATH', 'SWIFTPM_MODULECACHE_OVERRIDE')})
    overrides.update(GIT_TERMINAL_PROMPT='0', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
                     GIT_ASKPASS='/usr/bin/false', SSH_ASKPASS='/usr/bin/false')
    env.update(overrides)
    claimed = dict(result, environmentOverrides=overrides, controller=file_fact(Path(__file__)))
    with (evidence/'COMMAND.json').open('x') as stream:
        stream.write(json.dumps(claimed, indent=2) + '\n')

    def step(name, command, cap=30, purpose='metadata'):
        remaining = GLOBAL_SECONDS - (time.monotonic() - started)
        if remaining <= 0:
            raise RuntimeError('whole actual resolver admission deadline')
        row = run_stage(evidence, name, command, project, env, min(cap, remaining), FLOOR, GROWTH, LOG_CEILING, purpose)
        result['stages'].append(row)
        if not row['stageSucceeded']:
            raise RuntimeError('actual original stage failed/ending unproved: ' + name)
        return evidence/(name+'.stdout')

    try:
        release = api_json('jsflax/LatticeCore/releases/' + str(CORE_RELEASE_ID), evidence/'PUBLISHED-CORE-RELEASE.json')
        if any(release.get(k) != value for k, value in {'id': CORE_RELEASE_ID, 'tag_name': CORE_VERSION,
                'target_commitish': CORE_COMMIT, 'draft': False, 'prerelease': False,
                'published_at': CORE_PUBLISHED_AT,
                'html_url': 'https://github.com/jsflax/LatticeCore/releases/tag/'+CORE_VERSION}.items()):
            raise RuntimeError('actual published Core release identity differs')
        tag = api_json('jsflax/LatticeCore/git/ref/tags/' + CORE_VERSION, evidence/'PUBLISHED-CORE-TAG.json')
        if tag.get('ref') != 'refs/tags/'+CORE_VERSION or tag.get('object', {}).get('type') != 'commit' or tag.get('object', {}).get('sha') != CORE_COMMIT:
            raise RuntimeError('actual published Core tag commit differs')
        source = api_json(SDK_REPOSITORY+'/git/commits/'+SDK_COMMIT, evidence/'SDK-COMMIT.json')
        expected_tree = source.get('tree', {}).get('sha')
        if source.get('sha') != SDK_COMMIT or not isinstance(expected_tree, str) or not re.fullmatch('[0-9a-f]{40}', expected_tree):
            raise RuntimeError('actual fixed SDK commit/tree proof differs')
        result['publishedCoreProofObserved'] = True
        result['sourceTree'] = expected_tree
        baseline, prospective = project/'baseline', project/'prospective'
        step('git-init', ['/usr/bin/git', 'init', str(baseline)])
        step('git-fetch-exact-sdk', ['/usr/bin/git', '-C', str(baseline), 'fetch', '--depth=1', '--no-tags',
             'https://github.com/'+SDK_REPOSITORY+'.git', SDK_COMMIT], 120, 'source-checkout')
        step('git-checkout-exact-sdk', ['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-C', str(baseline), 'checkout', '--detach', SDK_COMMIT])
        commit = step('git-actual-commit', ['/usr/bin/git', '-C', str(baseline), 'rev-parse', 'HEAD']).read_text().strip()
        tree = step('git-actual-tree', ['/usr/bin/git', '-C', str(baseline), 'rev-parse', 'HEAD^{tree}']).read_text().strip()
        if commit != SDK_COMMIT or tree != expected_tree:
            raise RuntimeError('actual fetched commit/tree differs from exact published API object')
        if step('git-original-clean', ['/usr/bin/git', '-C', str(baseline), 'status', '--porcelain', '--untracked-files=all']).read_bytes():
            raise RuntimeError('actual fixed original SDK checkout is not clean')
        inventory = step('git-actual-full-tree', ['/usr/bin/git', '-C', str(baseline), 'ls-tree', '-r', '-z', '--full-tree', 'HEAD'])
        if inventory.stat().st_size > 8*1024*1024:
            raise RuntimeError('actual full tracked inventory exceeds ceiling')
        raw_inventory = inventory.read_bytes()
        if not raw_inventory.endswith(b'\0'):
            raise RuntimeError('incomplete actual tracked inventory')
        expected = {}
        total = 0
        prospective.mkdir(mode=0o700)
        for entry in raw_inventory[:-1].split(b'\0'):
            prefix, raw_name = entry.split(b'\t', 1)
            mode, kind, oid = prefix.decode('ascii').split(' ')
            name = raw_name.decode('utf-8')
            logical = PurePosixPath(name)
            if mode not in ('100644', '100755') or kind != 'blob' or not re.fullmatch('[0-9a-f]{40}', oid) or logical.is_absolute() or '..' in logical.parts or str(logical) != name or name in expected or logical.parts[0] == '.git':
                raise RuntimeError('closed whole actual tracked source inventory required')
            original = baseline/name
            if original.is_symlink() or not original.is_file():
                raise RuntimeError('regular actual tracked source required')
            size = original.stat().st_size
            if size > SOURCE_BYTES-total or len(expected) >= 10000:
                raise RuntimeError('complete copied source exceeds admitted finite ceiling')
            body = original.read_bytes()
            if len(body) != size or hashlib.sha1(b'blob '+str(len(body)).encode()+b'\0'+body).hexdigest() != oid:
                raise RuntimeError('actual source body differs from authenticated Git blob')
            total += len(body)
            expected[name] = dict(gitMode=mode, gitBlob=oid, bytes=len(body), sha256=hashlib.sha256(body).hexdigest())
            copied = prospective/name
            copied.parent.mkdir(parents=True, exist_ok=True)
            with copied.open('xb') as stream:
                stream.write(body)
            copied.chmod(int(mode, 8) & 0o777)
        if any(expected.get(name, {}).get('sha256') != wanted for name, wanted in [('Package.swift', MANIFEST_SHA), ('Package.resolved', LOCK_SHA), (COLD_TEST, COLD_SHA)]):
            raise RuntimeError('actual original manifest/lock/public cold controls differ')
        source_snapshot(baseline, expected)
        source_snapshot(prospective, expected)
        for name in expected:
            (baseline/name).chmod(0o444)
        write_json(evidence/'BASELINE-SOURCE.json', source_snapshot(baseline, expected, frozen=True))
        manifest, lock = prospective/'Package.swift', prospective/'Package.resolved'
        before_raw = lock.read_bytes()
        before = json.loads(before_raw)
        before_pins = pins_by_identity(before)
        if before.get('version') != 3:
            raise RuntimeError('actual original version3 lock required')
        original_manifest = manifest.read_text()
        if original_manifest.count(OLD_REQUIREMENT) != 1:
            raise RuntimeError('exact unique original Core floor required')
        manifest.write_text(original_manifest.replace(OLD_REQUIREMENT, NEW_REQUIREMENT, 1))
        manifest_sha = file_fact(manifest)['sha256']
        expected_overrides = {'Package.swift': manifest_sha}
        prepared_snapshot = source_snapshot(prospective, expected, expected_overrides)
        for folder in ('before', 'prospective-before', 'after'):
            (evidence/folder).mkdir(mode=0o700)
        (evidence/'before/Package.swift').write_bytes((baseline/'Package.swift').read_bytes())
        (evidence/'before/Package.resolved').write_bytes(before_raw)
        (evidence/'prospective-before/Package.swift').write_bytes(manifest.read_bytes())
        write_json(evidence/'PREPARED.json', dict(sourceCommit=commit, sourceTree=tree, sourceFiles=len(expected),
                   sourceBytes=total, originalManifestSHA256=MANIFEST_SHA, originalLockSHA256=LOCK_SHA,
                   prospectiveManifestSHA256=manifest_sha, publicColdTestSHA256=COLD_SHA,
                   fullSource=prepared_snapshot, originalCompletePins=before))
        version_output = step('swift-version', ['/usr/bin/swift', '--version']).read_text()
        match = re.search(r'Swift version (\d+)\.(\d+)', version_output)
        if match is None or tuple(map(int, match.groups())) < (6, 3):
            raise RuntimeError('actual Swift toolchain must support swift-tools-version6.3')
        step('actual-xcode-swift', ['/usr/bin/xcrun', '--find', 'swift'])
        help_text = step('swift-package-help', ['/usr/bin/swift', 'package', '--help']).read_text()
        for option in ('--manifest-cache', '--disable-experimental-prebuilts', '--scratch-path', '--cache-path', '--config-path', '--security-path', '--jobs'):
            if option not in help_text:
                raise RuntimeError('actual resolver lacks required explicit option: ' + option)
        command = ['/usr/bin/swift', 'package', '--package-path', str(prospective),
                   '--scratch-path', str(project/'scratch'), '--cache-path', str(project/'cache'),
                   '--config-path', str(project/'config'), '--security-path', str(project/'security'),
                   '--manifest-cache', 'local', '--disable-experimental-prebuilts', '--jobs', '2', 'resolve']
        result['resolveCommand'] = command
        step('swift-package-resolve', command, RESOLVE_SECONDS, 'resolve')
        # Every original must be known ended before reading actual resolver output/source.
        if not all(row['knownEnding'] for row in result['stages']):
            raise RuntimeError('actual original group ending unproved')
        after = json.loads(lock.read_bytes())
        after_pins = pins_by_identity(after)
        changed = sorted(name for name in before_pins.keys() | after_pins.keys() if before_pins.get(name) != after_pins.get(name))
        expected_core = dict(before_pins['latticecore'], state=dict(revision=CORE_COMMIT, version=CORE_VERSION))
        result.update(changedPinIdentities=changed, exactly34UniqueCompletePins=True,
                      allOther33CompletePinsUnchanged=(changed == ['latticecore'] and all(before_pins[k] == after_pins.get(k) for k in before_pins if k != 'latticecore')),
                      coreCompletePinMatchesActualPublishedRelease=(after_pins.get('latticecore') == expected_core),
                      otherRootFieldsUnchanged=({k:v for k,v in before.items() if k not in ('pins','originHash')} == {k:v for k,v in after.items() if k not in ('pins','originHash')}),
                      actualResolverOriginHash=after.get('originHash'),
                      manifestUnchanged=(file_fact(manifest)['sha256'] == manifest_sha))
        if not result['allOther33CompletePinsUnchanged'] or not result['coreCompletePinMatchesActualPublishedRelease'] or not result['otherRootFieldsUnchanged'] or not result['manifestUnchanged'] or after.get('version') != 3 or not isinstance(after.get('originHash'), str) or not re.fullmatch('[0-9a-f]{64}', after['originHash']):
            raise RuntimeError('actual resolver complete lock/manifest correspondence refused')
        expected_overrides['Package.resolved'] = file_fact(lock)['sha256']
        write_json(evidence/'AFTER-SOURCE.json', source_snapshot(prospective, expected, expected_overrides))
        write_json(evidence/'BASELINE-SOURCE-AFTER.json', source_snapshot(baseline, expected, frozen=True))
        if file_fact(prospective/COLD_TEST)['sha256'] != COLD_SHA:
            raise RuntimeError('actual public cold controls changed')
        (evidence/'after/Package.swift').write_bytes(manifest.read_bytes())
        (evidence/'after/Package.resolved').write_bytes(lock.read_bytes())
        result.update(state='EXACT_RESOLVER_OUTPUT_QUALIFIED_NOT_PRODUCT_GRAPH_ACCEPTANCE', passed=True,
                      baselineUnchanged=True, fullCopiedSourceCorrespondence=True, publicColdTestsUnchanged=True,
                      generatedManifest=file_fact(evidence/'after/Package.swift'), generatedLock=file_fact(evidence/'after/Package.resolved'))
    except BaseException as error:
        result['error'] = repr(error)
    result['allKnownOriginalEndings'] = bool(result['stages']) and all(row['knownEnding'] for row in result['stages'])
    result['elapsedSeconds'] = time.monotonic() - started
    result['finishedAtUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with (evidence/'RESULT.json').open('x') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
