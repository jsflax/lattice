"""Synthetic analyzer tests. These are not Lattice runtime/performance evidence."""
import copy
import json
import unittest

import evaluate_sync as e


def fixture(run_id="run", native=True, full=False, quiet_only=False):
    parameters = dict(e.FULL) if full else dict(e.FULL, writerCount=2, opsPerWriter=3, warmupPerWriter=1,
                                              quietOps=1, drainNS=20_000_000_000, driverWorkers=2)
    if quiet_only:
        parameters["writerCount"] = 0
    rows = []
    epoch = 2_000_000_000
    hot_last = ((parameters["opsPerWriter"] - 1) * parameters["cadenceNS"]
                + (parameters["writerCount"] - 1) * parameters["staggerNS"] if parameters["writerCount"] else 0)
    quiet_last = (parameters["quietOps"] - 1) * parameters["quietCadenceNS"]
    deadline = epoch + max(hot_last, quiet_last) + parameters["drainNS"]
    for stream in ("hot", "quiet"):
        for phase in ("warmup", "measured"):
            for writer in range(parameters["writerCount"] if stream == "hot" else 1):
                count = (parameters["warmupPerWriter" if phase == "warmup" else "opsPerWriter"] if stream == "hot"
                         else parameters["quietWarmupOps" if phase == "warmup" else "quietOps"])
                for sequence in range(count):
                    token = len(rows) + 1
                    scheduled = (epoch + sequence * parameters["cadenceNS"] + writer * parameters["staggerNS"] if stream == "hot"
                                 else epoch + sequence * parameters["quietCadenceNS"]) if phase == "measured" else 10_000_000
                    origin = scheduled + 1_000_000
                    rows.append(dict(id=f"{run_id}/{stream}/{phase}/{writer}/{sequence}", token=token, runID=run_id,
                        stream=stream, phase=phase, writer=writer, sequence=sequence,
                        writerStoreID=f"clients/{stream}-writer-{writer}.sqlite", scheduledNS=scheduled,
                        readerStoreID=f"clients/{stream}-watcher.sqlite", observedID=f"{run_id}/{stream}/{phase}/{writer}/{sequence}",
                        offeredNS=scheduled, writeStartNS=scheduled, writeReturnNS=origin + 10_000_000,
                        probeArmedNS=origin - 500_000 if native else None,
                        postcommitNS=origin if native else None, firstExactReadNS=origin + 5_000_000,
                        observationDeadlineNS=deadline if phase == "measured" else epoch - 1,
                        armStatus=0, probeStatus=0, probeOperationID=token, probeAttemptID=1,
                        probeOwnerID=writer + (100 if stream == "quiet" else 1),
                        probeConnectionID=writer + (100 if stream == "quiet" else 1), probeThreadID=7,
                        ignoredOwnerCommits=0, ignoredSchemaCommits=0, valueMatch=True,
                        valueMismatchCount=0, duplicateCallbacks=0, timedOut=False))
    if not native:
        for row in rows:
            for field in e.PROBE_FIELDS:
                row.pop(field, None)
    return dict(schema=e.SCHEMA, runID=run_id, mode="full" if full else "smoke", profile="quiet-only" if quiet_only else "loaded",
                clock=e.NATIVE_CLOCK if native else "dispatch-uptime/no-probe", complete=True,
                effectiveParameters=parameters, startedNS=1, measurementEpochNS=epoch,
                deadlineNS=deadline, finishedNS=epoch+max(hot_last, quiet_last)+2_000_000_000, errors=[],
                counters=dict.fromkeys(e.COUNTERS, 0), receipts=rows, metadata={})


class AnalyzerTests(unittest.TestCase):
    def test_smoke_never_qualifies_headline_but_signed_return_survives(self):
        result = e.analyze(fixture())
        self.assertTrue(result["validCompleteRun"])
        self.assertFalse(result["eligibleForNumericalComparison"])
        latency = result["streams"]["hot"]["metrics"]
        self.assertEqual(latency["postcommitToVisible"]["p95MS"], 5)
        self.assertEqual(latency["writeReturnToVisible"]["p95MS"], -5)
        self.assertEqual(latency["writeReturnToVisible"]["negativeCount"], 6)

    def test_callback_duplicate_is_not_an_extra_operation(self):
        d = fixture(); d["receipts"][0]["duplicateCallbacks"] = 9
        d["counters"]["duplicateCallbacks"] = 9
        r = e.analyze(d)
        self.assertTrue(r["validCompleteRun"])
        self.assertEqual(r["streams"]["hot"]["completed"], 6)

    def test_duplicate_operation_and_token_are_rejected(self):
        d = fixture(); d["receipts"].append(copy.deepcopy(d["receipts"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            e.analyze(d)
        d = fixture(); d["receipts"][1]["token"] = d["receipts"][0]["token"]
        with self.assertRaisesRegex(ValueError, "duplicate"):
            e.analyze(d)

    def test_missing_operation_cannot_reduce_denominator(self):
        d = fixture(); d["receipts"].pop()
        r = e.analyze(d)
        self.assertFalse(r["validCompleteRun"])
        self.assertEqual(r["expectedReceiptCount"], 10)
        self.assertIn("missing logical operation receipts", r["violations"])

    def test_negative_origin_is_retained_and_fails_qualification(self):
        d = fixture(); row = next(r for r in d["receipts"] if r["phase"] == "measured")
        row["firstExactReadNS"] = row["postcommitNS"] - 1
        result = e.analyze(d)
        self.assertFalse(result["validCompleteRun"])
        self.assertEqual(result["streams"]["hot"]["metrics"]["postcommitToVisible"]["negativeCount"], 1)

    def test_late_value_never_replaces_timed_out_sample(self):
        d = fixture(); row = d["receipts"][-1]
        row["lateExactReadNS"] = row.pop("firstExactReadNS"); row["timedOut"] = True
        r = e.analyze(d)
        self.assertFalse(r["validCompleteRun"])
        self.assertEqual(r["streams"]["quiet"]["completed"], 0)
        self.assertEqual(r["streams"]["quiet"]["metrics"]["postcommitToVisible"]["count"], 0)

    def test_bool_cannot_masquerade_as_integer_timestamp(self):
        d = fixture(); d["receipts"][0]["scheduledNS"] = True
        with self.assertRaises(ValueError): e.analyze(d)

    def test_fixed_schedule_and_origin_identity_are_checked(self):
        d = fixture(); d["receipts"][-1]["scheduledNS"] += 1
        d["receipts"][0]["probeOperationID"] += 1
        r = e.analyze(d)
        self.assertIn("fixed offered schedule/deadline mismatch", r["violations"])
        self.assertIn("native probe does not identify operation/attempt", r["violations"])

    def test_error_and_overflow_invalidate_even_with_all_reads(self):
        for field in ("unknownOperation", "valueMismatch", "diagnosticOverflow", "malformedObservation", "rawSyncErrors"):
            d = fixture(); d["counters"][field] = 1
            self.assertFalse(e.analyze(d)["validCompleteRun"])

    def test_wrong_replica_cannot_complete_operation(self):
        d = fixture(); d["receipts"][0]["readerStoreID"] = "clients/quiet-watcher.sqlite"
        self.assertFalse(e.analyze(d)["validCompleteRun"])

    def test_no_probe_never_yields_commit_metric(self):
        r = e.analyze(fixture(native=False))
        self.assertTrue(r["validCompleteRun"])
        self.assertEqual(r["streams"]["hot"]["metrics"]["postcommitToVisible"]["count"], 0)

    def test_unexpected_no_probe_origin_is_not_a_commit_sample(self):
        d = fixture(native=False)
        for row in d["receipts"]:
            row["postcommitNS"] = row["writeStartNS"] + 1
        r = e.analyze(d)
        self.assertFalse(r["validCompleteRun"])
        self.assertIsNone(r["streams"]["hot"]["metrics"]["postcommitToVisible"]["p95MS"])
        self.assertEqual(r["streams"]["hot"]["metrics"]["postcommitToVisible"]["count"], 0)
        self.assertEqual(r["streams"]["hot"]["completed"], 6)

    def test_drain_is_exact_for_smoke_full_and_quiet_profiles(self):
        for full in (False, True):
            for quiet_only in (False, True):
                for shift in (-1, 1_000_000_000_000):
                    with self.subTest(full=full, quiet_only=quiet_only, shift=shift):
                        d = fixture(full=full, quiet_only=quiet_only)
                        self.assertTrue(e.analyze(d)["validCompleteRun"])
                        d["deadlineNS"] += shift
                        for row in d["receipts"]:
                            if row["phase"] == "measured":
                                row["observationDeadlineNS"] = d["deadlineNS"]
                        r = e.analyze(d)
                        self.assertFalse(r["eligibleForNumericalComparison"])
                        self.assertIn("measured deadline differs from last scheduled offer plus fixed drain", r["violations"])

    def test_warmup_write_and_visibility_precede_measurement(self):
        for field in ("writeReturnNS", "firstExactReadNS"):
            d = fixture(); row = d["receipts"][0]
            row[field] = d["measurementEpochNS"] + 1
            row["observationDeadlineNS"] = d["deadlineNS"]
            r = e.analyze(d)
            self.assertIn("warmup write and exact visibility must finish before measurement epoch", r["violations"])
            self.assertEqual(r["streams"]["hot"]["receiptCount"], 6)

    def test_each_owner_and_connection_is_distinct_across_writers(self):
        for field, message in (("probeOwnerID", "different logical writers share physical owner"),
                               ("probeConnectionID", "different logical writers share SQLite connection")):
            d = fixture()
            for row in d["receipts"]:
                row[field] = 1
            r = e.analyze(d)
            self.assertFalse(r["validCompleteRun"])
            self.assertIn(message, r["violations"])

    def test_arm_is_required_and_precedes_commit(self):
        for invalid in (None, 2_000_000_000):
            d = fixture(); row = d["receipts"][0]
            row["probeArmedNS"] = invalid
            self.assertFalse(e.analyze(d)["validCompleteRun"])

    def test_structural_fields_reject_bad_types_and_out_of_bounds_ids(self):
        for key, invalid in (("effectiveParameters", []), ("counters", []), ("metadata", []),
                             ("measurementEpochNS", True), ("measurementEpochNS", -1),
                             ("measurementEpochNS", 2**64)):
            d = fixture(); d[key] = invalid
            with self.assertRaises(ValueError): e.analyze(d)
        for key, invalid in (("stream", []), ("phase", {}), ("writer", -1), ("sequence", 2**64), ("writer", 3)):
            d = fixture(); d["receipts"][0][key] = invalid
            with self.assertRaises(ValueError): e.analyze(d)

    def test_failed_samples_are_retained_without_completing_operations(self):
        d = fixture()
        for row in d["receipts"]:
            if row["phase"] == "measured" and row["stream"] == "hot":
                row["valueMatch"] = False
        r = e.analyze(d)
        self.assertFalse(r["validCompleteRun"])
        self.assertEqual(r["streams"]["hot"]["completed"], 0)
        self.assertEqual(r["streams"]["hot"]["metrics"]["postcommitToVisible"]["count"], 6)
        self.assertEqual(r["streams"]["hot"]["expected"], 6)

    def test_throughput_window_includes_schedule_and_late_completion(self):
        d = fixture()
        self.assertEqual(e.analyze(d)["streams"]["quiet"]["completedOperationsPerSecond"], 1)
        row = next(r for r in d["receipts"] if r["stream"] == "quiet" and r["phase"] == "measured")
        row["firstExactReadNS"] = d["measurementEpochNS"] + 1_500_000_000
        r = e.analyze(d)
        self.assertTrue(r["validCompleteRun"])
        self.assertEqual(r["streams"]["quiet"]["throughputWindowSeconds"], 1.5)
        self.assertAlmostEqual(r["streams"]["quiet"]["completedOperationsPerSecond"], 2/3)

    def test_json_duplicate_fields_rejected(self):
        with self.assertRaises(ValueError):
            json.loads('{"x":1,"x":2}', object_pairs_hook=e.unique_object)

    def test_nearest_rank_is_not_interpolated(self):
        self.assertEqual(e.quantile(list(range(1, 101)), .95), 95)
        self.assertEqual(e.quantile([-2, -1], .5), -2)

    def groups(self):
        groups = []
        for i in range(5):
            group = {}
            for j, label in enumerate(("A", "A2", "B")):
                r = e.analyze(fixture(f"{i}-{label}"))
                # Deliberately synthetic analyzed summaries for ratio arithmetic;
                # no small fixture is presented as an actual full-profile run.
                r["eligibleForNumericalComparison"] = True
                r["metadata"] = dict(SDK_REVISION=("b" if label == "B" else "a")*40,
                    CORE_REVISION="c"*40, BUILD_ID="synthetic-debug", HOST_ID="test",
                    RUN_GROUP=str(i), RUN_ORDER=str(j), LOGGING="off", platform="synthetic", placement="synthetic")
                r["streams"]["hot"]["metrics"]["postcommitToVisible"]["p95MS"] = 2 if label == "B" else 5
                group[label] = r
            groups.append(group)
        return groups

    def test_matched_gates_and_no_goal_claim(self):
        r = e.compare(self.groups())
        self.assertTrue(r["numericalGatesPass"])
        self.assertFalse(r["releaseOrGoalAccepted"])
        self.assertEqual(r["comparisons"]["A"]["hotPostcommitP95"]["bootstrapMedian95PercentInterval"], [.4, .4])

    def test_one_failed_group_cannot_hide_in_mean(self):
        groups = self.groups()
        groups[2]["B"]["streams"]["quiet"]["metrics"]["postcommitToVisible"]["p95MS"] = 7
        self.assertFalse(e.compare(groups)["numericalGatesPass"])

    def test_missing_full_run_or_reused_run_invalidates_comparison(self):
        groups = self.groups(); groups[2]["B"]["eligibleForNumericalComparison"] = False
        self.assertFalse(e.compare(groups)["eligible"])
        groups = self.groups(); groups[2]["B"]["runID"] = groups[0]["A"]["runID"]
        with self.assertRaises(ValueError): e.compare(groups)
        with self.assertRaises(ValueError): e.compare(groups[:4])

    def test_graph_drift_and_missing_declared_metadata_fail(self):
        groups = self.groups(); groups[1]["A2"]["metadata"]["CORE_REVISION"] = "d"*40
        self.assertFalse(e.compare(groups)["eligible"])
        groups = self.groups(); del groups[0]["B"]["metadata"]["LOGGING"]
        self.assertFalse(e.compare(groups)["eligible"])

    def test_full_synthetic_groups_qualify_without_overriding_eligibility(self):
        groups = []
        for i in range(5):
            group = {}
            for j, label in enumerate(("A", "A2", "B")):
                d = fixture(f"full-{i}-{label}", full=True)
                d["metadata"] = dict(SDK_REVISION=("b" if label == "B" else "a")*40,
                    CORE_REVISION="c"*40, BUILD_ID="synthetic-debug", HOST_ID="test",
                    RUN_GROUP=str(i), RUN_ORDER=str((j+i)%3), LOGGING="off", platform="synthetic", placement="synthetic")
                if label == "B":
                    for row in d["receipts"]:
                        if row["stream"] == "hot":
                            row["firstExactReadNS"] = row["postcommitNS"] + 2_000_000
                group[label] = e.analyze(d)
                self.assertTrue(group[label]["eligibleForNumericalComparison"])
                self.assertEqual(group[label]["expectedReceiptCount"], 8201)
                self.assertEqual(group[label]["streams"]["quiet"]["completedOperationsPerSecond"], 1)
            groups.append(group)
        result = e.compare(groups)
        self.assertTrue(result["numericalGatesPass"])
        self.assertFalse(result["releaseOrGoalAccepted"])
        self.assertEqual(result["comparisons"]["A"]["hotPostcommitP95"]["pairedRunRatios"], [.4]*5)
        groups[0]["B"]["metadata"]["HOST_ID"] = "different-host"
        self.assertFalse(e.compare(groups)["eligible"])


if __name__ == "__main__": unittest.main()
