#!/usr/bin/env python3
"""One changed-observability original A2-loaded child; never numerical evidence."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import resource
import sys
import time
import uuid

ORIGINAL_BASELINE = 'c30f2f30e229dc917f4aa2583ce3c872b5abbecb'
BASELINE = '739877770932b7cc334efb558c738288a29e416a'
CORE = 'a05fd480236430ab0d707ed0201d3edbef299de5'
TOOLCHAIN = ('swift-driver version: 1.148.6 Apple Swift version 6.3.3 '
             '(swiftlang-6.3.3.1.3 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0')
BACKTRACE = ('enable=yes,interactive=no,threads=all,registers=crashed,images=mentioned,'
             'limit=64,top=16,format=json,sanitize=no,output-to=stderr')
SCOPE = 'One original A2-loaded SIG11 diagnostic; no numerical/release/recovery acceptance.'


def save(path, value):
    with path.open('x') as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')


def pin(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('original regular image required: ' + str(path))
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return {'path': str(path), 'bytes': path.stat().st_size, 'sha256': digest.hexdigest()}


def entitlement(log):
    text = log.read_bytes()
    begin, end = text.find(b'<?xml'), text.find(b'</plist>')
    if begin < 0 or end < begin or text.find(b'<?xml', begin + 1) >= 0:
        raise ValueError('one actual helper entitlement plist required')
    value = plistlib.loads(text[begin:end + len(b'</plist>')])
    if not isinstance(value, dict) or value.get('com.apple.security.get-task-allow') is not True:
        raise ValueError('original SwiftPM helper lacks required debug entitlement; images unchanged')
    return value


def modules(root):
    scripts = root / 'baseline/lattice/Scripts'
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(scripts))
    spec = importlib.util.spec_from_file_location('original_matched', scripts / 'sync_matched_experiment.py')
    matched = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(matched)
    return matched, matched.load_development(scripts / 'run-development.py')


def original_helper(observation, runner, label):
    facts = observation['facts']
    expected = ['/usr/bin/codesign', '--display', '--entitlements', ':-',
                '/Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper']
    if (len(facts) != 3 or facts[0].get('argv') != ['swift', '--version']
            or facts[0].get('exitCode') != 0
            or (facts[0]['stderr'] + facts[0]['stdout']).strip() != TOOLCHAIN
            or facts[1].get('argv') != expected or facts[1].get('exitCode') != 0
            or facts[2].get('accepted') is not True):
        raise ValueError('exact original toolchain/helper observation required')
    helper = Path(facts[1]['argv'][-1])
    before = pin(helper)
    log = runner.run(label, ['/usr/bin/codesign', '--display', '--entitlements', ':-', str(helper)],
                     cwd=runner.root, timeout=30, require_full_timeout=True)
    entitlements = entitlement(log)
    if pin(helper) != before:
        raise ValueError('actual original helper changed during inspection')
    return {'image': before, 'entitlements': entitlements, 'entitlementLog': pin(log)}


def lifecycle_module():
    path = Path(__file__).with_name('baseline_crash_lifecycle.py')
    spec = importlib.util.spec_from_file_location('scoped_baseline_lifecycle', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def observed_image_uuids(runner, module, images):
    result = {}
    for ordinal, image in enumerate(images):
        before = pin(Path(image['path']))
        if before != image:
            raise ValueError('original diagnostic image changed')
        log = runner.run('original-image-uuid-' + str(ordinal),
                         ['/usr/bin/dwarfdump', '--uuid', image['path']],
                         cwd=runner.root, timeout=30, require_full_timeout=True)
        rows = module.image_uuids(log.read_text())
        if any(row['path'] != image['path'] for row in rows) or pin(Path(image['path'])) != image:
            raise ValueError('original image UUID supplier differs')
        result[image['path']] = {row['uuid'] for row in rows}
    return result


def run(root):
    matched, development = modules(root)
    receipts = root / 'matched-receipts'
    receipts.mkdir(exist_ok=False)
    baseline = root / 'baseline'
    env = os.environ.copy()
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    result = {'scope': SCOPE, 'attemptedProfile': None, 'actualChildStarted': None,
              'success': False, 'firstError': None, 'numericalGatesPass': False,
              'originalRunID': '38694390397', 'originalFailedLabel': 'matched-1-A2-loaded',
              'releaseOrGoalAccepted': False}
    first = None
    with development.Interrupts() as interrupts:
        runner = development.GuardedRunner(root, receipts, env, interrupts)
        try:
            data = matched.check_prepared(baseline, development)
            if (data['source']['sdk']['commit'] != BASELINE or data['source']['core']['commit'] != CORE
                    or data['binding']['buildConfiguration']['toolchain'] != TOOLCHAIN):
                raise ValueError('exact test-only diagnostic child of original c30/a05/Swift6.3.3 preparation required')
            matched.reinspect(runner, data, development)
            observation = json.loads((root / 'hosted-receipts/ORIGINAL-TOOLCHAIN.json').read_text())
            helper = original_helper(observation, runner, 'original-helper-entitlements')
            early = observation['facts'][-1]
            if (early.get('accepted') is not True or early['helperSHA256'] != helper['image']['sha256']
                    or early['helperBytes'] != helper['image']['bytes']):
                raise ValueError('original helper changed since pre-build observation')
            images = [name for name in data['binaries'] if '.xctest/Contents/MacOS/' in name and '.dSYM/' not in name]
            if len(images) != 1:
                raise ValueError('one original prepared debug test image required')
            image = pin(baseline / images[0])
            if {k: image[k] for k in ('bytes', 'sha256')} != data['binaries'][images[0]]:
                raise ValueError('prepared original test image changed')
            runner.run('original-test-image-signature', ['/usr/bin/codesign', '--display', '--entitlements', ':-', image['path']],
                       cwd=root, timeout=30, require_full_timeout=True)
            version = runner.run('original-swift-version', ['swift', '--version'], cwd=baseline / 'lattice', timeout=60).read_text().strip()
            if version != TOOLCHAIN:
                raise ValueError('actual original toolchain changed')
            lifecycle = lifecycle_module()
            observed_uuids = observed_image_uuids(runner, lifecycle, [helper['image'], image])
            diagnostic_id = str(uuid.uuid4())
            experiment = 'sig11-diagnostic-' + str(uuid.uuid4())
            group = {'ordinal': 1, 'groupID': experiment + '/group-1', 'profileOrder': ['loaded', 'quiet-only']}
            leg = {'label': 'A2', 'legID': group['groupID'] + '/A2', 'order': '1:A2'}
            plan = matched.profile_plan(root, data['binding'], group, leg, 'loaded', env)
            plan['env'].update({name: str(baseline / suffix) for name, suffix in (
                ('TMPDIR', 'tmp'), ('TMP', 'tmp'), ('TEMP', 'tmp'),
                ('CLANG_MODULE_CACHE_PATH', 'module-cache'), ('SWIFT_MODULECACHE_PATH', 'module-cache'),
                ('SWIFTPM_MODULECACHE_OVERRIDE', 'module-cache'))})
            plan['env']['SWIFT_BACKTRACE'] = BACKTRACE
            plan['env']['LATTICE_BASELINE_LIFECYCLE_PHASES'] = '1'
            plan['env']['LATTICE_BASELINE_DIAGNOSTIC_ID'] = diagnostic_id
            original_core_limit = resource.getrlimit(resource.RLIMIT_CORE)
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            save(receipts / 'DIAGNOSTIC-ISSUED.json', {'scope': SCOPE, 'baselinePreparation': pin(baseline / 'receipts/sync-matched-preparation.json'),
                'originalHelper': helper, 'originalTestImage': image,
                'source': {'sdk': BASELINE, 'core': CORE, 'productionSDKParent': ORIGINAL_BASELINE},
                'diagnosticID': diagnostic_id, 'actualImageUUIDs': {key: sorted(value) for key, value in observed_uuids.items()},
                'oneTestOnlyLifecycleFollowing': True, 'mainMatchedBaselineAndCandidateUnchanged': True,
                'originalEnvironmentSWIFT_BACKTRACE': os.environ.get('SWIFT_BACKTRACE'),
                'diagnosticEnvironmentSWIFT_BACKTRACE': BACKTRACE,
                'coreDumpRlimitBefore': original_core_limit, 'coreDumpRlimitDuring': resource.getrlimit(resource.RLIMIT_CORE),
                'metadata': plan['metadata'], 'capturePolicy': matched.capture.POLICY,
                'childBudgetSeconds': matched.TIMEOUT, 'offeredWorkload': matched.evaluate_sync.FULL,
                'originalMeasurementAndProbeBodies': {'sdk': data['measurementFiles'], 'core': data['probeFiles']},
                'noImageResigningOrMutation': True, 'plannedDiagnosticProfiles': [plan['label']],
                'originalThirtyProfileComparisonStillIncomplete': True})
            result['attemptedProfile'] = plan['label']
            runner.env = plan['env']
            observed_started_wall = time.time()
            try:
                runner.run(plan['label'], ['swift', 'test', *data['common'], *matched.FLAGS,
                    '--force-resolved-versions', '--skip-build', '--filter', matched.FILTER],
                    cwd=baseline / 'lattice', timeout=matched.TIMEOUT, require_full_timeout=True)
            except Exception:
                pass  # Actual command/first signal remains in the original GuardedRunner receipt.
            finally:
                runner.env = env
            observed_ended_wall = time.time()
            command = json.loads((receipts / (plan['label'] + '.json')).read_text())
            log_path = receipts / (plan['label'] + '.log')
            try:
                observation = lifecycle.phases(log_path, command, diagnostic_id,
                    {helper['image']['path'], image['path']}, observed_started_wall, observed_ended_wall)
            except Exception as error:
                observation = {'qualified': False, 'unknown': True, 'category': type(error).__name__,
                               'originalOutcomeUnchanged': True}
            observation_evidence_errors = []
            try:
                save(receipts / 'LIFECYCLE-OBSERVATION.json', observation)
            except Exception as error:
                observation_evidence_errors.append({'stage': 'phase-data-retention', 'category': type(error).__name__})
            # Optional DATA cannot replace the actual command, terminal test or
            # cleanup result. No observer process, debugger or new signal policy.
            try:
                os_report = lifecycle.collect_reports(receipts, observation,
                    observed_started_wall, observed_ended_wall, observed_uuids, image['path'],
                    min(runner.work_deadline, time.monotonic() + 10),
                    lifecycle.unexpected_sig11(log_path))
            except Exception as error:
                os_report = {'unknown': True, 'category': type(error).__name__,
                             'originalOutcomeUnchanged': True}
            try:
                save(receipts / 'SIG11-OS-REPORT-OBSERVATION.json', os_report)
            except Exception as error:
                observation_evidence_errors.append({'stage': 'OS-report-data-retention', 'category': type(error).__name__})
            result.update(lifecycleObservation=observation, osReportObservation=os_report,
                          originalProductionBaseline=ORIGINAL_BASELINE,
                          actualDiagnosticOnlyTestChild=BASELINE, noCauseAssigned=True,
                          observationEvidenceErrors=observation_evidence_errors)
            report = matched.inspect(runner, plan)
            result.update(actualChildStarted=command['started'], exitCode=command['exitCode'],
                          commandReceipt=pin(receipts / (plan['label'] + '.json')),
                          log=pin(receipts / (plan['label'] + '.log')), inspection=report)
            if pin(Path(helper['image']['path'])) != helper['image'] or pin(baseline / images[0]) != image:
                raise ValueError('original helper or test image changed during diagnostic')
            matched.reinspect(runner, data, development)
            # This is only supervisor/retention completion. A crash or incomplete
            # fixture stays unsuccessful and no numerical comparison is emitted.
            result['originalProfileSucceeded'] = command['success'] is True and report.get('measurementUsable') is True
            result['success'] = result['originalProfileSucceeded'] and not observation_evidence_errors
        except BaseException as error:
            first = error
            result['firstError'] = {'type': type(error).__name__, 'message': str(error)}
        finally:
            runner.env = env
            with interrupts.hold():
                result.update(commands=runner.records, receivedSignals=interrupts.received, evidenceErrors=[])
                try:
                    result['finalResources'] = runner.measure(receipts / 'DIAGNOSTIC-RESULT.json')
                    if runner.violation(result['finalResources']):
                        raise ValueError('unchanged final resource guard refused')
                except BaseException as error:
                    result['success'] = False
                    result['evidenceErrors'].append({'type': type(error).__name__, 'message': str(error)})
                if interrupts.received:
                    result['success'] = False
                save(receipts / 'DIAGNOSTIC-RESULT.json', result)
    if first is not None:
        raise first
    if not result['success']:
        raise ValueError('diagnostic child failed/incomplete; exact first logs retained')


def retain(root):
    # Reuse the reviewed bounded actual evidence copier; no stores/builds/cache.
    spec = importlib.util.spec_from_file_location('existing_hosted_retainer', Path(__file__).with_name('sync_matched_hosted.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    manifest = module.retain(root)
    save(root / 'hosted-receipts/RETENTION.json', {'scope': SCOPE, 'manifest': manifest, 'noNumericalAcceptance': True})
    if manifest['omitted']:
        raise ValueError('bounded evidence omissions retained')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('operation', choices=('run', 'retain'))
    args = parser.parse_args()
    root = args.root
    expected = Path.home() / 'localdev' / ('lattice-baseline-sig11-' + os.environ.get('GITHUB_RUN_ID', '') + '-' + os.environ.get('GITHUB_RUN_ATTEMPT', ''))
    if (root.is_symlink() or root.resolve(strict=True) != expected.resolve(strict=True)
            or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_OS') != 'macOS'
            or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
            or os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'):
        raise ValueError('actual owned hosted macOS diagnostic namespace required')
    (run if args.operation == 'run' else retain)(root)


if __name__ == '__main__':
    main()
