# Lattice performance refinement benchmark contract v1

Status: source preparation only. No Swift compiler, discovery, test, or benchmark was invoked while preparing this contract. Native execution waits for the allocated build slot. A passing Python reporter self-check is not a native test result.

Implementation: `../lattice/Tests/LatticeTests/PerfRefinementBenchmarks.swift` and `../lattice/Scripts/perf_refinement_report.py`.

## Frozen inputs and behavior

Both workloads use a deterministic 10,000-row `PerfRefinementMemory` model. Rank is indexed. Rank identifies logical rows; each row also has a deterministic UUID `00000000-0000-4000-8000-XXXXXXXXXXXX`, with the last component equal to rank+1 in hexadecimal. Physical IDs are not used as cross-store identity.

| Displayed scalar | Exact seeded value for rank r |
| --- | --- |
| rank | r, from 0 through 9,999 |
| title | `memory-` followed by five zero-padded decimal digits |
| body | 256 identical ASCII bytes: a+(r mod 26) |
| accessCount | r mod 17 |
| lastAccessed | Date at Unix epoch seconds 1,700,000,000+r |
| pinned | r mod 3 equals 0 |

Local variant: all 10,000 rows in `main.sqlite`. Attached variant: even ranks in `main.sqlite`, odd ranks in `attached.sqlite`; both contain 5,000 rows and intentionally overlap physical primary keys. Query through `main.attaching(lattice: other)` so the result is a UNION ALL view. Expected logical results and checksums are identical between variants. No production user data is accessed.

Every iteration begins by copying the same closed, fully checkpointed master database(s) to a never-before-used path. A nonempty master WAL rejects the run. The copied file is independently checked before opening the measured Lattice handles. Fixture creation, copying, opening, validation, and cleanup are outside timing. The unique path gives fresh model registry and query shape identities, so repeated samples do not silently turn into cache hits. This does not flush the OS page cache: “cold” means a cold Lattice shape/model set, not cold storage hardware.

Model audit triggers and default generation tuning stay enabled. Page size is explicitly 100 in both baseline and candidate. The fixture installs no explicit observers or IPC/WSS transports, identically in all runs. The experiment measures synchronous foreground API time, including synchronous commit hooks; background delivery completion is outside scope. No candidate-only trigger suppression or synchronization bypass is permitted.

## Read100

Construct the same sorted live results shape, ordered by rank ascending. Do not call count, snapshot, or materialize before timing. Start with zero shape fills and anchors.

1. `read.cold_page_identity_anchor`: call `element(at:)` for indices 4,000 through 4,099 and hold the returned 100 model instances. This includes the offset-page query, identity/hydration, anchor extraction when supported, and foreground generation work.
2. `read.live_scalars`: read each of the six specified scalars once from those same live objects into value structs. No implicit row materialization is allowed. Date comparison keeps the exact Double epoch value, without integer truncation.
3. `read.total`: outer elapsed scope containing steps 1 and 2; nested instrumentation overhead is included. Do not sum this total with its children.
4. Separately report `read.warm_hit`: repeat the same 100 indexed lookups while retaining all original objects and the shape. Require the exact same object identities and no additional fill/anchor. `read.warm_live_scalars` reads the same six live fields again and must produce identical values. The reporter rejects SQL in `read.warm_hit` rather than treating an accidental refill as a warm sample.

All returned rows and all 600 scalar values are compared against independently constructed expectations outside timing. A stable FNV-1a checksum is recorded over length-delimited fields; it is a reproducibility check, not a security hash.

Page counters diagnose the backend mechanism, not the displayed-value contract. Both variants must perform exactly one cold offset fill and zero cold keyset fills. Local requires one cold anchor; attached permits zero or one. Attached physical IDs intentionally overlap, so `(sort, id)` is not a general total order across stores; a correct backend may disable that keyset mechanism and omit its anchor. The report retains each counter distribution so this difference remains visible. The subsequent warm lookup must add no fills or anchors and issue no SQL. These diagnostics do not relax any of the six live scalar reads or their value/identity checks.

## Update11

The same newly copied iteration fixture is then used for a complete checked write transaction on the measured query handle. The preceding read100 is part of the frozen precondition in every build. No updated rank overlaps the displayed 100-row window.

Fixed ascending rank set: `[7,100,333,999,1234,2345,3456,4567,5678,6789,9998]`.

- `update.total` includes BEGIN, ID discovery/hydration/attached routing, 11 timestamp sets, 11 SQL-side atomic increments, and COMMIT.
- `update.discovery_hydration_routing`: inside that transaction, query rank IN the fixed set, sorted ascending, using the current snapshot API. Exactly 11 rows must be returned.
- `update.set_and_atomic_increment`: set `lastAccessed` to Unix epoch seconds 1,800,000,000 and atomically increment `accessCount` once for each found row. The default implementation loops over the rows and calls `increment("accessCount")`; the explicitly opted-in candidate calls `bulkUpdate(selected, changes: [.set(...), .increment(..., by: 1)])` inside this same phase. Neither implementation uses Swift read-modify-write.

The baseline uses existing APIs. A later candidate must preserve the same transaction, lookup/routing inputs, result semantics, trigger behavior, and included work. Moving lookup outside the total or resetting fixtures in only one candidate is invalid. Any alternative narrower write-only microbenchmark needs a new contract and cannot replace the complete target.

The batch implementation is a candidate-only **compile** opt-in: `LATTICE_PERF_SELECTED_BATCH` is off for both baseline A/A builds and may be enabled for the candidate with the Swift compiler flag `-D LATTICE_PERF_SELECTED_BATCH` (for SwiftPM, `-Xswiftc -DLATTICE_PERF_SELECTED_BATCH` in the allocated build command). It is not an environment-variable toggle. All references to the new `bulkUpdate` API are inside this condition, so the same harness source remains compilable against old APIs with the condition absent. No immutable baseline source/build tree is modified to adopt this option.

Every manifest declares `writeImplementation` as exactly `legacy-row-set-and-increment-v1` or `selected-batch-set-and-increment-v1`. Missing and unknown labels are rejected; older unlabeled artifacts cannot be silently interpreted as legacy runs. A/A labels must match. The reporter permits equal implementations or the explicit legacy-baseline → selected-batch-candidate comparison, rejects the reverse change, and exposes all three labels plus `candidateSelectedBatchOptIn`, `candidateChangesWriteImplementation`, and `comparisonKind` under `writeImplementations`. The compile flag also belongs in the external build-identity receipt. This label declares an algorithm change while retaining the frozen Update11 semantics; it is not evidence that a candidate ran or improved performance.

Both implementations return a changed-row count checked as 11 after the existing total timer, and the independent SQLite verification checks the exact set of 11 unique changed ranks. Legacy's returned count is its selected-row count, so the independent postimage verification is authoritative for persisted changes. Candidate's returned count additionally checks the selected-batch API receipt. These assertions introduce no lookup, scalar read, reset, or validation SQL into the timed write scopes. Read100, all phase names, timestamp, increment amount, discovery placement, and enclosing transaction/commit remain unchanged.

After commit, independent read-only SQLite queries inspect every row in each physical store. They require all UUIDs and all six scalar values to match expectations, exactly the 11 intended count/date changes, and every other row unchanged. This also verifies attached routing despite overlapping physical IDs. Verification runs outside timing without warming Lattice shapes/models. The immutable master is retained as the before image; the first measured iteration's after image and sidecars are retained. Successful later copies are removed after handles close; a failing iteration remains for diagnosis.

## Sampling, accounting, and outputs

Default: five unreported warmups plus 100 measured iterations per variant. Overrides permit 5–100 warmups and 100–1,000 measured samples; fewer samples are rejected. Every sample records `DispatchTime` monotonic nanoseconds and `Lattice.threadSQLStatementCount` deltas for the same synchronous API scopes. The counter excludes other threads; it is not a whole-process SQL count. Nested scopes are nonadditive with their totals.

The reporter produces distributions for every phase: min, mean, median, nearest-rank p95/p99, maximum, sample count, and SQL statement distribution. Nearest-rank p95 is sorted index ceil(0.95*n)-1. No timing threshold is encoded in the suite or changed to make a candidate pass.

For comparison, run baseline A twice from identical source/Core/build identity, then candidate B on the exact same physical host under comparable idle conditions. Comparison requires matching `hostIdentity`, OS, CPU count, and active CPU count, along with the contract, sample policy, logical checksums, and A/A provenance. Matching CPU/OS facts alone do not identify a machine. It reports B/A and B/A2, the observed absolute A/A difference, and whether B improves on both baselines by more than that observed difference. This is descriptive noise context, not a confidence interval or statistical significance claim. Fresh fixture bytes can differ across A/A seeds due to internal audit metadata; the semantic checksums must agree. Preserved master files receive SHA256 hashes in the report.

No native baseline has yet been qualified. If the original baseline fails attached identity/routing or displayed-value invariants, retain the failing evidence and report that baseline as invalid; do not fabricate results or ignore the invariant. A later comparison can use an explicitly documented correctness-only baseline patch, with the original revision, exact patch/tree receipt, reason, and native correctness evidence recorded before both A/A runs. Performance changes must remain in the candidate. That comparison must be described as against the corrected baseline, not the untouched original revision.

Each run requires a new absolute directory below `~/localdev`, with an existing parent, and:

- `LATTICE_PERF_REFINEMENT=1`
- `LATTICE_PERF_RUN_DIR=<new allocated path>`
- `LATTICE_PERF_SOURCE_REVISION=<exact source/tree receipt>`
- `LATTICE_PERF_CORE_REVISION=<exact Core/tree receipt>`
- `LATTICE_PERF_BUILD_IDENTITY=<compiler/SDK/configuration/flags/lock receipt identity>`
- `LATTICE_PERF_HOST_ID=<stable allocated-run-owner receipt for this physical host>`

These provenance values are required nonempty owner-supplied labels. Build and physical-host identity must be externally verified by run receipts; equal `hostIdentity` labels are a comparison gate, not independent proof of the same machine. The benchmark does not infer these identities, and the reporter rejects missing/empty host identity and cross-run host-label mismatches even for identical hardware counts. The suite refuses a Debug build, a missing path, a path outside localdev, or an existing run directory. It does not invoke compiler/SDK commands. Its test is `PerfRefinementBenchmarks/releaseRead100AndUpdate11`; the run owner must use supported test-runner options rather than copy an older unrelated `--no-parallel` invocation.

Run artifacts: `manifest.json`; one `sample-NNNN.json` per completed iteration; immutable masters; first measured postimages; and `result.json` written only after every iteration and invariant completes. A partial directory without `complete:true` in `result.json` cannot produce a qualifying report.

Reporter examples after allocated native runs:

```text
python3 Scripts/perf_refinement_report.py --run <run>/result.json --output <localdev>/single-report.json
python3 Scripts/perf_refinement_report.py --baseline <A>/result.json --repeat <A2>/result.json --candidate <B>/result.json --output <localdev>/comparison.json
```

The reporter requires a new output path under localdev and refuses overwriting. Full-suite correctness, observer routing, WAL, external fresh-reader, cross-process notification, and live concurrency semantics remain separately qualified; these two benchmarks do not waive them.
