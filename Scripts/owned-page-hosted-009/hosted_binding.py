"""Narrow hosted path/admission/source binding around the unchanged SDK008 runner."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

P = Path(__file__).resolve().parent
H = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
J = lambda p: json.loads(p.read_text())


def require(ok, message):
    if not ok:
        raise ValueError(message)


def regular(path):
    require(path.is_file() and not path.is_symlink(), 'regular input required: ' + str(path))
    return path


def packet_check(expected):
    require(re.fullmatch(r'[0-9a-f]{64}', expected or '') and H(P/'PACKET-SEAL.json') == expected,
            'reviewed hosted packet seal required')
    seal = J(P/'PACKET-SEAL.json')
    for name, digest in seal['files'].items():
        path = P/name
        require(path.resolve().is_relative_to(P) and H(regular(path)) == digest, 'packet drift: ' + name)
    required = {'hosted.py', 'hosted_binding.py', 'source_checks.py', 'qualify.py', 'CONFIG.json',
                'COMMANDS.json', 'PRESERVATION.json', 'CORE-BASE-MANIFEST.json', 'CORE-POSTIMAGES.json',
                'EXPECTED-TESTS.json', 'SDK-SOURCE-MANIFEST.json', 'CORE-SOURCE-MANIFEST.json',
                'Package.resolved.original', 'build_proof.py', 'runtime_oracles.py', 'sdk_test_oracles.py',
                'guarded_runner.py', 'process_custody.py', 'detached_owner.py'}
    require(required <= set(seal['files']), 'runtime input omitted from seal')
    for prefix in ('overlay/', 'core-postimages/', 'evidence/sdk008/'):
        actual = {str(f.relative_to(P)) for f in (P/prefix).rglob('*') if f.is_file()}
        require(actual and actual <= set(seal['files']), 'unsealed input subtree: ' + prefix)
    return seal


def preservation_check():
    proof = J(P/'PRESERVATION.json')
    old = P/'evidence/sdk008'
    require(H(old/'SOURCE-READY.json') == proof['SDK008SealSHA256'], 'SDK008 seal changed')
    original = J(old/'SOURCE-READY.json')
    require(original['files'] == proof['SDK008SourceFiles'], 'SDK008 inventory changed')
    for name, digest in original['files'].items():
        require(H(regular(old/name)) == digest, 'SDK008 evidence drift: ' + name)
    require(H(P/'evidence/SDK008-INDEPENDENT-REVIEW.json') == proof['SDK008ReviewSHA256'], 'SDK008 review drift')
    for name, digest in proof['reusedExactFiles'].items():
        require(H(regular(P/name)) == digest == original['files'][name], 'reviewed runtime source changed: ' + name)
    for source in (old/'overlay').rglob('*'):
        if source.is_file():
            require(H(P/'overlay'/source.relative_to(old/'overlay')) == H(source), 'qualification overlay changed')
    config, prior = J(P/'CONFIG.json'), J(old/'CONFIG.json')
    for name in ('proposedLimits', 'flags', 'originalCases9', 'sdkCommit', 'sdkTree', 'sourceCounts'):
        require(config[name] == prior[name], 'SDK008 invariant changed: ' + name)
    normalized = json.loads((old/'COMMANDS.json').read_text().replace(proof['SDK008RuntimeRoot'], '@RUNTIME@'))
    require(J(P/'COMMANDS.json') == normalized, 'compiler/test commands changed beyond owned root')
    base, current, post = J(P/'CORE-BASE-MANIFEST.json'), J(P/'CORE-SOURCE-MANIFEST.json'), J(P/'CORE-POSTIMAGES.json')
    require(len(base) == 901 and len(current) == 919 and set(base) <= set(current), 'Core inventory')
    require(post == {k:v for k,v in current.items() if base.get(k) != v}, 'Core postimage inventory')
    for name, digest in post.items():
        require(H(regular(P/'core-postimages'/name)) == digest, 'Core postimage drift')
    return proof


def validate_root(root, metadata):
    allowed = Path.home()/'localdev'
    require(re.fullmatch(r'[0-9]+', metadata.get('runID', '')) and
            re.fullmatch(r'[1-9][0-9]*', metadata.get('attempt', '')) and
            re.fullmatch(r'[0-9a-f]{40}', metadata.get('workflowCommit', '')),
            'hosted workflow identity required')
    expected = allowed/('lattice-owned-page-hosted-' + metadata['runID'] + '-' + metadata['attempt'])
    require(root == expected and root.resolve() == root and root.is_dir() and not root.is_symlink(),
            'fresh exact hosted localdev root required')
    return root


def root_context():
    root = Path(os.environ['OWNED_PAGE_HOSTED_ROOT'])
    require(H(regular(root/'HOSTED-CONTEXT.json')) == os.environ['OWNED_PAGE_HOSTED_CONTEXT_SHA256'],
            'hosted context bytes changed')
    record = J(regular(root/'HOSTED-CONTEXT.json'))
    validate_root(root, record['hosted'])
    require(record['root'] == str(root), 'hosted root binding changed')
    return root, record


def admission_check(raw, expected, seal, metadata, config):
    require(len(raw) <= 32768 and hashlib.sha256(raw).hexdigest() == expected, 'admission byte binding')
    value = json.loads(raw)
    wanted = {'schemaVersion': 1, 'packetSealSHA256': seal, 'SDKCommit': config['sdkCommit'],
              'SDKTree': config['sdkTree'], 'coreManifestSHA256': config['privateCoreSourceManifestSHA256'],
              'limits': config['proposedLimits'], 'hostedToolIdentityAccepted': True,
              'sourceOnlyPacketApprovedForOneHostedRun': True, 'publicActivation': False,
              'performanceClaimed': False, 'workflowCommit': metadata['workflowCommit'],
              'attempt': '1'}
    require(metadata['attempt'] == '1', 'automatic hosted rerun is not admitted')
    require(value == wanted, 'exact one-run hosted admission required')
    return value


def tool_identity(config):
    # These are selected Xcode inputs, not a complete SDK/toolchain byte archive.
    return {name: {'resolved': str(Path(name).resolve(strict=True)), 'sha256': H(Path(name))}
            for name in config['toolPaths']}


def config_for(root, context):
    config = json.loads((P/'CONFIG.json').read_text().replace('@RUNTIME@', str(root/'run')))
    require(tool_identity(config) == context['tools'], 'hosted tool input changed')
    config['toolFiles'] = {k:v['sha256'] for k,v in context['tools'].items()}
    config['sdkSource'] = str(root/'run/incoming/SDK')
    config['privateCoreSource'] = str(root/'run/incoming/Core')
    return config


def source_packet(expected, *, no_runtime=False, prelaunch=False):
    packet_check(expected)
    preservation_check()
    root, context = root_context()
    require(context['packetSealSHA256'] == expected, 'hosted context seal mismatch')
    admission = regular(root/'ADMISSION.json')
    admission_check(admission.read_bytes(), context['admissionSHA256'], expected, context['hosted'], J(P/'CONFIG.json'))
    config = config_for(root, context)
    runtime = Path(config['runtimeRoot'])
    if no_runtime:
        require(not runtime.exists(), 'fresh runtime root required')
    if prelaunch:
        require(not runtime.with_name(runtime.name+'-owner').exists(), 'fresh owner root required')
    return config


def commands(root):
    return json.loads((P/'COMMANDS.json').read_text().replace('@RUNTIME@', str(root/'run')))


def fetch_sources(config, runtime, run, files_at, save):
    incoming = runtime/'incoming'
    incoming.mkdir()
    proof = {}
    for side, url, commit, tree, manifest in (
        ('SDK', config['sdkURL'], config['sdkCommit'], config['sdkTree'], J(P/'SDK-SOURCE-MANIFEST.json')),
        ('Core', config['coreURL'], config['coreBaseCommit'], config['coreBaseTree'], J(P/'CORE-BASE-MANIFEST.json'))):
        destination = incoming/side
        def command(suffix, argv, cwd, seconds=60):
            return run('source-'+side.lower()+'-'+suffix, {'argv': argv, 'cwd': str(cwd), 'timeoutSeconds': seconds})
        command('init', ['/usr/bin/git', 'init', str(destination)], incoming)
        command('fetch', ['/usr/bin/git', 'fetch', '--depth=1', url, commit], destination, 600)
        command('checkout', ['/usr/bin/git', 'checkout', '--detach', commit], destination)
        head = command('head', ['/usr/bin/git', 'rev-parse', 'HEAD'], destination).read_text().strip()
        actual_tree = command('tree', ['/usr/bin/git', 'rev-parse', 'HEAD^{tree}'], destination).read_text().strip()
        status = command('status', ['/usr/bin/git', 'status', '--porcelain=v1', '--untracked-files=all'], destination).read_text()
        require(head == commit and actual_tree == tree and not status, 'remote source identity mismatch: '+side)
        files_at(destination, manifest)
        proof[side] = {'URL': url, 'commit': head, 'tree': actual_tree, 'files': len(manifest)}
    for name, digest in J(P/'CORE-POSTIMAGES.json').items():
        source, target = P/'core-postimages'/name, incoming/'Core'/name
        require(H(source) == digest, 'Core postimage source drift')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    files_at(incoming/'Core', J(P/'CORE-SOURCE-MANIFEST.json'))
    proof['Core']['effectiveManifestSHA256'] = H(P/'CORE-SOURCE-MANIFEST.json')
    save(runtime/'receipts/REMOTE-SOURCES.json', proof)
    return proof
