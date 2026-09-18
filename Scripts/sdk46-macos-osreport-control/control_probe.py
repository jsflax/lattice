#!/usr/bin/env python3
"""Prove OS report capture on a tiny direct child. No SDK/network path exists."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import stat
import sys
import time
import control_reports
import parse_report
import development_supervisor as guard

P = Path(__file__).resolve().parent


def authenticate(seal_sha):
    path = P / 'SOURCE-SEAL.json'
    assert guard.digest(path) == seal_sha, 'source seal mismatch'
    seal = json.loads(path.read_text())
    assert seal['scope'] == 'SDK46 OS-report control only'
    for name, expected in seal['files'].items():
        candidate = P / name
        assert candidate.resolve().is_relative_to(P) and not candidate.is_symlink()
        assert guard.digest(candidate) == expected, 'source drift: ' + name
    return seal


def expected_signal(record):
    assert record['started'] and record['exitCode'] == -11
    assert not record['primaryError'] and not record['evidenceErrors'] and not record['receivedSignals'] and not record['stopReason']
    cleanup = record['cleanup']
    assert cleanup['leaderReaped'] and cleanup['groupGone'] and not cleanup['signals'] and not cleanup['errors']
    return record['pid']


def retained_report(path, expected_sha):
    fd = os.open(path,os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as stream:
        before = os.fstat(stream.fileno())
        assert stat.S_ISREG(before.st_mode) and 0 < before.st_size <= parse_report.MAX_REPORT
        data = stream.read(parse_report.MAX_REPORT+1)
        after = os.fstat(stream.fileno())
    assert (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns) == (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns)
    assert len(data) == before.st_size and hashlib.sha256(data).hexdigest() == expected_sha
    return data


def main():
    args = argparse.ArgumentParser()
    args.add_argument('--root', type=Path, required=True)
    args.add_argument('--source-seal-sha256', required=True)
    args = args.parse_args()
    seal = authenticate(args.source_seal_sha256)
    root = args.root.resolve(); allowed = (Path.home()/'localdev').resolve(strict=True)
    assert root.is_relative_to(allowed) and root != allowed and not root.exists()
    root.mkdir(parents=True, exist_ok=False)
    for name in ['receipts','control','tmp','module-cache']:
        (root/name).mkdir()
    rec = root/'receipts'
    env = os.environ.copy()
    env.update(TMPDIR=str(root/'tmp'), TMP=str(root/'tmp'), TEMP=str(root/'tmp'),
               CLANG_MODULE_CACHE_PATH=str(root/'module-cache'), SWIFT_MODULECACHE_PATH=str(root/'module-cache'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(root/'module-cache'), PYTHONDONTWRITEBYTECODE='1',
               SWIFT_BACKTRACE='enable=yes,interactive=no,output-to=stderr')
    resource.setrlimit(resource.RLIMIT_CORE, (0,0))
    result = {'scope':'control-only OS-report mechanism; no SDK qualification', 'sourceSealSHA256':args.source_seal_sha256,
              'sourceFiles':seal['files'], 'success':False, 'controlCompleted':False, 'controlCaptureAccepted':False,
              'sdkBuildStarted':False, 'focusedAccepted':False, 'fullSuiteAccepted':False,
              'releaseQualified':False, 'crashCauseEstablished':False,
              'workflowCommit':env.get('GITHUB_SHA'), 'primaryError':None, 'evidenceErrors':[],
              'captureRejections':[], 'nativeCaps':{'version':30,'compile':60,'execution':10},
              'reportArrivalSeconds':60, 'overallSeconds':240, 'cleanupReserveSeconds':30,
              'selectedEnvironment':{'SWIFT_BACKTRACE':env['SWIFT_BACKTRACE']}}
    collector = admission = signal_record = None
    source_path = root/'control/CrashControl.swift'
    # Fresh owned path + PID + time is the identity gate; no old report is reused.
    binary = root/'control/CrashControl'
    admitted_source = admitted_binary = None
    with guard.Interrupts() as interrupts:
        runner = guard.GuardedRunner(root,rec,env,interrupts,overall_seconds=240,reserve=30)
        try:
            assert platform.system() == 'Darwin' and platform.machine() == 'arm64'
            assert re.fullmatch('[0-9a-f]{40}', env.get('GITHUB_SHA','')), 'exact workflow commit missing'
            version = runner.run('swift-version',['swift','--version'],cwd=root,timeout=30,require_full_timeout=True).read_text()
            assert re.search(r'\bSwift version 6\.3\.3\b',version), 'unreviewed toolchain'
            result['swiftVersion'] = version[:4096]
            shutil.copyfile(P/'CrashControl.swift',source_path)
            runner.run('control-compile',['swiftc','-Onone','-g','-module-name','SDK46CrashControl',str(source_path),'-o',str(binary)],cwd=root,timeout=60,require_full_timeout=True)
            admitted_source, admitted_binary = guard.digest(source_path), guard.digest(binary)
            assert admitted_source == seal['files']['CrashControl.swift'], 'compiled control source differs'
            result.update(controlSourceSHA256=admitted_source,controlBinarySHA256=admitted_binary)
            launch_begin = time.time()
            collector = control_reports.Collector(root,rec/'crash-reports',launch_begin,binary)
            try:
                runner.run('control-signal',[str(binary)],cwd=root,timeout=10,require_full_timeout=True)
            except Exception as error:
                result['expectedSignalCommandError'] = guard.error_record(error)
            exit_end = time.time()
            signal_record = json.loads((rec/'control-signal.json').read_text())
            pid = expected_signal(signal_record)
            result['controlCompleted'] = True
            result.update(launchBeginEpoch=launch_begin,exitEndEpoch=exit_end,ownedPID=pid,executable=str(binary))
            assert time.monotonic()+60 <= runner.work_deadline, 'cannot admit complete 60s report window'
            assert not runner.violation(runner.measure(rec/'CONTROL-ADMISSION.json')), 'pre-scan resource guard'
            captured = collector.scan('control-arrival',wait_seconds=60)
            scan_end = time.time()
            guard.save_json(rec/'control-scan.json',captured)
            for entry in captured['files']:
                if entry['status'] != 'complete':
                    continue
                report_path = rec/'crash-reports'/entry['name']
                try:
                    proof = parse_report.parse(retained_report(report_path,entry['sha256']),executable=str(binary),pid=pid,
                                               launch_begin=launch_begin,exit_end=exit_end,scan_end=scan_end)
                    admission = {'proof':proof,'reportName':entry['name'],'reportSHA256':entry['sha256'],
                                 'sourceSHA256':admitted_source,'binarySHA256':admitted_binary,
                                 'launchBeginEpoch':launch_begin,'exitEndEpoch':exit_end,'scanEndEpoch':scan_end}
                    break
                except (ValueError,UnicodeError,RecursionError) as error:
                    result['captureRejections'].append({'name':entry['name'],'reason':str(error)[:1024]})
            assert admission is not None, 'no exact symbolized owned control report; SDK work remains blocked'
            guard.save_json(rec/'CONTROL-ADMISSION.json',admission)
            result['controlCaptureAccepted'] = True
        except BaseException as error:
            result['primaryError'] = guard.error_record(error)
        finally:
            with interrupts.hold():
                def evidence(name, action):
                    try: return action()
                    except BaseException as error:
                        result['evidenceErrors'].append({'operation':name,**guard.error_record(error)})
                evidence('source packet final',lambda: authenticate(args.source_seal_sha256))
                if collector is not None:
                    evidence('aggregate report custody',lambda: guard.save_json(rec/'crash-aggregate.json',collector.snapshot()))
                def final_checks():
                    if admitted_source is not None:
                        assert guard.digest(source_path) == admitted_source and guard.digest(binary) == admitted_binary
                    if admission is not None:
                        report_path = rec/'crash-reports'/admission['reportName']
                        assert guard.digest(report_path) == admission['reportSHA256']
                        assert parse_report.parse(retained_report(report_path,admission['reportSHA256']),executable=str(binary),pid=result['ownedPID'],
                            launch_begin=admission['launchBeginEpoch'],exit_end=admission['exitEndEpoch'],scan_end=admission['scanEndEpoch']) == admission['proof']
                    for item in runner.records:
                        row = json.loads((rec/(item['label']+'.json')).read_text())
                        if item['label'] == 'control-signal': expected_signal(row)
                        else: assert row['success']
                        assert guard.digest(rec/(item['label']+'.log')) == row['logSHA256']
                    sample = runner.measure(rec/'RESULT.json'); result['finalResource'] = sample
                    assert not runner.violation(sample) and time.monotonic() <= runner.overall_deadline
                evidence('final identity/resources/commands/deadline',final_checks)
                result.update(commands=runner.records,receivedSignals=interrupts.received,elapsedSeconds=time.monotonic()-runner.started)
                result['success'] = result['controlCaptureAccepted'] and result['controlCompleted'] and not result['primaryError'] and not result['evidenceErrors'] and not interrupts.received
                if not result['success']: result['controlCaptureAccepted'] = False
                try: guard.save_json(rec/'RESULT.json',result)
                except BaseException as error:
                    result.update(success=False,controlCaptureAccepted=False)
                    result['evidenceErrors'].append({'operation':'RESULT write',**guard.error_record(error)})
                    print('FINAL_RESULT_WRITE_FAILED',json.dumps(result),flush=True)
    return 0 if result['success'] else 1


if __name__ == '__main__':
    sys.exit(main())
