#!/usr/bin/env python3
"""One fresh native process, raw signal receipt, and no inherited signal ignore."""
import argparse
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--case', required=True, choices=['header', 'payload', 'roundtrip', 'pipe'])
    parser.add_argument('--expected', required=True, type=int)
    parser.add_argument('--receipt', required=True, type=Path)
    args = parser.parse_args()
    # SIGPIPE must not create a large dump. The native fixture explicitly
    # resets and unblocks SIGPIPE after this fresh exec.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    record = {'argv': [args.binary, args.case], 'expectedExitCode': args.expected,
              'bodyAlarmSeconds': 5, 'outerTimeoutSeconds': 8, 'success': False,
              'childSharesGuardedProcessGroup': True}
    started = time.monotonic()
    process = None
    try:
        process = subprocess.Popen(record['argv'])
        record.update(pid=process.pid, processGroup=os.getpgid(process.pid))
        record['exitCode'] = process.wait(timeout=8)
        record['signal'] = (signal.Signals(-process.returncode).name
                            if process.returncode < 0 else None)
        record['success'] = process.returncode == args.expected
    except BaseException as error:
        record['error'] = {'type': type(error).__name__, 'message': str(error)}
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        record['leaderReaped'] = process is not None and process.poll() is not None
        record['elapsedSeconds'] = time.monotonic() - started
        with args.receipt.open('x') as output:
            json.dump(record, output, indent=2, sort_keys=True)
            output.write('\n')
    print(json.dumps(record, sort_keys=True), flush=True)
    return 0 if record['success'] and record['leaderReaped'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
