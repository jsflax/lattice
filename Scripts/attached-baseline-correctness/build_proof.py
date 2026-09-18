"""Join verbose compile inputs to real objects, link inputs and test bundle."""
from pathlib import Path
import hashlib
import json
import shlex
import guarded_runner as guard

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

def make(log, sdk, core, scratch, overlay):
    proof = guard.compiler_input_proof(log, core)
    expected_cpp = set(proof['sourceFiles'])
    native = {}; swift_inputs = {}; link_graph = {}; responses = {}
    scratch = scratch.resolve(); sdk = sdk.resolve()
    for line in log.read_text().splitlines():
        if not any(flag in line for flag in (' -c ', ' -output-file-map ', ' -o ')):
            continue
        try: argv = shlex.split(line)
        except ValueError: continue
        if not argv: continue
        if argv[0] == 'builtin-SwiftDriver' and len(argv) > 2 and argv[1] == '--':
            argv = argv[2:]
        tool = Path(argv[0]).name
        if tool in ('clang', 'clang++') and '-c' in argv:
            source = str(Path(argv[argv.index('-c') + 1]).resolve())
            if source in expected_cpp:
                output = Path(argv[argv.index('-o') + 1]).resolve()
                assert output.is_relative_to(scratch) and output.is_file()
                assert source not in native
                expanded, response_files = native_arguments(argv, scratch)
                optimizations = [a for a in expanded if a.startswith('-O')]
                assert optimizations and all(a in ('-O', '-O1', '-O2', '-O3', '-Os') for a in optimizations)
                for name, digest in response_files.items():
                    assert name not in responses or responses[name] == digest
                    responses[name] = digest
                native[source] = {'sourceSHA256': guard.digest(Path(source)),
                    'object': str(output), 'objectSHA256': guard.digest(output), 'argv': argv,
                    'expandedArguments': expanded, 'responseFiles': response_files}
        if tool == 'swiftc' and '-module-name' in argv and '-output-file-map' in argv:
            module = argv[argv.index('-module-name') + 1]
            if module in ('Lattice', 'LatticeTests'):
                path = Path(argv[argv.index('-output-file-map') + 1]).resolve()
                assert path.is_relative_to(scratch)
                mapping = json.loads(path.read_text()); inputs = {}; objects = {}
                for name, outputs in mapping.items():
                    if name:
                        file = Path(name).resolve()
                        assert file.is_relative_to(sdk) or file.is_relative_to(scratch)
                        inputs[str(file)] = guard.digest(file)
                    for kind, value in outputs.items():
                        if kind == 'object':
                            obj = Path(value).resolve()
                            assert obj.is_relative_to(scratch) and obj.is_file()
                            objects[str(obj)] = guard.digest(obj)
                assert objects and '-O' in argv and '-enable-testing' in argv
                item = {'argv': argv, 'outputMap': str(path), 'outputMapSHA256': guard.digest(path),
                    'sources': inputs, 'objects': objects}
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
            members = set(); list_proof = []
            for path, format in lists:
                assert path.is_relative_to(scratch) and path.stat().st_size < 4 * 2**20
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
            assert str(output) not in link_graph or link_graph[str(output)] == record
            link_graph[str(output)] = record
    assert set(native) == expected_cpp
    assert set(swift_inputs) == {'Lattice', 'LatticeTests'}
    expected_swift = {str(f.resolve()) for f in (sdk / 'Sources/Lattice').rglob('*.swift')}
    assert expected_swift <= set(swift_inputs['Lattice']['sources'])
    assert str((sdk / overlay).resolve()) in swift_inputs['LatticeTests']['sources']
    executables = {Path(name) for name in link_graph
        if '/LatticeTests.xctest/Contents/MacOS/' in name or '/LatticePackageTests.xctest/Contents/MacOS/' in name}
    assert len(executables) == 1
    binary = next(iter(executables)); assert binary.is_file() and binary.is_relative_to(scratch)
    object_paths = {v['object'] for v in native.values()}
    object_paths |= set(swift_inputs['Lattice']['objects']) | set(swift_inputs['LatticeTests']['objects'])
    reachable = set(); pending = [str(binary)]; selected_links = {}
    while pending:
        name = pending.pop()
        if name in reachable: continue
        reachable.add(name)
        if name in link_graph:
            selected_links[name] = link_graph[name]
            pending.extend(link_graph[name]['inputs'])
    assert object_paths <= reachable, 'all Core/SDK/test objects must transitively join the selected test binary'
    archives = {name: guard.digest(Path(name)) for name in reachable if name.endswith('.a')}
    bundles = [p for p in scratch.rglob('*.xctest') if p.is_dir()]
    assert sum(binary.is_relative_to(p) for p in bundles) == 1
    bundle = {str(f): guard.digest(f) for p in bundles for f in p.rglob('*') if f.is_file() and not f.is_symlink()}
    proof.update(nativeObjects=native, nativeResponseFiles=responses, swiftModules=swift_inputs, linkGraph=selected_links,
        linkedArchives=archives, binary=str(binary), binarySHA256=guard.digest(binary), bundle=bundle)
    return proof

def verify(proof):
    for name, digest in proof['nativeResponseFiles'].items(): assert guard.digest(Path(name)) == digest
    for name, digest in proof['sourceFiles'].items(): assert guard.digest(Path(name)) == digest
    for item in proof['nativeObjects'].values(): assert guard.digest(Path(item['object'])) == item['objectSHA256']
    for module in proof['swiftModules'].values():
        assert guard.digest(Path(module['outputMap'])) == module['outputMapSHA256']
        for field in ('sources', 'objects'):
            for name, digest in module[field].items(): assert guard.digest(Path(name)) == digest
    for output, link in proof['linkGraph'].items():
        assert guard.digest(Path(output)) == link['outputSHA256']
        for item in link['lists']: assert guard.digest(Path(item['path'])) == item['SHA256']
        for name, digest in link['inputs'].items(): assert guard.digest(Path(name)) == digest
    for field in ('linkedArchives', 'bundle'):
        for name, digest in proof[field].items(): assert guard.digest(Path(name)) == digest
    assert guard.digest(Path(proof['binary'])) == proof['binarySHA256']
