import ast
from pathlib import Path
import tempfile
import unittest
import uuid
import struct
import sdk_capture as capture

P=Path(__file__).resolve().parent

class ImageInventory(unittest.TestCase):
    def setUp(self):
        (P/'check-tmp').mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=P/'check-tmp')
        self.root=Path(self.temp.name)
        self.swift=self.root/'usr/bin/swift';self.swift.parent.mkdir(parents=True);self.swift.write_bytes(b'path fixture')
        self.xctest=self.root/'xctest';self.xctest.write_bytes(b'unsupported fixture image'*3)
        self.helper=self.root/'usr/libexec/swift/pm/swiftpm-testing-helper'
    def tearDown(self):self.temp.cleanup()
    def valid_helper(self):
        self.helper.parent.mkdir(parents=True)
        self.helper.write_bytes(struct.pack('<8I',0xfeedfacf,0x0100000c,0,2,1,24,0,0)+struct.pack('<2I',0x1b,24)+uuid.UUID('11111111-2222-4333-8444-555555555555').bytes)
    def test_missing_candidates_retained_before_same_rejection(self):
        snapshots=[]
        with self.assertRaisesRegex(ValueError,'no exact supported SwiftPM helper'):
            capture.Images(self.swift,self.xctest,inventory_sink=snapshots.append)
        self.assertEqual(len(snapshots),1)
        errors=snapshots[0]['unsupportedOrMissingImages'];self.assertEqual(len(errors),3)
        self.assertEqual(errors[0]['path'],str(self.helper));self.assertIsNone(errors[0]['resolvedPath'])
        self.assertEqual(errors[0]['errorType'],'FileNotFoundError')
        self.assertEqual(errors[2]['resolvedPath'],str(self.xctest));self.assertEqual(errors[2]['errorType'],'ValueError')
        self.assertFalse(snapshots[0]['images'])
    def test_unsupported_existing_helper_still_rejected_and_recorded(self):
        self.helper.parent.mkdir(parents=True);self.helper.write_bytes(b'unknown-format'*8)
        snapshots=[]
        with self.assertRaisesRegex(ValueError,'no exact supported SwiftPM helper'):
            capture.Images(self.swift,self.xctest,inventory_sink=snapshots.append)
        first=snapshots[0]['unsupportedOrMissingImages'][0]
        self.assertEqual(first['resolvedPath'],str(self.helper));self.assertIn('unsupported image magic',first['error'])
        self.assertEqual(first['formatEvidence']['prefixHex'],(b'unknown-format'*8)[:32].hex())
        self.assertTrue(first['formatEvidence']['diagnosticOnly'])
        self.assertFalse(first['formatEvidence']['fullFileHashEstablished'])
    def test_valid_helper_acceptance_and_identity_unchanged(self):
        self.valid_helper();snapshots=[]
        result=capture.Images(self.swift,self.xctest,inventory_sink=snapshots.append)
        self.assertEqual(snapshots,[result.snapshot()]);result.verify()
        self.assertEqual(result.images[str(self.helper)],capture.image_identity(self.helper,(2,)))
    def test_sink_failure_stops_even_supported_helper(self):
        self.valid_helper()
        def fail(_):raise OSError('injected inventory write failure')
        with self.assertRaisesRegex(OSError,'injected inventory write failure'):
            capture.Images(self.swift,self.xctest,inventory_sink=fail)
    def test_snapshot_is_detached_from_later_mutation(self):
        self.valid_helper();snapshots=[]
        result=capture.Images(self.swift,self.xctest,inventory_sink=snapshots.append)
        result.errors[0]['error']='changed after snapshot'
        self.assertNotEqual(snapshots[0],result.snapshot())
    def test_actual_retained_paths_join_historical_launcher(self):
        # Text/path join only. No claim that hosted image bytes exist locally.
        swift=Path((P/'helper-fixtures/selected-swift-path.log').read_text().strip())
        xctest=Path((P/'helper-fixtures/selected-xctest-path.log').read_text().strip())
        expected=swift.parent.parent/'libexec/swift/pm/swiftpm-testing-helper'
        launch=(P/'helper-fixtures/historical-helper-launch.log').read_text()
        self.assertIn("error: Process '"+str(expected)+' --test-bundle-path ',launch)
        self.assertEqual(swift.name,'swift');self.assertEqual(xctest.name,'xctest')
        self.assertEqual(xctest.parts[:5],swift.parts[:5])
    def test_real_qualifier_persists_attempt_during_constructor_before_checkout(self):
        tree=ast.parse((P/'qualify.py').read_text())
        calls=[n for n in ast.walk(tree) if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and n.func.attr=='Images']
        self.assertEqual(len(calls),1)
        sink=next(k.value for k in calls[0].keywords if k.arg=='inventory_sink')
        self.assertIsInstance(sink,ast.Lambda);self.assertEqual(sink.body.func.attr,'save_json')
        self.assertEqual(sink.body.args[0].right.value,'TOOLCHAIN-IMAGE-ATTEMPT.json')
        source=(P/'qualify.py').read_text()
        self.assertLess(source.index('images = sdk_capture.Images'),source.index("runner.run(name + '-init'"))
