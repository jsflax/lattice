#!/usr/bin/env python3
"""One fresh public Swift consumer, using the unchanged owned-process guard."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import time
from types import SimpleNamespace

import guarded_runner as guard
import validate as check

P = Path(__file__).resolve().parent
REQUIRED_INPUTS = {'qualify.py', 'validate.py', 'guarded_runner.py', 'config.json',
    'publication-inputs.json', 'OBSERVED-SDK-PINS.json', 'consumer/Package.swift',
    'consumer/Sources/ReleaseConsumer/Models.swift', 'consumer/Sources/ReleaseConsumer/Consumer.swift'}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--packet-seal-sha256', required=True)
    args = parser.parse_args()

    def inputs():
        check.require(guard.digest(P / 'PACKET-SEAL.json') == args.packet_seal_sha256, 'packet seal differs')
        seal = check.load(P / 'PACKET-SEAL.json')
        check.require(REQUIRED_INPUTS <= set(seal['files']), 'seal omits a fixed runtime input')
        for name, expected in seal['files'].items():
            check.require(guard.digest(check.file_at(P, name)) == expected, 'packet input drift: ' + name)
        actual_consumer = {str(q.relative_to(P)) for q in (P / 'consumer').rglob('*') if q.is_file() or q.is_symlink()}
        check.require(actual_consumer == {name for name in seal['files'] if name.startswith('consumer/')},
                      'unsealed consumer file inventory')
    inputs()
    config = check.load(P / 'config.json')
    binding = check.load(P / 'publication-inputs.json')
    # Refuse unbound publication before creating a consumer or invoking any tool.
    expected = check.publication(binding, P)
    evidence_names = {binding[role][key] for role in ('sdk', 'core') for key in ('releaseObjectFile', 'releaseEvidenceFile')}
    evidence_names.update([binding['core']['releaseReceiptFile'], binding['sdk']['bindingReceiptFile']])
    check.require(evidence_names <= set(check.load(P / 'PACKET-SEAL.json')['files']), 'seal omits bound publication evidence')
    observed = check.pins({'version': 3, 'pins': check.load(P / 'OBSERVED-SDK-PINS.json')['pins']})
    check.require({k: v for k, v in expected.items() if k != 'latticecore'} ==
                  {k: v for k, v in observed.items() if k != 'latticecore'}, '33 non-Core pins differ from reviewed graph')
    root = args.root.absolute()
    localdev = (Path.home() / 'localdev').resolve(strict=True)
    check.require(root.parent.resolve(strict=True).is_relative_to(localdev) and not root.exists(), 'root must be fresh beneath localdev')
    check.require(root.name == 'qualification' and root.parent.name.startswith('lattice-release-consumer-'),
                  'root must belong to the unique consumer workflow task directory')
    root.mkdir(exist_ok=False); root = root.resolve(strict=True)
    receipts = root / 'receipts'
    for name in ('receipts', 'tmp', 'scratch', 'cache', 'config', 'security', 'module-cache', 'fixture'):
        (root / name).mkdir()
    (root / 'config/gitconfig').write_text('')
    consumer = root / 'consumer'
    shutil.copytree(P / 'consumer', consumer)
    env = {key: os.environ[key] for key in ('HOME', 'USER', 'LOGNAME') if key in os.environ}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8',
        DEVELOPER_DIR=config['developerDirectory'], TMPDIR=str(root / 'tmp'), TMP=str(root / 'tmp'), TEMP=str(root / 'tmp'),
        CLANG_MODULE_CACHE_PATH=str(root / 'module-cache'), SWIFT_MODULECACHE_PATH=str(root / 'module-cache'),
        SWIFTPM_MODULECACHE_OVERRIDE=str(root / 'module-cache'), PYTHONDONTWRITEBYTECODE='1',
        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(root / 'config/gitconfig'), GIT_TERMINAL_PROMPT='0')
    result = {key: False for key in check.ACCEPTANCE}
    result.update(scope='Fresh external macOS public Lattice consumer only', primaryError=None,
        evidenceErrors=[], observed={}, packetSealSHA256=args.packet_seal_sha256,
        sourceAndLockUnchanged=False, binaryUnchanged=False, allOwnedGroupsGone=False)
    binary = None; binary_hash = None; lock_hash = None
    source_proofs = {}; held_receipts = {}; graph_before = None
    consumer_sources = {str(q.relative_to(consumer)): guard.digest(q) for q in consumer.rglob('*') if q.is_file()}
    common = ['--package-path', str(consumer), '--scratch-path', str(root / 'scratch'),
        '--cache-path', str(root / 'cache'), '--config-path', str(root / 'config'),
        '--security-path', str(root / 'security'), '--disable-sandbox', '--disable-experimental-prebuilts']
    swift = config['swift']
    with guard.Interrupts() as interrupts:
        # root.parent is the unique task root, so tools/bootstrap artifacts also
        # count against the owned packet ceiling.
        runner = guard.GuardedRunner(root.parent, receipts, env, interrupts,
            free_floor=config['freeFloorBytes'], packet_ceiling=config['packetCeilingBytes'],
            log_ceiling=config['logCeilingBytes'], overall_seconds=config['overallSeconds'],
            reserve=config['reserveSeconds'], poll_seconds=.5, signal_grace=3)

        def command(label, argv, cwd=root, timeout=60):
            log = runner.run(label, argv, cwd=cwd, timeout=timeout, require_full_timeout=True)
            receipt = receipts / (label + '.json')
            check.command(check.load(receipt), log)
            held_receipts[label] = guard.digest(receipt)
            return log

        def authenticate(label, path, role):
            item = binding[role]
            # Route unchanged helper commands through full-timeout admission and
            # full receipt capture too, rather than interpreting compact records.
            owned_commands = SimpleNamespace(receipts=receipts, run=command)
            proof = guard.authenticate_repository(owned_commands, label, path, item['commit'], initial=True)
            check.require(proof['tree'] == item['tree'], role + ' source tree differs')
            source_proofs[label] = {'path': str(path), 'manifest': proof['files'],
                'receiptPath': str(receipts / (label + '-manifest.json')),
                'receiptSHA256': guard.digest(receipts / (label + '-manifest.json'))}
            return proof

        def fetch_tag(role):
            path = root / ('pristine-' + role); item = binding[role]
            command(role + '-init', ['git', 'init', str(path)])
            command(role + '-fetch-tag', ['git', 'fetch', '--depth=1', item['repository'], 'refs/tags/' + item['tag']], path, 300)
            actual = command(role + '-peel-tag', ['git', 'rev-parse', 'FETCH_HEAD^{commit}', 'FETCH_HEAD^{tree}'], path).read_text().split()
            check.require(actual == [item['commit'], item['tree']], role + ' published tag commit/tree differs')
            command(role + '-checkout', ['git', 'checkout', '--detach', item['commit']], path)
            authenticate(role + '-pristine', path, role)
            return path

        def consumer_source_check():
            check.require({str(q.relative_to(consumer)): guard.digest(q) for q in consumer.rglob('*')
                           if q.is_file() and q.relative_to(consumer) != Path('Package.resolved')} == consumer_sources,
                          'consumer source inventory drift or new override file')
            check.require(lock_hash is not None and guard.digest(consumer / 'Package.resolved') == lock_hash,
                          'generated consumer lock drift')
            check.require(not any((root / 'config').iterdir()) or
                          sorted(q.name for q in (root / 'config').iterdir()) == ['gitconfig'], 'SwiftPM config/mirror drift')
            check.require((root / 'config/gitconfig').read_bytes() == b'', 'Git config drift')

        def graph(label, actual_pins):
            log = command(label + '-graph', [swift, 'package', *common, '--force-resolved-versions', 'show-dependencies', '--format', 'json'])
            nodes = guard.graph_nodes(guard.read_graph(log))
            workspace = root / 'scratch/workspace-state.json'
            state = check.load(workspace)
            entries = state['object']['dependencies']
            by_id = {entry['packageRef']['identity']: entry for entry in entries}
            check.require(len(entries) == len(by_id) and set(nodes) == set(by_id) == set(actual_pins), 'actual graph/workspace/lock identities differ')
            proof = {}
            for identity in sorted(nodes):
                node, entry, pin = nodes[identity], by_id[identity], actual_pins[identity]
                check.require(entry['state']['name'] == 'sourceControlCheckout'
                    and entry['state']['checkoutState'] == pin['state'], 'edited/path/unpinned dependency: ' + identity)
                path = Path(node['path']).resolve(strict=True)
                wanted = (root / 'scratch/checkouts' / entry['subpath']).resolve(strict=True)
                check.require(path == wanted and path.is_relative_to((root / 'scratch/checkouts').resolve()), 'checkout path escaped: ' + identity)
                check.require(guard.url_key(node['url']) == guard.url_key(pin['location']) == guard.url_key(entry['packageRef']['location']), 'dependency repository differs')
                check.require(node.get('version') == pin['state']['version'], 'dependency graph version differs')
                head = command(label + '-' + identity + '-head', ['git', 'rev-parse', 'HEAD'], path).read_text().strip()
                dirty = command(label + '-' + identity + '-status', ['git', 'status', '--porcelain=v1', '--untracked-files=all'], path).read_text()
                check.require(head == pin['state']['revision'] and not dirty, 'dependency checkout source differs: ' + identity)
                proof[identity] = {'path': str(path), 'pin': pin}
                if identity in ('lattice', 'latticecore'):
                    role = 'sdk' if identity == 'lattice' else 'core'
                    current = authenticate(label + '-' + role, path, role)
                    check.require(current['files'] == source_proofs[role + '-pristine']['manifest'], 'effective source differs from pristine tag')
            consumer_source_check()
            guard.save_json(receipts / (label + '-graph-proof.json'),
                {'dependencies': proof, 'workspaceStateSHA256': guard.digest(workspace), 'consumerLockSHA256': lock_hash})
            return proof

        try:
            check.require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'requires hosted arm64 macOS')
            guard.save_json(receipts / 'invocation.json', {'config': config, 'environment': env,
                'packetSealSHA256': args.packet_seal_sha256, 'publicationInputs': binding,
                'consumerSources': consumer_sources, 'platform': platform.platform(), 'python': sys.version})
            version = command('swift-version', [swift, '--version']).read_text()
            parsed = re.search(r'Swift version (\d+)\.(\d+)', version)
            check.require(parsed and tuple(map(int, parsed.groups())) >= (6, 3), 'Swift tools 6.3 or newer required')
            command('xcode-version', ['xcodebuild', '-version'])
            command('macos-version', ['sw_vers'])
            command('sdk-version', ['xcrun', '--sdk', 'macosx', '--show-sdk-version'])
            sdk = fetch_tag('sdk'); fetch_tag('core')
            sdk_lock = sdk / 'Package.resolved'
            check.require(guard.digest(sdk_lock) == binding['sdk']['packageResolvedSHA256']
                and check.pins(check.load(sdk_lock)) == expected, 'published complete 34-pin SDK lock differs')
            expectations = sdk / 'Scripts/wrapper-expected-bindings.json'
            check.require(guard.digest(expectations) == binding['sdk']['expectedBindingsSHA256'], 'SDK binding source differs')
            check.require(check.load(expectations)['releaseEvidence']['receiptSHA256'] == binding['sdk']['bindingReceiptSHA256'], 'SDK combined upstream receipt does not match bound evidence')
            command('published-sdk-bindings', ['python3', '-B', str(sdk / 'Scripts/verify-wrapper-bindings.py'), '--expected', str(expectations), '--resolved', str(sdk_lock)])
            result['publicationAuthenticated'] = True
            consumer_expected = check.consumer_expected_pins(expected, binding)
            seed = {'version': 3, 'pins': [*consumer_expected.values(), check.sdk_pin(binding)]}
            guard.save_json(receipts / 'consumer-seed-lock.json', seed)
            guard.save_json(consumer / 'Package.resolved', seed)
            command('consumer-resolve', [swift, 'package', *common, 'resolve'], timeout=config['resolveSeconds'])
            lock = check.load(consumer / 'Package.resolved')
            actual, omitted = check.consumer_pins(lock, consumer_expected, binding)
            lock_hash = guard.digest(consumer / 'Package.resolved')
            shutil.copyfile(consumer / 'Package.resolved', receipts / 'consumer-generated-lock.json')
            result.update(sdkCompletePins=list(expected.values()), consumerExpectedPins=list(consumer_expected.values()), consumerCompletePins=list(actual.values()),
                sdkPinsNotInConsumerGraph=omitted, generatedConsumerOriginHash=lock['originHash'], consumerLockSHA256=lock_hash)
            graph_before = graph('before', actual)
            result['graphAccepted'] = True
            command('consumer-debug-build', [swift, 'build', *common, '-c', 'debug', '--product', 'ReleaseConsumer',
                '--force-resolved-versions', '-j', str(config['jobs']), '-v'], timeout=config['buildSeconds'])
            result['observed']['buildExitZero'] = True
            bin_text = command('consumer-bin-path', [swift, 'build', *common, '-c', 'debug', '--product', 'ReleaseConsumer',
                '--force-resolved-versions', '--show-bin-path']).read_text().strip()
            check.require(len(bin_text.splitlines()) == 1, 'ambiguous binary directory')
            candidate = Path(bin_text) / 'ReleaseConsumer'
            check.require(not candidate.is_symlink(), 'product is a symlink')
            binary = candidate.resolve(strict=True)
            check.require(binary.is_relative_to((root / 'scratch').resolve()) and binary.is_file()
                and binary.stat().st_size > 0 and os.access(binary, os.X_OK), 'product is not an owned executable')
            binary_hash = guard.digest(binary)
            result.update(binaryPath=str(binary), binarySHA256=binary_hash, consumerBuildPassed=True)
            command('consumer-linkage', ['otool', '-L', str(binary)])
            consumer_source_check()
            guard.save_json(receipts / 'build-identity.json', {'binary': str(binary), 'binarySHA256': binary_hash,
                'consumerSources': consumer_sources, 'consumerLockSHA256': lock_hash,
                'buildReceiptSHA256': held_receipts['consumer-debug-build'],
                'scope': 'Fresh Debug product build and source/lock/workspace/binary custody; no exhaustive compiler input or system-header proof'})
            for phase, flag in [('write', 'writerPassed'), ('read', 'reopenPassed')]:
                check.require(guard.digest(binary) == binary_hash, 'binary changed before runtime')
                runner.log_ceiling = config['runtimeLogCeilingBytes']
                try:
                    label = 'consumer-' + phase
                    log = command(label, [str(binary), phase, str(root / 'fixture/store.sqlite')], timeout=config['runtimeSeconds'])
                finally:
                    runner.log_ceiling = config['logCeilingBytes']
                record = check.load(receipts / (label + '.json'))
                result['observed'][phase] = check.runtime(log.read_text(), phase, record['pid'])
                result[flag] = True
            check.require(graph('final', actual) == graph_before, 'final effective dependency graph differs')
        except BaseException as error:
            result['primaryError'] = guard.error_record(error)
        finally:
            with interrupts.hold():
                try:
                    inputs()
                    check.publication(binding, P)
                    consumer_source_check()
                    check.require(binary is not None and guard.digest(binary) == binary_hash, 'final binary custody missing/drifted')
                    for proof in source_proofs.values():
                        check.require(guard.digest(Path(proof['receiptPath'])) == proof['receiptSHA256'], 'source proof receipt drift')
                        check.require(guard.tracked_manifest(Path(proof['path']), proof['manifest']) == proof['manifest'], 'final SDK/Core source bytes differ')
                    # records are compact summaries. Load EACH full receipt and
                    # authenticate its log; never read cleanup from a summary.
                    full = []
                    for summary in runner.records:
                        label = summary['label']; receipt = receipts / (label + '.json')
                        check.require(summary['success'] is True, 'unsuccessful command summary: ' + label)
                        if label in held_receipts:
                            check.require(guard.digest(receipt) == held_receipts[label], 'command receipt drift')
                        record = check.load(receipt)
                        check.command(record, receipts / (label + '.log'))
                        full.append({'label': label, 'receiptSHA256': guard.digest(receipt), 'logSHA256': record['logSHA256']})
                    result.update(commandProofs=full, sourceAndLockUnchanged=True, binaryUnchanged=True, allOwnedGroupsGone=True)
                    fixture = root / 'fixture'
                    result['fixtureFiles'] = {q.name: {'bytes': q.stat().st_size, 'sha256': guard.digest(q)} for q in fixture.iterdir() if q.is_file()}
                    check.require(time.monotonic() < runner.overall_deadline, 'finalization budget exceeded')
                    sample = runner.measure(receipts / 'consumer-debug-build.log')
                    check.require(runner.violation(sample) is None, 'final resource guard failed')
                    result['finalResources'] = sample
                    check.require(time.monotonic() < runner.overall_deadline, 'final resource measurement exceeded budget')
                except BaseException as error:
                    result['evidenceErrors'].append(guard.error_record(error))
                result['receivedSignals'] = list(interrupts.received)
                result['observedCommands'] = runner.records
                if time.monotonic() >= runner.overall_deadline:
                    result['evidenceErrors'].append({'type': 'TimeoutError', 'message': 'final acceptance budget exceeded'})
                check.finalize(result)
                try:
                    guard.save_json(receipts / 'RESULT.json', result)
                    check.require(time.monotonic() < runner.overall_deadline, 'result publication budget exceeded')
                except BaseException as error:
                    result['evidenceErrors'].append(guard.error_record(error))
                    check.reject_acceptance(result)
                    print('RESULT_WRITE_FAILED', json.dumps(result, sort_keys=True), flush=True)
                print(json.dumps({key: result[key] for key in ('success', 'consumerAccepted', 'primaryError', 'evidenceErrors')}, sort_keys=True), flush=True)
    return 0 if result['consumerAccepted'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
