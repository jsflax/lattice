#!/usr/bin/env python3
"""Capture complete declared lock evidence and refuse drift in a hosted checkout.

This is a strict-consumer integrity gate, not resolution or graph qualification.
Each invocation writes a distinct phase. Native commands remain separate CI steps.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


PHASES = ("baseline", "before-build", "after-build", "before-test", "after-test", "final")
SOURCES = (
    "Package.swift",
    ".github/workflows/ci.yml",
    "Scripts/verify-wrapper-bindings.py",
    "Scripts/wrapper-expected-bindings.json",
    "Scripts/verify-wrapper-lock-integrity.py",
)
MAX_FILE = 4 * 1024 * 1024
MAX_TOTAL = 32 * 1024 * 1024
MAX_FILES = 64
MAX_TREE_BYTES = 2 * 1024 * 1024


def reject_constant(value):
    raise ValueError("Non-JSON numeric constant: " + value)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key: " + key)
        result[key] = value
    return result


def decode(data):
    return json.loads(data, object_pairs_hook=unique_object, parse_constant=reject_constant)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def stable_bytes(path, root):
    """No-follow bounded read; every parent beneath root must be physical."""
    current = root
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise ValueError("Capture root is not a physical directory")
    for part in path.relative_to(root).parts[:-1]:
        current /= part
        if not stat.S_ISDIR(current.lstat().st_mode):
            raise ValueError("Metadata parent is not a physical directory")
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_FILE:
        raise ValueError("Metadata is not a bounded regular file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as handle:
        opened = os.fstat(handle.fileno())
        if identity(before) != identity(opened):
            raise ValueError("Metadata changed before open")
        data = handle.read(MAX_FILE + 1)
        ended = os.fstat(handle.fileno())
    after = path.lstat()
    if identity(before) != identity(ended) or identity(before) != identity(after) or len(data) != before.st_size:
        raise ValueError("Metadata changed during capture")
    return data


def capture(workspace, destination, phase):
    record = {
        "schema": "lattice.strict-lock-snapshot/1", "phase": phase,
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "workspace": str(workspace), "strictConsumer": True, "graphAccepted": False,
        "files": [], "errors": [], "lockPaths": [],
        "discovery": {"rootLock": "Package.resolved", "metadataRoot": ".swiftpm",
                      "maximumDepth": 8, "maximumDirectories": 128, "maximumEntries": 4096,
                      "maximumFiles": MAX_FILES, "maximumFileBytes": MAX_FILE,
                      "maximumTotalBytes": MAX_TOTAL},
    }
    total = 0
    seen = set()

    def add(relative, role):
        nonlocal total
        item = {"relativePath": relative, "role": role}
        record["files"].append(item)
        try:
            if relative in seen or len(record["files"]) > MAX_FILES:
                raise ValueError("Duplicate path or file-count bound exceeded")
            seen.add(relative)
            data = stable_bytes(workspace / relative, workspace)
            if total + len(data) > MAX_TOTAL:
                raise ValueError("Total metadata byte bound exceeded")
            total += len(data)
            output = destination / "files" / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open("xb") as handle:
                handle.write(data)
            item.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), present=True,
                        artifactPath=str(output.relative_to(destination)))
            if role == "lock":
                parsed = decode(data)
                if not isinstance(parsed, dict) or not isinstance(parsed.get("pins"), list):
                    raise ValueError("Lock must be a JSON object with pins array")
                item.update(formatVersion=parsed.get("version"), pinCount=len(parsed["pins"]),
                            originHashPresent="originHash" in parsed, originHash=parsed.get("originHash"))
                record["lockPaths"].append(relative)
        except Exception as error:
            item["error"] = str(error)
            record["errors"].append({"path": relative, "error": str(error)})

    for relative in SOURCES:
        add(relative, "source")
    add("Package.resolved", "lock")
    metadata = workspace / ".swiftpm"
    record["discovery"]["metadataRootPresent"] = os.path.lexists(metadata)
    directories = entries = 0
    try:
        if os.path.lexists(metadata) and not stat.S_ISDIR(metadata.lstat().st_mode):
            raise ValueError(".swiftpm is not a physical metadata directory")
        queue = [(metadata, 0)] if os.path.lexists(metadata) else []
        while queue:
            directory, depth = queue.pop()
            if not stat.S_ISDIR(directory.lstat().st_mode):
                raise ValueError("Metadata directory changed or became a link")
            directories += 1
            if directories > 128:
                raise ValueError("Metadata directory bound exceeded")
            with os.scandir(directory) as scanned:
                children = []
                for entry in scanned:
                    entries += 1
                    if entries > 4096:
                        raise ValueError("Metadata entry bound exceeded")
                    children.append(entry)
            for entry in sorted(children, key=lambda value: value.name):
                if entry.is_symlink():
                    raise ValueError("Metadata symlink refused: " + entry.name)
                if entry.is_dir(follow_symlinks=False):
                    if depth >= 8:
                        raise ValueError("Metadata depth bound exceeded")
                    queue.append((Path(entry.path), depth + 1))
                elif entry.name == "Package.resolved":
                    add(str(Path(entry.path).relative_to(workspace)), "lock")
    except Exception as error:
        record["errors"].append({"path": ".swiftpm", "error": str(error)})
    record["discovery"].update(directoriesVisited=directories, entriesVisited=entries)
    record["lockPaths"].sort()
    record["capturedBytes"] = total
    record["completeWithinDeclaredBounds"] = not record["errors"]
    return record


def git(workspace, destination, label, *arguments):
    """Read-only Git object commands; no implicit lazy network fetching."""
    argv = ["git", "-c", "safe.directory=" + str(workspace), *arguments]
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
    completed = subprocess.run(argv, cwd=workspace, env=environment, capture_output=True, timeout=15)
    (destination / (label + ".stdout")).write_bytes(completed.stdout)
    (destination / (label + ".stderr")).write_bytes(completed.stderr)
    (destination / (label + ".command.json")).write_text(json.dumps({
        "argv": argv, "cwd": str(workspace), "exitCode": completed.returncode,
    }, indent=2) + "\n")
    if completed.returncode != 0:
        raise ValueError("Read-only Git identity command failed: " + label)
    return completed.stdout


def inventory(record):
    if record.get("completeWithinDeclaredBounds") is not True or record.get("errors"):
        raise ValueError("Incomplete lock/source snapshot")
    result = {}
    for item in record["files"]:
        if item.get("present") is not True or item.get("error"):
            raise ValueError("Missing or invalid captured file")
        name = item["relativePath"]
        if name in result:
            raise ValueError("Duplicate inventory path")
        result[name] = {key: item[key] for key in ("role", "bytes", "sha256")}
    if "Package.resolved" not in result or not set(SOURCES).issubset(result):
        raise ValueError("Required source/root lock missing")
    return result


def committed_lock_inventory(data):
    """Validate NUL-delimited `ls-tree -r -t` metadata in the declared scope."""
    if not data or len(data) > MAX_TREE_BYTES or not data.endswith(b"\0"):
        raise ValueError("Missing, truncated or oversized committed metadata inventory")
    nodes = {}
    directories = entries = 0
    locks = []
    for row in data[:-1].split(b"\0"):
        header, separator, raw_path = row.partition(b"\t")
        match = re.fullmatch(rb"(040000|100644|100755) (tree|blob) ([0-9a-f]{40})", header)
        if not separator or not match:
            raise ValueError("Invalid or non-physical committed metadata entry")
        path = raw_path.decode("utf-8")
        parts = path.split("/")
        if (any(part in ("", ".", "..") for part in parts)
                or "\\" in path or any(ord(char) < 32 or ord(char) == 127 for char in path)
                or path in nodes):
            raise ValueError("Unsafe or duplicate committed metadata path")
        mode, kind = match.group(1), match.group(2)
        if (mode == b"040000") != (kind == b"tree"):
            raise ValueError("Committed metadata mode/type mismatch")
        if path == "Package.resolved":
            if kind != b"blob":
                raise ValueError("Committed root lock is not a regular file")
        elif parts[0] == ".swiftpm":
            if path == ".swiftpm" and kind != b"tree":
                raise ValueError("Committed .swiftpm is not a physical directory")
            if len(parts) > 1:
                entries += 1
            if kind == b"tree":
                directories += 1
            depth = len(parts) - (1 if kind == b"tree" else 2)
            if depth > 8 or directories > 128 or entries > 4096:
                raise ValueError("Committed metadata discovery bound exceeded")
        else:
            raise ValueError("Committed metadata path outside declared scope")
        nodes[path] = kind
        if parts[-1] == "Package.resolved":
            if kind != b"blob":
                raise ValueError("Committed lock is not a regular file")
            locks.append(path)
    for path in nodes:
        if "/" in path and nodes.get(path.rsplit("/", 1)[0]) != b"tree":
            raise ValueError("Missing physical committed metadata parent")
    if "Package.resolved" not in locks or len(locks) + len(SOURCES) > MAX_FILES:
        raise ValueError("Missing root lock or committed lock-count bound exceeded")
    return {"lockPaths": sorted(locks), "directoriesVisited": directories,
            "entriesVisited": entries, "metadataBytes": len(data)}


def match_committed_locks(current, committed):
    captured = {name for name, item in current.items() if item["role"] == "lock"}
    expected = set(committed["lockPaths"])
    if captured != expected:
        raise ValueError("Captured/committed lock path mismatch: missing="
                         + repr(sorted(expected - captured)) + " added="
                         + repr(sorted(captured - expected)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True, choices=PHASES)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    args = parser.parse_args()
    workspace = Path(os.environ["GITHUB_WORKSPACE"])
    if not workspace.is_absolute() or not args.evidence_dir.is_absolute():
        parser.error("Workspace and evidence directory must be absolute")
    destination = args.evidence_dir / args.phase
    destination.mkdir(parents=True, exist_ok=False)
    record = capture(workspace, destination, args.phase)
    outcome = {"schema": "lattice.strict-lock-integrity/1", "phase": args.phase,
               "qualified": False, "graphAccepted": False, "errors": []}
    try:
        outcome["stepOutcomes"] = decode(os.environ.get("CONSUMER_STEP_OUTCOMES", "{}"))
        current = inventory(record)
        head = git(workspace, destination, "checkout-sha", "rev-parse", "HEAD").decode().strip()
        if not re.fullmatch(r"[0-9a-f]{40}", head):
            raise ValueError("Actual HEAD is not a full commit")
        tree = git(workspace, destination, "checkout-tree", "rev-parse", head + "^{tree}").decode().strip()
        if not re.fullmatch(r"[0-9a-f]{40}", tree):
            raise ValueError("Actual tree is not a full identity")
        outcome.update(checkoutSHA=head, checkoutTree=tree)
        if args.phase == "baseline":
            captured_head = stable_bytes(args.evidence_dir / "checkout-sha.stdout", args.evidence_dir).decode().strip()
            if captured_head != head:
                raise ValueError("Metadata checkout and baseline HEAD differ")
            declared = committed_lock_inventory(git(
                workspace, destination, "committed-lock-tree", "ls-tree", "-r", "-t", "-z",
                head, "--", "Package.resolved", ".swiftpm"))
            outcome["committedLockInventory"] = declared
            match_committed_locks(current, declared)
            outcome["immutableHEADLockPathsVerified"] = True
            for relative in sorted(current):
                blob = git(workspace, destination, relative.replace("/", "_") + ".committed", "show", head + ":" + relative)
                if len(blob) != current[relative]["bytes"] or hashlib.sha256(blob).hexdigest() != current[relative]["sha256"]:
                    raise ValueError("Captured source/lock differs from immutable HEAD: " + relative)
            outcome["immutableHEADBytesVerified"] = True
        else:
            baseline = decode(stable_bytes(args.evidence_dir / "baseline/INDEX.json", args.evidence_dir))
            baseline_result = decode(stable_bytes(args.evidence_dir / "baseline/INTEGRITY.json", args.evidence_dir))
            if (baseline_result.get("qualified") is not True
                    or baseline_result.get("immutableHEADBytesVerified") is not True
                    or baseline_result.get("immutableHEADLockPathsVerified") is not True):
                raise ValueError("No qualified committed baseline")
            if baseline_result.get("checkoutSHA") != head or baseline_result.get("checkoutTree") != tree:
                raise ValueError("Checkout identity drift")
            before = inventory(baseline)
            added, removed = sorted(current.keys() - before.keys()), sorted(before.keys() - current.keys())
            changed = sorted(name for name in current.keys() & before.keys() if current[name] != before[name])
            outcome.update(added=added, removed=removed, changed=changed)
            if added or removed or changed:
                raise ValueError("Complete declared lock/source inventory drift")
            outcome["baselineINDEXSHA256"] = hashlib.sha256(stable_bytes(args.evidence_dir / "baseline/INDEX.json", args.evidence_dir)).hexdigest()
        outcome["qualified"] = True
    except Exception as error:
        outcome["errors"].append(str(error))
    (destination / "INDEX.json").write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")
    (destination / "INTEGRITY.json").write_text(json.dumps(outcome, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"phase": args.phase, "integrityQualified": outcome["qualified"],
                      "errors": outcome["errors"], "graphAccepted": False}, sort_keys=True))
    return 0 if outcome["qualified"] else 1


if __name__ == "__main__":
    sys.exit(main())
