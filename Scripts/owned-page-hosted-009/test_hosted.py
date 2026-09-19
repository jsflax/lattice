"""Pure hosted adaptation tests. All commands, clocks and process identities are fake."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import hosted
import hosted_binding as binding
import qualify


class Hosted(unittest.TestCase):
    def setUp(self):
        (binding.P/'pure-tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=binding.P/'pure-tmp')
        self.root = Path(self.temp.name)
        self.config = binding.J(binding.P/'CONFIG.json')
        self.metadata = {'runID': '123', 'attempt': '1', 'workflowCommit': 'a'*40}
        self.seal = 'b'*64
        self.admission = {'schemaVersion': 1, 'packetSealSHA256': self.seal,
            'SDKCommit': self.config['sdkCommit'], 'SDKTree': self.config['sdkTree'],
            'coreManifestSHA256': self.config['privateCoreSourceManifestSHA256'],
            'limits': self.config['proposedLimits'], 'hostedToolIdentityAccepted': True,
            'sourceOnlyPacketApprovedForOneHostedRun': True, 'publicActivation': False,
            'performanceClaimed': False, 'workflowCommit': 'a'*40, 'attempt': '1'}
    def tearDown(self):
        self.temp.cleanup()
    def check_admission(self, value, metadata=None):
        raw = json.dumps(value).encode()
        return binding.admission_check(raw, hashlib.sha256(raw).hexdigest(), self.seal,
                                       metadata or self.metadata, self.config)
    def test_exact_admission_and_refusals(self):
        self.assertEqual(self.check_admission(self.admission), self.admission)
        for key, value in [('hostedToolIdentityAccepted', False), ('workflowCommit', 'c'*40),
                           ('SDKCommit', 'd'*40), ('publicActivation', True), ('performanceClaimed', True)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check_admission(self.admission | {key: value})
        changed = copy.deepcopy(self.admission); changed['limits']['jobs'] = 3
        with self.assertRaises(ValueError): self.check_admission(changed)
        with self.assertRaises(ValueError): self.check_admission(self.admission, self.metadata | {'attempt': '2'})
    def test_admission_exact_bytes_not_reserialized(self):
        raw = json.dumps(self.admission).encode()
        with self.assertRaises(ValueError):
            binding.admission_check(raw+b'\n', hashlib.sha256(raw).hexdigest(), self.seal, self.metadata, self.config)
    def test_relocation_changes_only_exact_runtime_prefix(self):
        actual = binding.commands(self.root)
        old = binding.J(binding.P/'evidence/sdk008/COMMANDS.json')
        prefix = binding.J(binding.P/'PRESERVATION.json')['SDK008RuntimeRoot']
        expected = json.loads(json.dumps(old).replace(prefix, str(self.root/'run')))
        self.assertEqual(actual, expected)
        self.assertEqual(len(actual), 12)
        self.assertNotIn(prefix, json.dumps(actual))
    def test_actual_tool_bytes_and_resolved_identity_are_required(self):
        tool = self.root/'swiftc';tool.write_text('host-tool')
        c = self.config | {'toolPaths': [str(tool)]}
        expected = binding.tool_identity(c)
        self.assertEqual(expected[str(tool)]['sha256'], binding.H(tool))
        tool.write_text('changed-host-tool')
        self.assertNotEqual(binding.tool_identity(c), expected)
    def test_core_and_oracle_preservation(self):
        proof = binding.preservation_check()
        self.assertEqual((proof['baseCoreFiles'], proof['privateCoreFiles'], proof['corePostimages']), (901,919,29))
        self.assertEqual(self.config['proposedLimits']['packetCeilingBytes'], 8*2**30)
    def receipt(self):
        return {'nonce': 'synthetic', 'identity': {'pid': 7, 'birth': [10, 11]}, 'overallDeadline': 100}
    def terminal(self, receipt, *, success=True):
        directory = self.root/'run-owner';directory.mkdir()
        runtime = self.root/'run';(runtime/'receipts').mkdir(parents=True)
        result = runtime/'receipts/RESULT.json';result.write_text(json.dumps({'success': success}))
        value = {'nonce': receipt['nonce'], 'identity': receipt['identity'],
                 'resultPath': str(result), 'resultSHA256': binding.H(result),
                 'exitCode': 0 if success else 1, 'error': None}
        (directory/'TERMINAL.json').write_text(json.dumps(value))
        return directory, runtime
    def test_wait_requires_terminal_bound_result_and_actual_owner_exit(self):
        receipt = self.receipt();directory,runtime = self.terminal(receipt)
        identities = iter([receipt['identity'], None]);sleeps=[]
        value = hosted.wait_owner(directory, receipt, runtime, SimpleNamespace(received=[]),
            now=lambda: 1, sleep=sleeps.append, identity=lambda pid: next(identities))
        self.assertTrue(value['success']);self.assertEqual(sleeps, [0.2])
        (runtime/'receipts/RESULT.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'result drift'):
            hosted.terminal_check(directory, receipt, runtime)
    def test_owner_missing_without_terminal_refuses_without_relaunch(self):
        directory=self.root/'owner';directory.mkdir()
        with patch.object(hosted.owner, 'launch') as launch, self.assertRaisesRegex(RuntimeError, 'without terminal'):
            hosted.wait_owner(directory,self.receipt(),self.root/'run',SimpleNamespace(received=[]),
                now=lambda:1,identity=lambda pid:None,sleep=lambda _:None)
        launch.assert_not_called()
    def test_first_interruption_requests_exact_stop_and_never_credits_success(self):
        receipt=self.receipt();directory,runtime=self.terminal(receipt)
        with self.assertRaisesRegex(ValueError, 'interrupted'):
            hosted.wait_owner(directory,receipt,runtime,SimpleNamespace(received=['SIGTERM']),
                now=lambda:1,identity=lambda pid:None,sleep=lambda _:None)
        self.assertEqual(binding.J(directory/'STOP.json'), {'nonce':receipt['nonce'],'identity':receipt['identity']})
    def test_deadline_preserves_owner_and_requests_stop_only(self):
        receipt=self.receipt();directory=self.root/'owner';directory.mkdir()
        with patch.object(hosted.custody.os, 'kill') as kill, self.assertRaisesRegex(RuntimeError, 'overall deadline'):
            hosted.wait_owner(directory,receipt,self.root/'run',SimpleNamespace(received=[]),now=lambda:101)
        kill.assert_not_called();self.assertTrue((directory/'STOP.json').exists())
    def test_failed_qualification_terminal_is_not_success(self):
        receipt=self.receipt();directory,runtime=self.terminal(receipt,success=False)
        with self.assertRaisesRegex(ValueError, 'qualification failed'):
            hosted.terminal_check(directory,receipt,runtime)
    def test_context_hash_is_checked_before_parsing(self):
        (self.root/'HOSTED-CONTEXT.json').write_text('{}')
        with patch.dict(os.environ, {'OWNED_PAGE_HOSTED_ROOT':str(self.root),
                                    'OWNED_PAGE_HOSTED_CONTEXT_SHA256':'0'*64}), \
             self.assertRaisesRegex(ValueError, 'context bytes changed'):
            binding.root_context()
    def fetch_fixture(self, *, bad=None):
        packet=self.root/'packet';packet.mkdir()
        runtime=self.root/'run';runtime.mkdir();(runtime/'receipts').mkdir()
        sdk={'Package.swift':hashlib.sha256(b'sdk').hexdigest()}
        base={'core.cpp':hashlib.sha256(b'base').hexdigest()}
        current={'core.cpp':hashlib.sha256(b'changed').hexdigest()}
        for name,value in [('SDK-SOURCE-MANIFEST.json',sdk),('CORE-BASE-MANIFEST.json',base),
                           ('CORE-SOURCE-MANIFEST.json',current),('CORE-POSTIMAGES.json',current)]:
            (packet/name).write_text(json.dumps(value))
        (packet/'core-postimages').mkdir();(packet/'core-postimages/core.cpp').write_bytes(b'changed')
        calls=[]
        def run(label,command):
            calls.append((label,command))
            argv=command['argv'];cwd=Path(command['cwd']);output=''
            side='SDK' if 'sdk' in label else 'Core'
            if label.endswith('-init'):Path(argv[-1]).mkdir()
            if label.endswith('-checkout'):
                (cwd/('Package.swift' if side=='SDK' else 'core.cpp')).write_bytes(b'sdk' if side=='SDK' else b'base')
            if label.endswith('-head'):output=self.config['sdkCommit' if side=='SDK' else 'coreBaseCommit']
            if label.endswith('-tree'):output=self.config['sdkTree' if side=='SDK' else 'coreBaseTree']
            if label.endswith('-'+str(bad)):output='wrong'
            path=runtime/'receipts'/(label+'.log');path.write_text(output);return path
        return packet,runtime,calls,run
    def test_actual_fetch_sequence_authenticates_base_before_postimages(self):
        packet,runtime,calls,run=self.fetch_fixture()
        with patch.object(binding,'P',packet):
            proof=binding.fetch_sources(self.config,runtime,run,qualify.files_at,qualify.guard.save_json)
        self.assertEqual(len(calls),12)
        self.assertEqual((runtime/'incoming/Core/core.cpp').read_bytes(),b'changed')
        self.assertEqual(proof['Core']['commit'],self.config['coreBaseCommit'])
        self.assertEqual([c['timeoutSeconds'] for n,c in calls if n.endswith('-fetch')],[600,600])
    def test_remote_wrong_commit_refuses_before_private_postimage(self):
        packet,runtime,calls,run=self.fetch_fixture(bad='head')
        with patch.object(binding,'P',packet),self.assertRaisesRegex(ValueError,'identity mismatch'):
            binding.fetch_sources(self.config,runtime,run,qualify.files_at,qualify.guard.save_json)
        self.assertFalse((runtime/'incoming/Core').exists())
        self.assertFalse((runtime/'receipts/REMOTE-SOURCES.json').exists())
    def test_hosted_entry_reaches_authenticated_owner_before_qualifier_staging(self):
        (self.root/'tools').mkdir();(self.root/'tmp').mkdir()
        raw=json.dumps(self.admission).encode();(self.root/'ADMISSION.json').write_bytes(raw)
        calls=[]
        def launch(directory,body,description,*,overall_seconds):
            calls.append((directory,description,overall_seconds));directory.mkdir()
            control=SimpleNamespace(owner={'description':description},
                check=lambda phase:(_ for _ in ()).throw(RuntimeError('authenticated staging boundary')))
            with patch.object(qualify.guard.detached_owner,'Control',return_value=control):body()
        env={'GITHUB_SHA':'a'*40,'GITHUB_RUN_ID':'123','GITHUB_RUN_ATTEMPT':'1'}
        with patch.dict(os.environ,env),patch.object(binding,'packet_check'), \
             patch.object(binding,'preservation_check'),patch.object(binding,'validate_root',return_value=self.root), \
             patch.object(binding,'tool_identity',return_value={}), \
             patch.object(hosted.owner,'launch',side_effect=launch), \
             patch.object(hosted.sys,'argv',['hosted.py','--root',str(self.root),'--packet-seal-sha256',self.seal,
                 '--admission-sha256',hashlib.sha256(raw).hexdigest()]):
            self.assertEqual(hosted.main(),1)
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0][2],9000)
        self.assertEqual(binding.J(self.root/'HOSTED-RESULT.json')['primaryError']['message'],'authenticated staging boundary')
        self.assertFalse((self.root/'run').exists())


if __name__ == '__main__': unittest.main()
