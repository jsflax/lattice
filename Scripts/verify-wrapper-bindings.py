#!/usr/bin/env python3
"""Check committed SwiftPM pins against an explicitly qualified binding record."""

import argparse
import json
from pathlib import Path
import re
import sys


SCHEMA = "lattice.wrapper-dependency-bindings/1"
IDENTITIES = frozenset({"latticecore", "swift-sdk"})
REPOSITORIES = {
    "latticecore": "https://github.com/jsflax/LatticeCore",
    "swift-sdk": "https://github.com/jsflax/swift-sdk",
}
REVISION = re.compile(r"[0-9a-f]{40}\Z")
GITHUB_REPOSITORY = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")


class BindingError(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise BindingError("JSON contains a duplicate object key")
        result[key] = value
    return result


def reject_constant(value):
    raise BindingError("JSON contains a non-finite numeric constant")


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object, parse_constant=reject_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BindingError(f"cannot read valid JSON from {path.name}") from error


def repository(value):
    """Allow only an optional trailing .git on an HTTPS GitHub repository."""
    if not isinstance(value, str) or not GITHUB_REPOSITORY.fullmatch(value):
        raise BindingError("repository must be an HTTPS GitHub URL without extra components")
    return value[:-4] if value.endswith(".git") else value


def expected_pins(document):
    if not isinstance(document, dict) or document.get("schema") != SCHEMA:
        raise BindingError("expected-binding schema is unsupported")
    if document.get("qualified") is not True:
        raise BindingError("expected bindings are NOT QUALIFIED; release identities are required")
    rows = document.get("pins")
    if not isinstance(rows, list):
        raise BindingError("expected bindings must contain a pins array")
    expected = {}
    for row in rows:
        if not isinstance(row, dict):
            raise BindingError("expected pin must be an object")
        identity = row.get("identity")
        if not isinstance(identity, str) or identity not in IDENTITIES:
            raise BindingError("expected bindings contain an unsupported identity")
        if identity in expected:
            raise BindingError(f"{identity}: duplicate expected binding")
        if row.get("kind") != "remoteSourceControl":
            raise BindingError(f"{identity}: expected kind must be remoteSourceControl")
        location = repository(row.get("repository"))
        if location != REPOSITORIES[identity]:
            raise BindingError(f"{identity}: expected repository must match the wrapper manifest")
        version = row.get("version")
        if not isinstance(version, str) or not version:
            raise BindingError(f"{identity}: expected exact version is missing")
        revision = row.get("revision")
        if not isinstance(revision, str) or not REVISION.fullmatch(revision):
            raise BindingError(f"{identity}: expected full 40-character release revision is missing")
        expected[identity] = row
    if set(expected) != IDENTITIES:
        raise BindingError("expected bindings must name latticecore and swift-sdk exactly once")
    return expected


def verify_resolved(document, expected):
    if not isinstance(document, dict) or type(document.get("version")) is not int or document["version"] != 3:
        raise BindingError("Package.resolved must use the current version 3 format")
    rows = document.get("pins")
    if not isinstance(rows, list):
        raise BindingError("Package.resolved must contain a pins array")
    pins = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("identity"), str) or not row["identity"]:
            raise BindingError("Package.resolved contains a malformed pin identity")
        identity = row["identity"]
        if identity in pins:
            raise BindingError(f"{identity}: duplicate resolved pin")
        pins[identity] = row
    errors = []
    for identity in sorted(expected):
        want = expected[identity]
        pin = pins.get(identity)
        if pin is None:
            errors.append(f"{identity}: resolved pin is missing")
            continue
        if pin.get("kind") != want["kind"]:
            errors.append(f"{identity}: pin kind does not match qualified binding")
        try:
            same_repository = repository(pin.get("location")) == repository(want["repository"])
        except BindingError:
            same_repository = False
        if not same_repository:
            errors.append(f"{identity}: repository does not match qualified binding")
        state = pin.get("state")
        if not isinstance(state, dict):
            errors.append(f"{identity}: resolved state is missing or malformed")
            continue
        if state.get("version") != want["version"]:
            errors.append(f"{identity}: exact version does not match qualified binding")
        if state.get("revision") != want["revision"]:
            errors.append(f"{identity}: full revision does not match qualified binding")
        if state.get("branch") is not None:
            errors.append(f"{identity}: a versioned release pin must not select a branch")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", required=True, type=Path)
    parser.add_argument("--resolved", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        expected = expected_pins(read_json(args.expected))
        errors = verify_resolved(read_json(args.resolved), expected)
    except BindingError as error:
        print(f"wrapper bindings: {error}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print(f"wrapper bindings: {error}", file=sys.stderr)
        return 1
    print("Wrapper dependency bindings verified: latticecore, swift-sdk.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
