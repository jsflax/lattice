"""Pure Python/file admission tests. No SQLite import, open, or workload."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import sync_visibility_postmortem as p


def fixture_receipt():
    run = '65DD0B26-CFD4-4B3F-AA99-AD487F655EF8'
    rows = []
    for stream, writers in [('hot', 2), ('quiet', 1)]:
        for writer in range(writers):
            for phase, count in [('warmup', 1), ('measured', 3 if stream == 'hot' else 1)]:
                for sequence in range(count):
                    rows.append(dict(id=f'{run}/{stream}/{phase}/{writer}/{sequence}', runID=run,
                                     stream=stream, phase=phase, writer=writer, sequence=sequence,
                                     writerStoreID=f'clients/{stream}-writer-{writer}.sqlite'))
    return dict(schema='lattice.sync-public-visibility/1', runID=run, mode='smoke', profile='loaded',
                effectiveParameters=p.SMOKE.copy(), receipts=rows, complete=False)


COMMAND = dict(started=True, exitCode=1, cleanup=dict(leaderReaped=True, groupGone=True))


class PostmortemAdmissionTests(unittest.TestCase):
    def setUp(self):
        # All test scratch has an explicit user-approved localdev parent.
        parent = Path(os.environ['LATTICE_POSTMORTEM_TEST_TMP'])
        p.checked_path(parent)
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def test_exact_smoke_and_failed_verdict_are_preserved(self):
        receipt = fixture_receipt()
        before = copy.deepcopy(receipt)
        self.assertEqual(len(p.validate_receipts(receipt, COMMAND)), 10)
        self.assertEqual(receipt, before)

    def test_full_unknown_path_duplicate_and_wrong_parameters_refused(self):
        for mutate in [lambda x: x.update(mode='full'),
                       lambda x: x['effectiveParameters'].update(writerCount=8),
                       lambda x: x['receipts'][0].update(writerStoreID='../outside.sqlite'),
                       lambda x: x['receipts'].__setitem__(0, x['receipts'][1])]:
            receipt = fixture_receipt(); mutate(receipt)
            with self.assertRaises(ValueError): p.validate_receipts(receipt, COMMAND)

    def test_both_exit_proofs_and_started_process_required(self):
        for field in ['leaderReaped', 'groupGone']:
            command = copy.deepcopy(COMMAND); command['cleanup'][field] = False
            with self.assertRaises(ValueError): p.validate_receipts(fixture_receipt(), command)
        command = copy.deepcopy(COMMAND); command['started'] = False
        with self.assertRaises(ValueError): p.validate_receipts(fixture_receipt(), command)

    def test_fixed_file_inventory_and_byte_identical_sidecar_copy(self):
        fixture = self.base / 'fixture'; (fixture / 'clients').mkdir(parents=True)
        values = {p.STORES[0]: b'db', p.STORES[0] + '-wal': b'wal', p.STORES[0] + '-shm': b'shm'}
        for relative, content in values.items(): (fixture / relative).write_bytes(content)
        (fixture / 'clients/unrelated.sqlite').write_bytes(b'ignored')
        rows, total = p.inventory(fixture)
        self.assertEqual(len(rows), 21); self.assertEqual(total, 8)
        destination = self.base / 'copies'
        self.assertEqual(p.copy_files(fixture, destination, rows), 8)
        for relative, content in values.items():
            self.assertEqual((fixture / relative).read_bytes(), content)
            self.assertEqual((destination / relative).read_bytes(), content)
        self.assertFalse((destination / 'clients/unrelated.sqlite').exists())
        with self.assertRaises(ValueError): p.copy_files(fixture, destination, rows)

    def test_parent_and_file_symlinks_are_refused(self):
        fixture = self.base / 'fixture'; fixture.mkdir()
        real = self.base / 'real'; real.mkdir()
        (fixture / 'clients').symlink_to(real, target_is_directory=True)
        with self.assertRaises(ValueError): p.inventory(fixture)
        (fixture / 'clients').unlink(); (fixture / 'clients').mkdir()
        (fixture / p.STORES[0]).symlink_to(self.base / 'absent')
        with self.assertRaises(ValueError): p.inventory(fixture)

    def test_oversize_and_between_inventory_copy_mutation_refused(self):
        fixture = self.base / 'fixture'; (fixture / 'clients').mkdir(parents=True)
        target = fixture / p.STORES[0]; target.write_bytes(b'1234')
        with mock.patch.object(p, 'BYTE_CAP', 3):
            with self.assertRaises(ValueError): p.inventory(fixture)
        rows, _ = p.inventory(fixture); target.write_bytes(b'changed')
        with self.assertRaises(ValueError): p.copy_files(fixture, self.base / 'copies', rows)

    def test_collect_missing_files_never_imports_sqlite_or_changes_receipt(self):
        home = self.base / 'home'; root = home / 'localdev/run'
        (root / 'visibility-smoke').mkdir(parents=True); (root / 'receipts').mkdir()
        frozen = root / 'visibility-smoke/receipts.json'
        frozen.write_text(json.dumps(fixture_receipt()))
        (root / 'receipts/sdk-probe-fixtures.json').write_text(json.dumps(COMMAND))
        before = frozen.read_bytes()
        with mock.patch.object(Path, 'home', return_value=home), mock.patch.dict('sys.modules', {'sqlite3': None}):
            report = p.collect(root)
        self.assertFalse(report['frozenMeasurementComplete'])
        self.assertEqual(len(report['stores']), 7)
        self.assertTrue(all(not item['present'] for item in report['stores']))
        self.assertEqual(report['copiedBytes'], 0)
        self.assertEqual(frozen.read_bytes(), before)

    def test_cross_store_audit_association_preserves_distinct_local_ids(self):
        home = self.base / 'home'; root = home / 'localdev/run'
        fixture = root / 'visibility-smoke'
        (fixture / 'clients').mkdir(parents=True); (fixture / 'relay').mkdir()
        (root / 'receipts').mkdir()
        receipt = fixture_receipt(); operation = receipt['receipts'][0]['id']
        (fixture / 'receipts.json').write_text(json.dumps(receipt))
        (root / 'receipts/sdk-probe-fixtures.json').write_text(json.dumps(COMMAND))
        for name in [p.STORES[0], p.STORES[2], p.STORES[5]]: (fixture / name).write_bytes(b'opaque fixture')
        gid = '12345678-1234-4321-8123-123456789012'
        def inspect(path, _):
            if path.name == 'hot-writer-0.sqlite':
                return dict(presentTables=['SyncVisibilityObject', 'AuditLog'],
                            modelRows=[dict(localRowID=3, globalID=gid, operationID=operation)], auditRows=[])
            if path.name == 'hot.sqlite':
                return dict(presentTables=['SyncVisibilityObject', 'AuditLog'], modelRows=[],
                            auditRows=[dict(auditEntryID=91, localRowID=7, globalRowID=gid, operationID=None)])
            return dict(presentTables=[], modelRows=[], auditRows=[])
        with mock.patch.object(Path, 'home', return_value=home), mock.patch.object(p, 'inspect_copy', side_effect=inspect), \
                mock.patch.dict('sys.modules', {'sqlite3': None}):
            report = p.collect(root)
        match = next(row for row in report['operationAssociations'] if row['operationID'] == operation)
        relay = next(row for row in match['stores'] if row['store'] == 'relay/hot.sqlite')
        self.assertEqual(relay['modelCount'], 0)
        self.assertEqual(relay['associatedAuditCount'], 1)
        self.assertEqual(relay['auditLocalRowIDs'], [7])
        watcher = next(row for row in match['stores'] if row['store'] == 'clients/hot-watcher.sqlite')
        self.assertFalse(watcher['available'])  # Missing schema is not zero rows.


if __name__ == '__main__':
    unittest.main()
