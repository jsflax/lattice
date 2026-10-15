import copy
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
import checked_mounted_fix_qualification as api


def fixture(system='Darwin'):
    identities = api.expected(system)
    root = ET.Element('testsuites')
    suite = ET.SubElement(root, 'testsuite', tests=str(len(identities)), failures='0', errors='0', skipped='0')
    lines = []
    for identity in identities:
        group, name = identity.split('/')
        ET.SubElement(suite, 'testcase', classname=group, name=name)
        lines += ['◇ Test ' + name + ' started.', '✔ Test ' + name + ' passed after 0.001 seconds.']
    lines.append(f'✔ Test run with {len(identities)} tests in 4 suites passed after 0.123 seconds.')
    return ET.tostring(root), ('\n'.join(lines) + '\n').encode()


class CheckedMountedFixControls(unittest.TestCase):
    def test_exact_platform_populations(self):
        self.assertEqual(len(api.expected('Darwin')), 28)
        self.assertEqual(len(api.expected('Linux')), 25)
        self.assertEqual(len(set(api.expected('Darwin')) - set(api.expected('Linux'))), 3)

    def test_real_source_inventory_binds_all_four_current_test_tus(self):
        root = Path(__file__).resolve().parents[1]
        for system in ['Darwin', 'Linux']:
            inventory = api.source_inventory(root, system)
            self.assertEqual(len(inventory['sources']), 4)
            self.assertEqual(len(inventory['identifiers']), 28 if system == 'Darwin' else 25)

    def test_both_exact_synthetic_platform_reports(self):
        for system in ['Darwin', 'Linux']:
            self.assertEqual(api.framework(*fixture(system), system)['testCount'], len(api.expected(system)))

    def test_wrong_platform_does_not_turn_into_skip(self):
        with self.assertRaises(ValueError): api.framework(*fixture('Linux'), 'Darwin')

    def test_unreviewed_platform_refuses(self):
        with self.assertRaises(ValueError): api.expected('Windows')

    def test_missing_xml_case_refuses(self):
        xml, log = fixture(); root = ET.fromstring(xml); root[0].remove(root[0][0])
        with self.assertRaises(ValueError): api.framework(ET.tostring(root), log, 'Darwin')

    def test_duplicate_xml_case_refuses(self):
        xml, log = fixture(); root = ET.fromstring(xml); root[0].append(copy.deepcopy(root[0][0]))
        with self.assertRaises(ValueError): api.framework(ET.tostring(root), log, 'Darwin')

    def test_foreign_xml_case_refuses(self):
        xml, log = fixture(); root = ET.fromstring(xml); root[0][0].set('classname', 'LatticeTests.Foreign')
        with self.assertRaises(ValueError): api.framework(ET.tostring(root), log, 'Darwin')

    def test_failure_error_skip_elements_refuse(self):
        for tag in ['failure', 'error', 'skipped']:
            xml, log = fixture(); root = ET.fromstring(xml); ET.SubElement(root[0][0], tag)
            with self.assertRaises(ValueError): api.framework(ET.tostring(root), log, 'Darwin')

    def test_nonzero_suite_counts_refuse(self):
        for field in ['failures', 'errors', 'skipped']:
            xml, log = fixture(); root = ET.fromstring(xml); root[0].set(field, '1')
            with self.assertRaises(ValueError): api.framework(ET.tostring(root), log, 'Darwin')

    def test_missing_affirmative_start_refuses(self):
        xml, log = fixture(); log = b'\n'.join(log.splitlines()[1:]) + b'\n'
        with self.assertRaises(ValueError): api.framework(xml, log, 'Darwin')

    def test_duplicate_affirmative_start_refuses(self):
        xml, log = fixture(); log += log.splitlines()[0] + b'\n'
        with self.assertRaises(ValueError): api.framework(xml, log, 'Darwin')

    def test_missing_affirmative_pass_refuses(self):
        xml, log = fixture(); log = b'\n'.join(x for i, x in enumerate(log.splitlines()) if i != 1) + b'\n'
        with self.assertRaises(ValueError): api.framework(xml, log, 'Darwin')

    def test_issue_skip_signal_and_failure_text_refuse(self):
        for note in ['recorded an issue', 'skipped', 'unexpected signal', '✘ failed']:
            xml, log = fixture()
            with self.assertRaises(ValueError): api.framework(xml, log + note.encode() + b'\n', 'Darwin')

    def test_zero_or_wrong_summary_refuses(self):
        for summary in [b'0 tests in 4 suites', b'28 tests in 3 suites']:
            xml, log = fixture()
            with self.assertRaises(ValueError): api.framework(xml, log.replace(b'28 tests in 4 suites', summary), 'Darwin')

    def test_dtd_and_entity_refuse(self):
        xml, log = fixture()
        for lead in [b'<!DOCTYPE testsuites>', b'<!ENTITY x "y">']:
            with self.assertRaises(ValueError): api.framework(lead + xml, log, 'Darwin')

    def test_utf16_entity_and_nul_refuse(self):
        xml, log = fixture()
        for altered in [xml.decode().encode('utf-16'), xml + b'\x00']:
            with self.assertRaises((ValueError, UnicodeError)): api.framework(altered, log, 'Darwin')

    def test_invalid_utf8_log_refuses(self):
        xml, log = fixture()
        with self.assertRaises(UnicodeError): api.framework(xml, log + b'\xff', 'Darwin')

    def test_report_symlink_and_size_refuse(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); report = root / 'report'; report.write_bytes(b'123'); link = root / 'link'; link.symlink_to(report)
            with self.assertRaises(ValueError): api.read_report(link, 4)
            with self.assertRaises(ValueError): api.read_report(report, 2)
            self.assertEqual(api.read_report(report, 3), b'123')


if __name__ == '__main__': unittest.main()
