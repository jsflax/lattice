#!/usr/bin/env python3
"""Published SDK root iOS build with one explicit published Core lock overlay."""
import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import time
from types import SimpleNamespace

import guarded_runner as guard
import validate as check

P = Path(__file__).resolve().parent
REQUIRED = {'qualify-ios.py', 'qualify.py', 'guarded_runner.py', 'validate.py',
            'config.json', 'publication-inputs.json', 'OBSERVED-SDK-PINS.json'}


def verify_observed_pins(observed, original):
    # This inherited fixture predates SDK2.0.0 and authenticates the33 other
    # dependencies. publication() separately checks the SDK's real Core2.0.4 pin.
    check.require({k: v for k, v in observed.items() if k != 'latticecore'} ==
                  {k: v for k, v in original.items() if k != 'latticecore'},
                  '33 non-Core pins differ from reviewed graph')


def overlay_lock(original, expected, binding):
    check.require(check.pins(original) == expected, 'original SDK lock differs')
    result = copy.deepcopy(original)
    for pin in result['pins']:
        if pin['identity'] == 'latticecore':
            pin['state'] = {'revision': binding['core']['commit'], 'version': '2.0.7'}
    check.require(check.pins(result) == check.consumer_expected_pins(expected, binding),
                  'overlay changed more than the exact published Core state')
    check.require({k: v for k, v in result.items() if k != 'pins'} ==
                  {k: v for k, v in original.items() if k != 'pins'}, 'overlay root metadata drift')
    return result


def workspace_rows(state, expected, scratch):
    entries = state['object']['dependencies']
    by_id = {entry['packageRef']['identity']: entry for entry in entries}
    check.require(len(entries) == len(by_id) and set(by_id) == set(expected),
                  'actual Xcode/SwiftPM graph differs from all34 expected identities')
    result = {}
    for identity, pin in sorted(expected.items()):
        entry = by_id[identity]
        check.require(entry['state']['name'] == 'sourceControlCheckout'
                      and entry['state']['checkoutState'] == pin['state'],
                      'edited/path/unpinned dependency: ' + identity)
        check.require(guard.url_key(entry['packageRef']['location']) == guard.url_key(pin['location']),
                      'dependency location differs: ' + identity)
        path = (scratch / 'checkouts' / entry['subpath']).resolve(strict=True)
        check.require(path.is_relative_to((scratch / 'checkouts').resolve()) and path.is_dir(),
                      'dependency escapes owned checkouts: ' + identity)
        result[identity] = {'path': str(path), 'revision': pin['state']['revision'],
                            'version': pin['state']['version'], 'location': pin['location']}
    return result


def xcode_command(root):
    return ['xcodebuild', '-scheme', 'Lattice', '-destination', 'generic/platform=iOS Simulator',
            'build', '-skipMacroValidation', '-onlyUsePackageVersionsFromResolvedFile',
            '-derivedDataPath', str(root / 'derived-data'),
            '-clonedSourcePackagesDirPath', str(root / 'scratch'),
            '-packageCachePath', str(root / 'cache'), '-disablePackageRepositoryCache',
            'ARCHS=arm64', 'CLANG_MODULE_CACHE_PATH=' + str(root / 'module-cache'),
            'SWIFT_MODULE_CACHE_PATH=' + str(root / 'module-cache')]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--packet-seal-sha256', required=True)
    args = parser.parse_args()
    check.require(guard.digest(P / 'PACKET-SEAL.json') == args.packet_seal_sha256, 'packet seal differs')
    seal = check.load(P / 'PACKET-SEAL.json')
    check.require(REQUIRED <= set(seal['files']), 'seal omits runtime input')
    for name, expected_hash in seal['files'].items():
        check.require(guard.digest(check.file_at(P, name)) == expected_hash, 'packet input drift: ' + name)
    config = check.load(P / 'config.json')
    binding = check.load(P / 'publication-inputs.json')
    # Same release evidence validator as the public consumer. It refuses the
    # unbound source packet before creating a job directory or invoking a tool.
    original_pins = check.publication(binding, P)
    evidence_names = {binding[role][key] for role in ('sdk', 'core')
                      for key in ('releaseObjectFile', 'releaseEvidenceFile')}
    evidence_names.update([binding['core']['releaseReceiptFile'], binding['sdk']['bindingReceiptFile']])
    check.require(evidence_names <= set(seal['files']), 'seal omits publication evidence')
    check.require(binding['sdk']['commit'] == '0461b210aa028f3c4bb6165fed895e0f4385b565'
                  and binding['sdk']['tree'] == 'a1faa2850ebf2bf7dca152feffa461a24755a154',
                  'published SDK identity differs')
    check.require(config['reviewedCoreTree'] == binding['core']['tree'], 'maintenance source tree differs')
    observed = check.pins({'version': 3, 'pins': check.load(P / 'OBSERVED-SDK-PINS.json')['pins']})
    verify_observed_pins(observed, original_pins)
    root = args.root.absolute()
    localdev = (Path.home() / 'localdev').resolve(strict=True)
    check.require(root.parent.resolve(strict=True).is_relative_to(localdev) and not root.exists()
                  and root.name == 'qualification' and root.parent.name.startswith('lattice-release-consumer-'),
                  'iOS root must be fresh in the owned localdev workflow directory')
    root.mkdir(); root = root.resolve(strict=True)
    for name in ('receipts', 'tmp', 'scratch', 'cache', 'config', 'security', 'module-cache', 'derived-data'):
        (root / name).mkdir()
    receipts, sdk = root / 'receipts', root / 'sdk'
    (root / 'config/gitconfig').write_text('')
    env = {key: os.environ[key] for key in ('HOME', 'USER', 'LOGNAME') if key in os.environ}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8',
               DEVELOPER_DIR=config['developerDirectory'], TMPDIR=str(root / 'tmp'), TMP=str(root / 'tmp'), TEMP=str(root / 'tmp'),
               CLANG_MODULE_CACHE_PATH=str(root / 'module-cache'), SWIFT_MODULECACHE_PATH=str(root / 'module-cache'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(root / 'module-cache'), PYTHONDONTWRITEBYTECODE='1',
               GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(root / 'config/gitconfig'), GIT_TERMINAL_PROMPT='0')
    result = {'scope': 'postpublication root Lattice iOS arm64 simulator build only; no runtime',
              'success': False, 'iosBuildPassed': False, 'publicationAuthenticated': False,
              'graphAccepted': False, 'sourceAndOverlayUnchanged': False, 'primaryError': None,
              'evidenceErrors': [], 'packetSealSHA256': args.packet_seal_sha256}
    initial_sdk = initial_core = None
    overlay = overlay_hash = graph_before = None
    held_receipts = {}
    common = ['--package-path', str(sdk), '--scratch-path', str(root / 'scratch'),
              '--cache-path', str(root / 'cache'), '--config-path', str(root / 'config'),
              '--security-path', str(root / 'security'), '--disable-sandbox', '--disable-experimental-prebuilts']
    with guard.Interrupts() as interrupts:
        runner = guard.GuardedRunner(root.parent, receipts, env, interrupts,
            free_floor=config['freeFloorBytes'], packet_ceiling=config['packetCeilingBytes'],
            log_ceiling=config['logCeilingBytes'], overall_seconds=config['iosOverallSeconds'],
            reserve=config['reserveSeconds'], poll_seconds=.5, signal_grace=3)

        def command(label, argv, cwd=root, timeout=60):
            log = runner.run(label, argv, cwd=cwd, timeout=timeout, require_full_timeout=True)
            receipt = receipts / (label + '.json')
            check.command(check.load(receipt), log)
            held_receipts[label] = guard.digest(receipt)
            return log

        owned = SimpleNamespace(receipts=receipts, run=command)

        def fetch(role, path):
            item = binding[role]
            command(role + '-init', ['git', 'init', str(path)])
            command(role + '-fetch-tag', ['git', 'fetch', '--depth=1', item['repository'], 'refs/tags/' + item['tag']], path, 300)
            actual = command(role + '-peel', ['git', 'rev-parse', 'FETCH_HEAD^{commit}', 'FETCH_HEAD^{tree}'], path).read_text().split()
            check.require(actual == [item['commit'], item['tree']], role + ' published tag differs')
            command(role + '-checkout', ['git', 'checkout', '--detach', item['commit']], path)
            proof = guard.authenticate_repository(owned, role + '-published', path, item['commit'], initial=True)
            check.require(proof['tree'] == item['tree'], role + ' tree differs')
            return proof

        def graph(label, expected):
            state = check.load(root / 'scratch/workspace-state.json')
            rows = workspace_rows(state, expected, root / 'scratch')
            for identity, row in rows.items():
                path = Path(row['path'])
                head = command(label + '-' + identity + '-head', ['git', 'rev-parse', 'HEAD'], path).read_text().strip()
                dirty = command(label + '-' + identity + '-status', ['git', 'status', '--porcelain=v1', '--untracked-files=all'], path).read_text()
                check.require(head == row['revision'] and not dirty, 'actual source mismatch: ' + identity)
            guard.save_json(receipts / (label + '-graph.json'), rows)
            shutil.copyfile(root / 'scratch/workspace-state.json', receipts / (label + '-workspace-state.json'))
            return rows

        def source_and_overlay():
            check.require(overlay_hash is not None and guard.digest(sdk / 'Package.resolved') == overlay_hash,
                          'root SDK overlay bytes drifted')
            check.require(check.load(sdk / 'Package.resolved') == overlay, 'root SDK overlay records drifted')
            after = guard.authenticate_repository(owned, 'sdk-final', sdk, binding['sdk']['commit'],
                                                  allowed_changes=('Package.resolved',))
            expected = {k: v for k, v in initial_sdk['files'].items() if k != 'Package.resolved'}
            check.require(after['files'] == expected and after['tree'] == initial_sdk['tree'], 'SDK source drift')
            path = Path(graph_before['latticecore']['path'])
            final_core = guard.authenticate_repository(owned, 'core-final', path, binding['core']['commit'])
            check.require(final_core == initial_core, 'effective Core source drift')
            check.require(sorted(p.name for p in (root / 'config').iterdir()) == ['gitconfig']
                          and (root / 'config/gitconfig').read_bytes() == b'', 'unexpected resolution/Git configuration')

        try:
            command('swift-version', [config['swift'], '--version'])
            command('xcode-version', ['xcodebuild', '-version'])
            command('xcode-help', ['xcodebuild', '-help'])
            command('ios-sdk-path', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
            command('ios-sdk-version', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'])
            initial_sdk = fetch('sdk', sdk)
            fetch('core', root / 'core-published-reference')
            lock = check.load(sdk / 'Package.resolved')
            check.require(guard.digest(sdk / 'Package.resolved') == binding['sdk']['packageResolvedSHA256']
                          and guard.digest(sdk / 'Package.swift') == config['sdkManifestSHA256'], 'published SDK input differs')
            check.require(guard.digest(sdk / 'Scripts/wrapper-expected-bindings.json') == binding['sdk']['expectedBindingsSHA256'], 'SDK binding input differs')
            shutil.copyfile(sdk / 'Package.resolved', receipts / 'SDK-Package.resolved.original')
            command('published-sdk-bindings', ['python3', '-B', str(sdk / 'Scripts/verify-wrapper-bindings.py'),
                    '--expected', str(sdk / 'Scripts/wrapper-expected-bindings.json'), '--resolved', str(sdk / 'Package.resolved')], sdk)
            result['publicationAuthenticated'] = True
            overlay = overlay_lock(lock, original_pins, binding)
            (sdk / 'Package.resolved').write_text(json.dumps(overlay, indent=2, sort_keys=True) + '\n')
            overlay_hash = guard.digest(sdk / 'Package.resolved')
            shutil.copyfile(sdk / 'Package.resolved', receipts / 'SDK-Package.resolved.overlay')
            effective = check.pins(overlay)
            command('resolve-published-graph', [config['swift'], 'package', *common, '--force-resolved-versions', 'resolve'], sdk,
                    config['iosResolveSeconds'])
            check.require(guard.digest(sdk / 'Package.resolved') == overlay_hash, 'versioned resolution changed the overlay')
            graph_before = graph('before', effective)
            core_path = Path(graph_before['latticecore']['path'])
            initial_core = guard.authenticate_repository(owned, 'core-effective', core_path, binding['core']['commit'], initial=True)
            check.require(initial_core['tree'] == binding['core']['tree'], 'effective Core tree differs')
            result['graphAccepted'] = True
            build = command('ios-build', xcode_command(root), sdk, config['iosBuildSeconds'])
            guard.save_json(receipts / 'compiler-input-proof.json', guard.compiler_input_proof(build, core_path))
            result['iosBuildPassed'] = True
            check.require(graph('final', effective) == graph_before, 'final actual dependency graph differs')
            source_and_overlay()
            result['sourceAndOverlayUnchanged'] = True
            result['success'] = True
        except BaseException as error:
            result['primaryError'] = guard.error_record(error)
        finally:
            with interrupts.hold():
                def evidence(label, operation):
                    try:
                        operation()
                    except BaseException as error:
                        result['evidenceErrors'].append({'operation': label, **guard.error_record(error)})
                if (sdk / 'Package.resolved').is_file():
                    evidence('final lock', lambda: shutil.copyfile(sdk / 'Package.resolved', receipts / 'SDK-Package.resolved.final'))
                if (root / 'scratch/workspace-state.json').is_file():
                    evidence('final workspace', lambda: shutil.copyfile(root / 'scratch/workspace-state.json', receipts / 'workspace-state.at-exit.json'))
                if initial_sdk is not None:
                    evidence('final SDK bytes', lambda: guard.save_json(receipts / 'sdk-files-at-exit.json', guard.tracked_manifest(sdk, initial_sdk['files'])))
                def final_checks():
                    for label, expected_hash in held_receipts.items():
                        receipt, log = receipts / (label + '.json'), receipts / (label + '.log')
                        check.require(guard.digest(receipt) == expected_hash, 'command receipt drift: ' + label)
                        check.command(check.load(receipt), log)
                    sample = runner.measure(receipts / 'RESULT.json')
                    result['finalResources'] = sample
                    check.require(not runner.violation(sample), 'final resource guard')
                    check.require(time.monotonic() < runner.overall_deadline, 'overall qualification deadline')
                evidence('terminal command/resources', final_checks)
                result.update(commands=runner.records, receivedSignals=interrupts.received,
                              elapsedSeconds=time.monotonic() - runner.started)
                result['success'] = (result['success'] and not result['primaryError'] and not result['evidenceErrors']
                                     and not interrupts.received and all(x['success'] for x in runner.records))
                if not result['success']:
                    result.update(iosBuildPassed=False, graphAccepted=False, sourceAndOverlayUnchanged=False)
                guard.save_json(receipts / 'RESULT.json', result)
    if not result['success']:
        raise RuntimeError('iOS published graph not accepted; inspect preserved RESULT.json')


if __name__ == '__main__':
    main()
