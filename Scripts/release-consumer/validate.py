"""Fixed release-consumer checks; no processes, network or database access."""
import hashlib
import json
import re
from pathlib import Path

SHA = re.compile(r'[0-9a-f]{40}\Z')
HASH = re.compile(r'[0-9a-f]{64}\Z')
REPOS = {'sdk': 'https://github.com/jsflax/lattice.git',
         'core': 'https://github.com/jsflax/LatticeCore.git'}
TAGS = {'sdk': '2.0.0', 'core': '2.0.4'}
ACCEPTANCE = ('success', 'publicationAuthenticated', 'graphAccepted', 'consumerBuildPassed',
              'writerPassed', 'reopenPassed', 'consumerAccepted')

def require(condition, message):
    if not condition:
        raise ValueError(message)

def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result

def parse(text):
    return json.loads(text, object_pairs_hook=unique,
        parse_constant=lambda value: (_ for _ in ()).throw(ValueError('nonfinite JSON: ' + value)))

def load(path, limit=4 * 2**20):
    require(path.stat().st_size <= limit, 'JSON input too large: ' + str(path))
    return parse(path.read_text())

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()

def file_at(root, name):
    require(isinstance(name, str), 'missing input path')
    part = Path(name)
    require(not part.is_absolute() and '..' not in part.parts, 'input path escapes packet')
    path = root / part
    require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root.resolve()),
            'input is not an owned regular file: ' + name)
    return path

def pins(lock):
    require(lock.get('version') == 3 and isinstance(lock.get('pins'), list), 'unsupported lock shape')
    result = {}
    for pin in lock['pins']:
        identity = pin.get('identity')
        require(isinstance(identity, str) and identity and identity == identity.lower(), 'invalid pin identity')
        require(identity not in result, 'duplicate pin identity')
        state = pin.get('state', {})
        require(pin.get('kind') == 'remoteSourceControl' and isinstance(pin.get('location'), str), 'non-versioned dependency')
        require(set(state) == {'revision', 'version'} and SHA.fullmatch(state['revision'])
                and isinstance(state['version'], str) and state['version'], 'invalid version/revision pin')
        result[identity] = pin
    return result

def publication(inputs, root):
    require(inputs.get('publicationQualified') is True and inputs.get('dispatchReady') is True,
            'publication inputs remain unbound; no consumer work admitted')
    require(inputs.get('sdkExpectedPinCount') == 34, 'SDK graph is not the reviewed 34-pin graph')
    expected = pins({'version': 3, 'pins': inputs['sdkExpectedCompletePins']})
    require(len(expected) == 34, 'published SDK graph requires exactly 34 unique pins')
    for role in ('sdk', 'core'):
        item = inputs[role]
        require(item.get('repository') == REPOS[role] and item.get('tag') == TAGS[role], 'wrong release target')
        require(SHA.fullmatch(item.get('commit') or '') and SHA.fullmatch(item.get('tree') or ''), 'unbound source identity')
        for file_key, hash_key in [('releaseObjectFile', 'releaseObjectSHA256'),
                                   ('releaseEvidenceFile', 'releaseEvidenceSHA256')]:
            path = file_at(root, item.get(file_key))
            require(HASH.fullmatch(item.get(hash_key) or '') and digest(path) == item[hash_key], 'release evidence hash differs')
        release = load(file_at(root, item['releaseObjectFile']))
        require(release.get('tag_name') == item['tag'] and release.get('draft') is False
                and release.get('prerelease') is False and bool(release.get('published_at'))
                and isinstance(release.get('id'), int), 'release object is not a published stable release')
        require(release.get('html_url') == item['repository'].removesuffix('.git') + '/releases/tag/' + item['tag'],
                'release URL differs')
        run = load(file_at(root, item['releaseEvidenceFile']))
        require(run.get('id') == item['releaseWorkflowRun'] and isinstance(run.get('id'), int)
                and run.get('run_attempt') == item['releaseWorkflowAttempt']
                and isinstance(run.get('run_attempt'), int) and run['run_attempt'] > 0
                and run.get('head_sha') == item['commit'] and run.get('status') == 'completed'
                and run.get('conclusion') == 'success', 'release workflow identity or outcome differs')
        require(run.get('repository', {}).get('html_url') == item['repository'].removesuffix('.git')
                and run.get('path', '').split('@')[0] == '.github/workflows/release.yml', 'wrong release workflow repository/path')
    core = inputs['core']; sdk = inputs['sdk']
    receipt = file_at(root, core['releaseReceiptFile'])
    require(HASH.fullmatch(core.get('releaseReceiptSHA256') or '') and digest(receipt) == core['releaseReceiptSHA256'],
            'Core release receipt hash differs')
    body = load(receipt)
    require(body.get('schemaVersion') == 1 and body.get('sourceSha') == core['commit']
            and body.get('state') == 'validated-and-packaged', 'Core receipt is not qualified for this source')
    binding = file_at(root, sdk['bindingReceiptFile'])
    require(HASH.fullmatch(sdk.get('bindingReceiptSHA256') or '') and digest(binding) == sdk['bindingReceiptSHA256'],
            'combined upstream binding receipt hash differs')
    require(expected['latticecore']['location'] == REPOS['core']
            and expected['latticecore']['state'] == {'revision': core['commit'], 'version': TAGS['core']}, 'SDK Core pin differs')
    return expected

def sdk_pin(inputs):
    return {'identity': 'lattice', 'kind': 'remoteSourceControl', 'location': REPOS['sdk'],
            'state': {'revision': inputs['sdk']['commit'], 'version': TAGS['sdk']}}

def consumer_pins(lock, expected, inputs):
    actual = pins(lock)
    require(HASH.fullmatch(lock.get('originHash') or ''), 'missing generated consumer originHash')
    require({'lattice', 'latticecore'} <= set(actual), 'SDK/Core missing from actual consumer graph')
    require(actual['lattice'] == sdk_pin(inputs), 'consumer SDK tag pin differs')
    require(set(actual) - {'lattice'} <= set(expected), 'unreviewed consumer dependency')
    for identity in set(actual) - {'lattice'}:
        require(actual[identity] == expected[identity], 'consumer pin differs: ' + identity)
    return actual, sorted(set(expected) - set(actual))

def command(record, log=None):
    require(record.get('success') is True and record.get('started') is True and record.get('exitCode') == 0,
            'command did not complete successfully')
    require(not any(record.get(key) for key in ('primaryError', 'evidenceErrors', 'receivedSignals', 'stopReason')),
            'command has error, signal or stop evidence')
    cleanup = record.get('cleanup', {})
    require(cleanup.get('leaderReaped') is True and cleanup.get('groupGone') is True
            and not cleanup.get('signals') and not cleanup.get('errors'), 'owned command cleanup unqualified')
    if log is not None:
        require(record.get('logSHA256') == digest(log) and record.get('logBytes') == log.stat().st_size,
                'command log drift')

EXPECTED_ROWS = [
    {'globalId': '10000000-0000-4000-8000-000000000001', 'ordinal': 1, 'title': 'alpha', 'score': 1.25},
    {'globalId': '10000000-0000-4000-8000-000000000002', 'ordinal': 2, 'title': 'βeta', 'score': -2.5},
    {'globalId': '10000000-0000-4000-8000-000000000003', 'ordinal': 3, 'title': '', 'score': 0},
]

def runtime(text, phase, pid):
    require(phase in ('write', 'read'), 'unknown runtime phase')
    require(len(text.encode()) <= 2**20, 'runtime log exceeds bound')
    records = [parse(line.removeprefix('CONSUMER_RESULT ')) for line in text.splitlines() if line.startswith('CONSUMER_RESULT ')]
    require(len(records) == 1, 'missing/duplicate runtime result')
    record = records[0]
    require(record.get('schema') == 'lattice.release-consumer/1' and record.get('phase') == phase
            and record.get('pid') == pid and type(pid) is int and pid > 0, 'runtime identity differs')
    require(type(record.get('checkedRowCount')) is int and record['checkedRowCount'] == 3
            and record.get('rollbackRowAbsent') is True and record.get('rows') == EXPECTED_ROWS, 'persistence oracle differs')
    require(all(type(row.get('ordinal')) is int and type(row.get('score')) in (int, float)
                and isinstance(row.get('title'), str) and isinstance(row.get('globalId'), str)
                for row in record['rows']), 'runtime field types differ')
    require(record.get('rollbackSentinelCaught') is (True if phase == 'write' else None), 'rollback sentinel result differs')
    return record

def reject_acceptance(result):
    for key in ACCEPTANCE:
        result[key] = False

def finalize(result):
    accepted = (all(result.get(key) is True for key in ACCEPTANCE[1:-1])
                and result.get('sourceAndLockUnchanged') is True and result.get('binaryUnchanged') is True
                and result.get('allOwnedGroupsGone') is True and not result.get('primaryError')
                and not result.get('evidenceErrors') and not result.get('receivedSignals'))
    if accepted:
        result['success'] = result['consumerAccepted'] = True
    else:
        reject_acceptance(result)
