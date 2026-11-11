#!/usr/bin/env python3
"""Typecheck the diagnostic access boundary against a previously built Lattice module."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
PROBES = ROOT / "Tests/CompileProbes/DebugSPI"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", required=True, help="Compiler used for the reviewed build")
    parser.add_argument("--manifest-json", required=True, type=Path,
                        help="swift package dump-package JSON for the reviewed checkout")
    parser.add_argument("--compiler-arguments-json", required=True, type=Path,
                        help="JSON string array of matching import, SDK, target and C++ flags")
    parser.add_argument("--scratch-path", required=True, type=Path,
                        help="Fresh caller-owned build directory for module cache and probe logs")
    args = parser.parse_args()
    manifest = json.loads(args.manifest_json.read_text())
    products = {item["name"] for item in manifest["products"]}
    targets = {item["name"] for item in manifest["targets"]}
    if "LatticeDebugBridge" in products or "LatticeDebugBridge" not in targets:
        raise ValueError("LatticeDebugBridge must remain an implementation target, not a product")
    compiler_arguments = json.loads(args.compiler_arguments_json.read_text())
    if not isinstance(compiler_arguments, list) or not all(isinstance(item, str) for item in compiler_arguments):
        raise ValueError("Compiler arguments must be a JSON array of strings")
    args.scratch_path.mkdir(parents=True, exist_ok=False)
    command = [args.swiftc, "-typecheck", "-module-name", "DebugSPIBoundary",
               "-module-cache-path", str(args.scratch_path / "ModuleCache"), *compiler_arguments]
    cases = [
        ("PublicControl.swift", None),
        ("Allowed.swift", None),
        ("HiddenPrimaryKey.swift", "debugPrimaryKey"),
        ("HiddenJSON.swift", "debugJSON"),
        ("HiddenError.swift", "DynamicDebugReadError"),
    ]
    results = []
    for filename, hidden in cases:
        completed = subprocess.run(command + [str(PROBES / filename)],
                                   capture_output=True, text=True, timeout=120)
        output = completed.stdout + completed.stderr
        (args.scratch_path / (filename + ".log")).write_text(output)
        if hidden is None:
            passed = completed.returncode == 0
        else:
            # A missing module or broken SDK is not evidence of SPI protection.
            # The matching positive control must pass, and the negative must
            # identify this symbol as inaccessible or absent from the import.
            diagnostic = re.search(
                r"error:.*(?:'" + re.escape(hidden) + r"(?:\([^']*\))?'.*(?:inaccessible|scope)|"
                r"has no member '" + re.escape(hidden) + r"')", output)
            passed = completed.returncode != 0 and diagnostic is not None
        results.append(dict(probe=filename, expected="hidden" if hidden else "available",
                            exit_code=completed.returncode, passed=passed))
    report = dict(manifest_bridge_target_only=True, probes=results,
                  passed=all(item["passed"] for item in results))
    (args.scratch_path / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print("Debug SPI probe failed: " + str(error), file=sys.stderr)
        sys.exit(1)
