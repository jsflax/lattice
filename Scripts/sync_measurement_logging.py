"""Measurement-only logging controls; no native/SQLite imports or execution."""
POLICY = "lattice.visibility.logging/1;native=off;native-sink=stderr;observer-worker=off;ack-path=off;sql-dump=absent;swift-log-env=absent"
CONTROL = 'LATTICE_SYNC_VISIBILITY_LOGGING_POLICY'
ATTESTATION = {
    'LOGGING': POLICY,
    'nativeLoggingLevelAtStart': '0',
    'nativeLoggingLevelAtEnd': '0',
    'nativeLoggingSink': 'stderr; nil FILE setter returned; no sink getter',
    'nativeLoggingVerification': 'level readback at start/end; not continuous monitoring',
    'diagnosticControls': 'observer-worker=0;ack-path=0;sql-dump=absent',
    'swiftLogging': 'LOG_LEVEL absent; pinned library defaults retained',
}


def apply_environment(original):
    """Return a controlled child environment without mutating the caller."""
    env = dict(original)
    # SQL dumping checks getenv presence, so even value '0' enables it.
    env.pop('LATTICE_DUMP_SQL', None)
    env.pop('LOG_LEVEL', None)
    env[CONTROL] = POLICY
    env.update(LATTICE_LOG_LEVEL='0', LATTICE_ACK_PATH_DIAGNOSTICS='0',
               LATTICE_OBSERVER_WORKER_DIAGNOSTICS='0')
    return env


def require_controls(env):
    for key in ('LATTICE_DUMP_SQL', 'LOG_LEVEL'):
        if key in env:
            raise ValueError('measurement requires absent ' + key)
    for key in ('LATTICE_ACK_PATH_DIAGNOSTICS', 'LATTICE_OBSERVER_WORKER_DIAGNOSTICS'):
        if env.get(key) not in (None, '0'):
            raise ValueError('measurement requires disabled ' + key)


def metadata_valid(metadata):
    return isinstance(metadata, dict) and all(metadata.get(k) == v for k, v in ATTESTATION.items())


def require_metadata(metadata):
    if not metadata_valid(metadata):
        raise ValueError('measurement logging setup/readback attestation missing or contradictory')
