#!/usr/bin/env python3
"""One hosted wrapper; keep the step open until the reviewed detached owner settles."""
import argparse
import json
import os
from pathlib import Path
import platform
import sys
import time

import hosted_binding as binding
import detached_owner as owner
import guarded_runner as guard
import process_custody as custody
import qualify


def stop(directory, receipt):
    value = {'nonce': receipt['nonce'], 'identity': receipt['identity']}
    path = directory/'STOP.json'
    if path.exists():
        binding.require(binding.J(binding.regular(path)) == value, 'existing stop identity differs')
    else:
        owner.exclusive(path, value)


def terminal_check(directory, receipt, runtime):
    terminal = binding.J(binding.regular(directory/'TERMINAL.json'))
    binding.require(terminal['nonce'] == receipt['nonce'] and terminal['identity'] == receipt['identity'],
                    'terminal owner identity mismatch')
    result_path = runtime/'receipts/RESULT.json'
    binding.require(terminal['resultPath'] == str(result_path) and terminal['resultSHA256'] is not None,
                    'terminal has no bound result')
    binding.require(binding.H(binding.regular(result_path)) == terminal['resultSHA256'], 'terminal result drift')
    result = binding.J(result_path)
    binding.require(terminal['exitCode'] == 0 and terminal['error'] is None and result['success'],
                    'owned qualification failed')
    return {'terminalSHA256': binding.H(directory/'TERMINAL.json'),
            'resultSHA256': terminal['resultSHA256'], 'success': True}


def wait_owner(directory, receipt, runtime, interrupts, *, now=time.monotonic, sleep=time.sleep,
               identity=custody.identity):
    """No relaunch and no wrapper signals to PIDs; STOP uses authenticated owner control."""
    interrupted = False
    while now() <= receipt['overallDeadline']:
        if interrupts.received and not interrupted:
            stop(directory, receipt)
            interrupted = True
        terminal = directory/'TERMINAL.json'
        current = identity(receipt['identity']['pid'])
        live = custody.same(current, receipt['identity'])
        if terminal.exists() and not live:
            evidence = terminal_check(directory, receipt, runtime)
            binding.require(not interrupted, 'hosted wrapper interrupted; success not credited')
            return evidence
        if not live and not terminal.exists():
            raise RuntimeError('owner disappeared without terminal evidence; no relaunch')
        sleep(0.2)
    stop(directory, receipt)
    raise RuntimeError('owner did not settle within unchanged overall deadline; no speculative cleanup')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--packet-seal-sha256', required=True)
    parser.add_argument('--admission-sha256', required=True)
    args = parser.parse_args()
    binding.require(platform.system() == 'Darwin' and platform.machine() == 'arm64' and __debug__,
                    'arm64 macOS and nonoptimized Python required')
    binding.packet_check(args.packet_seal_sha256)
    binding.preservation_check()
    metadata = {'workflowCommit': os.environ.get('GITHUB_SHA', ''),
                'runID': os.environ.get('GITHUB_RUN_ID', ''),
                'attempt': os.environ.get('GITHUB_RUN_ATTEMPT', '')}
    root = binding.validate_root(args.root, metadata)
    binding.require({p.name for p in root.iterdir()} == {'tools', 'tmp', 'ADMISSION.json'},
                    'fresh hosted root contains unexpected prior outputs')
    binding.require(not (root/'tmp').is_symlink() and not any((root/'tmp').iterdir()), 'fresh temporary root')
    config = binding.J(binding.P/'CONFIG.json')
    binding.admission_check(binding.regular(root/'ADMISSION.json').read_bytes(), args.admission_sha256,
                            args.packet_seal_sha256, metadata, config)
    context = {'schemaVersion': 1, 'root': str(root), 'hosted': metadata,
               'packetSealSHA256': args.packet_seal_sha256, 'admissionSHA256': args.admission_sha256,
               'tools': binding.tool_identity(config), 'toolIdentityIsSDK008LocalIdentity': False}
    owner.exclusive(root/'HOSTED-CONTEXT.json', context)
    os.environ['OWNED_PAGE_HOSTED_ROOT'] = str(root)
    os.environ['OWNED_PAGE_HOSTED_CONTEXT_SHA256'] = binding.H(root/'HOSTED-CONTEXT.json')
    config = qualify.source_packet(args.packet_seal_sha256, no_runtime=True, prelaunch=True)
    runtime = Path(config['runtimeRoot'])
    directory = runtime.with_name(runtime.name+'-owner')
    def body():
        sys.argv = [str(binding.P/'qualify.py'), '--reviewed-sdk-owned-page-qualification',
                    '--source-ready-sha256', args.packet_seal_sha256]
        return qualify.main()
    outcome = {'success': False, 'primaryError': None, 'receivedSignals': [],
               'packetSealSHA256': args.packet_seal_sha256, 'hosted': metadata}
    with guard.Interrupts() as interrupts:
        # Defer wrapper interruption into the existing owner STOP channel.
        # The qualifier installs its own interrupt handling after the fork.
        with interrupts.hold():
            try:
                receipt = owner.launch(directory, body,
                    {'sourceReadySHA256': args.packet_seal_sha256, 'runtimeRoot': str(runtime),
                     'qualifier': str(binding.P/'qualify.py'),
                     'hostedContextSHA256': os.environ['OWNED_PAGE_HOSTED_CONTEXT_SHA256']},
                    overall_seconds=config['proposedLimits']['overallSeconds'])
                outcome.update(wait_owner(directory, receipt, runtime, interrupts))
            except BaseException as error:
                outcome['primaryError'] = guard.error_record(error)
            outcome['receivedSignals'] = interrupts.received
            owner.exclusive(root/'HOSTED-RESULT.json', outcome)
    print(json.dumps(outcome))
    return 0 if outcome['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
