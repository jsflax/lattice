"""Synthetic oracle checks only; never invokes Swift, Core, git or the network."""
from pathlib import Path
from copy import deepcopy
import ast
import json
import os
import sqlite3
import tempfile
import unittest
import analyze as a
import build_proof as b
import guarded_runner as guard
import qualify

P = Path(__file__).resolve().parent

def record(code=0):
    return dict(started=True, exitCode=code, success=code == 0,
        primaryError=None, evidenceErrors=[], receivedSignals=[], stopReason=None,
        cleanup=dict(leaderReaped=True, groupGone=True, signals=[], errors=[]))

def framework(arm):
    failure = '<failure message="ATTACHED_DISPLAY_ORACLE">invariant</failure>' if arm == 'original' else ''
    xml = '<testsuites><testsuite>' + ''.join(
        f'<testcase classname="LatticeTests.AttachedBaselineCorrectnessTests" name="{name}()">'
        + (failure if name == a.DISPLAY else '') + '</testcase>' for name in a.NAMES) + '</testsuite></testsuites>'
    log = ('recorded an issue\nTest run with 2 tests failed after 1 seconds with 1 issue.\n'
        if arm == 'original' else 'Test run with 2 tests passed after 1 seconds.\n')
    return xml, log

def fixtures(root, arm, physical=False):
    for name in a.NAMES:
        directory = root / name; directory.mkdir()
        files = {}
        for parity, kind in enumerate(('main', 'attached')):
            for master in (True, False):
                path = directory / (('master-' if master else '') + kind + '.sqlite')
                if physical:
                    db = sqlite3.connect(path)
                    db.execute('CREATE TABLE PerfRefinementMemory(id INTEGER, globalId TEXT, rank INTEGER, title TEXT, body TEXT, accessCount INTEGER, lastAccessed REAL, pinned INTEGER)')
                    rows = []
                    for index in range(5000):
                        rank = index * 2 + parity; v = a.values(rank)
                        if arm == 'corrected' and name == a.DISPLAY and not master:
                            if rank in (4000, 4001):
                                v['accessCount'] += 1; v['lastAccessedSeconds'] = 1_800_000_000 + rank - 4000
                            if rank == 4001: v['title'] = 'outside-owner-04001'
                        rows.append((index + 1, a.uuid(rank).upper(), rank, v['title'], v['body'],
                            v['accessCount'], v['lastAccessedSeconds'], int(v['pinned'])))
                    db.executemany('INSERT INTO PerfRefinementMemory VALUES(?,?,?,?,?,?,?,?)', rows)
                    db.commit(); db.close()
                else: path.write_bytes(b'fixed synthetic seed')
            files['master-' + kind + '.sqlite'] = a.digest(directory / ('master-' + kind + '.sqlite'))
            files[kind + '.sqlite'] = files['master-' + kind + '.sqlite']
        data = dict(caseName=name, complete=True, phase='complete', failure=None, files=files,
            counts=dict(physicalRowsPerStore=5000), sql={})
        if name == a.PRIME:
            data['counts']['primedRows'] = 100
            data['sql'].update(rawCollection=1, priming100=100, sixLiveFields=600)
        else:
            ranks = [rank - rank % 2 for rank in range(4000, 4100)] if arm == 'original' else list(range(4000, 4100))
            data.update(returned=[a.values(r) for r in ranks], returnedUUIDs=[a.uuid(r) for r in ranks],
                localIDs=[r // 2 + 1 for r in range(4000, 4100)])
            data['counts'].update(distinctObjects=50 if arm == 'original' else 100, distinctLocalIDs=50,
                coldOffsetFills=1, coldKeysetFills=0, coldAnchors=1)
            data['sql'].update(sixLiveFields=600, warmLookup=0, warmSixLiveFields=600)
            if arm == 'original':
                data.update(complete=False, phase='display_oracle', failure='invariant("ATTACHED_DISPLAY_ORACLE")')
        (directory / 'RESULT.json').write_text(json.dumps(data))

class Oracle(unittest.TestCase):
    def test_release_build_command_explicit_testability_and_no_early_tests(self):
        tree = ast.parse((P / 'qualify.py').read_text())
        lists = [n for n in ast.walk(tree) if isinstance(n, ast.List)
            and any(isinstance(x, ast.Constant) and x.value == '--build-tests' for x in n.elts)]
        self.assertEqual(len(lists), 1)
        expression = ast.Expression(body=lists[0])
        argv = eval(compile(expression, 'exact Release argv', 'eval'),
            {'config': {'swift': '/owned/swift', 'j': 2}, 'common': lambda c: ['--scratch-path', '/owned/scratch'], 'context': {}})
        self.assertEqual(argv, ['/owned/swift', 'build', '--scratch-path', '/owned/scratch',
            '-c', 'release', '--force-resolved-versions', '--build-tests', '-Xswiftc', '-enable-testing', '-j', '2', '-v'])
        loops = [n for n in ast.walk(tree) if isinstance(n, ast.For)
            and any(isinstance(c, ast.List) and c is lists[0] for c in ast.walk(n))]
        self.assertEqual(len(loops), 1)
        loop = loops[0]
        self.assertEqual(ast.literal_eval(loop.iter), ('corrected',))
        test_calls = [n for n in ast.walk(tree) if isinstance(n, ast.List)
            and any(isinstance(x, ast.Constant) and x.value == '--xunit-output' for x in n.elts)]
        self.assertEqual(len(test_calls), 1)
        self.assertGreater(test_calls[0].lineno, loop.end_lineno)

    def test_final_custody_clears_acceptance_but_retains_observations(self):
        original = dict(success=True, primaryError=None, evidenceErrors=[], receivedSignals=[],
            experimentCompleted=True, correctedFocusedAccepted=True, reproductionConfirmed=True,
            originalSafetyAccepted=False, arms={'original': {'expectedRedConfirmed': True}, 'corrected': {'actual': {'passed': 2}}})
        control = deepcopy(original); qualify.finalize_acceptance(control); self.assertEqual(control, original)
        for key, value in [('success', False), ('primaryError', {'message': 'primary'}),
                ('evidenceErrors', [{'message': 'final custody/deadline/receipt failure'}]), ('receivedSignals', [15])]:
            changed = deepcopy(original); changed[key] = value; qualify.finalize_acceptance(changed)
            self.assertFalse(changed['success']); self.assertFalse(changed['experimentCompleted'])
            self.assertFalse(changed['correctedFocusedAccepted']); self.assertFalse(changed['originalSafetyAccepted'])
            self.assertTrue(changed['reproductionConfirmed']); self.assertEqual(changed['arms'], original['arms'])

    def temporary(self):
        parent = Path(os.environ.get('LATTICE_PARSER_CHECK_ROOT', str(P / 'python-checks'))); parent.mkdir(exist_ok=True)
        item = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(item.cleanup)
        return Path(item.name)

    def test_normal_exit_controls(self):
        a.command(record()); a.command(record(1), 1)

    def test_signals_timeouts_and_cleanup_fail_closed(self):
        for key, value in [('exitCode', -13), ('primaryError', {'message': 'failed'}),
                ('receivedSignals', [15]), ('stopReason', 'command timeout'), ('started', False),
                ('evidenceErrors', ['missing receipt'])]:
            with self.subTest(key=key):
                r = record(1); r[key] = value
                with self.assertRaises(AssertionError): a.command(r, 1)
        for key, value in [('groupGone', False), ('leaderReaped', False), ('signals', ['TERM']), ('errors', ['EPERM'])]:
            with self.subTest(cleanup=key):
                r = record(1); r['cleanup'][key] = value
                with self.assertRaises(AssertionError): a.command(r, 1)

    def test_exact_discovery(self):
        expected = json.loads((P / 'expected-tests.json').read_text())
        text = '\n'.join(expected['caseIdentifiers'])
        a.discover(text, expected)
        for changed in (text.splitlines()[0], text + '\n' + text.splitlines()[0], text.replace(a.PRIME, 'another')):
            with self.assertRaises(AssertionError): a.discover(changed, expected)

    def test_framework_controls(self):
        for arm in ('original', 'corrected'): a.framework(*framework(arm), arm)

    def test_framework_wrong_case_or_issue_rejected(self):
        xml, log = framework('original')
        for changed in (xml.replace('ATTACHED_DISPLAY_ORACLE', 'unrelated'), xml.replace(a.DISPLAY, 'unexpected'),
                xml.replace('<failure ', '<failure/><failure '), xml.replace('</testsuite>', '<failure>global</failure></testsuite>')):
            with self.assertRaises(AssertionError): a.framework(changed, log, 'original')

    def test_global_error_or_skip_rejected(self):
        xml, log = framework('corrected')
        for node in ('<error>setup</error>', '<skipped/>'):
            with self.assertRaises(AssertionError): a.framework(xml.replace('</testsuites>', node + '</testsuites>'), log, 'corrected')

    def test_missing_case_and_signal_log_rejected(self):
        xml, log = framework('corrected')
        with self.assertRaises(AssertionError): a.framework(xml.replace(a.PRIME, a.DISPLAY), log, 'corrected')
        with self.assertRaises(AssertionError): a.framework(xml, log + 'Exited with unexpected signal 13', 'corrected')

    def test_case_controls_and_original_pattern(self):
        for arm in ('original', 'corrected'):
            root = self.temporary(); fixtures(root, arm); a.case_receipts(root, arm)
        file = root / a.DISPLAY / 'RESULT.json'
        original = json.loads(file.read_text())
        for category, key, value in [('sql', 'sixLiveFields', 599), ('sql', 'warmLookup', 1), ('counts', 'distinctObjects', 50)]:
            changed = deepcopy(original); changed[category][key] = value; file.write_text(json.dumps(changed))
            with self.assertRaises(AssertionError): a.case_receipts(root, 'corrected')

    def test_original_wrong_row_signature_rejected(self):
        root = self.temporary(); fixtures(root, 'original')
        file = root / a.DISPLAY / 'RESULT.json'; changed = json.loads(file.read_text())
        changed['returned'][1] = a.values(4001); file.write_text(json.dumps(changed))
        with self.assertRaises(AssertionError): a.case_receipts(root, 'original')

    def test_seed_hash_and_extra_fixture_rejected(self):
        root = self.temporary(); fixtures(root, 'corrected')
        (root / a.PRIME / 'master-main.sqlite').write_bytes(b'changed')
        with self.assertRaises(AssertionError): a.case_receipts(root, 'corrected')
        root = self.temporary(); fixtures(root, 'corrected'); (root / 'extra').mkdir()
        with self.assertRaises(AssertionError): a.case_receipts(root, 'corrected')

    def test_full_independent_physical_read_and_wrong_route(self):
        for arm in ('original', 'corrected'):
            root = self.temporary(); fixtures(root, arm, physical=True)
            self.assertEqual(a.physical_postimages(root, arm)['independentReadRows'], 40000)
        db = sqlite3.connect(root / a.DISPLAY / 'main.sqlite')
        db.execute('UPDATE PerfRefinementMemory SET title=? WHERE rank=4000', ('outside-owner-04001',))
        db.commit(); db.close()
        with self.assertRaises(AssertionError): a.physical_postimages(root, 'corrected')

    def compile_fixture(self):
        root = self.temporary(); sdk = root / 'sdk'; core = root / 'core'; scratch = root / 'scratch'
        def put(path, value='synthetic'):
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text(value); return path
        lines = []; objects = []
        for module in ('LatticeCore', 'LatticeSwiftCppBridge'):
            source = put(core / 'Sources' / module / 'src/unit.cpp')
            obj = put(scratch / (module + '.o')); objects.append(obj)
            lines.append(f'/usr/bin/clang++ -O3 -c {source} -o {obj}')
        overlay = 'Tests/LatticeTests/AttachedBaselineCorrectnessTests.swift'
        for module, path in [('Lattice', 'Sources/Lattice/One.swift'), ('LatticeTests', overlay)]:
            source = put(sdk / path); obj = put(scratch / (module + '.o')); objects.append(obj)
            mapping = put(scratch / (module + '.map'), json.dumps({str(source): {'object': str(obj)}}))
            lines.append(f'builtin-SwiftDriver -- /usr/bin/swiftc -module-name {module} -O -enable-testing -output-file-map {mapping}')
        object_list = put(scratch / 'partial.LinkFileList', '\n'.join(str(x) for x in objects))
        partial = put(scratch / 'partial.o')
        lines.append(f'/usr/bin/clang -r -filelist {object_list} -o {partial}')
        binary = put(scratch / 'LatticeTests.xctest/Contents/MacOS/LatticeTests')
        final_list = put(scratch / 'LatticeTests.LinkFileList', str(partial))
        lines.append(f'/usr/bin/swiftc @{final_list} -o {binary}')
        log = put(root / 'build.log', '\n'.join(lines))
        return log, sdk, core, scratch, overlay

    def test_compiler_transitive_link_control(self):
        args = self.compile_fixture(); proof = b.make(*args); b.verify(proof)
        self.assertEqual(len(proof['nativeObjects']), 2)
        self.assertEqual(len(proof['linkGraph']), 2)

    def test_native_filelist_preserves_literal_spaces(self):
        args = self.compile_fixture(); scratch = args[3]
        old = scratch / 'Lattice.o'; new = scratch / 'Lattice with spaces.o'; old.rename(new)
        mapping = scratch / 'Lattice.map'; mapping.write_text(mapping.read_text().replace(str(old), str(new)))
        filelist = scratch / 'partial.LinkFileList'; filelist.write_text(filelist.read_text().replace(str(old), str(new)))
        proof = b.make(*args); b.verify(proof)
        self.assertIn(str(new), proof['swiftModules']['Lattice']['objects'])

    def test_owned_native_response_control_and_drift(self):
        args = self.compile_fixture(); response = args[3] / 'native.resp'; response.write_text('-O3 -fexceptions')
        args[0].write_text(args[0].read_text().replace('-O3', '@' + str(response)))
        proof = b.make(*args); b.verify(proof)
        self.assertEqual(proof['nativeResponseFiles'], {str(response): a.digest(response)})
        response.write_text('-O0')
        with self.assertRaises(AssertionError): b.verify(proof)
        with self.assertRaises(AssertionError): b.make(*args)

    def test_native_response_escape_cycle_depth_and_bytes_rejected(self):
        args = self.compile_fixture(); scratch = args[3]; outside = scratch.parent / 'outside.resp'; outside.write_text('-O3')
        with self.assertRaises(AssertionError): b.native_arguments(['@' + str(outside)], scratch)
        with self.assertRaises(AssertionError): b.native_arguments(['@relative.resp'], scratch)
        response = scratch / 'cycle.resp'; response.write_text('@' + str(response))
        with self.assertRaises(AssertionError): b.native_arguments(['@' + str(response)], scratch)
        response.write_text('x' * (1024 * 1024 + 1))
        with self.assertRaises(AssertionError): b.native_arguments(['@' + str(response)], scratch)
        chain = [scratch / f'depth{i}.resp' for i in range(9)]
        for index, path in enumerate(chain): path.write_text('@' + str(chain[index+1]) if index < 8 else '-O3')
        with self.assertRaises(AssertionError): b.native_arguments(['@' + str(chain[0])], scratch)

    def test_compiler_missing_input_or_release_flag_rejected(self):
        for transform in (lambda t: '\n'.join(t.splitlines()[1:]), lambda t: t.replace('-O3', '-O0'), lambda t: t.replace('-enable-testing', '')):
            args = self.compile_fixture(); args[0].write_text(transform(args[0].read_text()))
            with self.assertRaises((AssertionError, ValueError)): b.make(*args)

    def test_compiler_unlinked_object_rejected(self):
        args = self.compile_fixture(); path = args[3] / 'partial.LinkFileList'
        path.write_text('\n'.join(path.read_text().splitlines()[1:]))
        with self.assertRaises(AssertionError): b.make(*args)

    def test_compiler_mutated_object_map_or_binary_rejected(self):
        for relative in ('Lattice.o', 'Lattice.map', 'LatticeTests.xctest/Contents/MacOS/LatticeTests'):
            args = self.compile_fixture(); proof = b.make(*args)
            (args[3] / relative).write_text('changed')
            with self.assertRaises(AssertionError): b.verify(proof)

    def build_identity_fixture(self):
        args = self.compile_fixture(); proof = b.make(*args); receipts = args[0].parent / 'receipts'; receipts.mkdir()
        def save(name, value):
            path = receipts / ('original-' + name + '.json'); path.write_text(json.dumps(value)); return a.digest(path)
        identity = dict(success=True, sourceProofSHA256=save('source-proof', {'source': 'fixed'}),
            compilerProofSHA256=save('compiler-proof', proof), commandReceiptSHA256=save('release-build', record()),
            binarySHA256=proof['binarySHA256'], packetSealSHA256='synthetic fixed seal')
        save('build-result', identity)
        tree = ast.parse((P / 'qualify.py').read_text())
        functions = [node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and node.name == 'verify_build']
        self.assertEqual(len(functions), 1)
        namespace = dict(receipts=receipts, load=lambda p: json.loads(p.read_text()), guard=guard, analyze=a, build_proof=b)
        exec(compile(ast.Module(body=functions, type_ignores=[]), 'exact qualify.py verify_build', 'exec'), namespace)
        return namespace['verify_build'], dict(arm='original', buildIdentity=identity, compilerProof=proof), receipts

    def test_exact_outer_build_identity_control(self):
        verify, context, _ = self.build_identity_fixture(); verify(context)

    def test_outer_build_failure_or_receipt_drift_rejected(self):
        for suffix in ('source-proof', 'compiler-proof', 'release-build', 'build-result'):
            verify, context, receipts = self.build_identity_fixture()
            (receipts / ('original-' + suffix + '.json')).write_text('{}')
            with self.assertRaises(AssertionError): verify(context)
        verify, context, receipts = self.build_identity_fixture()
        path = receipts / 'original-release-build.json'; failed = record(1); path.write_text(json.dumps(failed))
        context['buildIdentity']['commandReceiptSHA256'] = a.digest(path)
        (receipts / 'original-build-result.json').write_text(json.dumps(context['buildIdentity']))
        with self.assertRaises(AssertionError): verify(context)

    def actual_link_fixture(self):
        data = json.loads((P / 'observed-link-commands.json').read_text())
        self.assertEqual(data['sourceLogSHA256'], '72132feda93436588ab7e2d6d3fe7110b2a9a072f6270790224272bf10ea235a')
        self.assertFalse(data['stableOrTemporaryListContentsRetainedInDownloadedArtifact'])
        drivers = {}; pairs = []
        for row in data['records']:
            if Path(row['argv'][0]).name == 'swiftc':
                # Command-shape fixture only: no fabricated file bytes/hashes.
                drivers[row['output']] = dict(argv=row['argv'], lists=row['lists'],
                    lineNumber=row['lineNumber'], inputs={})
            else:
                scratch = Path(row['output'].split('/scratch/')[0] + '/scratch')
                pairs.append((row, drivers[row['output']], scratch, scratch.parent / 'tmp'))
        return pairs

    def test_actual_five_driver_children_join_without_claiming_missing_bytes(self):
        pairs = self.actual_link_fixture(); self.assertEqual(len(pairs), 5)
        for row, driver, scratch, temporary in pairs:
            lists = [(Path(x['path']), x['format']) for x in row['lists']]
            self.assertFalse(lists[0][0].is_relative_to(scratch))
            child = b.derived_driver_link(row['argv'], lists, driver, scratch, temporary, row['lineNumber'])
            self.assertEqual(child['canonicalDriverLine'], driver['lineNumber'])
            for item in child['temporaryLists']:
                self.assertFalse(item['contentsCaptured']); self.assertFalse(item['contentsIndependentlyVerified'])
                self.assertIsNone(item['contentsSHA256'])

    def test_actual_child_mismatches_and_unexplained_inputs_rejected(self):
        row, driver, scratch, temporary = self.actual_link_fixture()[0]
        lists = [(Path(x['path']), x['format']) for x in row['lists']]
        cases = [('unmatched', row['argv'], lists, None)]
        argv = list(row['argv']); argv[0] = '/other/bin/clang'; cases.append(('toolchain', argv, lists, driver))
        argv = list(row['argv']); argv[argv.index('-o') + 1] += '.other'; cases.append(('output', argv, lists, driver))
        argv = [x.replace('--target=arm64', '--target=x86_64') for x in row['argv']]; cases.append(('target', argv, lists, driver))
        argv = list(row['argv']); argv[argv.index('--sysroot') + 1] += '.other'; cases.append(('sdk', argv, lists, driver))
        cases.append(('new object', row['argv'] + ['/unexplained/a.o'], lists, driver))
        cases.append(('escaped list', row['argv'], [(Path('/unowned/a.LinkFileList'), 'newline-paths')], driver))
        cases.append(('unknown format', row['argv'], [(lists[0][0], 'response-arguments')], driver))
        altered = deepcopy(driver); altered['lists'][0]['path'] = '/unowned/a.LinkFileList'
        cases.append(('unowned canonical list', row['argv'], lists, altered))
        for name, argv, paths, parent in cases:
            with self.subTest(name=name), self.assertRaises(AssertionError):
                b.derived_driver_link(argv, paths, parent, scratch, temporary, row['lineNumber'])

    def paired_synthetic_link(self):
        # Separate synthetic parser integration; never native-run evidence.
        args = self.compile_fixture(); log, _, _, scratch, _ = args
        temporary = scratch.parent / 'tmp'; temporary.mkdir()
        lines = log.read_text().splitlines()
        lines[-1] += ' -target arm64-apple-macosx14.0 -sdk /synthetic/MacOSX.sdk'
        binary = scratch / 'LatticeTests.xctest/Contents/MacOS/LatticeTests'
        missing = temporary / 'TemporaryDirectory.owned/inputs.LinkFileList'
        lines.append(f'/usr/bin/clang -filelist {missing} --target=arm64-apple-macosx14.0 --sysroot /synthetic/MacOSX.sdk -o {binary}')
        log.write_text('\n'.join(lines))
        return args, temporary, missing

    def test_canonical_graph_accepts_derived_child_without_temp_file(self):
        args, temporary, missing = self.paired_synthetic_link()
        self.assertFalse(missing.exists())
        proof = b.make(*args, temporary=temporary); b.verify(proof)
        self.assertEqual(len(proof['linkGraph']), 2)
        self.assertEqual(len(proof['derivedLinkInvocations']), 1)
        self.assertNotIn(str(missing), proof['nativeResponseFiles'])
        self.assertFalse(missing.exists())

    def test_unmatched_and_duplicate_children_rejected(self):
        for mutation in ('remove driver', 'duplicate child'):
            args, temporary, _ = self.paired_synthetic_link(); lines = args[0].read_text().splitlines()
            if mutation == 'remove driver': del lines[-2]
            else: lines.append(lines[-1])
            args[0].write_text('\n'.join(lines))
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError): b.make(*args, temporary=temporary)

    def test_derived_child_does_not_repair_unlinked_core_object(self):
        args, temporary, _ = self.paired_synthetic_link()
        listing = args[3] / 'partial.LinkFileList'; listing.write_text('\n'.join(listing.read_text().splitlines()[1:]))
        with self.assertRaisesRegex(AssertionError, 'transitively join'): b.make(*args, temporary=temporary)

    def test_canonical_list_drift_is_still_rejected_after_child_join(self):
        args, temporary, _ = self.paired_synthetic_link(); proof = b.make(*args, temporary=temporary)
        (args[3] / 'LatticeTests.LinkFileList').write_text('changed canonical input list')
        with self.assertRaises(AssertionError): b.verify(proof)

    def test_proof_failure_receipt_retains_position_without_acceptance(self):
        tree = ast.parse((P / 'qualify.py').read_text())
        matching = [node for node in ast.walk(tree) if isinstance(node, ast.Try) and node.body
            and isinstance(node.body[0], ast.Assign) and isinstance(node.body[0].value, ast.Call)
            and isinstance(node.body[0].value.func, ast.Attribute)
            and node.body[0].value.func.attr == 'make'
            and isinstance(node.body[0].value.func.value, ast.Name)
            and node.body[0].value.func.value.id == 'build_proof']
        self.assertEqual(len(matching), 1)
        root = self.temporary(); receipts = root / 'receipts'; receipts.mkdir(); log = root / 'build.log'; log.write_text('retained build log')
        class FailingProof:
            @staticmethod
            def make(*args, **kwargs): raise AssertionError('known failing stable-list predicate')
        import traceback
        namespace = dict(build_proof=FailingProof, log=log, sdk=root, context={'core': root},
            home=root, config={'overlay': 'owned.swift'}, arm='original', receipts=receipts,
            traceback=traceback, guard=guard, Path=Path, json=json)
        with self.assertRaisesRegex(RuntimeError, 'original compiler proof failed at .*known failing stable-list predicate'):
            exec(compile(ast.Module(body=matching, type_ignores=[]), 'exact compiler-proof exception scope', 'exec'), namespace)
        result = json.loads((receipts / 'original-compiler-proof-failure.json').read_text())
        self.assertFalse(result['compilerProofAccepted']); self.assertTrue(result['buildCommandSucceeded'])
        self.assertEqual(result['type'], 'AssertionError'); self.assertTrue(result['frames'])
        self.assertLessEqual(len(result['frames']), 8); self.assertEqual(result['buildLogSHA256'], a.digest(log))

if __name__ == '__main__': unittest.main(verbosity=2)
