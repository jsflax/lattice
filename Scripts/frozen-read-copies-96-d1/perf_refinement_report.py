#!/usr/bin/env python3
"""Validate and summarize allocated PerfRefinementBenchmarks Release runs.

One run: --run /.../result.json
A/A/B:   --baseline /.../A/result.json --repeat /.../A2/result.json
         --candidate /.../B/result.json
Every invocation requires --output under ~/localdev. This script never launches
Swift, edits fixtures, changes thresholds, or interprets missing data as a pass.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics


PHASES = {
    "read.total", "read.cold_page_identity_anchor", "read.live_scalars",
    "read.warm_hit", "read.warm_live_scalars", "update.total",
    "update.discovery_hydration_routing", "update.set_and_atomic_increment",
}
CONTRACT_KEYS = (
    "schema", "contract", "releaseBuild", "fixtureRows", "bodyBytes",
    "pageSize", "readStart", "readCount", "updateRanks", "measuredSamples",
    "warmupSamples", "sqlCounterScope", "fixtureMode", "variants",
)
HOST_KEYS = ("hostIdentity", "operatingSystem", "processorCount", "activeProcessorCount")
LEGACY_WRITES = "legacy-row-set-and-increment-v1"
SELECTED_BATCH_WRITES = "selected-batch-set-and-increment-v1"
WRITE_IMPLEMENTATIONS = {LEGACY_WRITES, SELECTED_BATCH_WRITES}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def write_implementation(manifest):
    label = manifest.get("writeImplementation")
    require(isinstance(label, str) and label in WRITE_IMPLEMENTATIONS,
            "missing or unknown writeImplementation")
    return label


def write_comparison(a, repeat, candidate):
    labels = {name: write_implementation(run["manifest"])
              for name, run in (("baseline", a), ("repeat", repeat), ("candidate", candidate))}
    require(labels["baseline"] == labels["repeat"], "A/A writeImplementation differs")
    changed = labels["candidate"] != labels["baseline"]
    require(not changed or (labels["baseline"] == LEGACY_WRITES
                           and labels["candidate"] == SELECTED_BATCH_WRITES),
            "undeclared writeImplementation comparison direction")
    return {
        **labels,
        "candidateSelectedBatchOptIn": labels["candidate"] == SELECTED_BATCH_WRITES,
        "candidateChangesWriteImplementation": changed,
        "comparisonKind": "selected-batch-opt-in" if changed else "same-write-implementation",
    }


def percentile(values, p):
    """Nearest rank: index ceil(p*n)-1; no interpolation of the p95 tail."""
    values = sorted(values)
    return values[max(0, math.ceil(p * len(values)) - 1)]


def distribution(values):
    require(bool(values), "empty distribution")
    return {
        "n": len(values), "min": min(values), "median": statistics.median(values),
        "p95": percentile(values, .95), "p99": percentile(values, .99),
        "max": max(values), "mean": statistics.mean(values),
    }


def load_run(path):
    path = path.resolve(strict=True)
    data = json.loads(path.read_text())
    require(data.get("complete") is True, f"incomplete run: {path}")
    manifest = data["manifest"]
    write_implementation(manifest)
    require(manifest["schema"] == "lattice.perf-refinement/1", "unknown schema")
    require(manifest["contract"] == "read100-six-scalars-update11-v1", "unknown contract")
    require(manifest["releaseBuild"] is True, "not a Release run")
    require(manifest["fixtureRows"] == 10000 and manifest["bodyBytes"] == 256,
            "fixture differs from frozen contract")
    require(manifest["readStart"] == 4000 and manifest["readCount"] == 100
            and manifest["pageSize"] == 100, "read window differs")
    require(manifest["updateRanks"] == [7, 100, 333, 999, 1234, 2345, 3456, 4567, 5678, 6789, 9998],
            "update set differs")
    measured, warmups = manifest["measuredSamples"], manifest["warmupSamples"]
    require(100 <= measured <= 1000 and 5 <= warmups <= 100, "insufficient sample policy")
    require(manifest["variants"] == ["local", "attached"], "missing fixture variant")
    require(Path(manifest["runDirectory"]).resolve() == path.parent, "result moved without its run directory")
    for key in ("sourceRevision", "coreRevision", "buildIdentity"):
        require(bool(manifest.get(key)), f"missing {key}")
    require(isinstance(manifest.get("hostIdentity"), str) and bool(manifest["hostIdentity"].strip()),
            "missing hostIdentity")
    samples = data["samples"]
    require(len(samples) == 2 * (measured + warmups), "sample count mismatch")
    variants = {}
    checksum_contract = {}
    for variant in manifest["variants"]:
        subset = [s for s in samples if s["variant"] == variant]
        require([s["iteration"] for s in subset] == list(range(measured + warmups)),
                f"duplicate/missing/unordered iterations: {variant}")
        for sample in subset:
            require(sample["warmup"] is (sample["iteration"] < warmups), "warmup classification mismatch")
            require(sample["readRows"] == 100 and sample["updatedRows"] == 11, "result count mismatch")
            require(set(sample["phases"]) == PHASES, "phase inventory mismatch")
            for phase in sample["phases"].values():
                require(isinstance(phase["elapsedNS"], int) and phase["elapsedNS"] >= 0, "invalid elapsed time")
                require(isinstance(phase["sqlStatements"], int) and phase["sqlStatements"] >= 0, "invalid SQL count")
            require(sample["coldOffsetFills"] == 1 and sample["coldKeysetFills"] == 0,
                    "cold workload did not fill exactly one offset page")
            allowed_anchors = (1,) if variant == "local" else (0, 1)
            require(sample["coldAnchors"] in allowed_anchors,
                    f"unexpected cold anchor count: {variant}")
            require(sample["warmOffsetFills"] == sample["coldOffsetFills"]
                    and sample["warmKeysetFills"] == sample["coldKeysetFills"]
                    and sample["warmAnchors"] == sample["coldAnchors"], "warm hit unexpectedly filled")
            require(sample["phases"]["read.warm_hit"]["sqlStatements"] == 0,
                    "warm hit issued SQL; inspect rather than silently mixing workload classes")
            for total, parts in (
                ("read.total", ["read.cold_page_identity_anchor", "read.live_scalars"]),
                ("update.total", ["update.discovery_hydration_routing", "update.set_and_atomic_increment"]),
            ):
                for metric in ("elapsedNS", "sqlStatements"):
                    require(sample["phases"][total][metric] >= sum(sample["phases"][p][metric] for p in parts),
                            f"nested phase accounting invalid: {total}")
        checksums = {}
        for field in ("readChecksum", "beforeChecksum", "afterChecksum"):
            unique = {s[field] for s in subset}
            require(len(unique) == 1, f"nondeterministic {field}: {variant}")
            checksums[field] = next(iter(unique))
        require(checksums["beforeChecksum"] != checksums["afterChecksum"], "update had no observed effect")
        checksum_contract[variant] = checksums
        measured_rows = [s for s in subset if not s["warmup"]]
        variants[variant] = {
            "checksums": checksums,
            # Anchors describe the backend mechanism, not the displayed data.
            # Attached stores can overlap physical IDs, so a correct backend
            # may disable (sort, id) keyset anchors for their union view.
            "pageDiagnostics": {
                field: distribution([s[field] for s in measured_rows])
                for field in ("coldOffsetFills", "coldKeysetFills", "coldAnchors",
                              "warmOffsetFills", "warmKeysetFills", "warmAnchors")
            },
            "phases": {
                phase: {
                    "milliseconds": distribution([s["phases"][phase]["elapsedNS"] / 1e6 for s in measured_rows]),
                    "sqlStatements": distribution([s["phases"][phase]["sqlStatements"] for s in measured_rows]),
                } for phase in sorted(PHASES)
            },
        }
    require(checksum_contract["local"] == checksum_contract["attached"],
            "local and attached logical result checksums differ")
    fixtures = {}
    for db in sorted(path.parent.glob("*/master/*.sqlite")):
        fixtures[str(db.relative_to(path.parent))] = {
            "bytes": db.stat().st_size, "sha256": hashlib.sha256(db.read_bytes()).hexdigest(),
        }
    require(len(fixtures) == 3, "missing preserved master databases")
    for variant in manifest["variants"]:
        retained = path.parent / variant / f"iteration-{warmups:04d}"
        require(retained.is_dir(), f"missing first measured postimage: {variant}")
    return {
        "resultPath": str(path), "resultSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "manifest": manifest, "fixtureFiles": fixtures, "variants": variants,
    }


def ratio(new, old):
    return new / old if old != 0 else None


def comparison(a, repeat, candidate):
    write_comparison(a, repeat, candidate)
    for other in (repeat, candidate):
        for key in CONTRACT_KEYS + HOST_KEYS:
            require(a["manifest"][key] == other["manifest"][key], f"comparison mismatch: {key}")
        for variant in a["variants"]:
            require(a["variants"][variant]["checksums"] == other["variants"][variant]["checksums"],
                    f"result semantics differ: {variant}")
    for key in ("sourceRevision", "coreRevision", "buildIdentity"):
        require(a["manifest"][key] == repeat["manifest"][key], f"A/A provenance differs: {key}")
    result = {}
    for variant in a["variants"]:
        result[variant] = {}
        for phase in sorted(PHASES):
            av = a["variants"][variant]["phases"][phase]
            rv = repeat["variants"][variant]["phases"][phase]
            bv = candidate["variants"][variant]["phases"][phase]
            stats = {}
            for percentile_name in ("median", "p95"):
                a_time, repeat_time, candidate_time = (
                    x["milliseconds"][percentile_name] for x in (av, rv, bv)
                )
                noise = abs(repeat_time - a_time)
                improvement = min(a_time, repeat_time) - candidate_time
                stats[percentile_name] = {
                    "baselineMs": a_time, "repeatMs": repeat_time, "candidateMs": candidate_time,
                    "aaAbsoluteDifferenceMs": noise,
                    "repeatOverBaseline": ratio(repeat_time, a_time),
                    "candidateOverBaseline": ratio(candidate_time, a_time),
                    "candidateOverRepeat": ratio(candidate_time, repeat_time),
                    "candidateBelowBothByMoreThanAADifference": improvement > noise,
                    "baselineStatements": av["sqlStatements"][percentile_name],
                    "repeatStatements": rv["sqlStatements"][percentile_name],
                    "candidateStatements": bv["sqlStatements"][percentile_name],
                }
            result[variant][phase] = stats
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--repeat", type=Path)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    singles = args.run is not None
    require(singles != any(x is not None for x in (args.baseline, args.repeat, args.candidate)),
            "choose --run OR all of --baseline/--repeat/--candidate")
    output = args.output.expanduser().resolve()
    allowed = (Path.home() / "localdev").resolve()
    require(output.is_relative_to(allowed), "--output must be under ~/localdev")
    require(not output.exists(), "refuse to replace existing report")
    report = {
        "schema": "lattice.perf-refinement-report/1",
        "percentileMethod": "nearest rank ceil(p*n)-1",
        "limitations": [
            "A/A difference is observed repeat noise, not a confidence interval or significance test.",
            "Thread SQL counter omits background worker statements.",
            "Nested phases must not be added to their enclosing totals.",
            "Cold means fresh Lattice shape/instances; OS file cache is uncontrolled.",
            "Attached cold anchors may be zero or one; page diagnostics expose this backend choice without changing the six live displayed fields.",
            "Full fixture verification occurs outside timed scopes; native correctness gates remain separate.",
            "Provenance strings are supplied by the run owner and need external build and physical-host receipts; matching labels do not independently prove host identity.",
            "The selected batch write implementation is an explicit candidate compile opt-in; its label changes the algorithm, not the Update11 semantics or timed scope.",
        ],
    }
    if singles:
        run = load_run(args.run)
        report["runs"] = {"run": run}
        report["writeImplementations"] = {"run": write_implementation(run["manifest"])}
    else:
        require(all(x is not None for x in (args.baseline, args.repeat, args.candidate)), "A/A/B requires three runs")
        a, repeat, candidate = (load_run(x) for x in (args.baseline, args.repeat, args.candidate))
        report["runs"] = {"baseline": a, "repeat": repeat, "candidate": candidate}
        report["writeImplementations"] = write_comparison(a, repeat, candidate)
        report["comparison"] = comparison(a, repeat, candidate)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"No qualifying report: {error}") from error
