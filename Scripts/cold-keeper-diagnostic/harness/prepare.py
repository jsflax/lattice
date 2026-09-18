"""Exact source export/overlay; adapted from the retained retention diagnostic."""
import argparse, hashlib, json, os, subprocess, tarfile
from pathlib import Path
P = Path(__file__).resolve().parent.parent
SHA = '73ac6c2ab102216a68a33ee09b0ba5b73ba76e75'
TREE = 'c32f882de14b158c15ed71dee6ca8fe6d8a20cc9'
def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()
def save(path, value):
    with path.open('x') as stream: json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')
def facts(path): return {'sha256': digest(path), 'bytes': path.stat().st_size}
def verify_inputs():
    manifest = json.loads((P/'INPUTS.json').read_text())
    for name, expected in manifest['files'].items():
        path = P/name
        assert not path.is_symlink() and facts(path) == expected, name
    return digest(P/'INPUTS.json')
def verify_source():
    manifest = json.loads((P/'SOURCE-MANIFEST.json').read_text())
    assert manifest['source'] == SHA and manifest['tree'] == TREE
    expected = dict(manifest['files']); expected.update(manifest['overlay'])
    root = P/'source'
    actual = {str(f.relative_to(root)): facts(f) for f in root.rglob('*') if f.is_file()}
    assert not any(f.is_symlink() for f in root.rglob('*'))
    assert actual == expected, 'complete source inventory/hash mismatch'
    return digest(P/'SOURCE-MANIFEST.json')
def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--repo', type=Path, required=True); args = ap.parse_args()
    verify_inputs(); repo = args.repo.resolve(strict=True)
    def git(*parts): return subprocess.check_output(['git', '-C', str(repo), *parts], text=True).strip()
    assert git('rev-parse', SHA+'^{commit}') == SHA and git('rev-parse', SHA+'^{tree}') == TREE
    source = P/'source'; assert not source.exists(); source.mkdir()
    expected = json.loads((P/'SOURCE-MANIFEST.json').read_text()); total = 0; files = {}
    # This child inherits the outer GuardedRunner process group.
    child = subprocess.Popen(['git', '-C', str(repo), 'archive', SHA, 'CMakeLists.txt', 'Sources', 'Tests'], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=child.stdout, mode='r|') as archive:
            for item in archive:
                rel = Path(item.name); assert not rel.is_absolute() and '..' not in rel.parts
                target = source/rel
                if item.isdir(): target.mkdir(parents=True, exist_ok=True); continue
                assert item.isfile(); total += item.size
                assert total <= 128*2**20 and len(files) < 20000
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(item) as incoming, target.open('xb') as out:
                    remaining = item.size
                    while remaining:
                        block = incoming.read(min(65536, remaining)); assert block
                        out.write(block); remaining -= len(block)
                os.chmod(target, 0o755 if item.mode & 0o111 else 0o644); files[item.name] = facts(target)
        assert child.wait(timeout=5) == 0
    finally:
        child.stdout.close()
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=2)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=2)
    assert files == expected['files'], 'baseline source differs'
    for name, fact in expected['overlay'].items():
        original = P/'overlay'/name; assert facts(original) == fact
        target = source/name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(original.read_bytes())
    verify_source()
    save(P/'PREPARED.json', {'source': SHA, 'tree': TREE, 'baseFiles': len(files), 'baseBytes': total,
         'sourceManifestSHA256': digest(P/'SOURCE-MANIFEST.json'), 'inputsSHA256': digest(P/'INPUTS.json'),
         'patchSHA256': digest(P/'diagnostic.patch'), 'workingTreeRead': False})
if __name__ == '__main__': main()
