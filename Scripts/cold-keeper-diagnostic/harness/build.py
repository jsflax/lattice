"""One fresh arm: exact probe syntax first, uniform build, actual link custody."""
import argparse, json, re, shlex, subprocess, hashlib
from pathlib import Path
from prepare import P, SHA, TREE, digest, save, verify_inputs, verify_source

def words(item): return item.get('arguments') or shlex.split(item['command'])
def run(argv, **kwargs):
    print(json.dumps({'argv': list(map(str, argv))}), flush=True)
    return subprocess.run(argv, check=True, **kwargs)
def object_output(entry):
    argv = words(entry)
    assert argv.count('-o') == 1, 'compile command has no unique object output'
    return (Path(entry['directory']) / argv[argv.index('-o') + 1]).resolve()

def capture_configure_artifacts(root, entries, receipt):
    # Configure ran only after the caller proved this build root absent.
    # Record its exact outputs before the freshness assertion, including any
    # offending target output. Do not silently ignore all CMake directories.
    target_outputs = {object_output(entry) for entry in entries}
    target_outputs.update({root/'ColdKeeperProbe', root/'core/libLatticeCore.a', root/'core/libSqliteVec.a'})
    paths = sorted(set(root.rglob('*.o')) | set(root.rglob('*.a')) |
                   ({root/'ColdKeeperProbe'} if (root/'ColdKeeperProbe').exists() else set()))
    files = [{'path': str(path.relative_to(root)), 'bytes': path.stat().st_size,
              'sha256': digest(path), 'symlink': path.is_symlink()} for path in paths]
    offending = sorted(str(path.relative_to(root)) for path in target_outputs if path.exists())
    save(receipt, {'stage': 'before-target-build', 'files': files, 'existingTargetOutputs': offending,
                  'scope': 'observed after successful configure, not evidence of historical unretained paths'})
    assert not offending, 'pre-existing target outputs: ' + repr(offending)
    assert all(not item['symlink'] and (root/item['path']).resolve().is_relative_to(root) for item in files), 'unowned configured artifact'
    return files

def verify_configure_artifacts(root, files):
    for item in files:
        path = root/item['path']
        assert not path.is_symlink() and path.is_file() and path.resolve().is_relative_to(root), item['path']
        assert path.stat().st_size == item['bytes'] and digest(path) == item['sha256'], 'configured artifact changed: ' + item['path']
    return {root/item['path'] for item in files}

def expected_sources():
    cmake = (P/'source/CMakeLists.txt').read_text(); result = {}
    for target in ['LatticeCore', 'SqliteVec']:
        block = cmake.split('add_library('+target+' STATIC', 1)[1].split(')', 1)[0]
        result[target] = {str((P/'source'/f).resolve()) for f in re.findall(r'Sources/[^\s)]+\.(?:cpp|cc|c)', block)}
    result['ColdKeeperProbe'] = {str(P/'harness/probe.cpp')}; return result
def verify_build(arm, expected_proof_hash=None):
    path = P/('BUILD-PROOF-'+arm+'.json')
    if expected_proof_hash is not None: assert digest(path) == expected_proof_hash, 'proof changed'
    proof = json.loads(path.read_text())
    assert proof['source'] == SHA and proof['tree'] == TREE and proof['arm'] == arm and proof['uniformO3']
    assert proof['inputsSHA256'] == verify_inputs() and proof['sourceManifestSHA256'] == verify_source()
    assert proof['toolchainSHA256'] == digest(P/'TOOLCHAIN.json')
    toolchain = json.loads((P/'TOOLCHAIN.json').read_text())
    for name, expected in toolchain['files'].items():
        path = Path(toolchain[name]); assert digest(path) == expected['sha256'] and path.stat().st_size == expected['bytes']
    assert digest(Path(toolchain['sdk'])/'usr/include/sqlite3.h') == toolchain['sqliteHeader']['sha256']
    for name, hashed in proof['sdkImportStubs'].items():
        imported = Path(name).resolve()
        assert imported.is_relative_to(Path(toolchain['sdk']).resolve()) and digest(imported) == hashed
    for item in proof['custody']:
        path = P/item['path']; assert not path.is_symlink() and digest(path) == item['sha256'], item['path']
    assert proof['binary'] == 'build-'+arm+'/ColdKeeperProbe'
    return proof
def build(arm):
    verify_inputs(); verify_source(); root = P/('build-'+arm)
    entries = json.loads((root/'compile_commands.json').read_text())
    inventory_path = P/('CONFIGURE-ARTIFACTS-'+arm+'.json')
    configured = capture_configure_artifacts(root, entries, inventory_path)
    expected = expected_sources()
    all_expected = set().union(*expected.values())
    selected = [e for e in entries if str(Path(e['file']).resolve()) in all_expected]
    assert len(selected) == len(all_expected)
    fixture = [e for e in selected if Path(e['file']).resolve() == P/'harness/probe.cpp']; assert len(fixture) == 1
    syntax = words(fixture[0]).copy(); ix = syntax.index('-o'); del syntax[ix:ix+2]
    assert syntax.count('-c') == 1; syntax[syntax.index('-c')] = '-fsyntax-only'
    run(syntax, cwd=fixture[0]['directory'])
    run(['cmake', '--build', str(root), '--target', 'ColdKeeperProbe', '--parallel', '1'], cwd=P)
    objects = []; by_target = {target: {} for target in expected}
    for entry in selected:
        source = str(Path(entry['file']).resolve()); argv = words(entry)
        assert '-O3' in argv and '-g0' in argv and '-DNDEBUG' in argv
        assert all(not a.startswith('-O') or a == '-O3' for a in argv) and not any(a.startswith('-flto') for a in argv)
        definitions = [a for a in argv if a.startswith('-DLATTICE_COLD_KEEPER_TIMING')]
        assert definitions == (['-DLATTICE_COLD_KEEPER_TIMING=1'] if arm == 'on' else [])
        obj = (Path(entry['directory'])/argv[argv.index('-o')+1]).resolve(); assert obj.is_relative_to(root) and obj.is_file()
        target = next(t for t, sources in expected.items() if source in sources)
        assert obj.name not in by_target[target]; by_target[target][obj.name] = obj
        objects.append({'source': str(Path(source).relative_to(P)), 'sourceSHA256': digest(Path(source)),
                        'object': str(obj.relative_to(P)), 'objectSHA256': digest(obj), 'argv': argv})
    configured_paths = verify_configure_artifacts(root, configured)
    configured_objects = {path for path in configured_paths if path.suffix == '.o'}
    configured_archives = {path for path in configured_paths if path.suffix == '.a'}
    assert {f.resolve() for f in root.rglob('*.o')} == {P/x['object'] for x in objects} | configured_objects, 'unexpected compiled object'
    link_path = root/'CMakeFiles/ColdKeeperProbe.dir/link.txt'; link = shlex.split(link_path.read_text())
    archives = {(root/a).resolve() for a in link if a.endswith('.a')}
    assert archives == {root/'core/libLatticeCore.a', root/'core/libSqliteVec.a'}
    assert set(root.rglob('*.a')) == archives | configured_archives
    direct = {(root/a).resolve() for a in link if a.endswith('.o')}; assert direct == set(by_target['ColdKeeperProbe'].values())
    ar = json.loads((P/'TOOLCHAIN.json').read_text())['ar']; members = {}
    for archive in sorted(archives):
        target = archive.stem.removeprefix('lib')
        listing = subprocess.check_output([ar, '-t', str(archive)], text=True, timeout=10).splitlines()
        listing = [name.strip() for name in listing if name.strip() and not name.startswith('__.SYMDEF')]
        assert len(listing) == len(set(listing)) and set(listing) == set(by_target[target]), 'archive member inventory'
        members[archive.name] = {}
        for name in listing:
            body = subprocess.check_output([ar, '-p', str(archive), name], timeout=10)
            hashed = hashlib.sha256(body).hexdigest(); assert hashed == digest(by_target[target][name]), 'archive/object bytes differ'
            members[archive.name][name] = hashed
    # Darwin map object table must reference only the exact direct object and
    # members proven above; archive members may be omitted by demand linking.
    map_path = root/'probe.map'; map_text = map_path.read_text()
    table = map_text.split('# Object files:', 1)[1].split('# Sections:', 1)[0]
    map_objects = []; used_archives = set(); platform_imports = {}; synthetic_objects = []
    sdk = Path(json.loads((P/'TOOLCHAIN.json').read_text())['sdk']).resolve()
    for line in table.splitlines():
        match = re.match(r'\[\s*\d+\]\s+(.+)$', line.strip())
        if not match: continue
        value = match.group(1)
        if value in {'linker synthesized', 'tlv-file', 'inits-file'}:
            synthetic_objects.append(value); continue
        member = re.fullmatch(r'(.+\.a)(?:\[\d+\])?\(([^)]+)\)', value)
        if member:
            archive = (root/member.group(1)).resolve(); name = member.group(2)
            assert archive in archives and name in members[archive.name], value; used_archives.add(archive)
        elif value.endswith('.tbd'):
            imported = (root/value).resolve()
            assert imported.is_relative_to(sdk) and imported.is_file(), value
            platform_imports[str(imported)] = digest(imported)
        else: assert (root/value).resolve() in direct, value
        map_objects.append(value)
    assert used_archives == archives and map_objects
    binary = root/'ColdKeeperProbe'; assert binary.is_file()
    toolchain = json.loads((P/'TOOLCHAIN.json').read_text()); otool = toolchain['otool']
    linkage = subprocess.check_output([otool, '-L', str(binary)], text=True, timeout=10)
    assert '/usr/lib/libsqlite3.dylib' in linkage, 'platform SQLite not linked'
    (root/'otool.txt').write_text(linkage)
    # Exact direct/archive/map gates above permit only selected target inputs;
    # configured objects/archives cannot be used as link inputs.
    verify_configure_artifacts(root, configured)
    custody_paths = [inventory_path, *configured_paths, binary, map_path, link_path, root/'compile_commands.json', root/'CMakeCache.txt', root/'otool.txt', *archives, *(P/x['object'] for x in objects)]
    proof = {'source': SHA, 'tree': TREE, 'arm': arm, 'uniformO3': True, 'freshBuild': True,
        'sourceManifestSHA256': digest(P/'SOURCE-MANIFEST.json'), 'inputsSHA256': digest(P/'INPUTS.json'),
        'toolchainSHA256': digest(P/'TOOLCHAIN.json'), 'binary': str(binary.relative_to(P)), 'syntaxFirst': syntax,
        'configureArtifacts': configured, 'configureInventory': str(inventory_path.relative_to(P)),
        'objects': objects, 'archiveMembers': members, 'linkArgv': link, 'mapObjects': map_objects,
        'platformSQLite': linkage, 'sdkImportStubs': platform_imports, 'linkerSyntheticObjects': synthetic_objects,
        'externalHeaderBoundary': 'Owned source and actual TU flags are authenticated. Xcode SDK/toolchain identity and SQLite header/import stubs are recorded; this does not hash every transitive SDK header.',
        'custody': [{'path': str(f.relative_to(P)), 'sha256': digest(f)} for f in custody_paths]}
    verify_inputs(); verify_source(); save(P/('BUILD-PROOF-'+arm+'.json'), proof)
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('arm', choices=['off', 'on']); build(parser.parse_args().arm)
