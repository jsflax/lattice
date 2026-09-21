#!/usr/bin/env python3
"""Offline arithmetic over SDK visibility receipts; never authenticates a run.

Usage: evaluate_sync.py run receipts.json
       evaluate_sync.py compare groups.json
groups.json: {"groups": [{"A": "a.json", "A2": "a2.json", "B": "b.json"}, ...]}
Paths are relative to the group manifest. Incomplete runs stay in the report and
make comparison ineligible. No operation or run is silently dropped to pass.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import statistics

SCHEMA = "lattice.sync-public-visibility/1"
NATIVE_CLOCK = "native-steady-ns/tagged-WAL-entry"
PARAMETERS = ("writerCount", "opsPerWriter", "payloadBytes", "cadenceNS", "staggerNS",
              "warmupPerWriter", "quietWarmupOps", "quietOps", "quietCadenceNS", "drainNS", "driverWorkers")
TIMES = ("scheduledNS", "offeredNS", "writeStartNS", "writeReturnNS", "postcommitNS",
         "probeArmedNS", "firstExactReadNS", "lateExactReadNS", "observationDeadlineNS")
COUNTERS = ("unknownOperation", "duplicateCallbacks", "valueMismatch", "readMiss",
            "diagnosticOverflow", "malformedObservation", "rawSyncStateTrue", "rawSyncStateFalse", "rawSyncErrors")
PROBE_FIELDS = ("armStatus", "probeStatus", "probeArmedNS", "postcommitNS", "probeOperationID",
                "probeAttemptID", "probeOwnerID", "probeConnectionID", "probeThreadID",
                "ignoredOwnerCommits", "ignoredSchemaCommits")
FULL = dict(writerCount=8, opsPerWriter=1000, payloadBytes=2048, cadenceNS=40_000_000,
            staggerNS=5_000_000, warmupPerWriter=20, quietWarmupOps=1, quietOps=40,
            quietCadenceNS=1_000_000_000, drainNS=60_000_000_000, driverWorkers=8)
DISCLAIMER = "Numerical checks only. External exact-source, dependency, build, clock, overhead and experiment qualification required. Not a release or goal acceptance."


def uint(value, label, positive=False):
    if type(value) is not int or not (int(positive) <= value <= 2**64 - 1):
        raise ValueError(f"{label}: expected {'positive' if positive else 'nonnegative'} UInt64 integer")
    return value


def string(value, label):
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label}: expected nonempty string")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def read_json(path):
    raw = Path(path).read_bytes()
    if len(raw) > 128 * 1024 * 1024:
        raise ValueError("receipt artifact exceeds 128 MiB analyzer limit")
    data = json.loads(raw, object_pairs_hook=unique_object,
                      parse_constant=lambda x: (_ for _ in ()).throw(ValueError(f"nonfinite JSON number: {x}")))
    return data, hashlib.sha256(raw).hexdigest()


def quantile(values, percentile):
    """Nearest rank, with no interpolation and no clamping of signed samples."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * percentile) - 1)] if ordered else None


def distribution(values):
    return {"count": len(values), "negativeCount": sum(x < 0 for x in values),
            "p50MS": quantile(values, .50), "p95MS": quantile(values, .95),
            "p99MS": quantile(values, .99), "maxMS": max(values) if values else None,
            "minMS": min(values) if values else None}


def analyze(data):
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        raise ValueError("unsupported receipt schema")
    run_id = string(data.get("runID"), "runID")
    mode, profile, clock = data.get("mode"), data.get("profile"), data.get("clock")
    if mode not in ("smoke", "full") or profile not in ("loaded", "quiet-only"):
        raise ValueError("invalid mode/profile")
    if clock not in (NATIVE_CLOCK, "dispatch-uptime/no-probe"):
        raise ValueError("unknown clock")
    if type(data.get("complete")) is not bool:
        raise ValueError("complete must be boolean")
    p = data.get("effectiveParameters", {})
    if not isinstance(p, dict):
        raise ValueError("effectiveParameters must be an object")
    if not isinstance(data.get("metadata", {}), dict):
        raise ValueError("metadata must be an object")
    for key in PARAMETERS:
        uint(p.get(key), f"effectiveParameters.{key}", key not in ("writerCount", "staggerNS"))
    if p["writerCount"] > 64 or p["opsPerWriter"] > 100_000 or p["quietOps"] > 100_000 or p["warmupPerWriter"] > 100_000 or p["quietWarmupOps"] > 100_000:
        raise ValueError("parameters exceed bounded analyzer profile")
    if (profile == "quiet-only") != (p["writerCount"] == 0):
        raise ValueError("quiet-only must have no hot writers; loaded must have hot writers")
    records = data.get("receipts")
    if not isinstance(records, list) or len(records) > 200_000:
        raise ValueError("receipts must be a bounded array")
    if p["writerCount"] * (p["warmupPerWriter"] + p["opsPerWriter"]) + p["quietWarmupOps"] + p["quietOps"] > 200_000:
        raise ValueError("expected coverage exceeds bounded analyzer profile")
    expected = {(stream, phase, writer, sequence)
                for stream in ("hot", "quiet")
                for phase in ("warmup", "measured")
                for writer in range(p["writerCount"] if stream == "hot" else 1)
                for sequence in range(p["warmupPerWriter" if phase == "warmup" else "opsPerWriter"]
                                      if stream == "hot" else p["quietWarmupOps" if phase == "warmup" else "quietOps"])}
    if len(expected) > 200_000:
        raise ValueError("expected coverage exceeds bounded analyzer profile")
    seen, ids, tokens = set(), set(), set()
    violations = []
    issue_counts = {}

    def issue(reason):
        issue_counts[reason] = issue_counts.get(reason, 0) + 1
        if len(violations) < 64 and reason not in violations:
            violations.append(reason)

    started, finished = uint(data.get("startedNS"), "startedNS"), uint(data.get("finishedNS"), "finishedNS")
    epoch, deadline = data.get("measurementEpochNS"), data.get("deadlineNS")
    for key, value in (("measurementEpochNS", epoch), ("deadlineNS", deadline)):
        if value is not None:
            uint(value, key)
    # Early completed profiles normally finish BEFORE the unused drain deadline.
    if epoch is None or deadline is None or not started <= epoch <= finished or deadline < epoch:
        issue("invalid or incomplete run time bounds")
    if epoch is not None:
        hot_last = ((p["opsPerWriter"] - 1) * p["cadenceNS"] + (p["writerCount"] - 1) * p["staggerNS"]
                    if p["writerCount"] else 0)
        quiet_last = (p["quietOps"] - 1) * p["quietCadenceNS"]
        if deadline != epoch + max(hot_last, quiet_last) + p["drainNS"]:
            issue("measured deadline differs from last scheduled offer plus fixed drain")
    errors = data.get("errors")
    if not isinstance(errors, list) or len(errors) > 64 or any(not isinstance(e, str) for e in errors):
        raise ValueError("errors must be a bounded string array")
    if errors:
        issue("run recorded errors")
    counters = data.get("counters", {})
    if not isinstance(counters, dict):
        raise ValueError("counters must be an object")
    for key in COUNTERS:
        uint(counters.get(key), f"counters.{key}")
    for key in ("unknownOperation", "valueMismatch", "diagnosticOverflow", "malformedObservation", "rawSyncErrors"):
        if counters[key]:
            issue(f"nonzero {key}")
    if not data["complete"]:
        issue("producer declared incomplete")
    groups = {stream: [] for stream in ("hot", "quiet")}
    owner_for_writer, writer_for_owner, writer_for_connection = {}, {}, {}
    for r in records:
        if not isinstance(r, dict):
            raise ValueError("receipt must be an object")
        stream, phase = string(r.get("stream"), "stream"), string(r.get("phase"), "phase")
        key = (stream, phase, uint(r.get("writer"), "writer"), uint(r.get("sequence"), "sequence"))
        identity = string(r.get("id"), "receipt.id")
        token = uint(r.get("token"), "token", True)
        if key not in expected or key in seen or identity in ids or token in tokens:
            raise ValueError("unexpected or duplicate logical operation/id/token")
        if r.get("runID") != run_id or identity != f"{run_id}/{key[0]}/{key[1]}/{key[2]}/{key[3]}":
            raise ValueError("logical operation identity does not match run/stream/phase/writer/sequence")
        seen.add(key); ids.add(identity); tokens.add(token)
        if r.get("writerStoreID") != f"clients/{key[0]}-writer-{key[2]}.sqlite":
            raise ValueError("writer store identity mismatch")
        for field in TIMES:
            if r.get(field) is not None:
                uint(r[field], field)
                if not started <= r[field] <= finished and field not in ("scheduledNS", "observationDeadlineNS"):
                    issue("operation timestamp outside run bounds")
        for field in ("valueMismatchCount", "duplicateCallbacks"):
            uint(r.get(field), field)
        if type(r.get("timedOut")) is not bool or r.get("valueMatch") not in (True, False, None) or (r.get("valueMatch") is not None and type(r["valueMatch"]) is not bool):
            raise ValueError("receipt boolean field has invalid type")
        if r.get("writeError") is not None and not isinstance(r["writeError"], str):
            raise ValueError("writeError must be null or string")
        if r.get("writeError") is not None or r["timedOut"] or r.get("valueMatch") is not True or r["valueMismatchCount"]:
            issue("write, timeout or exact-value failure")
        if r.get("firstExactReadNS") is not None and (r.get("observedID") != identity or r.get("readerStoreID") != f"clients/{key[0]}-watcher.sqlite"):
            issue("public read does not identify the expected receiver and operation")
        if any(r.get(t) is None for t in ("scheduledNS", "offeredNS", "writeStartNS", "writeReturnNS", "firstExactReadNS", "observationDeadlineNS")):
            issue("missing offer/write/public-visibility timestamp")
        else:
            if not r["scheduledNS"] <= r["offeredNS"] <= r["writeStartNS"] <= r["writeReturnNS"]:
                issue("invalid writer timestamp order")
            if not r["writeStartNS"] <= r["firstExactReadNS"] <= r["observationDeadlineNS"]:
                issue("public read outside operation observation window")
        if r.get("lateExactReadNS") is not None:
            issue("late public read cannot replace deadline success")
        if key[1] == "measured":
            offset = key[3] * p["cadenceNS"] + key[2] * p["staggerNS"] if key[0] == "hot" else key[3] * p["quietCadenceNS"]
            if epoch is None or r.get("scheduledNS") != epoch + offset or r.get("observationDeadlineNS") != deadline:
                issue("fixed offered schedule/deadline mismatch")
            groups[key[0]].append(r)
        elif epoch is None or any(r.get(field) is None or r[field] > epoch
                                  for field in ("writeReturnNS", "firstExactReadNS")):
            issue("warmup write and exact visibility must finish before measurement epoch")
        if clock == NATIVE_CLOCK:
            for field in ("armStatus", "probeStatus"):
                if type(r.get(field)) is not int or r[field] != 0:
                    issue("missing or failed native probe")
            for field in ("probeOperationID", "probeAttemptID", "probeOwnerID", "probeConnectionID", "probeThreadID", "ignoredOwnerCommits", "ignoredSchemaCommits"):
                if r.get(field) is None:
                    issue("missing native probe identity")
                else:
                    uint(r[field], field, field not in ("ignoredOwnerCommits", "ignoredSchemaCommits"))
            if r.get("probeOperationID") != token or r.get("probeAttemptID") != 1 or r.get("postcommitNS") is None or r.get("probeArmedNS") is None:
                issue("native probe does not identify operation/attempt")
            origin = r.get("postcommitNS")
            if origin is not None and r.get("writeStartNS") is not None and r.get("writeReturnNS") is not None:
                if not r["writeStartNS"] <= (r.get("probeArmedNS") or 0) <= origin <= r["writeReturnNS"]:
                    issue("native postcommit outside writer interval")
                if r.get("firstExactReadNS") is not None and r["firstExactReadNS"] < origin:
                    issue("negative postcommit interval requires investigation")
            owner = (r.get("probeOwnerID"), r.get("probeConnectionID"))
            writer = (key[0], key[2])
            if owner[0] is not None and owner[1] is not None:
                if writer in owner_for_writer and owner_for_writer[writer] != owner:
                    issue("physical writer identity changed")
                if owner[0] in writer_for_owner and writer_for_owner[owner[0]] != writer:
                    issue("different logical writers share physical owner")
                if owner[1] in writer_for_connection and writer_for_connection[owner[1]] != writer:
                    issue("different logical writers share SQLite connection")
                owner_for_writer[writer] = owner
                writer_for_owner[owner[0]] = writer; writer_for_connection[owner[1]] = writer
        elif any(r.get(field) is not None for field in PROBE_FIELDS):
            issue("native probe fields present without tagged native clock")
    if seen != expected:
        issue("missing logical operation receipts")
    headline = mode == "full" and clock == NATIVE_CLOCK and p == dict(FULL, writerCount=0 if profile == "quiet-only" else 8)
    streams = {}
    for stream, rows in groups.items():
        metrics = {}
        for name, field in (("scheduledToVisible", "scheduledNS"), ("writeStartToVisible", "writeStartNS"),
                            ("postcommitToVisible", "postcommitNS"), ("writeReturnToVisible", "writeReturnNS")):
            metrics[name] = distribution([(r["firstExactReadNS"] - r[field]) / 1e6 for r in rows
                                          if r.get("firstExactReadNS") is not None and r.get(field) is not None
                                          and (field != "postcommitNS" or clock == NATIVE_CLOCK)])
        metrics["offerLateness"] = distribution([(r["offeredNS"] - r["scheduledNS"]) / 1e6 for r in rows
                                                if r.get("offeredNS") is not None and r.get("scheduledNS") is not None])
        completed = [r for r in rows if r.get("firstExactReadNS") is not None and r.get("valueMatch") is True and not r["timedOut"] and r.get("writeError") is None and not r["valueMismatchCount"]]
        span = ((p["opsPerWriter"] * p["cadenceNS"] + (p["writerCount"] - 1) * p["staggerNS"])
                if stream == "hot" and p["writerCount"] else p["quietOps"] * p["quietCadenceNS"])
        end = max([epoch + span] + [r["firstExactReadNS"] for r in completed]) if epoch is not None else None
        duration = (end - epoch) / 1e9 if end is not None else None
        streams[stream] = {"expected": p["writerCount"] * p["opsPerWriter"] if stream == "hot" else p["quietOps"],
                           "receiptCount": len(rows), "completed": len(completed),
                           "offered": sum(r.get("offeredNS") is not None for r in rows),
                           "timedOut": sum(r["timedOut"] for r in rows), "metrics": metrics,
                           "throughputWindowSeconds": duration,
                           "completedOperationsPerSecond": len(completed) / duration if duration and rows else None}
    return {"runID": run_id, "mode": mode, "profile": profile, "clock": clock,
            "validCompleteRun": not issue_counts, "headlineProfile": headline,
            "eligibleForNumericalComparison": not issue_counts and headline,
            "expectedReceiptCount": len(expected), "receiptCount": len(records),
            "violations": violations, "issueCounts": issue_counts, "streams": streams,
            "counters": counters, "recordedErrors": errors, "metadata": data.get("metadata", {}),
            "effectiveParameters": p, "overhead": data.get("overhead", {}), "scope": DISCLAIMER,
            "quantileEstimator": "nearest rank per run; no pooled operations",
            "latencyPopulation": "all measured rows with the required timestamps, including failed rows; eligibility and exact completion counts are reported separately; postcommit metric requires tagged native clock",
            "throughputEstimator": "exact completed identities / max(offered schedule window, last successful public read minus measurement epoch)"}


def ratio_interval(values):
    rng = random.Random(0x51A7)
    boot = [statistics.median(rng.choices(values, k=len(values))) for _ in range(10_000)]
    return {"pairedRunRatios": values, "medianRatio": statistics.median(values),
            "bootstrapMedian95PercentInterval": [quantile(boot, .025), quantile(boot, .975)],
            "method": "10,000 paired-run resamples, deterministic seed; descriptive interval, not population guarantee"}


def compare(groups):
    if len(groups) < 5:
        raise ValueError("at least five matched A/A2/B groups required")
    failures, ids = [], set()
    declared_graphs = {}
    for index, group in enumerate(groups):
        if set(group) != {"A", "A2", "B"}:
            raise ValueError("each group must contain exactly A, A2, B")
        for label, run in group.items():
            if run["runID"] in ids:
                raise ValueError("run reused across matched groups")
            ids.add(run["runID"])
            if not run["eligibleForNumericalComparison"] or run["profile"] != "loaded":
                failures.append(f"group {index} {label}: incomplete/unqualified numerical profile")
            metadata = run["metadata"]
            for key in ("SDK_REVISION", "CORE_REVISION", "BUILD_ID", "HOST_ID", "RUN_GROUP", "RUN_ORDER", "LOGGING", "platform", "placement"):
                if not isinstance(metadata.get(key), str) or metadata[key] in ("", "unspecified"):
                    failures.append(f"group {index} {label}: missing declared {key}")
            for key in ("SDK_REVISION", "CORE_REVISION"):
                value = metadata.get(key, "")
                if len(value) != 40 or any(c not in "0123456789abcdef" for c in value):
                    failures.append(f"group {index} {label}: invalid declared {key}")
            graph = tuple(metadata.get(k) for k in ("SDK_REVISION", "CORE_REVISION", "BUILD_ID"))
            graph_label = "baseline" if label in ("A", "A2") else "candidate"
            if graph_label in declared_graphs and declared_graphs[graph_label] != graph:
                failures.append(f"group {index} {label}: declared source/build graph changed")
            declared_graphs[graph_label] = graph
        if any(group[x]["effectiveParameters"] != group["A"]["effectiveParameters"] for x in ("A2", "B")):
            failures.append(f"group {index}: workload parameters differ")
        for key in ("RUN_GROUP", "HOST_ID", "LOGGING", "platform", "placement"):
            if any(group[x]["metadata"].get(key) != group["A"]["metadata"].get(key) for x in ("A2", "B")):
                failures.append(f"group {index}: declared {key} differs")
        if len({group[x]["metadata"].get("RUN_ORDER") for x in ("A", "A2", "B")}) != 3:
            failures.append(f"group {index}: declared run order is duplicated")
    if failures:
        return {"eligible": False, "failures": failures, "numericalGatesPass": False, "scope": DISCLAIMER}
    output, passed = {}, True
    for baseline in ("A", "A2"):
        metrics = {}
        selectors = {
            "hotPostcommitP95": lambda r: r["streams"]["hot"]["metrics"]["postcommitToVisible"]["p95MS"],
            "quietPostcommitP95": lambda r: r["streams"]["quiet"]["metrics"]["postcommitToVisible"]["p95MS"],
            "quietThroughput": lambda r: r["streams"]["quiet"]["completedOperationsPerSecond"]}
        for name, select in selectors.items():
            denominators = [select(g[baseline]) for g in groups]
            numerators = [select(g["B"]) for g in groups]
            if any(v is None or not math.isfinite(v) or v <= 0 for v in denominators + numerators):
                return {"eligible": False, "failures": [f"nonpositive or missing {name}"], "numericalGatesPass": False, "scope": DISCLAIMER}
            values = [b / a for a, b in zip(denominators, numerators)]
            result = ratio_interval(values)
            # Every matched group must pass; the bootstrap interval is reported
            # alongside, never a way to hide a failing group inside a mean.
            result["pass"] = min(values) >= .9 if name == "quietThroughput" else max(values) <= (.5 if name == "hotPostcommitP95" else 1.1)
            passed &= result["pass"]
            metrics[name] = result
        output[baseline] = metrics
    return {"eligible": True, "groupCount": len(groups), "comparisons": output,
            "numericalGatesPass": bool(passed), "scope": DISCLAIMER,
            "externalQualificationAccepted": False, "releaseOrGoalAccepted": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("run", "compare")); parser.add_argument("input", type=Path)
    args = parser.parse_args()
    try:
        data, digest = read_json(args.input)
        if args.mode == "run":
            result = analyze(data); result["inputSHA256"] = digest
        else:
            groups = []
            for group in data["groups"]:
                analyzed = {}
                for label, relative in group.items():
                    raw, sha = read_json(args.input.parent / relative)
                    analyzed[label] = analyze(raw); analyzed[label]["inputSHA256"] = sha
                groups.append(analyzed)
            result = compare(groups); result["runs"] = groups; result["manifestSHA256"] = digest
        print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
        return 0 if result.get("validCompleteRun", result.get("numericalGatesPass", False)) else 1
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(json.dumps({"eligible": False, "error": str(error), "scope": DISCLAIMER}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
