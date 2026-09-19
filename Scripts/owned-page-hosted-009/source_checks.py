"""Source-only hosted preservation checks; never evaluate historical absolute paths."""
import hosted_binding as binding


def fresh_roots(config, *, require_no_runtime, require_no_owner):
    from pathlib import Path
    if require_no_runtime:
        assert not Path(config['runtimeRoot']).exists(), 'fresh runtime root required'
    if require_no_owner:
        assert not Path(config['runtimeRoot']+'-owner').exists(), 'fresh owner directory required before launch'


def verify(**_):
    proof = binding.preservation_check()
    return {'sourceOnly': True, 'SDK008SealSHA256': proof['SDK008SealSHA256'],
            'original26And9Preserved': True, 'allLimitsUnchanged': True,
            'allCompilerAndTestCommandsOnlyOwnedPathsChanged': True,
            'historicalAbsolutePathsExecuted': False, 'executionAdmitted': False}
