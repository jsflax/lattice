"""Native-free observations, image, report and shared-custody regressions."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
import uuid
from unittest.mock import patch
import crash_reports
import owned_process_identity as owned
import sdk_capture as capture

P=Path(__file__).parent
HELPER='/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper'
BUNDLE='/Users/runner/localdev/owned/scratch/debug/LatticePackageTests.xctest/Contents/MacOS/LatticePackageTests'
HU='12345678-1234-1234-1234-123456789abc';BU='87654321-4321-4321-4321-cba987654321'


def info(pid=10,pgid=10,birth=1000,ppid=1):
    return dict(pid=pid,pgid=pgid,ppid=ppid,status=2,birthSeconds=birth,birthMicroseconds=100000)


class Process:
    pid=10
    def __init__(self,states=None):self.states=list(states or [None]*100)
    def poll(self):return self.states.pop(0) if self.states else None


class Backend:
    def __init__(self):self.table={10:info(),20:info(20,10,1000,10)};self.path_value=HELPER;self.calls=0
    def info(self,pid):return copy.deepcopy(self.table[pid])
    def members(self,pgid):return list(self.table),False
    def path(self,pid):return '/usr/bin/swift' if pid==10 else self.path_value


class Observation(unittest.TestCase):
    def test_sdk_header_layout(self):owned.validate_layout()
    def observe(self,backend=None,process=None):
        ob=owned.Observer('full',backend=backend or Backend(),clock=lambda:1002)
        ob.observe(process or Process());return ob
    def test_owned_group_child_observed(self):
        ob=self.observe();rows=ob.snapshot()['members'];self.assertEqual({r['pid'] for r in rows},{10,20})
        self.assertFalse(ob.snapshot()['coverageComplete']);self.assertEqual(rows[-1]['executable'],HELPER)
    def test_foreign_member_not_blessed(self):
        back=Backend();back.table[20]['pgid']=30
        self.assertEqual([r['pid'] for r in self.observe(back).snapshot()['members']],[10])
    def test_member_reuse_during_path_read(self):
        back=Backend();original=back.path
        def path(pid):
            value=original(pid)
            if pid==20:back.table[20]['birthSeconds']+=1
            return value
        back.path=path;ob=self.observe(back)
        self.assertEqual([r['pid'] for r in ob.snapshot()['members']],[10]);self.assertTrue(ob.snapshot()['errors'])
    def test_leader_exit_prevents_new_ownership(self):
        ob=self.observe(process=Process([None,0]));self.assertEqual(ob.snapshot()['members'],[])
    def test_already_exited_does_not_query_backend(self):
        back=Backend()
        def fail(pid):raise AssertionError('must not query exited leader')
        back.info=fail;ob=self.observe(back,Process([0]));self.assertEqual(ob.snapshot()['members'],[])
    def test_leader_reuse_discards_scanned_members(self):
        back=Backend();original=back.path
        def path(pid):
            value=original(pid)
            if pid==20:back.table[10]['birthSeconds']+=1
            return value
        back.path=path;self.assertEqual(self.observe(back).snapshot()['members'],[])
    def test_member_cap_and_error_cap(self):
        back=Backend();back.table={n:info(n,10,1000,10) for n in range(10,100)}
        ob=self.observe(back);self.assertEqual(len(ob.snapshot()['members']),64);self.assertTrue(ob.snapshot()['inventoryTruncated'])
        for _ in range(100):ob.error(ValueError('x'*1024))
        self.assertEqual(len(ob.snapshot()['errors']),64);self.assertEqual(ob.snapshot()['errorsOmitted'],36)
    def test_missing_identity_records_unknown(self):
        back=Backend()
        def fail(pid):raise OSError('permission denied')
        back.info=fail;ob=self.observe(back);self.assertEqual(ob.snapshot()['members'],[]);self.assertTrue(ob.snapshot()['errors'])
    def test_changed_path_retained_as_ambiguous_history(self):
        back=Backend();ob=self.observe(back);back.path_value=HELPER+'other';ob.observe(Process())
        self.assertEqual(len([r for r in ob.snapshot()['members'] if r['pid']==20]),2)


def image(path,uid):return {'path':path,'uuid':uid,'sha256':'a'*64,'bytes':56,'fileType':2}


class Images:
    bundle=image(BUNDLE,BU)
    def lookup(self,path):return image(HELPER,HU) if path==HELPER else None


def observations():
    return {'members':[{**info(20,10,1000,10),'executable':HELPER,'procName':'swiftpm-testing-helper',
        'firstObservedEpoch':1000.3,'lastObservedEpoch':1001.9}]}


def identities():
    value=capture.Identities();value.add_arm('full',observations(),1000,1002,Images());return value


def body():
    return {'pid':20,'procName':'swiftpm-testing-helper','procPath':HELPER,
        'procLaunch':'1970-01-01T00:16:40.1+00:00','captureTime':'1970-01-01T00:16:41+00:00',
        'exception':{'signal':'SIGSEGV','type':'EXC_BAD_ACCESS'},'faultingThread':0,
        'threads':[{'triggered':True,'frames':[{'imageIndex':1,'symbol':'lattice::database::query'}]}],
        'usedImages':[{'path':HELPER,'uuid':HU},{'path':BUNDLE,'uuid':BU}]}


def encode(value):return json.dumps(value).encode()


class SDKReport(unittest.TestCase):
    def setUp(self):self.ids=identities();self.row=self.ids.rows[0]
    def admit(self,value=None):
        raw=encode(body() if value is None else value)
        candidate=self.ids.candidate(raw,1003)
        return capture.sdk_stack(raw,self.ids.get(candidate['descriptorId']),Images.bundle)
    def test_owned_helper_and_bundle_stack(self):self.assertEqual(self.admit()['bundleImageUUID'],BU)
    def test_literal_bundle_redaction_with_exact_uuid(self):
        value=body();value['usedImages'][1]['path']='/Users/USER/*/LatticePackageTests'
        self.assertEqual(self.admit(value)['sdkFrames'][0]['pathMode'],'literal-user-redaction-plus-anchored-UUID')
    def test_arbitrary_bundle_redaction_not_accepted(self):
        value=body();value['usedImages'][1]['path']='/Users/USER/anything/LatticePackageTests'
        with self.assertRaises(ValueError):self.admit(value)
    def test_unknown_applications_redaction_retained_unattributed(self):
        value=body();value['procPath']='/Applications/*/swiftpm-testing-helper';value['usedImages'][0]['path']=value['procPath']
        self.assertTrue(self.ids.candidate(encode(value),1003)['retentionOnly'])
        with self.assertRaises(ValueError):self.admit(value)
    def test_unobserved_pid_not_retained(self):
        value=body();value['pid']=21
        with self.assertRaises(ValueError):self.ids.candidate(encode(value),1003)
    def test_report_uuid_cannot_supply_expected_identity(self):
        for index in [0,1]:
            value=body();value['usedImages'][index]['uuid']='00000000-0000-0000-0000-000000000000'
            with self.subTest(index=index),self.assertRaises(ValueError):self.admit(value)
    def test_stale_birth_and_late_capture(self):
        for field,value in [('procLaunch','1970-01-01T00:16:30+00:00'),('captureTime','1970-01-01T00:16:45+00:00')]:
            data=body();data[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):self.ids.candidate(encode(data),1010)
    def test_pid_reuse_is_ambiguous(self):
        obs=observations();other=copy.deepcopy(obs['members'][0]);other['birthMicroseconds']=200000;obs['members'].append(other)
        ids=capture.Identities();ids.add_arm('full',obs,1000,1002,Images())
        with self.assertRaises(ValueError):ids.candidate(encode(body()),1003)
    def test_other_thread_or_unsymbolized_is_not_sdk_stack(self):
        for frames in [[{'imageIndex':0,'symbol':'system'}],[{'imageIndex':1,'imageOffset':1}]]:
            data=body();data['threads'][0]['frames']=frames
            with self.subTest(frames=frames),self.assertRaises(ValueError):self.admit(data)
    def test_ambiguous_triggered_thread(self):
        data=body();data['threads'].append(copy.deepcopy(data['threads'][0]))
        with self.assertRaises(ValueError):self.admit(data)
    def test_unknown_helper_image_remains_unattributed(self):
        self.row['binary']=None
        self.assertTrue(self.ids.candidate(encode(body()),1003)['retentionOnly'])
        with self.assertRaises(ValueError):self.admit()
    def test_capture_after_unobserved_helper_cannot_be_recovered_from_path(self):
        with self.assertRaises(ValueError):capture.Identities().candidate(encode(body()),1003)


def macho(uid=BU,kind=8):
    return struct.pack('<8I',0xfeedfacf,0x0100000c,0,kind,1,24,0,0)+struct.pack('<2I',0x1b,24)+uuid.UUID(uid).bytes


class ImageProof(unittest.TestCase):
    def setUp(self):
        (P/'check-tmp').mkdir(exist_ok=True);self.tmp=tempfile.TemporaryDirectory(dir=P/'check-tmp');self.root=Path(self.tmp.name)
    def tearDown(self):self.tmp.cleanup()
    def test_bundle_larger_than_tiny_control_read_limit_streams(self):
        path=self.root/'LatticePackageTests'
        with path.open('wb') as out:out.write(macho());out.seek(9*2**20-1);out.write(b'0')
        result=capture.image_identity(path);self.assertEqual(result['uuid'],BU);self.assertEqual(result['bytes'],9*2**20)
    def test_changed_uuid_or_binary_rejects_original_identity(self):
        path=self.root/'bundle';path.write_bytes(macho());before=capture.image_identity(path)
        path.write_bytes(macho(HU));self.assertNotEqual(capture.image_identity(path),before)
    def test_symlink_and_unknown_format_rejected(self):
        target=self.root/'bundle';target.write_bytes(macho());link=self.root/'link';link.symlink_to(target)
        with self.assertRaises(OSError):capture.image_identity(link)
        target.write_bytes(b'not-mach-o'*16)
        with self.assertRaises(ValueError):capture.image_identity(target)
    def test_process_executable_cannot_be_bundle(self):
        path=self.root/'bundle';path.write_bytes(macho())
        with self.assertRaises(ValueError):capture.image_identity(path,(2,))
    def test_images_refuse_missing_known_helper_before_sdk(self):
        swift=self.root/'usr/bin/swift';swift.parent.mkdir(parents=True);swift.write_bytes(b'placeholder')
        xt=self.root/'xctest';xt.write_bytes(b'placeholder')
        with self.assertRaises(ValueError):capture.Images(swift,xt)
    def test_image_verify_anchors_original_proofs(self):
        swift=self.root/'usr/bin/swift';swift.parent.mkdir(parents=True);swift.write_bytes(b'placeholder')
        xt=self.root/'xctest';xt.write_bytes(b'unsupported-fat')
        helper=self.root/'usr/libexec/swift/pm/swiftpm-testing-helper';helper.parent.mkdir(parents=True);helper.write_bytes(macho(HU,2))
        registry=capture.Images(swift,xt);registry.verify();helper.write_bytes(macho(BU,2))
        with self.assertRaises(ValueError):registry.verify()


class BirthPrecision(unittest.TestCase):
    def test_fractional_launch_rejects_different_birth_in_same_second(self):
        obs=observations();obs['members'][0]['birthMicroseconds']=800000
        obs['members'][0]['firstObservedEpoch']=1000.9
        ids=capture.Identities();ids.add_arm('full',obs,1000,1002,Images())
        with self.assertRaises(ValueError):ids.candidate(encode(body()),1003)
    def test_one_report_unit_plus_microsecond_resolution(self):
        raw='1970-01-01 00:16:40.1000 +0000'
        self.assertEqual(capture.birth_precision(raw,1000,100101)['fractionalDigits'],4)
        with self.assertRaises(ValueError):capture.birth_precision(raw,1000,100102)
        self.assertEqual(capture.birth_precision('1970-01-01T00:16:40.100000+00:00',1000,100002)['fractionalDigits'],6)
        with self.assertRaises(ValueError):capture.birth_precision('1970-01-01T00:16:40.100000+00:00',1000,100003)
    def test_whole_seconds_explicitly_record_their_precision(self):
        proof=capture.birth_precision('1970-01-01T00:16:40Z',1000,800000)
        self.assertEqual(proof['fractionalDigits'],0);self.assertEqual(proof['reportQuantumSeconds'],'1')
    def test_timezone_and_nine_digit_fraction(self):
        proof=capture.birth_precision('1970-01-01T01:16:40.100000001+01:00',1000,100000)
        self.assertEqual(proof['actualDeltaSeconds'],'1E-9')
    def test_missing_or_invalid_representation_rejects(self):
        for value in [None,'1970-01-01 00:16:40.1','1970-01-01T00:16:40.1234567890Z']:
            with self.subTest(value=value),self.assertRaises(ValueError):capture.birth_precision(value,1000,100000)


class SharedCustody(unittest.TestCase):
    def test_control_then_sdk_share_same_caps_and_raw_rejections_survive(self):
        temp=P/'check-tmp';temp.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temp) as td:
            root=Path(td);reports=root/'reports';reports.mkdir();ids=capture.Identities()
            ids.add_control('/Users/runner/localdev/control/CrashControl',99,1000,1002,{'uuid':HU})
            control=body();control.update(pid=99,procName='CrashControl',procPath='/Users/USER/*/CrashControl')
            (reports/'CrashControl-a.ips').write_bytes(encode(control))
            collector=crash_reports.Collector(root,root/'out',999,ids,[reports])
            with patch('crash_reports.time.time',return_value=1003):one=collector.scan('control',wait_seconds=0)
            self.assertEqual(len(one['files']),1)
            obs=observations();ids.add_arm('full',obs,1000,1002,Images())
            data=body();data['procPath']='/Applications/*/swiftpm-testing-helper';data['usedImages'][0]['path']=data['procPath']
            raw=encode(data);(reports/'swiftpm-testing-helper-a.ips').write_bytes(raw)
            with patch('crash_reports.time.time',return_value=1003):two=collector.scan('sdk',wait_seconds=0)
            self.assertEqual(len(two['files']),2);self.assertEqual(two['bytes'],len(encode(control))+len(raw))
            result=capture.analyze_sdk_reports(collector,ids,Images.bundle)
            self.assertFalse(result['sdkStackCaptured']);self.assertEqual(len(result['unattributed']),1)
            self.assertEqual((collector.destination/two['files'][1]['name']).read_bytes(),raw)


if __name__=='__main__':unittest.main()
