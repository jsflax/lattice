#!/usr/bin/env python3
"""Five fresh A/A2/B groups on two prepared, exact, same-host SDK/Core graphs.

Preparation is a separate run-development --sync-matched-prepare operation on
each source graph. This coordinator issues no build/resolve/download/edit
commands or post-hoc calibration relabeling. SwiftPM skip-build behavior still
needs actual Native qualification. It owns each fresh Swift test process via
the existing GuardedRunner and admits equal unchanged process/resource budgets.
Numerical gates are separate from runtime/release and original deadline facts.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import re
import shutil
import sys
import time
import uuid

sys.dont_write_bytecode = True
import evaluate_sync
import evaluate_sync_matched as capture
import sync_full_calibration as calibration
import sync_measurement_logging as logging
from sync_probe_qualification import FLAGS

GROUPS = 5
TIMEOUT = calibration.TIMEOUT  # 300; no supervisor deadline extension
CASE = 'matchedPublicVisibilityCaptureProfile'
FILTER = 'SyncPublicVisibilityTests/' + CASE
SEED = 0x51A7
PREPARATION = 'sync-matched-preparation.json'
MEASUREMENT_FILES = (
    'Tests/LatticeTests/SyncTests/SyncPublicVisibilitySupport.swift',
    'Tests/LatticeTests/SyncTests/SyncPublicVisibilityTests.swift',
    'Tests/LatticeTests/SyncTests/SyncVisibilityRecorderTests.swift',
    'Tests/LatticeTests/SyncTests/SyncMeasurementLogging.swift',
    'Scripts/evaluate_sync.py', 'Scripts/evaluate_sync_matched.py',
    'Scripts/sync_full_calibration.py', 'Scripts/sync_measurement_logging.py',
    'Scripts/sync_matched_experiment.py',
)
PROBE_FILES = ('Sources/LatticeCore/src/sync_commit_probe.cpp', 'Sources/LatticeCore/include/lattice/sync_commit_probe.hpp')
SCOPE = 'Matched instrumented public-API numerical evidence only; no release, goal, recovery, physical completion or adoption acceptance.'


def host():
    return dict(platform.uname()._asdict(), cpuCount=os.cpu_count())


def common(root):
    return ['--package-path', str(root / 'lattice'), '--scratch-path', str(root / 'scratch'),
            '--cache-path', str(root / 'cache'), '--config-path', str(root / 'config'),
            '--security-path', str(root / 'security'), '--disable-sandbox', '--disable-experimental-prebuilts']


def regular_manifest(base, names):
    result = {}
    for name in names:
        path = base / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('expected original regular file: ' + str(path))
        result[name] = {'bytes': path.stat().st_size, 'sha256': calibration.digest(path)}
    return result


def binary_manifest(root):
    names = []
    for base in (root / 'scratch', root / 'native-probe/scratch'):
        for path in sorted(base.rglob('*')):
            if not path.is_file() or path.is_symlink():
                continue
            if (path.suffix in ('.o', '.a', '.so', '.dylib', '.swiftmodule', '.pcm', '.xctest')
                    or '.xctest/Contents/MacOS/' in str(path)):
                names.append(str(path.relative_to(root)))
    if not any('LatticePackageTests.xctest' in name for name in names):
        raise ValueError('actual compiled SDK test executable is missing')
    return regular_manifest(root, names)


def prepare(runner, root, sdk_inputs, core_inputs):
    """Called only after actual native probe, SDK build/smoke and graph checks.

    The outer RESULT must subsequently finish successfully; this staged record
    alone never qualifies a preparation. All hashes are actual source/artifact
    bytes, not a future revision name or a copied build-success assertion.
    """
    binding = calibration.prepare_binding(runner, root, sdk_inputs, core_inputs)
    commands = {row['label']: row['success'] for row in runner.records}
    for name in ('native-probe', 'build-tests', 'sdk-probe-fixtures'):
        if commands.get(name) is not True:
            raise ValueError('actual prerequisite process did not pass: ' + name)
    sdk = root / 'lattice'
    inventories = []
    graph = json.loads((runner.receipts / 'graph-after.json').read_text())
    development = load_development(sdk / 'Scripts/run-development.py')
    for ordinal, row in enumerate(graph):
        path = Path(row['path']).resolve(strict=True)
        if not path.is_relative_to(root):
            raise ValueError('actual dependency source escaped original owned root')
        names = runner.run(f'matched-source-files-{ordinal}', ['git', 'ls-files', '-z'], cwd=path,
                           timeout=60).read_text().split('\0')
        # Existing tracked_manifest preserves actual tracked symlink spelling.
        # Reinspection never substitutes a different path or follows that link.
        inventories.append({'path': str(path), 'identity': row['identity'],
                            'commit': row['revision'],
                            'files': development.tracked_manifest(path, names)})
    source = {'sdk': json.loads((runner.receipts / 'sdk-final-manifest.json').read_text()),
              'core': core_inputs, 'dependencies': inventories,
              'resolvedSHA256': calibration.digest(sdk / 'Package.resolved')}
    data = {'schema': 'lattice.sync-matched-preparation/1', 'root': str(root),
            'scope': SCOPE, 'performanceAccepted': False, 'preparedHost': host(),
            'binding': binding, 'source': source, 'common': common(root),
            'measurementFiles': regular_manifest(sdk, MEASUREMENT_FILES),
            'probeFiles': regular_manifest(root / 'LatticeCore', PROBE_FILES),
            'binaries': binary_manifest(root),
            'swiftDriver': str(Path(shutil.which('swift')).resolve(strict=True)),
            'swiftDriverSHA256': calibration.digest(Path(shutil.which('swift')).resolve(strict=True)),
            'inputSHA256': {name: calibration.digest(runner.receipts / name) for name in (
                'sdk-probe-test-inventory.json', 'public-visibility-qualification.json',
                'native-probe-qualification.json', 'build-tests.json', 'compiler-input-proof.json',
                'graph-before.json', 'graph-after.json', 'sync-full-calibration-binding.json')},
            'policy': {'capture': capture.POLICY, 'childSeconds': TIMEOUT,
                       'offeredWorkload': evaluate_sync.FULL}}
    calibration.save(runner.receipts / PREPARATION, data)


def load_development(path):
    spec = importlib.util.spec_from_file_location('matched_guarded_runner', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_prepared(root, development):
    data = json.loads((root / 'receipts' / PREPARATION).read_text())
    result = json.loads((root / 'receipts/RESULT.json').read_text())
    if (data.get('schema') != 'lattice.sync-matched-preparation/1' or data.get('root') != str(root)
            or data.get('preparedHost') != host() or result.get('success') is not True
            or result.get('syncMatchedPreparation') is not True or result.get('evidenceErrors')
            or result.get('receivedSignals') or result.get('nonCorePinsUnchanged') is not True
            or result.get('nonCorePinCount') != 33 or data.get('common') != common(root)
            or data['policy'] != {'capture': capture.POLICY, 'childSeconds': TIMEOUT,
                                 'offeredWorkload': evaluate_sync.FULL}):
        raise ValueError('one genuine completed same-host preparation is required')
    if (result['sdkCommit'] != data['source']['sdk']['commit']
            or result['coreCommit'] != data['source']['core']['commit']):
        raise ValueError('source preparation/result graph mismatch')
    for name, sha in data['inputSHA256'].items():
        if calibration.digest(root / 'receipts' / name) != sha:
            raise ValueError('changed original prerequisite receipt: ' + name)
    if (data['measurementFiles'] != regular_manifest(root / 'lattice', MEASUREMENT_FILES)
            or data['probeFiles'] != regular_manifest(root / 'LatticeCore', PROBE_FILES)):
        raise ValueError('measurement/probe source changed after preparation')
    sdk_inventory = json.loads((root / 'receipts/sdk-probe-test-inventory.json').read_text())
    public = json.loads((root / 'receipts/public-visibility-qualification.json').read_text())
    if (public['analysis']['validCompleteRun'] is not True
            or public['analysis']['receiptCount'] != 10
            or not sdk_inventory.get('expectedCases')
            or any(sdk_inventory['affirmativePassedCases'].count(name) != 1
                   for name in sdk_inventory['expectedCases'])):
        raise ValueError('actual prior importer/public smoke results are missing')
    # The binding is recomputed from preserved actual process/compiler receipts,
    # not accepted merely because a caller supplied a matching JSON shape.
    recomputed = calibration.make_binding(root, data['source']['sdk'], data['source']['core'],
        json.loads((root / 'receipts/graph-before.json').read_text()),
        (root / 'receipts/swift-version.log').read_text(),
        json.loads((root / 'receipts/build-tests.json').read_text()),
        json.loads((root / 'receipts/native-probe.json').read_text()),
        json.loads((root / 'receipts/compiler-input-proof.json').read_text()),
        logging.apply_environment(dict(os.environ, GITHUB_REPOSITORY=result['repository'],
             GITHUB_RUN_ID=result['runID'], GITHUB_RUN_ATTEMPT=result['attempt'],
             GITHUB_JOB=result['job'], DEVELOPMENT_LEG=result['developmentLeg'])), host())
    for key in ('buildConfiguration', 'hostFacts', 'metadata', 'loggingPolicy'):
        if data['binding'][key] != recomputed[key]:
            raise ValueError('actual preserved build/compiler binding differs: ' + key)
    return data


def budget(runner):
    if runner.interrupts.received or time.monotonic() >= runner.work_deadline:
        raise RuntimeError('interruption/unchanged overall work budget')
    violation = runner.violation(runner.measure(runner.receipts / 'RESULT.json'))
    if violation:
        raise RuntimeError('unchanged resource guard: ' + violation)


def reinspect(runner, data, development):
    """No child may silently reuse altered source, compiler input or binary.

    Hashing is outside timed operations and applies equally to every leg. Its
    cache/IO/instrumentation effects still need Native measurement qualification.
    """
    budget(runner)
    root = Path(data['root'])
    if (str(Path(shutil.which('swift')).resolve(strict=True)) != data['swiftDriver']
            or calibration.digest(Path(data['swiftDriver'])) != data['swiftDriverSHA256']):
        raise ValueError('actual prepared Swift compiler driver changed')
    ordinal = len(runner.records)
    for entry in (data['source']['sdk'], data['source']['core'], *data['source']['dependencies']):
        path = Path(entry['path'])
        if not path.resolve(strict=True).is_relative_to(root):
            raise ValueError('source path retargeted outside prepared original')
        if development.tracked_manifest(path, entry['files']) != entry['files']:
            raise ValueError('prepared original tracked bytes changed: ' + str(path))
        head = runner.run(f'reinspect-{ordinal}-head', ['git', 'rev-parse', 'HEAD'], cwd=path,
                          timeout=60).read_text().strip()
        status = runner.run(f'reinspect-{ordinal}-status', ['git', 'status', '--porcelain=v1', '-z',
                           '--untracked-files=all'], cwd=path, timeout=60).read_text().split('\0')
        ordinal += 1
        allowed = ('Package.resolved',) if path == root / 'lattice' else ()
        if head != entry['commit'] or any(row[3:] not in allowed for row in status if row):
            raise ValueError('actual prepared source checkout identity/state changed')
    if binary_manifest(root) != data['binaries']:
        raise ValueError('compiled artifact changed or was added/removed after preparation')
    if calibration.digest(root / 'lattice/Package.resolved') != data['source']['resolvedSHA256']:
        raise ValueError('actual prepared resolved graph changed')
    for name, sha in data['inputSHA256'].items():
        if calibration.digest(root / 'receipts' / name) != sha:
            raise ValueError('prepared native/compiler/graph receipt changed')
    budget(runner)


def schedule(experiment_id):
    rng = random.Random(SEED)
    result = []
    for ordinal in range(1, GROUPS + 1):
        labels = ['A', 'A2']
        rng.shuffle(labels)
        labels.append('B')  # both independent baselines precede candidate
        profiles = ['loaded', 'quiet-only'] if ordinal % 2 else ['quiet-only', 'loaded']
        group_id = f'{experiment_id}/group-{ordinal}'
        result.append({'ordinal': ordinal, 'groupID': group_id, 'profileOrder': profiles,
                       'legs': [{'label': label, 'legID': f'{group_id}/{label}',
                                 'order': f'{order}:{label}'} for order, label in enumerate(labels, 1)]})
    return result


def profile_plan(root, binding, issued_group, issued_leg, profile, original_env):
    directory = root / 'captures' / str(issued_group['ordinal']) / issued_leg['label'] / profile
    if directory.exists() or directory.is_symlink():
        raise ValueError('matched child evidence must be unused: ' + str(directory))
    metadata = dict(binding['metadata'], EXPERIMENT_ID=issued_group['groupID'].rsplit('/', 1)[0],
                    RUN_GROUP=issued_group['groupID'], LEG=issued_leg['label'], LEG_ID=issued_leg['legID'],
                    RUN_ORDER=issued_leg['order'], PROFILE_ORDER=','.join(issued_group['profileOrder']),
                    CAPTURE_POLICY=capture.POLICY)
    env = {key: value for key, value in original_env.items() if not key.startswith(calibration.PREFIX)}
    env = logging.apply_environment(env)
    env.update({calibration.PREFIX + key: value for key, value in metadata.items()})
    env.update({calibration.PREFIX + 'PERF': '1', calibration.PREFIX + 'MATCHED': '1',
                calibration.PREFIX + 'PROFILE': profile, calibration.PREFIX + 'RUN_DIR': str(directory)})
    return {'directory': directory, 'metadata': metadata, 'env': env,
            'label': f"matched-{issued_group['ordinal']}-{issued_leg['label']}-{profile}", 'profile': profile}


def inspect_complete(runner, plan):
    command = json.loads((runner.receipts / (plan['label'] + '.json')).read_text())
    terminal = calibration.inspect_full_log(runner.receipts / (plan['label'] + '.log'), case=CASE)
    raw, sha = evaluate_sync.read_json(plan['directory'] / 'receipts.json')
    analysis = capture.analyze(raw)
    metadata_matches = all(analysis['metadata'].get(k) == v for k, v in plan['metadata'].items())
    exit_code = command.get('exitCode')
    terminal_matches = type(exit_code) is int and (
        (terminal['outcome'] == 'passed' and exit_code == 0 and analysis['timelyCalibration']['validCompleteRun'])
        or (terminal['outcome'] == 'failed' and exit_code > 0 and raw['deadlineFailureRecorded'] is True))
    usable = (calibration.clean_exit(command) and terminal_matches and metadata_matches
              and logging.metadata_valid(analysis['metadata'])
              and analysis['profile'] == plan['profile'] and analysis['measurementPopulationComplete'])
    report = {'scope': SCOPE, 'commandSHA256': calibration.digest(runner.receipts / (plan['label'] + '.json')),
              'inputSHA256': sha, 'terminal': terminal, 'commandSuccess': command['success'],
              'cleanExit': calibration.clean_exit(command), 'metadataMatches': metadata_matches,
              'measurementUsable': bool(usable), 'analysis': analysis, 'releaseOrGoalAccepted': False}
    calibration.save(runner.receipts / (plan['label'] + '-inspection.json'), report)
    return report


def inspect(runner, plan):
    try:
        return inspect_complete(runner, plan)
    except Exception as error:
        # Missing/corrupt receipt, missing terminal line or partial evidence
        # never silently removes this child from the planned denominator.
        report = {'scope': SCOPE, 'measurementUsable': False,
                  'errors': [calibration.failure(error)], 'releaseOrGoalAccepted': False}
        command = runner.receipts / (plan['label'] + '.json')
        if command.is_file():
            report['commandSHA256'] = calibration.digest(command)
        target = runner.receipts / (plan['label'] + '-inspection.json')
        if not target.exists():
            calibration.save(target, report)
        return report


def run(root, baseline, candidate, development):
    receipts = root / 'matched-receipts'
    receipts.mkdir(exist_ok=False)
    experiment_id = 'matched-' + str(uuid.uuid4())
    issued = schedule(experiment_id)
    original_env = os.environ.copy()
    original_env['PYTHONDONTWRITEBYTECODE'] = '1'
    summary = {'scope': SCOPE, 'experimentID': experiment_id, 'success': False,
               'numericalGatesPass': False, 'releaseOrGoalAccepted': False,
               'firstFailure': None, 'evidenceErrors': [], 'profiles': [], 'attemptedProfiles': [], 'unattempted': [], 'comparisons': {}}
    primary = None
    with development.Interrupts() as interrupts:
        runner = development.GuardedRunner(root, receipts, original_env, interrupts)
        try:
            prepared = {name: check_prepared(path, development) for name, path in
                        (('baseline', baseline), ('candidate', candidate))}
            a, b = prepared['baseline'], prepared['candidate']
            if (a['measurementFiles'] != b['measurementFiles'] or a['probeFiles'] != b['probeFiles']
                    or a['binding']['hostFacts'] != b['binding']['hostFacts']
                    or a['binding']['buildConfiguration']['toolchain'] != b['binding']['buildConfiguration']['toolchain']):
                raise ValueError('A/B must share exact measurement/probe code, actual host and toolchain')
            graph = lambda x: [row for row in x['binding']['buildConfiguration']['graph'] if row['identity'] != 'latticecore']
            if graph(a) != graph(b):
                raise ValueError('non-Core dependency graph differs across matched builds')
            # Immutable schedule and binding issued BEFORE any measurement child.
            calibration.save(receipts / 'EXPERIMENT.json', {'schema': 'lattice.sync-matched-experiment/1',
                'experimentID': experiment_id, 'host': host(), 'orderSeed': SEED,
                'orderPolicy': 'deterministic A/A2 shuffle then B; loaded/quiet order alternates per group and is shared by all three legs',
                'groups': issued, 'capturePolicy': capture.POLICY,
                'childBudgetSeconds': TIMEOUT, 'overallSeconds': development.OVERALL_SECONDS,
                'finalizationReserveSeconds': development.FINALIZATION_RESERVE,
                'resourceLimits': {'freeFloor': development.FREE_FLOOR, 'packetCeiling': development.PACKET_CEILING,
                                   'logCeiling': development.LOG_CEILING},
                'preparations': {name: {'root': data['root'], 'preparationSHA256': calibration.digest(Path(data['root']) / 'receipts' / PREPARATION),
                                      'RESULTSHA256': calibration.digest(Path(data['root']) / 'receipts/RESULT.json'),
                                      'binding': data['binding']} for name, data in prepared.items()}})
            analyzed = {'loaded': [], 'quiet-only': []}
            manifests = {'loaded': [], 'quiet-only': []}
            seen_runs = set()
            for group in issued:
                per_profile = {'loaded': {}, 'quiet-only': {}}
                files = {'loaded': {}, 'quiet-only': {}}
                for leg in group['legs']:
                    data = a if leg['label'] in ('A', 'A2') else b
                    graph_root = Path(data['root'])
                    calibration.save(receipts / f"LEG-{group['ordinal']}-{leg['label']}.json",
                        {'group': group, 'leg': leg, 'preparationSHA256': calibration.digest(graph_root / 'receipts' / PREPARATION),
                         'host': host(), 'issuedBeforeChild': True, 'capturePolicy': capture.POLICY,
                         'common': data['common'], 'flags': FLAGS, 'childBudgetSeconds': TIMEOUT,
                         'binding': data['binding']})
                    for profile in group['profileOrder']:
                        reinspect(runner, data, development)
                        version = runner.run(f"version-{group['ordinal']}-{leg['label']}-{profile}",
                                             ['swift', '--version'], cwd=graph_root / 'lattice', timeout=60).read_text()
                        if version.strip() != data['binding']['buildConfiguration']['toolchain']:
                            raise ValueError('actual Swift toolchain changed before child')
                        plan = profile_plan(root, data['binding'], group, leg, profile, original_env)
                        # Use this prepared graph's original scratch/cache paths.
                        plan['env'].update({name: str(graph_root / suffix) for name, suffix in (
                            ('TMPDIR', 'tmp'), ('TMP', 'tmp'), ('TEMP', 'tmp'),
                            ('CLANG_MODULE_CACHE_PATH', 'module-cache'), ('SWIFT_MODULECACHE_PATH', 'module-cache'),
                            ('SWIFTPM_MODULECACHE_OVERRIDE', 'module-cache'))})
                        calibration.save(receipts / (plan['label'] + '-ISSUED.json'),
                            {'metadata': plan['metadata'], 'directory': str(plan['directory']),
                             'binding': data['binding'], 'budgetSeconds': TIMEOUT, 'capturePolicy': capture.POLICY})
                        summary['attemptedProfiles'].append(plan['label'])
                        try:
                            runner.env = plan['env']
                            runner.run(plan['label'], ['swift', 'test', *data['common'], *FLAGS,
                                '--force-resolved-versions', '--skip-build', '--filter', FILTER],
                                cwd=graph_root / 'lattice', timeout=TIMEOUT, require_full_timeout=True)
                        except Exception:
                            # An ordinary deadline assertion failure is retained
                            # by GuardedRunner, never changed to command success.
                            # Only exact actual terminal/whole capture inspection
                            # can permit the next independent measurement child.
                            pass
                        finally:
                            runner.env = original_env
                        report = inspect(runner, plan)
                        summary['profiles'].append({'label': plan['label'], 'measurementUsable': report['measurementUsable'],
                                                    'inspectionSHA256': calibration.digest(receipts / (plan['label'] + '-inspection.json'))})
                        reinspect(runner, data, development)
                        if not report['measurementUsable']:
                            raise ValueError('child missing/invalid/process failure: ' + plan['label'])
                        run_id = report['analysis']['runID']
                        if run_id in seen_runs:
                            raise ValueError('actual run identity reused across experiment')
                        seen_runs.add(run_id)
                        per_profile[profile][leg['label']] = report['analysis']
                        files[profile][leg['label']] = str((plan['directory'] / 'receipts.json').relative_to(receipts.parent))
                for profile in ('loaded', 'quiet-only'):
                    analyzed[profile].append(per_profile[profile])
                    manifests[profile].append(files[profile])
            for profile in ('loaded', 'quiet-only'):
                calibration.save(root / ('MATCHED-' + profile + '.json'), {'groups': manifests[profile]})
                summary['comparisons'][profile] = capture.compare(analyzed[profile], profile=profile)
            summary['numericalGatesPass'] = all(r['numericalGatesPass'] for r in summary['comparisons'].values())
            summary['success'] = True  # evidence coordinator completion, not deadline/release acceptance
        except BaseException as error:
            primary = error
            summary['firstFailure'] = calibration.failure(error)
        finally:
            runner.env = original_env
            with interrupts.hold():
                attempted = set(summary['attemptedProfiles'])
                summary['unattempted'] = [f"matched-{g['ordinal']}-{l['label']}-{p}" for g in issued
                    for l in g['legs'] for p in g['profileOrder'] if f"matched-{g['ordinal']}-{l['label']}-{p}" not in attempted]
                summary.update(commands=runner.records, receivedSignals=interrupts.received,
                               elapsedSeconds=time.monotonic() - runner.started)
                try:
                    summary['finalResources'] = runner.measure(receipts / 'RESULT.json')
                    violation = runner.violation(summary['finalResources'])
                    if violation:
                        raise RuntimeError('final unchanged resource guard: ' + violation)
                except BaseException as error:
                    summary['success'] = False
                    summary['numericalGatesPass'] = False
                    summary['evidenceErrors'].append(calibration.failure(error))
                    if primary is None:
                        primary = error
                        summary['firstFailure'] = calibration.failure(error)
                if interrupts.received or time.monotonic() > runner.overall_deadline:
                    summary['success'] = False
                    summary['numericalGatesPass'] = False
                try:
                    calibration.save(receipts / 'RESULT.json', summary)
                except BaseException as error:
                    summary['success'] = False
                    summary['evidenceErrors'].append(calibration.failure(error))
                    if primary is None:
                        primary = error
                    print('MATCHED_RESULT_WRITE_FAILED', json.dumps(summary), flush=True)
    if primary is not None:
        raise primary
    if not summary['success'] or not summary['numericalGatesPass']:
        raise ValueError('matched experiment incomplete or numerical gates failed; all receipts retained')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--baseline-root', type=Path, required=True)
    parser.add_argument('--candidate-root', type=Path, required=True)
    args = parser.parse_args()
    allowed = (Path.home() / 'localdev').resolve(strict=True)
    root, baseline, candidate = (path.resolve(strict=True) for path in
                                 (args.root, args.baseline_root, args.candidate_root))
    if (root == allowed or not root.is_relative_to(allowed) or baseline == candidate
            or not baseline.is_relative_to(root) or not candidate.is_relative_to(root)
            or baseline == root or candidate == root):
        raise ValueError('two distinct prepared original roots must be children of one owned ~/localdev experiment')
    development = load_development(Path(__file__).with_name('run-development.py'))
    run(root, baseline, candidate, development)


if __name__ == '__main__':
    main()
