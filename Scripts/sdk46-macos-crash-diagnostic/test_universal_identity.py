"""Synthetic Mach-O bytes only: no native executable, image launch or tool."""
import ast
import copy
import hashlib
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
import uuid
from unittest.mock import patch
import macho_identity as macho
import sdk_capture as capture

P=Path(__file__).resolve().parent
ARM_UUID='11111111-2222-4333-8444-555555555555'
X86_UUID='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'

def thin(cpu=macho.ARM64,subtype=0,kind=2,identity=ARM_UUID,commands=None,count=1):
    commands=commands if commands is not None else struct.pack('<II',0x1b,24)+uuid.UUID(identity).bytes
    return struct.pack('<8I',0xfeedfacf,cpu,subtype,kind,count,len(commands),0,0)+commands

def universal(wide=False,arm_first=False,images=None):
    if images is None:
        images=[(macho.X86_64,3,thin(macho.X86_64,3,identity=X86_UUID)),(macho.ARM64,0,thin())]
        if arm_first:images.reverse()
    offset=4096;entries=[];body=bytearray(4096)
    struct.pack_into('>II',body,0,0xcafebabf if wide else 0xcafebabe,len(images))
    for index,(cpu,subtype,data) in enumerate(images):
        entry=(cpu,subtype,offset,len(data),12)+(0,) if wide else (cpu,subtype,offset,len(data),12)
        struct.pack_into('>IIQQII' if wide else '>IIIII',body,8+index*(32 if wide else 20),*entry)
        entries.append(offset)
        body.extend(data);offset=((len(body)+4095)//4096)*4096
        if index+1<len(images):body.extend(bytes(offset-len(body)))
    return bytes(body),entries

def parse(data,allowed=(2,8)):
    evidence={}
    return macho.image_header(io.BytesIO(data),len(data),allowed,evidence),evidence

class UniversalIdentity(unittest.TestCase):
    def test_thin_uuid_and_slice(self):
        result,evidence=parse(thin())
        self.assertEqual(result['uuid'],ARM_UUID);self.assertEqual(result['selectedSlice']['offset'],0)
        self.assertEqual(evidence['thinHeader']['cpuSubtype'],0)
    def test_fat32_and_fat64_select_only_arm_in_either_order(self):
        for wide in (False,True):
            for first in (False,True):
                with self.subTest(wide=wide,first=first):
                    data,offsets=universal(wide,first);result,evidence=parse(data)
                    self.assertEqual(result['uuid'],ARM_UUID)
                    self.assertEqual(result['selectedSlice']['offset'],offsets[0 if first else 1])
                    self.assertLessEqual(evidence['headerBytesRead'],macho.MAX_IMAGE_HEADER_READ)
    def test_fat_bundle_only_when_caller_allows_it(self):
        data,_=universal(images=[(macho.ARM64,0,thin(kind=8))])
        self.assertEqual(parse(data)[0]['fileType'],8)
        with self.assertRaises(ValueError):parse(data,(2,))
    def test_control_parser_remains_thin_only(self):
        data,_=universal()
        with self.assertRaises(ValueError):macho.parse(data)
    def test_no_arm_rejected(self):
        data,_=universal(images=[(macho.X86_64,3,thin(macho.X86_64,3))])
        with self.assertRaisesRegex(ValueError,'exactly one'):parse(data)
    def test_duplicate_arm_rejected(self):
        data,_=universal(images=[(macho.ARM64,0,thin()),(macho.ARM64,0,thin())])
        with self.assertRaisesRegex(ValueError,'ambiguous'):parse(data)
    def test_arm_variants_and_unknown_bits_rejected(self):
        for subtype in (1,2,3,12,0x80000000,0xff000002):
            for fat in (False,True):
                data=thin(subtype=subtype)
                if fat:data=universal(images=[(macho.ARM64,subtype,data)])[0]
                with self.subTest(subtype=subtype,fat=fat),self.assertRaisesRegex(ValueError,'architecture/subtype'):parse(data)
    def test_unknown_nonselected_architecture_rejected(self):
        data,_=universal(images=[(123,0,thin(123)),(macho.ARM64,0,thin())])
        with self.assertRaisesRegex(ValueError,'architecture/subtype'):parse(data)
    def test_swapped_fat_and_unknown_magic_rejected_with_prefix(self):
        for prefix in (b'\xbe\xba\xfe\xca',b'\xbf\xba\xfe\xca',b'ELF!'):
            evidence={};data=prefix+bytes(60)
            with self.assertRaisesRegex(ValueError,'unsupported image magic'):
                macho.image_header(io.BytesIO(data),len(data),(2,),evidence)
            self.assertEqual(evidence['prefixHex'],data[:32].hex())
    def test_architecture_table_count_and_truncation(self):
        for data in (struct.pack('>II',0xcafebabe,0)+bytes(24),
                     struct.pack('>II',0xcafebabe,9)+bytes(24),
                     struct.pack('>II',0xcafebabe,2)+bytes(24)):
            with self.assertRaises(ValueError):parse(data)
    def test_slice_table_overlap_and_file_bounds(self):
        original,_=universal()
        for offset,size in ((0,56),(40,56),(2**32-1,56),(4096,2**32-1)):
            data=bytearray(original);struct.pack_into('>II',data,16,offset,size)
            with self.subTest(offset=offset,size=size),self.assertRaises(ValueError):parse(bytes(data))
    def test_overlapping_slices_rejected(self):
        data,_=universal();data=bytearray(data);struct.pack_into('>I',data,36,4096)
        with self.assertRaisesRegex(ValueError,'overlapping'):parse(bytes(data))
    def test_alignment_and_reserved_rejected(self):
        for wide,index,value in ((False,24,32),(False,16,4097),(True,36,1)):
            data,_=universal(wide);data=bytearray(data);struct.pack_into('>I',data,index,value)
            with self.subTest(wide=wide,index=index),self.assertRaises(ValueError):parse(bytes(data))
    def test_table_and_embedded_architecture_mismatch(self):
        for cpu,subtype in ((macho.X86_64,0),(macho.ARM64,2)):
            data,offsets=universal();data=bytearray(data);struct.pack_into('<II',data,offsets[1]+4,cpu,subtype)
            with self.subTest(cpu=cpu,subtype=subtype),self.assertRaisesRegex(ValueError,'disagreement'):parse(bytes(data))
    def test_commands_cannot_cross_selected_slice(self):
        data,offsets=universal();data=bytearray(data);struct.pack_into('<I',data,offsets[1]+20,32)
        with self.assertRaisesRegex(ValueError,'command bounds'):parse(bytes(data))
    def test_uuid_only_in_other_slice_is_not_identity(self):
        no_uuid=thin(commands=struct.pack('<II',0,8))
        data,_=universal(images=[(macho.X86_64,3,thin(macho.X86_64,3)),(macho.ARM64,0,no_uuid)])
        with self.assertRaisesRegex(ValueError,'missing LC_UUID'):parse(data)
    def test_duplicate_nil_uuid_bad_command_alignment_rejected(self):
        command=struct.pack('<II',0x1b,24)+uuid.UUID(ARM_UUID).bytes
        for commands,count in ((command*2,2),(struct.pack('<II',0x1b,24)+bytes(16),1),
                               (struct.pack('<II',0x1b,23)+bytes(16),1)):
            data,_=universal(images=[(macho.ARM64,0,thin(commands=commands,count=count))])
            with self.assertRaises(ValueError):parse(data)
    def test_file_identity_hashes_complete_container(self):
        scratch=P/'check-tmp';scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch)as directory:
            path=Path(directory)/'helper';data,offsets=universal();path.write_bytes(data)
            before=capture.image_identity(path,(2,));self.assertEqual(before['sha256'],hashlib.sha256(data).hexdigest())
            changed=bytearray(data);changed[offsets[0]+40]^=1;path.write_bytes(changed)
            after=capture.image_identity(path,(2,));self.assertEqual(after['uuid'],before['uuid'])
            self.assertNotEqual(after['sha256'],before['sha256'])
            link=path.parent/'symlink';link.symlink_to(path)
            with self.assertRaises(OSError):capture.image_identity(link)
    def test_rejection_retains_actual_bounded_header_evidence(self):
        scratch=P/'check-tmp';scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch)as directory:
            path=Path(directory)/'helper';data,_=universal(images=[(macho.ARM64,2,thin(subtype=2))]);path.write_bytes(data)
            with self.assertRaises(ValueError)as failure:capture.image_identity(path)
            evidence=failure.exception.image_evidence
            self.assertEqual(evidence['fatSlices'][0]['cpuSubtype'],2)
            self.assertEqual(evidence['prefixHex'],data[:32].hex())
            self.assertTrue(evidence['stableDuringInspection'])
            self.assertFalse(evidence['fullFileHashEstablished'])
            self.assertLess(len(json.dumps(evidence)),4096)
    def test_inventory_accepts_unique_arm_helper_and_detects_whole_file_drift(self):
        scratch=P/'check-tmp';scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch)as directory:
            root=Path(directory);swift=root/'usr/bin/swift';swift.parent.mkdir(parents=True);swift.write_bytes(b'path fixture')
            helper=root/'usr/libexec/swift/pm/swiftpm-testing-helper';helper.parent.mkdir(parents=True)
            data,offsets=universal();helper.write_bytes(data)
            xctest=root/'xctest';xctest.write_bytes(thin())
            snapshots=[];images=capture.Images(swift,xctest,inventory_sink=snapshots.append)
            self.assertEqual(images.images[str(helper)]['uuid'],ARM_UUID);images.verify()
            self.assertEqual(snapshots,[images.snapshot()])
            changed=bytearray(data);changed[offsets[0]+40]^=1;helper.write_bytes(changed)
            with self.assertRaisesRegex(ValueError,'changed'):images.verify()
    def test_inventory_retains_rejected_fat_header_before_mandatory_gate(self):
        scratch=P/'check-tmp';scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch)as directory:
            root=Path(directory);swift=root/'usr/bin/swift';swift.parent.mkdir(parents=True);swift.write_bytes(b'path fixture')
            helper=root/'usr/libexec/swift/pm/swiftpm-testing-helper';helper.parent.mkdir(parents=True)
            helper.write_bytes(universal(images=[(macho.ARM64,2,thin(subtype=2))])[0])
            xctest=root/'xctest';xctest.write_bytes(thin())
            snapshots=[]
            with self.assertRaisesRegex(ValueError,'no exact supported SwiftPM helper'):
                capture.Images(swift,xctest,inventory_sink=snapshots.append)
            rejected=snapshots[0]['unsupportedOrMissingImages'][0]
            self.assertEqual(rejected['formatEvidence']['fatSlices'][0]['cpuSubtype'],2)
            self.assertFalse(rejected['formatEvidence']['fullFileHashEstablished'])
    def test_prior_receipt_does_not_prove_fat_format(self):
        actual=json.loads((P/'helper-fixtures/source007-image-attempt.json').read_text())
        errors=actual['unsupportedOrMissingImages'];self.assertEqual(len(errors),3)
        self.assertIsNotNone(errors[0]['resolvedPath']);self.assertIsNotNone(errors[2]['resolvedPath'])
        self.assertTrue(all('formatEvidence'not in row for row in errors))
        self.assertEqual(errors[0]['error'],'unsupported image format/type; thin arm64 required')

if __name__=='__main__':unittest.main()
