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
        for index, arg in enumerate(values):
            tokens[0] += 1
            assert tokens[0] <= 16384, 'native response argument cap'
            if not arg.startswith('@'):
                output.append(arg); continue
            # This exact token is the consumed operand of a Darwin linker
            # rpath option, not a compiler response file. No other @ spelling
            # or context is exempt from the owned-response rules below.
            if arg == '@loader_path' and values[max(0, index - 3):index] == ['-Xlinker', '-rpath', '-Xlinker']:
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

def package_plugin_drivers(log, scratch):
    """Bind known SwiftPM plugin drivers to typed owned state, never split paths."""
    scratch = scratch.resolve()
    cache = scratch / 'plugins/cache'
    if not cache.exists(): return {}
    assert cache.resolve() == cache and cache.is_dir(), 'plugin cache must be physical and owned'
    known = {'Swift_DocC': 'Swift-DocC Convert', 'Swift_DocC_Preview': 'Swift-DocC Preview'}
    states = sorted(cache.glob('*-state.json'))
    assert all(path.name in {name + '-state.json' for name in known} for path in states), 'unknown package plugin state'
    raw_log = log.read_text(); lines = raw_log.splitlines(); records = {}
    checkout = scratch / 'checkouts/swift-docc-plugin'
    for state_path in states:
        name = state_path.name.removesuffix('-state.json')
        prefix = 'package plugin ' + name + ': '
        assert not state_path.is_symlink() and state_path.is_file(), prefix + 'state must be a physical file'
        assert state_path.stat().st_size <= 2 * 2**20, prefix + 'state byte cap'
        state = json.loads(state_path.read_text())
        assert isinstance(state, dict) and set(state) == {'commandLine', 'environment', 'inputHash', 'output', 'result'}, prefix + 'unknown typed state'
        argv = state['commandLine']
        assert isinstance(argv, list) and 1 <= len(argv) <= 1024 and all(type(arg) is str and arg and not any(c in arg for c in '\r\n\0') for arg in argv), prefix + 'invalid typed command arguments'
        assert isinstance(state['environment'], dict) and all(type(k) is str and type(v) is str for k, v in state['environment'].items()), prefix + 'invalid typed environment'
        assert type(state['inputHash']) is str and re.fullmatch('[0-9a-f]{64}', state['inputHash']), prefix + 'input hash shape'
        assert state['result'] == {'exit': {'code': 0}} and type(state['result']['exit']['code']) is int, prefix + 'plugin compiler did not exit zero'
        compiler = Path(argv[0])
        assert compiler.is_absolute() and compiler.name == 'swiftc' and compiler.is_file(), prefix + 'explicit present Swift compiler required'
        compiler_target = compiler.resolve(strict=True)
        raw_command = ' '.join(argv)
        matches = [i for i, line in enumerate(lines, 1) if line == raw_command]
        assert len(matches) == 1, prefix + 'typed command has no unique exact raw-log join'
        line_number = matches[0]
        output = state['output']
        assert type(output) is str and output.strip(), prefix + 'plugin compiler output absent'
        output_lines = output.splitlines()
        assert lines[line_number:line_number + len(output_lines)] == output_lines, prefix + 'typed output is not the exact block immediately after driver'
        assert '-module-name' not in argv and '-output-file-map' not in argv and not any(arg.startswith('@') for arg in argv), prefix + 'unexpected plugin module/response shape'
        # Parse a narrow observed plugin grammar from the typed argument array.
        # Unquoted spaces remain inside their authoritative single arguments.
        single = {'-lPackagePlugin', '-g', '-parse-as-library', '-v'}
        paired = {'-L', '-I', '-F', '-Xlinker', '-target', '-plugin-path', '-sdk',
                  '-swift-version', '-package-description-version', '-module-cache-path', '-Xfrontend', '-o', '-j'}
        sources = []; options = {}; index = 1
        while index < len(argv):
            arg = argv[index]
            if arg in single:
                options.setdefault(arg, []).append(True); index += 1
            elif arg in paired:
                assert index + 1 < len(argv), prefix + 'missing option value'
                options.setdefault(arg, []).append(argv[index + 1]); index += 2
            elif re.fullmatch('-j[0-9]+', arg):
                options.setdefault('-j', []).append(arg[2:]); index += 1
            else:
                path = Path(arg)
                assert path.is_absolute() and path.suffix == '.swift', prefix + 'unknown plugin argument'
                sources.append(path); index += 1
        assert all(options.get(arg) == [True] for arg in single), prefix + 'required plugin flags differ'
        assert options.get('-o') == [str(cache / name)], prefix + 'plugin output not exact owned cache binary'
        assert len(options.get('-target', [])) == 1 and options['-target'][0].startswith('arm64-apple-macosx'), prefix + 'plugin target differs'
        assert options.get('-swift-version') == ['5'] and options.get('-package-description-version') == ['5.7.0'], prefix + 'plugin language/package shape changed'
        assert options.get('-module-cache-path') == [str(scratch.parent / 'module-cache')], prefix + 'plugin module cache outside owned root'
        assert options.get('-Xfrontend') == ['-serialize-diagnostics-path', str(cache / (name + '.dia'))], prefix + 'plugin diagnostic output differs'
        plugin_api = compiler.parent.parent / 'lib/swift/pm/PluginAPI'
        assert options.get('-Xlinker') == ['-rpath', str(plugin_api)], prefix + 'plugin linker arguments differ'
        assert options.get('-plugin-path') == [str(compiler.parent.parent / 'lib/swift/host/plugins/testing')], prefix + 'plugin host path differs'
        sdks = options.get('-sdk', [])
        assert len(sdks) == 2 and sdks[0] == sdks[1] and Path(sdks[0]).is_absolute() and Path(sdks[0]).is_dir(), prefix + 'plugin SDK arguments differ'
        platform_developer = Path(sdks[0]).parent.parent
        assert options.get('-L') == [str(plugin_api), str(platform_developer / 'usr/lib')], prefix + 'plugin library search paths differ'
        assert options.get('-I') == [str(platform_developer / 'usr/lib'), str(plugin_api)], prefix + 'plugin import search paths differ'
        assert options.get('-F') == [str(platform_developer / 'Library/Frameworks')], prefix + 'plugin framework search paths differ'
        # The three pinned DocC source roots account for the main file plus
        # its two shared-source links; traversal never follows arbitrary links.
        plugin_root = checkout / 'Plugins' / known[name]
        source_roots = [plugin_root, checkout / 'Plugins/SharedPackagePluginExtensions', checkout / 'Sources/SwiftDocCPluginUtilities']
        expected = {str(path.resolve(strict=True)) for root in source_roots for path in root.rglob('*.swift')}
        assert expected and all(Path(path).is_relative_to(checkout.resolve(strict=True)) for path in expected), prefix + 'unowned expected plugin source'
        inputs = {}; resolved = set()
        for path in sources:
            assert path.is_relative_to(plugin_root) and path.is_file(), prefix + 'source spelling outside exact plugin root'
            target = path.resolve(strict=True)
            assert target.is_relative_to(checkout.resolve(strict=True)), prefix + 'plugin source escapes owned checkout'
            assert str(path) not in inputs and str(target) not in resolved, prefix + 'duplicate plugin source'
            resolved.add(str(target))
            inputs[str(path)] = {'resolvedPath': str(target), 'SHA256': guard.digest(path)}
        assert resolved == expected, prefix + 'plugin source inventory differs'
        binary = cache / name; diagnostics = cache / (name + '.dia')
        assert binary.is_file() and not binary.is_symlink() and diagnostics.is_file() and not diagnostics.is_symlink(), prefix + 'owned compiler products missing'
        jobs = swift_driver_jobs(argv, scratch)
        assert jobs['expandedArguments'] == argv and not jobs['responseFiles'], prefix + 'plugin response drift'
        assert line_number not in records, prefix + 'ambiguous plugin command join'
        records[line_number] = {'name': name, 'lineNumber': line_number, 'argv': argv,
            'statePath': str(state_path), 'stateSHA256': guard.digest(state_path),
            'inputHash': state['inputHash'], 'inputHashIndependentlyRecomputed': False,
            'outputTextSHA256': hashlib.sha256(output.encode()).hexdigest(), 'outputLogStartLine': line_number + 1,
            'outputLogLineCount': len(output_lines), 'outputTextOccurrencesInLog': raw_log.count(output.strip()), 'exitCode': 0,
            'compiler': str(compiler), 'compilerResolvedPath': str(compiler_target), 'compilerSHA256': guard.digest(compiler),
            'sources': inputs, 'binary': str(binary), 'binarySHA256': guard.digest(binary),
            'diagnostics': str(diagnostics), 'diagnosticsSHA256': guard.digest(diagnostics), 'jobs': jobs,
            'scope': 'Typed SwiftPM plugin state, exact driver/output log joins and current source/compiler/product custody; opaque SwiftPM inputHash is not independently recomputed.'}
    return records

def verify_package_plugin(record):
    assert guard.digest(Path(record['statePath'])) == record['stateSHA256'], 'plugin state drift'
    compiler = Path(record['compiler'])
    assert str(compiler.resolve(strict=True)) == record['compilerResolvedPath'] and guard.digest(compiler) == record['compilerSHA256'], 'plugin compiler drift'
    for name, item in record['sources'].items():
        path = Path(name)
        assert str(path.resolve(strict=True)) == item['resolvedPath'] and guard.digest(path) == item['SHA256'], 'plugin source drift'
    for path_key, hash_key in [('binary', 'binarySHA256'), ('diagnostics', 'diagnosticsSHA256')]:
        path = Path(record[path_key])
        assert not path.is_symlink() and guard.digest(path) == record[hash_key], 'plugin product drift'

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
    plugins = package_plugin_drivers(log, scratch)
    for line_number, line in enumerate(log.read_text().splitlines(), 1):
        if line_number in plugins:
            plugin = plugins[line_number]
            driver_jobs.append(dict(plugin['jobs'], module='plugin:' + plugin['name'],
                kind='typed SwiftPM package plugin', lineNumber=line_number,
                compiler=plugin['compiler'], rawArguments=plugin['argv']))
            continue
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
    if plugins:
        assert {item['compiler'] for item in driver_jobs} == {item['compiler'] for item in plugins.values()}, 'plugin and ordinary Swift compiler paths differ'
    proof.update(swiftDriverJobs=driver_jobs, nativeObjects=native, nativeResponseFiles=responses, swiftModules=swift_inputs, linkGraph=selected_links,
        derivedLinkInvocations=derived_links, products=products, packagePluginDrivers=plugins,
        linkProofScope='Fresh Debug canonical driver stable lists and transitive objects/two binaries; derived child temporary-list bytes are not independently verified.',
        linkedArchives=archives, binary=str(binary), binarySHA256=guard.digest(binary), bundle=bundle)
    return proof

def verify(proof):
    for record in proof.get('packagePluginDrivers', {}).values(): verify_package_plugin(record)
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
