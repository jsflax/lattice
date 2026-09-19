#!/usr/bin/env python3
"""Export the exact reviewed Core inputs; no checkout mutation or dependency fetch."""
import argparse, hashlib, json, os, subprocess, tarfile
from pathlib import Path

PACKET = Path(__file__).resolve().parent.parent
CONFIG = json.loads((PACKET/'SOURCE-CONFIG.json').read_text())
SHA, TREE, SOURCE_MODE = CONFIG['source'], CONFIG['tree'], CONFIG['sourceMode']
assert SOURCE_MODE in {'baseline','bounded'}

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()

def verify_harness():
    manifest=json.loads((PACKET/'HARNESS-SOURCE.json').read_text())
    for name,value in manifest['files'].items():
        path=PACKET/'harness'/name
        assert path.stat().st_size==value['bytes'] and digest(path)==value['sha256'],name
    assert manifest['source']==SHA and manifest['tree']==TREE
    return manifest

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--core-source', required=True)
    args = parser.parse_args()
    verify_harness()
    assert '/localdev/' in str(PACKET), 'all owned output must be under localdev'
    repo = Path(args.core_source).resolve()
    assert git(repo, 'rev-parse', SHA+'^{commit}') == SHA
    assert git(repo, 'rev-parse', SHA+'^{tree}') == TREE
    source = PACKET/'source'
    assert not source.exists() and not (PACKET/'PREPARED.json').exists()
    source.mkdir()
    # Stream only the tracked source/build/test inputs referenced by Core's
    # existing CMake file. No .git, old build tree, network, or working-tree copy.
    child = subprocess.Popen(['git','-C',str(repo),'archive','--format=tar',SHA,
                              'CMakeLists.txt','Sources','Tests'], stdout=subprocess.PIPE)
    files = {}; total = 0
    try:
        with tarfile.open(fileobj=child.stdout, mode='r|') as archive:
            for item in archive:
                relative = Path(item.name)
                assert not relative.is_absolute() and '..' not in relative.parts
                target = source/relative
                if item.isdir(): target.mkdir(parents=True, exist_ok=True); continue
                assert item.isfile(), 'unexpected link or device in source archive'
                total += item.size
                assert total <= 128*2**20 and len(files) < 20000, 'source export cap'
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(item) as incoming, target.open('xb') as output:
                    remaining = item.size
                    while remaining:
                        data = incoming.read(min(65536,remaining)); assert data
                        output.write(data); remaining -= len(data)
                os.chmod(target, 0o755 if item.mode & 0o111 else 0o644)
                files[item.name] = {'sha256':digest(target),'bytes':item.size}
        assert child.wait() == 0
    finally:
        child.stdout.close()
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=2)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=2)
    expected = json.loads((PACKET/'SOURCE-MANIFEST.json').read_text())
    assert expected['source']==SHA and expected['tree']==TREE
    for name, value in expected['files'].items():
        assert name in files and files[name]==value, name
    with (PACKET/'PREPARED.json').open('x') as output:
        json.dump({'source':SHA,'tree':TREE,'sourceFiles':files,'sourceBytes':total,
                   'export':'git archive CMakeLists.txt Sources Tests','workingTreeRead':False},
                  output,indent=2,sort_keys=True)
        output.write('\n')

if __name__ == '__main__': main()
