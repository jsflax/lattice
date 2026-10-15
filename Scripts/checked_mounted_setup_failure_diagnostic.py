"""Closed bounded setup-failure DATA; never a product/transaction success oracle."""
import json
from pathlib import Path
PREFIX = 'LATTICE_CHECKED_MOUNTED_SETUP_FAILURE '
FORMAT = 'lattice-checked-mounted-setup-failure/1'
STAGES = {'authorizationValidation', 'checkedOwnerOpen', 'normalOwnerOpen', 'modelGateCreation',
          'ordinaryConnectionCreation', 'ordinaryStateInstall', 'recoveryOpen', 'catchUpStateCreation'}
KINDS = {'mountedConfiguration', 'mountedOpenRefused', 'exportCapacity', 'observationCapacity',
         'exportRefused', 'exportOther', 'modelConfiguration', 'modelControl', 'modelStopped',
         'modelEffectUnavailable', 'ordinaryControl', 'ordinaryCapacity', 'ordinaryStopped',
         'ordinaryReceipt', 'ordinaryHeader', 'other'}
REASONS = ['fingerprintCookie', 'schemaVersion', 'exportCapacity', 'writerBusy', 'quiescentConfiguration',
           'actualCatalogOwner', 'closedRelationshipScope', 'actualSchema', 'localProducer',
           'physicalFile', 'nativeRead', 'callerTransaction']
MAX_LOG = 512 * 2**20

def require(value):
    if not value: raise ValueError('checked_setup_failure_data_refused')

def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result); result[key] = value
    return result

def validate(row):
    require(type(row) is dict and set(row) == {'format', 'stage', 'errorType', 'nativeBytes', 'nativeReasons'})
    require(row['format'] == FORMAT and type(row['stage']) is str and row['stage'] in STAGES
            and type(row['errorType']) is str and row['errorType'] in KINDS)
    size, reasons = row['nativeBytes'], row['nativeReasons']
    require(type(size) is int and 0 <= size <= 8193 and type(reasons) is list)
    require(all(type(x) is str for x in reasons) and len(reasons) == len(set(reasons)))
    native = row['errorType'] in ('mountedOpenRefused', 'exportRefused')
    if not native: require(size == 0 and reasons == []); return
    require(1 <= len(reasons) <= len(REASONS))
    if reasons == ['oversized']: require(size == 8193); return
    require(size <= 8192)
    if reasons == ['unclassified']: return
    require(size > 0 and all(x in REASONS for x in reasons)
            and reasons == sorted(reasons, key=REASONS.index))

def parse(path):
    path = Path(path); require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_LOG)
    rows = []; consumed = 0
    with path.open('rb') as source:
        while True:
            raw = source.readline(65537)
            if not raw: break
            consumed += len(raw); require(len(raw) <= 65536 and consumed <= MAX_LOG)
            text = raw.decode('utf-8', errors='strict').rstrip('\r\n')
            if text.startswith(PREFIX):
                require(len(raw) <= 4096 and len(rows) < 32)
                row = json.loads(text[len(PREFIX):], object_pairs_hook=unique,
                                 parse_constant=lambda _: require(False))
                validate(row); rows.append(row)
    return {'format': 'lattice-checked-mounted-setup-failure-observations/1',
            'status': 'decoded', 'failures': rows, 'scope': 'closed stage/type/native-reason DATA only; no success or permission'}
