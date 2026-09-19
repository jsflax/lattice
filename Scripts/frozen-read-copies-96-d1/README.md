# Frozen Release benchmark source preparation: corrected A/A2 and SDK96/Core d1 B

This reuses the exact runtime packet accepted for hosted run35413106029 at qualification commit64ed90d51d0aca362b09288d1115c745abfeb948. Only candidate identities/manifests and path/label documentation change; the runner, guard, proof, reporter and pure test suite are byte-identical. No native command, dependency resolve, network request, dispatch or benchmark was run while preparing it. Runtime admission still requires explicit owner admission, root review and passing full exact-source SDK96a5bf02/Core d1e06f4b qualification.

The same hosted job builds both Release images before measuring A, A2 and B in that order. A and A2 use the same binary, historical SDKd18/Coref8, and only the already-qualified TableResults attached-identity correction. The unmodified original SDK and Core are retained separately. B uses exact SDK96a5bf02/Core d1e06f4b with no product/test overlays. Its committed benchmark is already the frozen SHA993d3a6f body. All 33 non-Core dependency pins match the historical baseline. B requires a source edit from its committed Core2.0.5 lock to the bound Core d1e06f4b source; this is development evidence, not a published consumer graph.

The baseline correction is precisely `baseline-product.patch` SHA2b4827d6; TableResults preimage f4e43207 and postimage9cd72274 are checked. It bypasses the ambiguous registry for attached physical stores while retaining the original per-row priming. Baseline measured source changes are exactly that one product file plus the new frozen benchmark file. No focused-test overlay, BaseTest logger change, new API, private prepared-statement cache or diagnostic-phase patch enters either measured arm. The original invalid attached run35352719982 and original expected-red run35394332578 remain negative evidence. Sealed prerequisites are focused corrected2/2 and the later four unchanged legacy cases in run35406715239.

The six live fields, 100 retained model objects, original observer lifetimes, 11 writes, checked transaction scopes, physical local/attached fixtures, result checksums, SQL counters, timers, sample count and independent SQLite afterimage validation are unchanged. Five warmups plus100 measured iterations per variant produce630 raw iterations across A/A2/B. The existing explicit B-only selected-batch compile flag is retained; A/A2 retain the legacy per-row write implementation. There is no diagnostic phase instrumentation beyond the existing frozen timing/counter scopes. The benchmark installs no extra observers or transports; that frozen fixture does not measure a remote sync/observer workload.

Unchanged runtime helpers: guard c31626b5, full-variant reporter aeb1d599, build_proof006 d527ba9d. Full source manifests bind201 pristine/202 effective baseline SDK files,870 baseline Core files,253 candidate SDK files and901 candidate Core files. The driver reuses the modern proof helper to join actual optimized native/Swift actions to objects, archives and the test binary, then rechecks source/binary/proof custody before measurements and final acceptance. It rejects private mechanism/cache compiler defines, signal-assisted cleanup, missing complete results and changed source. Root SwiftPM bookkeeping is the only ignored metadata subtree; nested committed `.swiftpm` paths are not hidden. Existing compiler-proof limits on temporary derived-child link lists remain explicit in its receipt.

No resource limit was relaxed: one job, `-j2`,5400s per build,1200s per measurement,18000s overall,600s finalization reserve,60s settling before each measurement,12GiB free floor,30GiB whole-packet ceiling,512MiB command-log ceiling and0.5s guard polling. Whole owned-process-group cleanup is inherited unchanged; the wrapper tightens acceptance to reject any cleanup signal/error. Build admission additionally requires the full original build timeout to remain. Runtime storage/cache/temp paths remain under the allocated localdev root. A resource/deadline failure preserves evidence and stops; no fallback or automatic retry is provided.

Hosted job/boot continuity and recorded load do not establish physical placement or an idle physical machine. `qualifiesFrozenPhysicalHostGate`, `physicalHostIdentityVerified` and `performanceTargetClaimed` remain false. The unchanged reporter exposes B/A, B/A2 and observed A/A difference. `TARGET-OBSERVATIONS.json` additionally evaluates the original2×p95 targets against both baselines, retains the existing noise comparison, and reports whether every candidate cold-page sample stays at most3 SQL statements. Negative results are successful experiments, not goal completion. No p95/noise/SQL target was weakened, and old measurements cannot be stitched into this allocation.

## Root admission and installation

1. Independently review `run-release-benchmark.py`/`binding.py`, source overlays, manifests, packet seal and the proposed workflow. Pure checks do not establish Swift compile/runtime compatibility.
2. Authenticate terminal passing exact SDK96a5bf02/Core d1e06f4b qualification, then author an admission JSON with this shape. Both accepted assessments must refer to actual saved parent audits; this receipt is root-owned evidence, not an independent runtime re-audit of CI:

```json
{
  "scope": "same-hosted-allocation-corrected-A-A2-B",
  "baselineLegacyAssessmentSHA256": "cc80bc991a9ad50f3b2f0ea55ae60cd723c819d3a400fd8cd3411778a3a289eb",
  "physicalHostQualified": false,
  "candidateQualification": {
    "sdk": {"commit": "96a5bf0256f81691a92d98cb8fe24b54e00de811", "tree": "466e724abeea3e01f0af8c5d7adde729628e4115", "accepted": true, "run": 0, "assessmentSHA256": "REPLACE_WITH_ACTUAL_ACCEPTED_ASSESSMENT"},
    "core": {"commit": "d1e06f4b74ffc76410a9e59f062117c160e191b6", "tree": "5280333ecc94b8e7339010c9c8e70a30019f86b9", "accepted": true, "run": 0, "assessmentSHA256": "REPLACE_WITH_ACTUAL_ACCEPTED_ASSESSMENT"}
  }
}
```

No accepted CI receipt is supplied by this preparation. The example intentionally fails admission until actual run IDs/hashes replace placeholders. Hash the exact UTF-8 JSON bytes. The workflow adds no newline and passes data through environment/Python, never shell interpolation. Runtime checks source pins, root receipt hash and accepted-gate bindings before launching any guarded command.

3. Install this packet at `Scripts/frozen-read-copies-96-d1/` and the sibling proposed workflow at `.github/workflows/release-benchmark.yml` in a reviewed qualification commit. The workflow is manual-only, so installing/pushing cannot start it. Freeze that exact workflow commit and dispatch one job with the packet-seal hash plus root admission JSON/hash. Do not retarget this packet to a new candidate.
4. Require normal guard-clean build/runtime completion, both physical variants in each complete result, all630 raw iterations, complete source/pin/compiler/binary joins, all retained masters/first measured postimages, exact host/boot continuity and an independent terminal artifact audit. The driver preserves raw failures and makes no release or platform qualification claim.

Command shape (the workflow supplies absolute owned paths):

```text
python3 -B run-release-benchmark.py --root OWNED_LOCALDEV_ROOT --candidate-sdk-sha 96a5bf0256f81691a92d98cb8fe24b54e00de811 --seal-sha256 REVIEWED_PACKET_SEAL --admission-json ROOT_ADMISSION_JSON_PATH --admission-sha256 ROOT_ADMISSION_BYTES_SHA256
```

This packet adds no measurements and does not inherit predecessor latency or SQL results. The exact candidate CI and owner admission are still pending; the existing root admission JSON contract remains unchanged. The registered workflow path is `.github/workflows/release-benchmark.yml` (workflow361313463), as actually used by accepted run35413106029. Qualification installation, commit identity and any one manual dispatch remain separate authorized steps.

Successor lineage: this preparation is the minimal SDK96/Core d1 successor of frozen-read-copies-bf-d1-001 (source seal0d99e299). SDK96 is the direct child of SDKbf and changes only the external-lock test fixture EOF reader detachment; every product source and the frozen benchmark body is identical. The exact Core d1 manifest and every dependency-pin value remain unchanged. The held hosted SDK qualification is run35428388263; terminal acceptance and its parent assessment hash are REQUIRED and UNBOUND. Its status is not asserted by this offline preparation. The existing Core d1 accepted evidence must be reauthenticated and bound by the root admission receipt; Coreeee is not this candidate. No root admission receipt or qualification commit is fabricated here.
