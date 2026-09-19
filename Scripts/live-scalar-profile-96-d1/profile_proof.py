"""Strict supplement to the unchanged frozen build proof; no subprocesses.

The retained build establishes the command and output-map dependency paths, not
the emitted .d bytes. This parser accepts only one make rule (possibly continued,
with multiple targets); repeated object/module/doc rules are intentionally an
unqualified, fail-closed shape limit until actual emitted evidence is available.
A future build must actually emit the shim and profile C header in LatticeTests.d.
Their presence on disk is not importer evidence. This module never repairs a .d.
"""
from pathlib import Path
import hashlib
import json
import re
import shlex

import build_proof
import guarded_runner as guard

PROFILE = 'LATTICE_PERF_LIVE_PROFILE'
BATCH = 'LATTICE_PERF_SELECTED_BATCH'
TARGET = 'arm64-apple-macosx14.0'
FORBIDDEN = ('LATTICE_MANAGED_CELL_STATEMENT_REUSE', 'LATTICE_MANAGED_CELL_SWIFT_MECHANISM')
CORE_PATHS = ('Sources/LatticeCore/src/db.cpp',
              'Sources/LatticeCore/src/perf_live_profile.hpp',
              'Sources/LatticeCore/include/lattice/perf_live_profile.h')
SDK_PATHS = ('Tests/CLatticeTestSQLite/shim.h',
             'Tests/LatticeTests/PerfRefinementBenchmarks.swift')


def require(value, message):
    if not value:
        raise ValueError(message)


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def one(argv, flag):
    require(argv.count(flag) == 1, 'missing or repeated ' + flag)
    index = argv.index(flag)
    require(index + 1 < len(argv), 'missing value for ' + flag)
    return argv[index + 1]


def definitions(argv, required, *, native):
    """Handle joined/split -D/-U, rejecting conflicting or hidden profile flags."""
    require(not any(name in arg for name in FORBIDDEN for arg in argv), 'old prototype flag')
    require(not any(arg in ('-include', '-imacros', '-undef') or arg.startswith(('-include=', '-imacros='))
                    for arg in argv), 'forced macro input unsupported')
    seen = {name: [] for name in (PROFILE, BATCH)}
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in ('-D', '-U'):
            require(index + 1 < len(argv), 'missing macro operand')
            kind, operand = arg, argv[index + 1]
            index += 2
        elif arg.startswith(('-D', '-U')) and len(arg) > 2:
            kind, operand = arg[:2], arg[2:]
            index += 1
        else:
            require(not any(name in arg for name in seen), 'unrecognized profile flag form')
            index += 1
            continue
        name, separator, value = operand.partition('=')
        if name in seen:
            require(kind == '-D', 'profile macro undefinition: ' + name)
            expected = '1' if native and name == PROFILE else ''
            require(value == expected and bool(separator) == bool(expected), 'conflicting profile definition: ' + name)
            seen[name].append(operand)
        else:
            require(not any(key in operand for key in seen), 'unrecognized profile macro')
    require(all(seen[name] for name in required), 'missing explicit profile definition')
    return seen


def swift_channels(argv):
    swift, importer = [], []
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in ('-Xcc', '-Xfrontend'):
            require(index + 1 < len(argv), 'missing forwarded argument')
            value = argv[index + 1]
            require(not value.startswith('@'), 'forwarded response-file form unsupported')
            (importer if arg == '-Xcc' else swift).append(value)
            index += 2
        else:
            swift.append(arg)
            index += 1
    return swift, importer


def checked_flags(argv, *, swift=False):
    if swift:
        language, importer = swift_channels(argv)
        return {'swift': definitions(language, (PROFILE, BATCH), native=False),
                'importer': definitions(importer, (PROFILE,), native=True)}
    require('-Xclang' not in argv and not any(x.startswith('-Wp,') for x in argv),
            'native forwarded preprocessor arguments unsupported')
    return {'native': definitions(argv, (PROFILE,), native=True)}


def object_mode(argv, *, swift, require_compile=True, frontend=False):
    """Only the supported object-producing mode earns existing object credit."""
    forbidden = ({'-typecheck', '-parse', '-dump-parse', '-dump-ast', '-print-ast',
                  '-emit-sil', '-emit-silgen', '-emit-ir', '-emit-bc', '-emit-assembly',
                  '-S', '-scan-dependencies', '-emit-imported-modules',
                  '-emit-supported-features'} if swift else
                 {'-fsyntax-only', '-E', '-S', '-M', '-MM', '--analyze', '-analyze',
                  '-emit-ast', '-emit-llvm', '-rewrite-objc'})
    require(not forbidden.intersection(argv), 'non-object compile mode')
    if require_compile:
        require(argv.count('-c') == 1, 'missing or repeated object compile mode')
    elif '-c' in argv:
        require(argv.count('-c') == 1, 'repeated object compile mode')
    else:
        require(frontend and argv.count('-emit-module') == 1,
                'unsupported noncompile frontend mode')
    if frontend:
        require(not ('-c' in argv and '-emit-module' in argv),
                'contradictory compile and module-only frontend modes')


def read_dependencies(path, *, scratch, cwd, allowed, allowed_targets):
    """SDK006's continuation/shlex technique, narrowed to one bounded rule."""
    path = Path(path)
    require(path.is_absolute(), 'dependency path must be absolute')
    resolved = path.resolve(strict=True)
    require(path == resolved, 'dependency output must not use a symlink alias')
    path = resolved
    require(path.is_relative_to(scratch) and path.is_file(), 'dependency file not owned')
    require(path.stat().st_size <= 4 * 1024 * 1024, 'dependency byte cap')
    raw = path.read_bytes()
    text = raw.decode().replace('\\\r\n', ' ').replace('\\\n', ' ')
    require(not any(x in text for x in ('\x00', '$', '#', ';', '|', '\r')), 'unsupported dependency syntax')
    lines = [line for line in text.splitlines() if line.strip()]
    require(len(lines) == 1 and lines[0].count(':') == 1, 'unknown dependency rule form')
    target_text, dependency_text = lines[0].split(':', 1)
    targets, names = shlex.split(target_text), shlex.split(dependency_text)
    require(targets and names and len(names) <= 32768, 'empty or oversized dependency rule')
    normalized_targets = {str((cwd / x).resolve()) if x != 'dependencies' else x for x in targets}
    require(normalized_targets <= allowed_targets, 'unexpected dependency target')
    files = {}
    for name in names:
        file = (cwd / name).resolve(strict=True)
        require(file.is_file() and any(file.is_relative_to(root) for root in allowed),
                'dependency outside authenticated roots: ' + name)
        files[str(file)] = guard.digest(file)
    return {'path': str(path), 'SHA256': hashlib.sha256(raw).hexdigest(),
            'targets': sorted(normalized_targets), 'files': files}


def log_commands(log):
    require(log.stat().st_size <= 512 * 1024 * 1024, 'build log byte cap')
    records = []
    for number, line in enumerate(log.read_text().splitlines(), 1):
        try:
            argv = shlex.split(line)
        except ValueError:
            continue
        if argv[:2] == ['builtin-SwiftDriver', '--']:
            argv = argv[2:]
        if argv and Path(argv[0]).name in ('clang', 'clang++', 'swiftc', 'swift-frontend'):
            records.append({'lineNumber': number, 'argv': argv})
    return records


def make(base_proof, log, sdk, core, scratch, postimages, retained_dir):
    """Join current build bytes and exact postimages; never accept stock hashes."""
    build_proof.verify(base_proof)
    sdk, core, scratch, log = (Path(x).resolve(strict=True) for x in (sdk, core, scratch, log))
    retained_dir = Path(retained_dir).absolute()
    require(not retained_dir.exists() and not retained_dir.is_symlink(), 'retention directory must be fresh')
    require(set(postimages) == {'sdk', 'core'}, 'postimage manifest roots')
    require(set(postimages['core']) == set(CORE_PATHS) and set(postimages['sdk']) == set(SDK_PATHS),
            'postimage manifest must bind exactly five diagnostic sources')
    sources = {}
    for label, root in (('sdk', sdk), ('core', core)):
        for relative, expected in postimages[label].items():
            path = (root / relative).resolve(strict=True)
            require(path.is_relative_to(root) and re.fullmatch('[0-9a-f]{64}', expected), 'invalid postimage')
            require(guard.digest(path) == expected, 'postimage source hash mismatch: ' + relative)
            sources[str(path)] = expected
    log_sha = guard.digest(log)
    records = log_commands(log)
    logged = [r['argv'] for r in records]
    actions, tools, responses, roots = [], {}, {}, {sdk, core, scratch}
    toolchain_roots, platform_roots, sdk_roots = set(), set(), set()

    def tool_file(name):
        lexical = Path(name)
        require(lexical.is_absolute(), 'compiler tool path must be absolute')
        resolved = lexical.resolve(strict=True)
        require(resolved.is_file(), 'compiler tool absent')
        if str(lexical) not in tools:
            tools[str(lexical)] = {'resolvedPath': str(resolved), 'SHA256': guard.digest(resolved)}
        else:
            require(tools[str(lexical)]['resolvedPath'] == str(resolved), 'tool changed during proof')
        chain = lexical.parent.parent.parent
        require(lexical.parent.name == 'bin' and lexical.parent.parent.name == 'usr'
                and chain.suffix == '.xctoolchain', 'unknown toolchain layout')
        toolchain_roots.add(chain.resolve(strict=True))

    def action(argv, label, swift=False):
        require(argv in logged, 'compile action absent from actual log: ' + label)
        # Reject forwarded response files before expansion loses their channel.
        if swift:
            swift_channels(argv)
        expanded, files = build_proof.native_arguments(argv, scratch)
        flags = checked_flags(expanded, swift=swift)
        language, importer = swift_channels(expanded) if swift else (expanded, [])
        require(not any(arg.startswith(('--target', '-target=')) or arg == '-target-variant'
                        for arg in language), 'alternate target spelling unsupported')
        require(one(language, '-target') == TARGET, 'actual compile target differs from frozen macOS target')
        if swift:
            optimizations = [arg for arg in language if arg.startswith('-O')]
            require(optimizations and all(arg == '-O' for arg in optimizations)
                    and '-enable-testing' in language and '-disable-testing' not in language,
                    'selected Swift action lacks consistent Release/testability flags')
            if '-target' in importer:
                require(one(importer, '-target') == TARGET, 'Swift importer target differs')
            require(not any(arg.startswith(('--target', '-target=')) for arg in importer),
                    'alternate importer target spelling unsupported')
        for path, sha in files.items():
            require(path not in responses or responses[path] == sha, 'response changed')
            responses[path] = sha
        tool_file(expanded[0])
        if '-new-driver-path' in expanded:
            tool_file(one(expanded, '-new-driver-path'))
        actual_sdk = Path(one(expanded, '-sdk' if swift else '-isysroot')).resolve(strict=True)
        require(actual_sdk.is_dir() and actual_sdk.suffix == '.sdk'
                and actual_sdk.parent.name == 'SDKs' and actual_sdk.parent.parent.name == 'Developer',
                'unknown SDK layout')
        platform_roots.add(actual_sdk.parent.parent)
        sdk_roots.add(actual_sdk)
        if swift:
            if '-isysroot' in importer:
                require(Path(one(importer, '-isysroot')).resolve(strict=True) == actual_sdk, 'Swift importer SDK differs')
        actions.append({'label': label, 'argv': argv, 'expandedArguments': expanded, 'flags': flags})
        return expanded

    native = base_proof['nativeObjects']
    require(set(native) == set(base_proof['sourceFiles']), 'base native source coverage')
    for source, item in native.items():
        require(Path(source).is_relative_to(core), 'native source not exact Core')
        expanded = action(item['argv'], source)
        require(expanded == item['expandedArguments'], 'base native expansion differs')
        object_mode(expanded, swift=False)
        require(str(Path(one(expanded, '-c')).resolve()) == source, 'native source action differs')
        require(str(Path(one(expanded, '-o')).resolve()) == item['object'], 'native object action differs')
    actual_native = [r for r in records if Path(r['argv'][0]).name in ('clang', 'clang++')
                     and '-c' in r['argv'] and any(x in ' '.join(r['argv']) for x in
                     ('/Sources/LatticeCore/src/', '/Sources/LatticeSwiftCppBridge/src/'))]
    require(len(actual_native) == len(native) and all(r['argv'] in [x['argv'] for x in native.values()]
            for r in actual_native), 'extra or missing actual Core action')

    modules = base_proof['swiftModules']
    require(set(modules) == {'Lattice', 'LatticeTests'}, 'Swift module coverage')
    swift_expanded = {}
    for module, item in modules.items():
        expanded = action(item['argv'], module + ' driver', swift=True)
        swift_expanded[module] = expanded
        language, _ = swift_channels(expanded)
        object_mode(language, swift=True)
        require(one(expanded, '-module-name') == module, 'Swift module action differs')
        actual_sources = {str(Path(x).resolve()) for x in expanded if x.endswith('.swift') and Path(x).is_absolute()}
        require(actual_sources == set(item['sources']), 'actual Swift driver source set differs from output map')
        frontends = [r for r in records if Path(r['argv'][0]).name == 'swift-frontend'
                     and '-module-name' in r['argv'] and one(r['argv'], '-module-name') == module]
        compiled = []
        driver_lines = [r['lineNumber'] for r in records if r['argv'] == item['argv']]
        require(driver_lines, 'selected module driver absent')
        for record in frontends:
            frontend = action(record['argv'], module + ' frontend line ' + str(record['lineNumber']), swift=True)
            frontend_language, _ = swift_channels(frontend)
            object_mode(frontend_language, swift=True, require_compile=False, frontend=True)
            if '-c' in frontend_language:
                compiled.append(record)
                require(record['lineNumber'] > min(driver_lines), 'compile frontend precedes driver')
                require(Path(frontend[0]).parent == Path(expanded[0]).parent, 'compile frontend toolchain differs')
                consumed_list = [str(Path(x).resolve()) for x in frontend if x.endswith('.swift') and Path(x).is_absolute()]
                output_list = [str(Path(frontend[i + 1]).resolve()) for i, x in enumerate(frontend) if x == '-o']
                require(len(consumed_list) == len(set(consumed_list)) and len(output_list) == len(set(output_list)),
                        'duplicate frontend source/object operand')
                consumed, outputs = set(consumed_list), set(output_list)
                require('-primary-file' not in frontend and consumed == set(item['sources'])
                        and outputs == set(item['objects']), 'frontend source/object set differs')
        require(len(compiled) == 1, 'no unique actual object-producing Swift frontend')
        if item['loggedFrontend'] is not None:
            require(item['loggedFrontend'] in frontends, 'base frontend not in actual log')
        drivers = [r['argv'] for r in records if Path(r['argv'][0]).name == 'swiftc'
                   and '-module-name' in r['argv'] and '-output-file-map' in r['argv']
                   and one(r['argv'], '-module-name') == module]
        require(drivers and all(x == item['argv'] for x in drivers), 'unexplained module driver')

    require(len(toolchain_roots) == len(platform_roots) == len(sdk_roots) == 1, 'compiler toolchain or SDK root mismatch')
    roots.update(toolchain_roots | platform_roots)
    db = str(core / CORE_PATHS[0])
    require(db in native and native[db]['sourceSHA256'] == sources[db], 'db.cpp source proof differs')
    db_args = native[db]['expandedArguments']
    require(db_args.count('-MD') == 1 and '-MMD' not in db_args,
            'db.cpp lacks supported full dependency-generation mode')
    require('-MQ' not in db_args, 'unsupported dependency quoting form')
    target = one(db_args, '-MT') if '-MT' in db_args else native[db]['object']
    require(target == 'dependencies' or Path(target).is_absolute(), 'unsupported native dep target')
    native_dep = read_dependencies(one(db_args, '-MF'), scratch=scratch, cwd=sdk,
        allowed=roots, allowed_targets={target})
    require({str(core / p) for p in CORE_PATHS} <= set(native_dep['files']), 'native dependency missing profile source/header')

    tests = modules['LatticeTests']
    mapping = json.loads(Path(tests['outputMap']).read_text())
    require('' in mapping and 'dependencies' in mapping[''], 'global LatticeTests dependency output absent')
    require('-emit-dependencies' in swift_expanded['LatticeTests'], 'driver did not request dependencies')
    target_paths = {str(Path(v).resolve()) for outputs in mapping.values() for k, v in outputs.items()
                    if k in ('object', 'swiftmodule')}
    for flag in ('-emit-module-path', '-emit-objc-header-path'):
        if flag in swift_expanded['LatticeTests']:
            target_paths.add(str(Path(one(swift_expanded['LatticeTests'], flag)).resolve()))
    require(target_paths and all(Path(x).is_relative_to(scratch) for x in target_paths), 'unowned Swift dependency targets')
    swift_dep = read_dependencies(mapping['']['dependencies'], scratch=scratch, cwd=sdk,
        allowed=roots, allowed_targets=target_paths)
    harness = str(sdk / SDK_PATHS[1])
    require({str(sdk / p) for p in SDK_PATHS} | {str(core / CORE_PATHS[2])} <= set(swift_dep['files']),
            'Swift dependency missing shim/header/harness')
    require(tests['sources'].get(harness) == sources[harness], 'harness source proof differs')
    require(harness in mapping and 'object' in mapping[harness], 'harness named object absent')
    harness_object = str(Path(mapping[harness]['object']).resolve())
    require(harness_object in tests['objects'], 'harness object not in base proof')
    reachable, pending = set(), [base_proof['binary']]
    while pending:
        name = pending.pop()
        if name in reachable:
            continue
        reachable.add(name)
        pending.extend(base_proof['linkGraph'].get(name, {}).get('inputs', {}))
    require({native[db]['object'], harness_object} <= reachable, 'profile objects not reachable from test binary')
    for dep in (native_dep, swift_dep):
        for path in set(dep['files']) & set(sources):
            require(dep['files'][path] == sources[path], 'dependency source postimage mismatch')

    retained_dir.mkdir(parents=True, exist_ok=False)
    for label, dep in (('native', native_dep), ('swift', swift_dep)):
        retained = retained_dir / (label + '.d')
        with retained.open('xb') as out:
            out.write(Path(dep['path']).read_bytes())
        require(guard.digest(retained) == dep['SHA256'], 'dependency changed while retaining')
        dep['retainedPath'] = str(retained)
    base_path = retained_dir / 'base-proof.json'
    with base_path.open('xb') as out:
        out.write(encoded(base_proof))
    require(guard.digest(log) == log_sha, 'build log changed while constructing proof')
    supplement = {'schemaVersion': 1, 'scope': 'diagnostic actual compile/importer/source/dependency/object custody only',
        'baseProof': {'path': str(base_path), 'SHA256': guard.digest(base_path)},
        'buildLog': {'path': str(log), 'SHA256': log_sha},
        'sources': sources, 'tools': tools, 'responseFiles': responses,
        'authenticatedDependencyRoots': sorted(str(x) for x in roots), 'actions': actions,
        'dependencies': {'native': native_dep, 'swift': swift_dep},
        'objectJoin': {'dbObject': native[db]['object'], 'harnessSource': harness,
                       'harnessObject': harness_object, 'binary': base_proof['binary']},
        'stockBuildFingerprintCredit': False, 'performanceGoalCredit': False}
    verify(supplement)
    return supplement


def verify(supplement):
    """Rehash actual tools, headers, dependencies and base products before reuse."""
    require(supplement['schemaVersion'] == 1 and not supplement['stockBuildFingerprintCredit']
            and not supplement['performanceGoalCredit'], 'invalid profile proof scope')
    for field in ('baseProof', 'buildLog'):
        record = supplement[field]
        require(guard.digest(Path(record['path'])) == record['SHA256'], field + ' custody changed')
    build_proof.verify(json.loads(Path(supplement['baseProof']['path']).read_text()))
    for field in ('sources', 'responseFiles'):
        for name, expected in supplement[field].items():
            require(guard.digest(Path(name)) == expected, field + ' custody changed')
    for name, record in supplement['tools'].items():
        path = Path(name).resolve(strict=True)
        require(str(path) == record['resolvedPath'] and guard.digest(path) == record['SHA256'], 'tool custody changed')
    for record in supplement['dependencies'].values():
        for field in ('path', 'retainedPath'):
            require(guard.digest(Path(record[field])) == record['SHA256'], 'dependency custody changed')
        for name, expected in record['files'].items():
            require(guard.digest(Path(name)) == expected, 'dependency input custody changed: ' + name)
