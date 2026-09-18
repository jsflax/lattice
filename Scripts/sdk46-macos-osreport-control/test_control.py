"""Synthetic bounded parser/custody checks only; no control/native process launch."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import control_probe
import control_reports
import parse_report
import macho_identity
import struct
import uuid

P = Path(__file__).parent
EXE = '/Users/runner/localdev/owned/control/CrashControl'
UUID = '12345678-1234-1234-1234-123456789abc'
ARGS = dict(executable=EXE,pid=123,launch_begin=1000.25,exit_end=1001.25,scan_end=1061.25)


def body():
    return {'procPath':EXE,'procName':'CrashControl','pid':123,'procLaunch':'1970-01-01T00:16:40.300+00:00',
            'captureTime':'1970-01-01T00:16:41+00:00','exception':{'type':'EXC_BAD_ACCESS','signal':'SIGSEGV'},
            'faultingThread':0,'threads':[{'triggered':True,'frames':[{'symbol':'latticeSDK46DiagnosticCrashControl()', 'imageIndex':0}]}],
            'usedImages':[{'path':EXE,'uuid':'12345678-1234-1234-1234-123456789abc'}]}


def encode(value): return json.dumps(value).encode()


class Parser(unittest.TestCase):
    def valid(self,value=None,args=None):
        return parse_report.parse(encode(body() if value is None else value),binary_uuid=UUID,**(ARGS if args is None else args))
    def reject(self,key,value):
        data=body();data[key]=value
        with self.assertRaises(ValueError): self.valid(data)
    def test_single_body(self): self.assertEqual(self.valid()['pid'],123)
    def test_header_and_body(self):
        self.assertEqual(parse_report.parse(b'{"bug_type":"309"}\n'+encode(body()),binary_uuid=UUID,**ARGS)['faultingThread'],0)
    def test_wrong_pid(self): self.reject('pid',124)
    def test_bool_pid(self): self.reject('pid',True)
    def test_wrong_path(self): self.reject('procPath',EXE+'other')
    def test_stale_time(self): self.reject('captureTime','1970-01-01T00:16:30+00:00')
    def test_future_time(self): self.reject('captureTime','1970-01-01T00:17:43+00:00')
    def test_missing_timezone(self): self.reject('captureTime','1970-01-01T00:16:41')
    def test_wrong_signal(self): self.reject('exception',{'type':'EXC_CRASH','signal':'SIGABRT'})
    def test_other_thread_symbol(self):
        data=body();data['threads'].append(copy.deepcopy(data['threads'][0]));data['threads'][1]['triggered']=False
        data['threads'][0]['frames']=[{'symbol':'raise','imageIndex':0}]
        with self.assertRaises(ValueError): self.valid(data)
    def test_ambiguous_crashed_thread(self):
        data=body();data['threads'].append(copy.deepcopy(data['threads'][0]))
        with self.assertRaises(ValueError): self.valid(data)
    def test_unknown_image(self):
        data=body();data['usedImages'][0]['path']='/tmp/other'
        with self.assertRaises(ValueError): self.valid(data)
    def test_unsymbolized(self):
        data=body();data['threads'][0]['frames'][0]={'imageOffset':123,'imageIndex':0}
        with self.assertRaises(ValueError): self.valid(data)
    def test_missing_image_uuid(self): self.reject('usedImages',[{'path':EXE}])
    def test_ambiguous_document(self):
        with self.assertRaises(ValueError): parse_report.parse(encode(body())+encode(body()),binary_uuid=UUID,**ARGS)
    def test_third_document(self):
        with self.assertRaises(ValueError): parse_report.parse(b'{}\n{}\n{}',binary_uuid=UUID,**ARGS)
    def test_runtime_warning_is_not_report(self):
        with self.assertRaises(ValueError): parse_report.parse(b'swift runtime: backtrace-on-crash is not supported for privileged executables.\n',binary_uuid=UUID,**ARGS)
    def test_legacy_text_requires_explicit_future_parser(self):
        with self.assertRaises(ValueError): parse_report.parse(b'Process: CrashControl [123]\nPath: '+EXE.encode(),binary_uuid=UUID,**ARGS)
    def test_module_qualified_symbol(self):
        data=body();data['threads'][0]['frames'][0]['symbol']='SDK46CrashControl.latticeSDK46DiagnosticCrashControl() -> ()'
        self.assertTrue(self.valid(data)['controlFrames'])
    def test_substring_symbol_rejected(self):
        data=body();data['threads'][0]['frames'][0]['symbol']='not_latticeSDK46DiagnosticCrashControl()'
        with self.assertRaises(ValueError): self.valid(data)
    def test_report_bound(self):
        with self.assertRaises(ValueError): parse_report.parse(b' '*(parse_report.MAX_REPORT+1),binary_uuid=UUID,**ARGS)
    def test_escaped_slashes_decode_before_matching(self):
        data=encode(body()).replace(b'/',b'\\/')
        self.assertNotIn(EXE.encode(),data)
        self.assertTrue(parse_report.retention_candidate(data,**ARGS)['decodedPathExact'])
        self.assertEqual(parse_report.parse(data,binary_uuid=UUID,**ARGS)['procPath'],EXE)
    def test_redacted_path_retained_not_admitted(self):
        data=body();data['procPath']='/Users/USER/localdev/redacted/CrashControl'
        proof=parse_report.retention_candidate(encode(data),**ARGS)
        self.assertTrue(proof['retentionOnly']);self.assertFalse(proof['fullAdmission']);self.assertFalse(proof['decodedPathExact'])
        with self.assertRaises(ValueError): self.valid(data)
    def test_missing_path_retained_not_admitted(self):
        data=body();del data['procPath']
        self.assertIsNone(parse_report.retention_candidate(encode(data),**ARGS)['decodedPath'])
        with self.assertRaises(ValueError): self.valid(data)
    def test_candidate_requires_proc_name(self):
        data=body();data['procName']='AnotherProcess'
        with self.assertRaises(ValueError): parse_report.retention_candidate(encode(data),**ARGS)
    def test_candidate_requires_pid(self):
        data=body();data['pid']=124
        with self.assertRaises(ValueError): parse_report.retention_candidate(encode(data),**ARGS)
    def test_candidate_requires_launch_time(self):
        data=body();del data['procLaunch']
        with self.assertRaises(ValueError): parse_report.retention_candidate(encode(data),**ARGS)
    def test_candidate_rejects_stale_launch(self):
        data=body();data['procLaunch']='1970-01-01T00:16:30+00:00'
        with self.assertRaises(ValueError): parse_report.retention_candidate(encode(data),**ARGS)
    def test_candidate_rejects_future_capture(self):
        data=body();data['captureTime']='1970-01-01T00:17:43+00:00'
        with self.assertRaises(ValueError): parse_report.retention_candidate(encode(data),**ARGS)
    def test_duplicate_identity_key_rejected(self):
        data=encode(body()).replace(b'"pid": 123',b'"pid": 124, "pid": 123')
        with self.assertRaises(ValueError): parse_report.retention_candidate(data,**ARGS)
        with self.assertRaises(ValueError): parse_report.parse(data,binary_uuid=UUID,**ARGS)
    def test_fractional_report_time_with_separated_numeric_zone(self):
        data=body();data['procLaunch']='1970-01-01 00:16:40.3000 +0000';data['captureTime']='1970-01-01 00:16:41.0000 +0000'
        self.assertEqual(parse_report.retention_candidate(encode(data),**ARGS)['captureEpoch'],1001)
        self.assertEqual(self.valid(data)['captureEpoch'],1001)


    def test_observed_redaction_with_owned_uuid(self):
        data=body();data['procPath']='/Users/USER/*/CrashControl';data['usedImages'][0]['path']=data['procPath']
        proof=self.valid(data)
        self.assertEqual(proof['ownedExecutable'],EXE)
        self.assertEqual(proof['procPath'],data['procPath'])
        self.assertEqual(proof['pathIdentityMode'],'observed-literal-redaction-plus-owned-UUID')
    def test_redaction_is_not_wildcard_acceptance(self):
        for path in ['/Users/USER/anything/CrashControl','/Users/OTHER/*/CrashControl','/Users/USER/*/CrashControlExtra','/Users/USER/*/*/CrashControl']:
            data=body();data['procPath']=path;data['usedImages'][0]['path']=path
            with self.subTest(path=path), self.assertRaises(ValueError):self.valid(data)
    def test_uuid_mismatch_rejects_exact_and_redacted(self):
        for path in [EXE,'/Users/USER/*/CrashControl']:
            data=body();data['procPath']=path;data['usedImages'][0]['path']=path
            data['usedImages'][0]['uuid']='12345678-1234-1234-1234-123456789abd'
            with self.subTest(path=path), self.assertRaises(ValueError):self.valid(data)
    def test_malformed_or_missing_independent_uuid(self):
        for value in [None,'','wrong','12345678-1234-1234-1234-123456789abz']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_report.parse(encode(body()),binary_uuid=value,**ARGS)
    def test_mixed_redacted_exact_image_rejects(self):
        data=body();data['procPath']='/Users/USER/*/CrashControl'
        with self.assertRaises(ValueError):self.valid(data)
    def test_full_admission_requires_process_name(self):self.reject('procName','other')
    def test_full_admission_requires_launch(self):
        data=body();del data['procLaunch']
        with self.assertRaises(ValueError):self.valid(data)
    def test_uuid_case_representation(self):
        data=body();data['usedImages'][0]['uuid']=UUID.upper()
        self.assertEqual(self.valid(data)['ownedBinaryUUID'],UUID)


def macho(commands=None, **fields):
    if commands is None:commands=struct.pack('<2I',0x1b,24)+uuid.UUID(UUID).bytes
    header={'magic':0xfeedfacf,'cpu':0x0100000c,'subtype':0,'kind':2,'count':1,'size':len(commands),'flags':0,'reserved':0}
    header.update(fields)
    return struct.pack('<8I',*header.values())+commands


class MachO(unittest.TestCase):
    def test_valid_uuid_hash(self):
        data=macho();proof=macho_identity.parse(data)
        self.assertEqual(proof['uuid'],UUID);self.assertEqual(proof['sha256'],hashlib.sha256(data).hexdigest())
    def test_wrong_magic_fat_and_endian_reject(self):
        for value in [0xcafebabe,0xcffaedfe,0xfeedface]:
            with self.subTest(value=value),self.assertRaises(ValueError):macho_identity.parse(macho(magic=value))
    def test_non_arm64_or_non_executable(self):
        for field,value in [('cpu',0x01000007),('kind',6)]:
            with self.subTest(field=field),self.assertRaises(ValueError):macho_identity.parse(macho(**{field:value}))
    def test_command_count_and_bytes_bounded(self):
        for fields in [{'count':0},{'count':257},{'size':65537},{'count':4}]:
            with self.subTest(fields=fields),self.assertRaises(ValueError):macho_identity.parse(macho(**fields))
    def test_truncation(self):
        for data in [b'',macho()[:31],macho()[:-1],macho(size=32)]:
            with self.assertRaises(ValueError):macho_identity.parse(data)
    def test_duplicate_uuid(self):
        command=struct.pack('<2I',0x1b,24)+uuid.UUID(UUID).bytes
        with self.assertRaises(ValueError):macho_identity.parse(macho(command*2,count=2))
    def test_missing_or_nil_uuid(self):
        for commands in [struct.pack('<2I',0,8),struct.pack('<2I',0x1b,24)+bytes(16)]:
            with self.assertRaises(ValueError):macho_identity.parse(macho(commands))
    def test_command_extent_and_alignment(self):
        for commands in [struct.pack('<2I',0x1b,0)+bytes(16),struct.pack('<2I',0x1b,23)+bytes(16),struct.pack('<2I',0x1b,32)+bytes(24),struct.pack('<2I',0x1b,24)+uuid.UUID(UUID).bytes+bytes(8)]:
            with self.assertRaises(ValueError):macho_identity.parse(macho(commands))
    def test_additional_command(self):
        data=macho(struct.pack('<2I',0,8)+struct.pack('<2I',0x1b,24)+uuid.UUID(UUID).bytes,count=2)
        self.assertEqual(macho_identity.parse(data)['loadCommands'],2)
    def test_binary_byte_limit(self):
        with self.assertRaises(ValueError):macho_identity.parse(bytes(macho_identity.MAX_BINARY+1))
    def test_owned_file_and_changed_identity(self):
        temp=P/'tmp';temp.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temp) as td:
            path=Path(td)/'control';path.write_bytes(macho());before=macho_identity.inspect(path)
            self.assertEqual(before['uuid'],UUID)
            path.write_bytes(macho()+b'changed')
            self.assertNotEqual(macho_identity.inspect(path),before)
            link=Path(td)/'link';link.symlink_to(path)
            with self.assertRaises(OSError):macho_identity.inspect(link)


class Custody(unittest.TestCase):
    def test_control_collector_filter_and_single_window(self):
        temp=P/'tmp';temp.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temp) as td:
            root=Path(td);(root/'control').mkdir();exe=root/'control/CrashControl';exe.write_bytes(b'not executable')
            reports=root/'reports';reports.mkdir();data=body();data['procPath']=str(exe)
            (reports/'CrashControl-valid.ips').write_bytes(encode(data))
            (reports/'LatticePackageTests-unrelated.ips').write_bytes(encode(data))
            collector=control_reports.Collector(root,root/'out',ARGS['launch_begin'],exe,123,ARGS['exit_end'],directories=[reports])
            with patch('control_reports.time.time',return_value=ARGS['scan_end']):
                snapshot=collector.scan('synthetic',wait_seconds=0)
            self.assertEqual(len(snapshot['files']),1);self.assertEqual(snapshot['limits']['arrivalWindowSeconds'],60)
            self.assertEqual(snapshot['limits']['total'],16*2**20);self.assertEqual(snapshot['limits']['candidates'],64)
            with self.assertRaises(ValueError): collector.scan('duplicate',wait_seconds=0)
            self.assertEqual(len(collector.snapshot()['files']),1)
    def test_redacted_candidate_raw_survives_strict_rejection(self):
        temp=P/'tmp';temp.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temp) as td:
            root=Path(td);(root/'control').mkdir();exe=root/'control/CrashControl';exe.write_bytes(b'not executable')
            reports=root/'reports';reports.mkdir();data=body();data['procPath']='/Users/USER/redacted/CrashControl'
            raw=encode(data);(reports/'CrashControl-own.ips').write_bytes(raw)
            collector=control_reports.Collector(root,root/'out',ARGS['launch_begin'],exe,123,ARGS['exit_end'],directories=[reports])
            with patch('control_reports.time.time',return_value=ARGS['scan_end']):
                snapshot=collector.scan('synthetic',wait_seconds=0)
            entry=snapshot['files'][0]
            self.assertFalse(entry['candidateIdentity']['decodedPathExact'])
            self.assertEqual((root/'out'/entry['name']).read_bytes(),raw)
            with self.assertRaises(ValueError): parse_report.parse(raw,binary_uuid=UUID,**dict(ARGS,executable=str(exe)))
            self.assertEqual(collector.snapshot()['bytes'],len(raw))
    def test_retained_hash_replacement_rejects(self):
        temp=P/'tmp';temp.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temp) as td:
            f=Path(td)/'report';data=encode(body());f.write_bytes(data)
            sha=hashlib.sha256(data).hexdigest();self.assertEqual(control_probe.retained_report(f,sha),data)
            f.write_bytes(data+b' ')
            with self.assertRaises(AssertionError): control_probe.retained_report(f,sha)
    def test_expected_signal_does_not_allow_guard_intervention(self):
        record={'started':True,'exitCode':-11,'primaryError':None,'evidenceErrors':[], 'receivedSignals':[], 'stopReason':None,
                'cleanup':{'leaderReaped':True,'groupGone':True,'signals':[],'errors':[]},'pid':123}
        self.assertEqual(control_probe.expected_signal(record),123)
        record['cleanup']['signals']=['TERM']
        with self.assertRaises(AssertionError): control_probe.expected_signal(record)


if __name__ == '__main__': unittest.main()
