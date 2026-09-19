"""Join verbose compile inputs to real objects, link inputs and test bundle."""
from pathlib import Path
import hashlib
import json
import shlex
import re
import guarded_runner as guard

def derived_driver_link(argv, lists, driver, scratch, temporary, line_number):
    """Join command text only; never invent or read ephemeral child-list bytes."""
    prefix = f'link line {line_number}: '
    assert driver is not None, prefix + 'temporary child link has no preceding canonical driver'
    parent = driver['argv']
    assert Path(parent[0]).name == 'swiftc', prefix + 'canonical link is not Swift driver'
    assert Path(argv[0]).parent == Path(parent[0]).parent, prefix + 'child toolchain differs'
    assert argv[argv.index('-o') + 1] == parent[parent.index('-o') + 1], prefix + 'child output differs'
    assert driver['lists'] and all(Path(x['path']).is_relative_to(scratch) for x in driver['lists']), prefix + 'canonical lists not owned stable inputs'
    assert len(lists) == 1 and lists[0][1] == 'newline-paths', prefix + 'unknown child-list shape'
    assert lists[0][0].is_relative_to(temporary), prefix + 'child list outside owned temporary root'
    assert '-target' in parent and '-sdk' in parent, prefix + 'driver target/SDK missing'
    assert [x for x in argv if x.startswith('--target=')] == ['--target=' + parent[parent.index('-target') + 1]], prefix + 'child target differs'
    assert argv.count('--sysroot') == 1 and argv[argv.index('--sysroot') + 1] == parent[parent.index('-sdk') + 1], prefix + 'child SDK differs'
    # Additional explicit object/archive paths cannot silently become new edges.
    direct = [str(Path(x).resolve()) for x in argv if Path(x).is_absolute() and x.endswith(('.o', '.a'))]
    assert set(direct) <= set(driver['inputs']), prefix + 'unexplained child object/archive'
    return {'lineNumber': line_number, 'argv': argv, 'canonicalDriverLine': driver['lineNumber'],
        'output': parent[parent.index('-o') + 1], 'kind': 'derived Swift driver invocation',
        'temporaryLists': [{'path': str(path), 'format': kind,
            'contentsCaptured': False, 'contentsSHA256': None,
            'contentsIndependentlyVerified': False,
            'reason': 'Ephemeral child input is not used as a provenance edge; canonical driver stable lists are authenticated.'}
            for path, kind in lists]}

def native_arguments(argv, scratch):
    """Expand only owned compiler response files; preserve their exact custody."""
    scratch = scratch.resolve(); files = {}; tokens = [0]
    def expand(values, parents=()):
        output = []
        for arg in values:
            tokens[0] += 1
            assert tokens[0] <= 16384, 'native response argument cap'
            if not arg.startswith('@'):
                output.append(arg); continue
            path = Path(arg[1:])
            assert path.is_absolute(), 'native response path must be explicit'
            path = path.resolve(strict=True)
            assert path.is_relative_to(scratch) and path.is_file(), 'native response outside owned scratch'
            assert path not in parents and len(parents) < 8, 'native response cycle/depth'
            assert path.stat().st_size <= 1024 * 1024, 'native response byte cap'
            files[str(path)] = guard.digest(path)
            assert len(files) <= 64, 'native response file cap'
            output.extend(expand(shlex.split(path.read_text()), (*parents, path)))
        return output
    return expand(argv), files

def swift_driver_jobs(argv, scratch):
    """Authenticate explicit driver scheduling options, not measured worker count."""
    expanded, files = native_arguments(argv, scratch)
    values = []
    for i, arg in enumerate(expanded):
        if arg in ('-j', '-num-threads'):
            assert i + 1 < len(expanded), 'driver scheduling value absent'
            value = expanded[i + 1]
            assert value.isdigit() and (int(value) == 2 if arg == '-j' else 1 <= int(value) <= 2), 'driver scheduling exceeds or differs from two jobs'
            if arg == '-j': values.append(value)
        elif arg.startswith('-j') and arg != '-j':
            value = arg[2:]
            assert value.isdigit() and int(value) == 2, 'driver scheduling exceeds or differs from two jobs'
            values.append(value)
        elif arg.startswith('-num-threads='):
            assert arg.split('=', 1)[1] in ('1', '2'), 'opposing driver thread count'
    assert values, 'actual explicit Swift driver job argument missing'
    return {'jobValues': values, 'expandedArguments': expanded, 'responseFiles': files,
            'scope': 'Observed explicit driver options only; no measured simultaneous-worker claim.'}

def logged_swift_frontends(log):
    records = []
    for number, line in enumerate(log.read_text().splitlines(), 1):
        if 'swift-frontend' not in line or ' -module-name ' not in line: continue
        try: argv = shlex.split(line)
        except ValueError: continue
        if argv and Path(argv[0]).name == 'swift-frontend' and '-module-name' in argv:
            records.append({'lineNumber': number, 'argv': argv})
    return records

def join_threaded_frontend(module, driver, driver_line, records, sources, objects):
    prefix = f'{module} driver line {driver_line}: '
    assert '-whole-module-optimization' in driver, prefix + 'absent global object without WMO'
    assert driver.count('-num-threads') >= 1, prefix + 'thread count missing'
    threads = [driver[i + 1] for i, x in enumerate(driver) if x == '-num-threads']
    assert len(set(threads)) == 1 and threads[0].isdigit() and int(threads[0]) > 1, prefix + 'not threaded WMO'
    matches = [r for r in records if r['argv'][r['argv'].index('-module-name') + 1] == module
               and '-c' in r['argv']]
    assert len(matches) == 1, prefix + 'no unique compile frontend'
    record = matches[0]; argv = record['argv']
    assert record['lineNumber'] > driver_line, prefix + 'frontend precedes driver'
    assert Path(argv[0]).parent == Path(driver[0]).parent, prefix + 'frontend toolchain differs'
    assert '-primary-file' not in argv and '-O' in argv and '-enable-testing' in argv, prefix + 'frontend mode differs'
    for flag in ('-target', '-sdk'):
        assert driver.count(flag) == argv.count(flag) == 1, prefix + flag + ' missing/duplicate'
        assert driver[driver.index(flag) + 1] == argv[argv.index(flag) + 1], prefix + flag + ' differs'
    assert argv.count('-num-threads') == 1 and argv[argv.index('-num-threads') + 1] == threads[0], prefix + 'frontend threads differ'
    actual_sources = [str(Path(x).resolve()) for x in argv if x.endswith('.swift') and Path(x).is_absolute()]
    actual_objects = [str(Path(argv[i + 1]).resolve()) for i, x in enumerate(argv) if x == '-o']
    assert len(actual_sources) == len(set(actual_sources)) and set(actual_sources) == set(sources), prefix + 'frontend source set differs from named map inputs'
    assert len(actual_objects) == len(set(actual_objects)) and set(actual_objects) == set(objects), prefix + 'frontend outputs differ from named map objects'
    assert len(actual_sources) == len(actual_objects), prefix + 'not one logged object per source'
    return record

def swift_map_record(module, path, argv, line_number, frontends, sdk, core, scratch, map_receipts):
    prefix = f'{module} driver line {line_number} map {path}: '
    assert path.is_relative_to(scratch) and path.is_file(), prefix + 'map not owned/present'
    assert path.stat().st_size <= 4 * 2**20, prefix + 'map byte cap'
    raw = path.read_bytes(); retained = None
    if map_receipts is not None:
        retained = map_receipts / (module + '-output-file-map.json')
        if retained.exists(): assert retained.read_bytes() == raw, prefix + 'map changed between driver records'
        else:
            with retained.open('xb') as out: out.write(raw)
    mapping = json.loads(raw); inputs = {}; objects = {}; named_objects = {}; absent_global = []
    for name, outputs in mapping.items():
        if name:
            file = Path(name).resolve()
            assert file.is_relative_to(sdk) or file.is_relative_to(core) or file.is_relative_to(scratch), prefix + f'unowned source {name!r}'
            inputs[str(file)] = guard.digest(file)
        for kind, value in outputs.items():
            if kind != 'object': continue
            obj = Path(value).resolve()
            context = prefix + f'key={name!r} object={value!r}: '
            assert obj.is_relative_to(scratch), context + 'object outside scratch'
            if not obj.is_file():
                assert name == '' and not obj.exists() and not obj.is_symlink(), context + 'required named object missing or invalid'
                absent_global.append(str(obj)); continue
            objects[str(obj)] = guard.digest(obj)
            if name: named_objects[str(obj)] = name
    assert objects and '-Onone' in argv and not any(x in argv for x in ('-O', '-Osize', '-Ounchecked', '-whole-module-optimization')), prefix + 'Debug mode required'
    if module in ('Lattice', 'LatticeTests'): assert '-enable-testing' in argv, prefix + 'testability required'
    frontend = None
    assert not absent_global, prefix + 'Debug proof requires every declared map object; no WMO alternative'
    if absent_global:
        assert len(absent_global) == 1, prefix + 'multiple absent global objects'
        assert all('object' in outputs for name, outputs in mapping.items() if name), prefix + 'named input lacks object mapping'
        assert len(named_objects) == len(inputs) and set(objects) == set(named_objects), prefix + 'not exclusively named object outputs'
        frontend = join_threaded_frontend(module, argv, line_number, frontends, inputs, objects)
    return {'argv': argv, 'outputMap': str(path), 'outputMapSHA256': hashlib.sha256(raw).hexdigest(),
        'sources': inputs, 'objects': objects, 'loggedFrontend': frontend,
        'absentGlobalObjectAlternatives': absent_global,
        'retainedOutputMap': str(retained) if retained is not None else None}

def make(log, sdk, core, scratch, overlay, *, temporary=None, map_receipts=None):
    proof = guard.compiler_input_proof(log, core)
    fixture = sdk / 'Qualification/DurablePageRuntimeFixture/runtime_fixture.cpp'
    sqlite = core / 'Sources/SqliteVec/src/sqlite-vec.c'
    for path in (fixture, sqlite): proof['sourceFiles'][str(path.resolve())] = guard.digest(path)
    expected_cpp = set(proof['sourceFiles'])
    required_modules = {'Lattice', 'LatticeTests', 'LatticeSwiftModule', 'OwnedPageQualificationRuntime'}
    native = {}; swift_inputs = {}; link_graph = {}; responses = {}; derived_links = {}; driver_jobs = []
    scratch = scratch.resolve(); sdk = sdk.resolve()
    temporary = temporary.resolve() if temporary is not None else None
    if map_receipts is not None: map_receipts.mkdir(exist_ok=False)
    frontends = logged_swift_frontends(log)
    for line_number, line in enumerate(log.read_text().splitlines(), 1):
        # Swift response files may contain every classification option. Parse and
        # expand recognized driver rows before considering compile/link shape.
        try: argv = shlex.split(line)
        except ValueError:
            assert not re.match(r'(?:builtin-SwiftDriver\s|\S*swiftc(?:\s|$))', line.lstrip()), 'malformed Swift driver row'
            continue
        if not argv: continue
        if argv[0] == 'builtin-SwiftDriver' and len(argv) > 2 and argv[1] == '--':
            argv = argv[2:]
        tool = Path(argv[0]).name
        swift_args = None
        if tool == 'swiftc':
            swift_args, swift_responses = native_arguments(argv, scratch)
            compiling = any(x in swift_args for x in ('-c', '-output-file-map', '-emit-module', '-emit-object')) or any(x.endswith('.swift') for x in swift_args)
            if compiling:
                assert swift_args.count('-module-name') == swift_args.count('-output-file-map') == 1, 'unknown Swift compile-module shape'
            else:
                assert '-o' in swift_args and ('-filelist' in argv or any(x.startswith('@') and 'LinkFileList' in x for x in argv)), 'unclassified Swift driver row'
        if tool in ('clang', 'clang++') and '-c' in argv:
            source = str(Path(argv[argv.index('-c') + 1]).resolve())
            if source in expected_cpp:
                output = Path(argv[argv.index('-o') + 1]).resolve()
                assert output.is_relative_to(scratch) and output.is_file()
                assert source not in native
                expanded, response_files = native_arguments(argv, scratch)
                optimizations = [a for a in expanded if a.startswith('-O')]
                assert optimizations and all(a == '-O0' for a in optimizations), 'fresh Debug native object required'
                for name, digest in response_files.items():
                    assert name not in responses or responses[name] == digest
                    responses[name] = digest
                native[source] = {'sourceSHA256': guard.digest(Path(source)),
                    'object': str(output), 'objectSHA256': guard.digest(output), 'argv': argv,
                    'expandedArguments': expanded, 'responseFiles': response_files}
        if tool == 'swiftc' and compiling:
            module = swift_args[swift_args.index('-module-name') + 1]
            jobs = swift_driver_jobs(argv, scratch)
            assert jobs['expandedArguments'] == swift_args and jobs['responseFiles'] == swift_responses, 'Swift response changed during classification'
            driver_jobs.append(dict(jobs, module=module, lineNumber=line_number, compiler=argv[0], rawArguments=argv))
            if module in required_modules:
                path = Path(swift_args[swift_args.index('-output-file-map') + 1]).resolve()
                assert path.is_relative_to(scratch / 'arm64-apple-macosx/debug'), 'native Debug module layout required'
                item = swift_map_record(module, path, swift_args, line_number, frontends, sdk, core, scratch, map_receipts)
                assert module not in swift_inputs or swift_inputs[module] == item
                swift_inputs[module] = item
        if tool in ('clang', 'clang++', 'swiftc') and '-o' in argv and '-c' not in argv:
            output = Path(argv[argv.index('-o') + 1]).resolve()
            if not output.is_relative_to(scratch) or not output.is_file(): continue
            lists = []
            for index, arg in enumerate(argv):
                if arg == '-filelist': lists.append((Path(argv[index + 1]).resolve(), 'newline-paths'))
                elif arg.startswith('@') and 'LinkFileList' in arg: lists.append((Path(arg[1:]).resolve(), 'response-arguments'))
            if not lists: continue
            if any(not path.is_relative_to(scratch) for path, _ in lists):
                assert temporary is not None and tool in ('clang', 'clang++'), f'link line {line_number}: unsupported link-list location/tool'
                child = derived_driver_link(argv, lists, link_graph.get(str(output)), scratch, temporary, line_number)
                assert str(output) not in derived_links, f'link line {line_number}: multiple derived children for one output'
                assert guard.digest(output) == link_graph[str(output)]['outputSHA256'], f'link line {line_number}: output drift'
                derived_links[str(output)] = child
                continue
            members = set(); list_proof = []
            for path, format in lists:
                assert path.is_relative_to(scratch) and path.stat().st_size < 4 * 2**20, f'link line {line_number}: stable input list bounds: {path}'
                # Darwin ld -filelist uses one literal path per line, including
                # unquoted spaces (e.g. Swift Collections' Integer rank.o).
                # Swift @response files retain shell-like argument tokenization.
                entries = path.read_text().splitlines() if format == 'newline-paths' else shlex.split(path.read_text())
                assert all(x and Path(x).is_absolute() for x in entries)
                listed = {str(Path(x).resolve()) for x in entries}
                assert all(Path(x).is_relative_to(scratch) and Path(x).is_file() for x in listed)
                members |= listed
                list_proof.append({'path': str(path), 'SHA256': guard.digest(path), 'format': format})
            for arg in argv:
                if arg.endswith('.a') and Path(arg).is_absolute():
                    archive = Path(arg).resolve(); assert archive.is_file()
                    members.add(str(archive))
            record = {'outputSHA256': guard.digest(output), 'argv': argv, 'lists': list_proof,
                'inputs': {name: guard.digest(Path(name)) for name in sorted(members)}}
            previous = link_graph.get(str(output))
            assert previous is None or {k: v for k, v in previous.items() if k != 'lineNumber'} == record, f'link line {line_number}: unexplained duplicate output: {output}'
            if previous is None: link_graph[str(output)] = dict(record, lineNumber=line_number)
    assert set(native) == expected_cpp
    assert set(swift_inputs) == required_modules
    expected_swift = {str(f.resolve()) for f in (sdk / 'Sources/Lattice').rglob('*.swift')}
    assert expected_swift <= set(swift_inputs['Lattice']['sources'])
    assert str((sdk / overlay).resolve()) in swift_inputs['LatticeTests']['sources']
    executables = {Path(name) for name in link_graph
        if '/LatticeTests.xctest/Contents/MacOS/' in name or '/LatticePackageTests.xctest/Contents/MacOS/' in name}
    assert len(executables) == 1
    binary = next(iter(executables)); assert binary.is_file() and binary.is_relative_to(scratch)
    runtime = scratch / 'arm64-apple-macosx/debug/OwnedPageQualificationRuntime'
    assert str(runtime) in link_graph and runtime.is_file() and runtime != binary
    required_sources = {
        'LatticeSwiftModule': {str(f.resolve()) for f in (core / 'Sources/LatticeSwiftModule').rglob('*.swift')},
        'OwnedPageQualificationRuntime': {str(sdk / 'Qualification/OwnedPageQualificationRuntime/main.swift')},
    }
    for module, expected in required_sources.items():
        assert expected <= set(swift_inputs[module]['sources']), module + ' source omitted'
    shared_objects = {v['object'] for name, v in native.items() if name != str(fixture)}
    for module in ('Lattice', 'LatticeSwiftModule'): shared_objects |= set(swift_inputs[module]['objects'])
    products = {}; selected_links = {}; reachable_all = set()
    for label, executable, additional in [
        ('tests', binary, set(swift_inputs['LatticeTests']['objects'])),
        ('runtime', runtime, set(swift_inputs['OwnedPageQualificationRuntime']['objects']) | {native[str(fixture)]['object']}),
    ]:
        reachable = set(); pending = [str(executable)]
        while pending:
            name = pending.pop()
            if name in reachable: continue
            reachable.add(name)
            if name in link_graph:
                selected_links[name] = link_graph[name]
                pending.extend(link_graph[name]['inputs'])
        assert shared_objects | additional <= reachable, label + ': source objects missing from actual binary link'
        if label == 'runtime':
            assert not set(swift_inputs['LatticeTests']['objects']) & reachable
            forbidden = ('/LatticeTests.build/', '/LatticePackageDiscoveredTests.build/',
                         '/LatticePackageTests.build/', 'libgtest', '/GoogleTest.build/')
            assert not any(any(part in name for part in forbidden) for name in reachable), 'unrelated test objects in isolated runtime'
        products[label] = {'binary': str(executable), 'binarySHA256': guard.digest(executable),
                           'requiredObjects': sorted(shared_objects | additional), 'reachableInputs': sorted(reachable)}
        reachable_all |= reachable
    archives = {name: guard.digest(Path(name)) for name in reachable_all if name.endswith('.a')}
    bundles = [p for p in scratch.rglob('*.xctest') if p.is_dir()]
    assert sum(binary.is_relative_to(p) for p in bundles) == 1
    bundle = {str(f): guard.digest(f) for p in bundles for f in p.rglob('*') if f.is_file() and not f.is_symlink()}
    assert required_modules <= {item['module'] for item in driver_jobs}
    proof.update(swiftDriverJobs=driver_jobs, nativeObjects=native, nativeResponseFiles=responses, swiftModules=swift_inputs, linkGraph=selected_links,
        derivedLinkInvocations=derived_links, products=products,
        linkProofScope='Fresh Debug canonical driver stable lists and transitive objects/two binaries; derived child temporary-list bytes are not independently verified.',
        linkedArchives=archives, binary=str(binary), binarySHA256=guard.digest(binary), bundle=bundle)
    return proof

def verify(proof):
    for item in proof['swiftDriverJobs']:
        assert item['jobValues'] and all(x == '2' for x in item['jobValues'])
        for name, digest in item['responseFiles'].items(): assert guard.digest(Path(name)) == digest
    for name, digest in proof['nativeResponseFiles'].items(): assert guard.digest(Path(name)) == digest
    for name, digest in proof['sourceFiles'].items(): assert guard.digest(Path(name)) == digest
    for item in proof['nativeObjects'].values(): assert guard.digest(Path(item['object'])) == item['objectSHA256']
    for module in proof['swiftModules'].values():
        assert guard.digest(Path(module['outputMap'])) == module['outputMapSHA256']
        if module['retainedOutputMap'] is not None:
            assert guard.digest(Path(module['retainedOutputMap'])) == module['outputMapSHA256']
        for name in module['absentGlobalObjectAlternatives']:
            assert not Path(name).exists() and not Path(name).is_symlink(), 'previously absent global object appeared'
        for field in ('sources', 'objects'):
            for name, digest in module[field].items(): assert guard.digest(Path(name)) == digest
    for output, link in proof['linkGraph'].items():
        assert guard.digest(Path(output)) == link['outputSHA256']
        for item in link['lists']: assert guard.digest(Path(item['path'])) == item['SHA256']
        for name, digest in link['inputs'].items(): assert guard.digest(Path(name)) == digest
    for field in ('linkedArchives', 'bundle'):
        for name, digest in proof[field].items(): assert guard.digest(Path(name)) == digest
    assert guard.digest(Path(proof['binary'])) == proof['binarySHA256']


def verify_products(proof):
    verify(proof)
    assert set(proof['products']) == {'tests', 'runtime'}
    for product in proof['products'].values():
        assert guard.digest(Path(product['binary'])) == product['binarySHA256']
        assert set(product['requiredObjects']) <= set(product['reachableInputs'])

    if 'fixtureDependencies' in proof:
        record=proof['fixtureDependencies']
        assert guard.digest(Path(record['path']))==record['sha256']
        for name,digest in record['files'].items(): assert guard.digest(Path(name))==digest
