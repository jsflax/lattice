"""Exact retained command shapes plus synthetic maps/files, never remote map proof."""
from copy import deepcopy
from pathlib import Path
import ast
import json
import shlex
import tempfile
import unittest
import build_proof as b
import test_analysis as prior

P = Path(__file__).resolve().parent

class MapCases(unittest.TestCase):
    def temporary(self):
        value = tempfile.TemporaryDirectory()
        self.addCleanup(value.cleanup)
        return Path(value.name)

    def observed(self):
        data = json.loads((P/'observed-swift-commands.json').read_text())
        self.assertEqual(data['sourceLogSHA256'], '9acd5849c4f0a54f235a1009821b7e2b163a3178a6dba19f03cf984ac8601516')
        self.assertFalse(data['remoteMapBytesRetained'])
        rows = data['records']; self.assertEqual(len(rows), 4)
        return [(rows[0], rows[1]), (rows[2], rows[3])]

    def test_actual_two_driver_frontends_exact_shape(self):
        for (driver, frontend), count in zip(self.observed(), (57, 90)):
            a = frontend['argv']; module = a[a.index('-module-name')+1]
            sources = [x for x in a if x.endswith('.swift') and Path(x).is_absolute()]
            objects = [a[i+1] for i,x in enumerate(a) if x == '-o']
            self.assertEqual(len(sources), count); self.assertEqual(len(objects), count)
            self.assertEqual(b.join_threaded_frontend(module, driver['argv'], driver['lineNumber'],
                [frontend], sources, objects), frontend)

    def test_actual_frontend_mismatches_reject(self):
        driver, frontend = self.observed()[0]; a = frontend['argv']; module = 'Lattice'
        sources = [x for x in a if x.endswith('.swift') and Path(x).is_absolute()]
        objects = [a[i+1] for i,x in enumerate(a) if x == '-o']
        cases = []
        for label, flag in [('target','-target'), ('sdk','-sdk'), ('threads','-num-threads')]:
            row = deepcopy(frontend); row['argv'][row['argv'].index(flag)+1] += 'different'; cases.append((label,[row]))
        row=deepcopy(frontend); row['argv'][0]='/different/swift-frontend'; cases.append(('toolchain',[row]))
        row=deepcopy(frontend); row['argv'].remove('-enable-testing'); cases.append(('testability',[row]))
        row=deepcopy(frontend); row['argv'] += ['-primary-file',sources[0]]; cases.append(('primary',[row]))
        row=deepcopy(frontend); row['argv'].remove(sources[0]); cases.append(('missing source',[row]))
        row=deepcopy(frontend); row['argv'] += [sources[0]]; cases.append(('duplicate source',[row]))
        row=deepcopy(frontend); row['argv'][row['argv'].index('-o')+1] += '.other'; cases.append(('object',[row]))
        row=deepcopy(frontend); row['argv'] += ['-o',objects[0]]; cases.append(('duplicate object',[row]))
        row=deepcopy(frontend); row['lineNumber']=driver['lineNumber']-1; cases.append(('order',[row]))
        cases.extend([('missing',[]),('duplicate',[frontend,frontend])])
        for label,rows in cases:
            with self.subTest(label=label), self.assertRaises(AssertionError):
                b.join_threaded_frontend(module,driver['argv'],driver['lineNumber'],rows,sources,objects)

    def fixture(self):
        args = prior.Oracle.compile_fixture(self)
        log,sdk,core,scratch,overlay=args
        lines=[]
        for line in log.read_text().splitlines():
            if '-module-name' not in line: lines.append(line); continue
            argv=shlex.split(line)[2:]; module=argv[argv.index('-module-name')+1]
            path=Path(argv[argv.index('-output-file-map')+1]); mapping=json.loads(path.read_text())
            source=next(iter(mapping)); obj=mapping[source]['object']
            mapping['']={'object':str(scratch/(module+'-unused-global.o'))};path.write_text(json.dumps(mapping))
            argv += ['-whole-module-optimization','-num-threads','3','-target','arm64-apple-macosx14.0','-sdk','/observed/sdk','-c']
            lines.append(shlex.join(argv))
            lines.append(shlex.join(['/usr/bin/swift-frontend','-frontend','-c',source,'-module-name',module,
                '-O','-enable-testing','-num-threads','3','-target','arm64-apple-macosx14.0','-sdk','/observed/sdk','-o',obj]))
        log.write_text('\n'.join(lines))
        return args

    def test_complete_graph_accepts_only_verified_absent_global_and_retains_bytes(self):
        args=self.fixture(); copies=args[0].parent/'maps'
        proof=b.make(*args,map_receipts=copies);b.verify(proof)
        for name,module in proof['swiftModules'].items():
            self.assertEqual(Path(module['retainedOutputMap']).read_bytes(),Path(module['outputMap']).read_bytes())
            self.assertEqual(len(module['absentGlobalObjectAlternatives']),1)
            self.assertIsNotNone(module['loggedFrontend'])
            self.assertTrue(all(Path(x).is_file() for x in module['objects']))

    def test_missing_named_object_rejects_with_map_bytes_and_precise_context(self):
        args=self.fixture(); missing=args[3]/'Lattice.o'; missing.unlink(); copies=args[0].parent/'maps'
        with self.assertRaisesRegex(AssertionError,"key=.*One.swift.*required named object missing"):
            b.make(*args,map_receipts=copies)
        self.assertEqual((copies/'Lattice-output-file-map.json').read_bytes(),(args[3]/'Lattice.map').read_bytes())

    def test_non_wmo_or_single_thread_cannot_skip_global(self):
        for old,new in [('-whole-module-optimization',''),('-num-threads 3','-num-threads 1')]:
            args=self.fixture();args[0].write_text(args[0].read_text().replace(old,new))
            with self.assertRaises(AssertionError):b.make(*args)

    def test_escaped_global_cannot_be_skipped(self):
        args=self.fixture();path=args[3]/'Lattice.map';mapping=json.loads(path.read_text())
        mapping['']['object']=str(args[0].parent/'outside.o');path.write_text(json.dumps(mapping))
        with self.assertRaisesRegex(AssertionError,'object outside scratch'):b.make(*args)

    def test_missing_or_extra_named_mapping_cannot_be_skipped(self):
        for mode in ('missing object field','extra source'):
            args=self.fixture();path=args[3]/'Lattice.map';mapping=json.loads(path.read_text())
            key=next(k for k in mapping if k)
            if mode=='missing object field':mapping[key]={}
            else:
                extra=args[1]/'Sources/Lattice/Extra.swift';extra.write_text('synthetic')
                mapping[str(extra)]=dict(mapping[key])
            path.write_text(json.dumps(mapping))
            with self.assertRaises(AssertionError):b.make(*args)

    def test_missing_frontend_cannot_be_skipped(self):
        args=self.fixture();args[0].write_text('\n'.join(x for x in args[0].read_text().splitlines() if 'swift-frontend' not in x))
        with self.assertRaisesRegex(AssertionError,'no unique compile frontend'):b.make(*args)

    def test_linked_missing_object_cannot_be_covered_by_global_exception(self):
        args=self.fixture();path=args[3]/'partial.LinkFileList'
        path.write_text('\n'.join(x for x in path.read_text().splitlines() if not x.endswith('/Lattice.o')))
        with self.assertRaisesRegex(AssertionError,'transitively join'):b.make(*args)

    def test_final_map_copy_or_absence_drift_rejects(self):
        for mode in ('copy','global'):
            args=self.fixture();proof=b.make(*args,map_receipts=args[0].parent/'maps')
            module=proof['swiftModules']['Lattice']
            path=module['retainedOutputMap'] if mode=='copy' else module['absentGlobalObjectAlternatives'][0]
            Path(path).write_text('changed')
            with self.assertRaises(AssertionError):b.verify(proof)

    def test_log_collector_uses_exact_actual_frontend_records(self):
        pairs=self.observed(); log=self.temporary()/'exact.log'
        lines=['']*max(r['lineNumber'] for pair in pairs for r in pair)
        for pair in pairs:
            for row in pair:lines[row['lineNumber']-1]=row['rawLine']
        log.write_text('\n'.join(lines))
        records=b.logged_swift_frontends(log)
        self.assertEqual(records,[{k:row[k] for k in ('lineNumber','argv')} for _,row in pairs])

    def test_retention_precedes_parsing_and_qualifier_supplies_owned_receipt_path(self):
        tree=ast.parse((P/'build_proof.py').read_text())
        method=next(x for x in tree.body if isinstance(x,ast.FunctionDef) and x.name=='swift_map_record')
        calls=[n for n in ast.walk(method) if isinstance(n,ast.Call)]
        write=next(x for x in calls if isinstance(x.func,ast.Attribute) and x.func.attr=='write')
        parse=next(x for x in calls if isinstance(x.func,ast.Attribute) and x.func.attr=='loads')
        self.assertLess(write.lineno,parse.lineno)
        q=ast.parse((P/'qualify.py').read_text())
        make=next(x for x in ast.walk(q) if isinstance(x,ast.Call) and isinstance(x.func,ast.Attribute)
                  and isinstance(x.func.value,ast.Name) and x.func.value.id=='build_proof' and x.func.attr=='make')
        value=next(x.value for x in make.keywords if x.arg=='map_receipts')
        self.assertEqual(eval(compile(ast.Expression(value),'<exact owned map receipt>','eval'),
            {'receipts':Path('/owned/receipts'),'arm':'original'}),Path('/owned/receipts/original-swift-output-maps'))

if __name__ == '__main__': unittest.main(verbosity=2)
