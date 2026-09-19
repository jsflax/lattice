"""Narrow source/admission checks for the existing guarded A/A2/B driver."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex

HEX64 = re.compile(r'^[0-9a-f]{64}$')
FORBIDDEN = ('LATTICE_MANAGED_CELL_STATEMENT_REUSE', 'LATTICE_MANAGED_CELL_SWIFT_MECHANISM')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def packet_check(packet, expected):
    require(HEX64.fullmatch(expected or ''), 'exact reviewed packet seal required')
    path = packet / 'PACKET-SEAL.json'
    require(digest(path) == expected, 'reviewed packet seal changed')
    seal = json.loads(path.read_text())
    required = {'run-release-benchmark.py', 'binding.py', 'guarded_runner.py', 'build_proof.py',
                'perf_refinement_report.py', 'benchmark-sources.json', 'PerfRefinementBenchmarks.swift',
                'baseline-product.patch', 'TableResults.corrected.swift', 'baseline-focused-assessment.json',
                'baseline-legacy-assessment.json', 'manifests/baseline-sdk-pristine.json',
                'manifests/baseline-sdk-effective.json', 'manifests/baseline-core.json',
                'manifests/candidate-sdk.json', 'manifests/candidate-core.json', 'manifests/dependency-pins.json'}
    require(required <= set(seal['files']), 'required runtime input missing from packet seal')
    for name, expected_hash in seal['files'].items():
        path = packet / name
        require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(packet), 'unsafe sealed path')
        require(digest(path) == expected_hash, 'sealed input changed: ' + name)
    return seal


def admission_check(path, expected_hash, config):
    require(HEX64.fullmatch(expected_hash or '') and digest(path) == expected_hash, 'root admission receipt hash mismatch')
    admission = json.loads(path.read_text())
    require(admission.get('scope') == 'same-hosted-allocation-corrected-A-A2-B', 'wrong admission scope')
    require(admission.get('baselineLegacyAssessmentSHA256') == config['baselineLegacyAssessmentSHA256'], 'wrong baseline prerequisite')
    for key, commit, tree in [('sdk', config['candidateSDK'], config['candidateSDKTree']),
                              ('core', config['candidateCore'], config['candidateCoreTree'])]:
        gate = admission.get('candidateQualification', {}).get(key, {})
        require(gate.get('accepted') is True and gate.get('commit') == commit and gate.get('tree') == tree,
                'candidate exact-source qualification missing: ' + key)
        require(type(gate.get('run')) is int and gate['run'] > 0
                and HEX64.fullmatch(gate.get('assessmentSHA256', '')), 'candidate assessment binding missing: ' + key)
    require(admission.get('physicalHostQualified') is False, 'hosted scope cannot assert physical placement')
    return admission


def config_check(config, packet):
    require(config.get('schemaVersion') == 2, 'wrong binding revision')
    require(config['measuredSamples'] == 100 and config['warmups'] == 5 and config['settlingSeconds'] == 60,
            'frozen sampling policy changed')
    require(config.get('variants') == ['local', 'attached'], 'both frozen physical variants required')
    require(config['baselineProductPatchesAllowed'] is False, 'generic baseline patches forbidden')
    require(config['candidateSwiftDefine'] == 'LATTICE_PERF_SELECTED_BATCH', 'unexpected candidate write implementation')
    fixed = {'freeFloorBytes': 12884901888, 'packetCeilingBytes': 32212254720,
             'overallSeconds': 18000, 'finalizationReserveSeconds': 600,
             'buildTimeoutSeconds': 5400, 'measurementTimeoutSeconds': 1200}
    require(all(config[k] == v for k, v in fixed.items()), 'resource/time policy changed')
    overlay = config['baselineCorrectnessOverlay']
    require(overlay['path'] == 'Sources/Lattice/Results/TableResults.swift'
            and digest(packet / 'baseline-product.patch') == overlay['patchSHA256']
            and digest(packet / 'TableResults.corrected.swift') == overlay['postimageSHA256'],
            'baseline correction differs from qualified exact overlay')
    require(digest(packet / 'baseline-legacy-assessment.json') == config['baselineLegacyAssessmentSHA256']
            and digest(packet / 'baseline-focused-assessment.json') == config['baselineFocusedAssessmentSHA256'],
            'baseline prerequisite receipt changed')
    legacy = json.loads((packet / 'baseline-legacy-assessment.json').read_text())
    focused = json.loads((packet / 'baseline-focused-assessment.json').read_text())
    require(legacy.get('accepted') is True and len(legacy['tests']) == 4
            and legacy['sdkCommit'] == config['baselineSDK'] and legacy['coreCommit'] == config['baselineCore'],
            'four-case baseline prerequisite absent')
    require(focused.get('correctedFocusedAccepted') is True and focused.get('reproductionConfirmed') is True
            and focused['sdkCommit'] == config['baselineSDK'] and focused['coreCommit'] == config['baselineCore'],
            'corrected focused and original red prerequisite absent')
    for name, expected_hash in config['frozenFiles'].items():
        require(digest(packet / name) == expected_hash, 'frozen helper changed: ' + name)


def manifest(packet, name):
    return json.loads((packet / 'manifests' / (name + '.json')).read_text())


def complete_sources(repository, expected, *, edited_core=None, mutable_lock=False):
    """Check all bytes, including untracked/ignored files; only root SwiftPM state is excluded."""
    require(repository.is_dir() and not repository.is_symlink() and repository.resolve() == repository,
            'source root must be a real owned directory')
    require(not any(p == '.swiftpm' or p.startswith('.swiftpm/') for p in expected),
            'root SwiftPM state exclusion overlaps committed source')
    require(not (repository / '.swiftpm').is_symlink(), 'root SwiftPM state cannot be a symlink')
    found = {}
    links = {}
    for directory, dirs, names in os.walk(repository, followlinks=False):
        parent = Path(directory)
        if parent == repository:
            dirs[:] = [d for d in dirs if d not in ('.git', '.swiftpm')]
        for name in list(dirs) + names:
            path = parent / name
            relative = str(path.relative_to(repository))
            if parent == repository and name in ('.git', '.swiftpm'):
                continue
            if path.is_symlink():
                links[relative] = str(path.resolve(strict=True))
                if name in dirs:
                    dirs.remove(name)
            elif path.is_file():
                found[relative] = {'sha256': digest(path), 'bytes': path.stat().st_size}
    allowed_links = {} if edited_core is None else {'Packages/LatticeCore': str(edited_core)}
    require(links == allowed_links, 'unexpected source symlink or missing exact Core edit')
    expected = dict(expected)
    if mutable_lock:
        found.pop('Package.resolved', None)
        expected.pop('Package.resolved', None)
    require(found == expected, 'complete source inventory/hash drift: ' + str(repository))
    return {'fileCount': len(found), 'links': links}


def command_check(receipts, label):
    path = receipts / (label + '.json')
    record = json.loads(path.read_text())
    cleanup = record['cleanup']
    require(record['success'] and record['started'] and record['exitCode'] == 0
            and record['primaryError'] is None and not record.get('stopReason')
            and not record['evidenceErrors'] and not record['receivedSignals']
            and cleanup['groupGone'] and cleanup['leaderReaped']
            and not cleanup.get('signals') and not cleanup.get('errors'), 'unclean command: ' + label)
    require(digest(receipts / (label + '.log')) == record['logSHA256'], 'command log changed: ' + label)
    return {'label': label, 'receiptSHA256': digest(path), 'logSHA256': record['logSHA256']}


def compiler_flags(proof, log, scratch, expand, selected_batch):
    """Reject diagnostic/native prototype conditions in actual compiler actions."""
    def check(args):
        require(not any(any(name in token for name in FORBIDDEN) for token in args),
                'private managed-cell prototype/diagnostic compiler option present')
    for item in proof['nativeObjects'].values():
        check(item['expandedArguments'])
    modules = {}
    for line in log.read_text().splitlines():
        try:
            args = shlex.split(line)
        except ValueError:
            continue
        if args[:2] == ['builtin-SwiftDriver', '--']:
            args = args[2:]
        if not args or Path(args[0]).name != 'swiftc' or '-module-name' not in args or '-output-file-map' not in args:
            continue
        module = args[args.index('-module-name') + 1]
        args, responses = expand(args, scratch)
        check(args)
        enabled = ('-DLATTICE_PERF_SELECTED_BATCH' in args
                   or any(args[i:i+2] == ['-D', 'LATTICE_PERF_SELECTED_BATCH'] for i in range(len(args)-1)))
        require(enabled == selected_batch, 'selected batch compiler definition mismatch: ' + module)
        require(not any(a.startswith(('-ULATTICE_PERF_SELECTED_BATCH', '-DLATTICE_PERF_SELECTED_BATCH=')) for a in args),
                'conflicting selected batch definition')
        modules[module] = {'selectedBatch': enabled, 'responseFiles': responses}
    require({'Lattice', 'LatticeTests'} <= set(modules), 'missing actual Swift compiler actions')
    return modules


def target_observations(comparison, candidate):
    rows = {}
    for variant in ('local', 'attached'):
        phases = {}
        for phase in ('read.total', 'update.total'):
            observed = comparison[variant][phase]['p95']
            phases[phase] = {
                'atLeastTwoTimesFasterThanBothBaselines': observed['candidateMs'] * 2 <= min(observed['baselineMs'], observed['repeatMs']),
                'exceedsObservedAADifference': observed['candidateBelowBothByMoreThanAADifference'],
                'observedP95': observed,
            }
        maximum = candidate['variants'][variant]['phases']['read.cold_page_identity_anchor']['sqlStatements']['max']
        rows[variant] = {'latency': phases, 'coldSQLMaximum': maximum, 'coldSQLAtMostThree': maximum <= 3}
    return {'observations': rows, 'physicalHostQualified': False, 'performanceGoalAchieved': False,
            'scope': 'Descriptive same hosted allocation only; target/noise thresholds unchanged; physical-host gate remains open.'}
