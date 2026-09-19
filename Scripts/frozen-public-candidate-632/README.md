# Executable source preparation: corrected A/A2 and public candidate B

This is a narrow successor of `Scripts/remote-benchmark/run-release-benchmark.py`, not a new process supervisor. No native command, dependency resolve, network request, dispatch or benchmark was run while preparing it. Runtime admission still requires root review and passing exact-source SDK632/Core4b qualification.

The same hosted job builds both Release images before measuring A, A2 and B in that order. A and A2 use the same binary, historical SDKd18/Coref8, and only the already-qualified TableResults attached-identity correction. The unmodified original SDK and Core are retained separately. B uses exact SDK632e3a4/Core4b0a292 with no product/test overlays. Its committed benchmark is already the frozen SHA993d3a6f body. All 33 non-Core dependency pins match the historical baseline. B requires a source edit from its committed Core2.0.3 lock to the bound Core4b source; this is development evidence, not a published consumer graph.

The baseline correction is precisely `baseline-product.patch` SHA2b4827d6; TableResults preimage f4e43207 and postimage9cd72274 are checked. It bypasses the ambiguous registry for attached physical stores while retaining the original per-row priming. Baseline measured source changes are exactly that one product file plus the new frozen benchmark file. No focused-test overlay, BaseTest logger change, new API, private prepared-statement cache or diagnostic-phase patch enters either measured arm. The original invalid attached run35352719982 and original expected-red run35394332578 remain negative evidence. Sealed prerequisites are focused corrected2/2 and the later four unchanged legacy cases in run35406715239.

The six live fields, 100 retained model objects, original observer lifetimes, 11 writes, checked transaction scopes, physical local/attached fixtures, result checksums, SQL counters, timers, sample count and independent SQLite afterimage validation are unchanged. Five warmups plus100 measured iterations per variant produce630 raw iterations across A/A2/B. The existing explicit B-only selected-batch compile flag is retained; A/A2 retain the legacy per-row write implementation. There is no diagnostic phase instrumentation beyond the existing frozen timing/counter scopes. The benchmark installs no extra observers or transports; that frozen fixture does not measure a remote sync/observer workload.

Unchanged runtime helpers: guard c31626b5, full-variant reporter aeb1d599, build_proof006 d527ba9d. Full source manifests bind201 pristine/202 effective baseline SDK files,870 baseline Core files,253 candidate SDK files and901 candidate Core files. The driver reuses the modern proof helper to join actual optimized native/Swift actions to objects, archives and the test binary, then rechecks source/binary/proof custody before measurements and final acceptance. It rejects private mechanism/cache compiler defines, signal-assisted cleanup, missing complete results and changed source. Root SwiftPM bookkeeping is the only ignored metadata subtree; nested committed `.swiftpm` paths are not hidden. Existing compiler-proof limits on temporary derived-child link lists remain explicit in its receipt.

No resource limit was relaxed: one job, `-j2`,5400s per build,1200s per measurement,18000s overall,600s finalization reserve,60s settling before each measurement,12GiB free floor,30GiB whole-packet ceiling,512MiB command-log ceiling and0.5s guard polling. Whole owned-process-group cleanup is inherited unchanged; the wrapper tightens acceptance to reject any cleanup signal/error. Build admission additionally requires the full original build timeout to remain. Runtime storage/cache/temp paths remain under the allocated localdev root. A resource/deadline failure preserves evidence and stops; no fallback or automatic retry is provided.

Hosted job/boot continuity and recorded load do not establish physical placement or an idle physical machine. `qualifiesFrozenPhysicalHostGate`, `physicalHostIdentityVerified` and `performanceTargetClaimed` remain false. The unchanged reporter exposes B/A, B/A2 and observed A/A difference. `TARGET-OBSERVATIONS.json` additionally evaluates the original2×p95 targets against both baselines, retains the existing noise comparison, and reports whether every candidate cold-page sample stays at most3 SQL statements. Negative results are successful experiments, not goal completion. No p95/noise/SQL target was weakened, and old measurements cannot be stitched into this allocation.

## Root admission and installation

1. Independently review `run-release-benchmark.py`/`binding.py`, source overlays, manifests, packet seal and the proposed workflow. Pure checks do not establish Swift compile/runtime compatibility.
2. Authenticate terminal passing exact SDK632/Core4b qualification, then author an admission JSON with this shape. Both accepted assessments must refer to actual saved parent audits; this receipt is root-owned evidence, not an independent runtime re-audit of CI:

```json
{
  "scope": "same-hosted-allocation-corrected-A-A2-B",
  "baselineLegacyAssessmentSHA256": "cc80bc991a9ad50f3b2f0ea55ae60cd723c819d3a400fd8cd3411778a3a289eb",
  "physicalHostQualified": false,
  "candidateQualification": {
    "sdk": {"commit": "632e3a4feccf45e7f4f0ba095a108a01a8effa2b", "tree": "645e2be1920dc5b4c1096fe1512dfe1891dc558c", "accepted": true, "run": 0, "assessmentSHA256": "REPLACE_WITH_ACTUAL_ACCEPTED_ASSESSMENT"},
    "core": {"commit": "4b0a292196047fc1ed0d9b6d961b2c0d22594c59", "tree": "4cfdb665ee3da6cc36cb3f3a64cb33af8718259e", "accepted": true, "run": 0, "assessmentSHA256": "REPLACE_WITH_ACTUAL_ACCEPTED_ASSESSMENT"}
  }
}
```

The example intentionally fails admission until actual run IDs/hashes replace placeholders. Hash the exact UTF-8 JSON bytes. The workflow adds no newline and passes data through environment/Python, never shell interpolation. Runtime checks source pins, root receipt hash and accepted-gate bindings before launching any guarded command.

3. Install this packet at `Scripts/frozen-public-candidate-632/` and the sibling proposed workflow at `.github/workflows/release-benchmark-public-candidate.yml` in a reviewed qualification commit. The workflow is manual-only, so installing/pushing cannot start it. Freeze that exact workflow commit and dispatch one job with the packet-seal hash plus root admission JSON/hash. Do not retarget this packet to a new candidate.
4. Require normal guard-clean build/runtime completion, both physical variants in each complete result, all630 raw iterations, complete source/pin/compiler/binary joins, all retained masters/first measured postimages, exact host/boot continuity and an independent terminal artifact audit. The driver preserves raw failures and makes no release or platform qualification claim.

Command shape (the workflow supplies absolute owned paths):

```text
python3 -B run-release-benchmark.py --root OWNED_LOCALDEV_ROOT --candidate-sdk-sha 632e3a4feccf45e7f4f0ba095a108a01a8effa2b --seal-sha256 REVIEWED_PACKET_SEAL --admission-json ROOT_ADMISSION_JSON_PATH --admission-sha256 ROOT_ADMISSION_BYTES_SHA256
```
