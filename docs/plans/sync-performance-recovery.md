# Sync performance and automatic recovery handoff

Recorded November 1, 2026. The work is **archived and incomplete** at checkpoint 301, where the user paused it on October 24. The user subsequently cleared the chat's goal on November 1 to begin separate background-sync planning; clearing it did not complete or resume the work. This is its plan and resumption point, not a claim that the unfinished candidate is on main. Earlier subjective completion percentages were withdrawn because they had no measured denominator.

The separate [iOS background sync plan](ios-background-sync.md) can proceed independently. Reconcile any shared fixes with current SDK/Core main before reusing the older recovery candidate.

## Goal and acceptance criteria

Make Lattice reliable and efficient for concurrent agent workloads, including automatic recovery from interrupted or stale synchronization.

- On the frozen eight-writer benchmark, reduce p95 local-commit-to-peer-observation latency to at most **0.5 times baseline**. Keep quiet-client latency at or below **1.1 times baseline** and throughput at or above **0.9 times baseline**.
- Preserve all **8,201 offered operations** in the matched A/A2/B benchmark and prove bounded admission, queues, storage growth, and object lifetimes.
- Prove correct ACK, replay, conflict, reconnect, and close behavior; complete automatic recovery, including the installed-store upgrade path.
- Pass affected-platform qualification, publish the qualified changes, and verify actual Engram and Orbital adoption.

Source review, successful compilation, selected tests, and notification receipts each establish only their own scope. None substitutes for the complete acceptance criteria.

## Decisions that carry forward

When an old local edit conflicts with the server and its previous sync status cannot be proved, use the server value while preserving the local edit for resolution. The initial managed recovery upgrade may perform a one-time coordinated restart of every app/service using the store, so old writers can be retired safely.

Release coordination is with Engram and Orbital. The user revoked **all direct and indirect contact with shock trooper**, including relays through Engram. This supersedes the original goal wording. Do not wake the separately human-paused parent task.

## Shipped and verified

This effort produced incremental releases even though the full goal remains unfinished:

- Core **2.2.4** fixed cold vector-index initialization so first vector reads include synced rows without reopening the store. The workstream recorded passing Core macOS, Linux, and C ABI qualification. See [Core PR 57](https://github.com/jsflax/LatticeCore/pull/57).
- The latest release fully verified by this workstream was [Swift SDK **2.2.5**](https://github.com/jsflax/lattice/releases/tag/2.2.5), published October 23, 2026, requiring Core **2.2.8** through [SDK PR 24](https://github.com/jsflax/lattice/pull/24). This carried the Core vector contention/readiness fixes and malformed-sync validation into the SDK dependency floor and resolved package lock.
- Required release checks were verified: macOS recorded 726 passes and 14 existing skips, plus two XCTest cases; stable/nightly Linux each recorded 714 passes and five existing skips, plus two XCTest cases. iOS qualification was a simulator build, **not physical-device background execution**.

The first macOS release attempt hit its original 30-minute timeout. One retry with unchanged source, tag, and limits passed; the timeout's cause remains unresolved. [Release run 40022303458](https://github.com/jsflax/lattice/actions/runs/40022303458) retains those attempts. Engram and Orbital release notices were accepted, but their complete adoption was not verified by this goal.

These versions describe this workstream's historical evidence, not today's newest releases. The SDK main inspected for the new plan is already later than this release.

## State at the pause

The latest frozen recovery composition contains 2,021 source files and reviewed work on query outcomes, deferred query cleanup, physical-return/lifetime accounting, final work-count observation, and admission/read controls. Its final incremental repair adds the existing export helper as a private friend of the query-ending implementation. That file compiled successfully; the complete composition is **not runtime-qualified**.

| Gate | State at checkpoint 301 |
| --- | --- |
| Complete build and inventory | Build 003 was cancelled for the user pause. Planned: 228 compiles, 77 verified reused objects, four new archives, 3,468 expected tests. No complete-build acceptance. |
| Focused runtime checks | Separate 225-case and 131-case cohorts prepared; not executed against an accepted final build. |
| Installed-store query cleanup diagnostic | Separate 2,022-file source bundle and CI controls prepared. Final bindings/review pending; unpublished and undispatched. |
| Full automatic recovery and resource bounds | Unfinished, including installed-store, crash, corruption, reader, old-writer upgrade, and disk-growth controls. |
| Frozen performance comparison | Target not demonstrated. |
| Final recovery release and adoption | Not completed. Earlier incremental releases remain valid within their tested scope. |

On pause, the build supervisor sent SIGTERM and reaped the compiler leader. Its process-group query returned EPERM, so the retained result reports an unproved group ending. A later process inventory showed no matching owned processes. Preserve both observations; do not rewrite the result as a clean success. Source, receipts, and partial objects remain intact, but cancellation did not qualify those objects for reuse.

Prior failures remain relevant. The last recorded complete ordinary Core run had **3,295 passes, 103 failures, and 10 skips out of 3,408**, and missed its owner-time gate. A later focused diagnostic compiled, linked, and matched a 3,426-test inventory, then exceeded its 600-second runtime cap: printed observations showed 95 starts, 81 passes, 13 failures, and one interrupted case. It produced no final XML and did not issue the cache cohort. These are different candidates and populations; do not combine them into a pass rate or claim they describe current main.

## Remaining execution plan

Resume this workstream only after explicit user instruction.

1. Reconcile the cancelled build's ending and verify any proposed partial-object reuse. Compare the frozen candidate with newer released/main changes before selecting a successor; preserve original failures and immutable inputs.
2. Complete a coherent build and exact test inventory, then run the prepared focused and cache cohorts independently. Diagnose actual failures without dropping cases or extending limits to manufacture a pass.
3. Finish deferred query/outcome/physical-return and cross-thread cleanup qualification. Prove count and charged-byte lifetimes, including cancellation and pending delivery.
4. Complete installed-store recovery and the managed restart. Preserve the existing eleven installed qualification batches, actual image/store identity checks, and normal full-build prerequisite. Bind and review the prepared diagnostic before CI publication.
5. Resolve the full correctness suite, replay/ACK/conflict and reconnect/close controls, crash/reader/corruption cases, and bounded resource behavior. Qualify the affected platforms.
6. Run the frozen matched performance comparison and report measured numbers against the original thresholds.
7. Release the qualified result, notify Engram and Orbital, and verify their dependency adoption. Accepted messages alone do not close that gate.

## Evidence and local resumption paths

[The compact evidence manifest](evidence/sync-recovery-pause/manifest.json) records hashes and the exact pause/build receipts included here. Historical fields in those receipts retain their original values; checkpoint 301 and this handoff supersede checkpoint 300's live-session instructions.

The full local archive remains at `/Users/jason/localdev/lattice-sync-perf-stability-20260919/`. It contains the complete historical `PLAN.md`, `recovery-resume-20261022-001/STATE.json`, all sources, failures, logs, and review receipts. The manifest fingerprints those original plan/state files; this repository handoff does not copy the multi-megabyte running diary or build artifacts.

| Item | Directory relative to the local archive |
| --- | --- |
| Authoritative state | `recovery-resume-20261022-001/STATE.json` |
| Frozen recovery source | `recovery-query-fulltail-composition-20261024-003/` |
| Cancelled build plan and result | `recovery-query-full-object-build-20261024-003/` |
| Prepared runtime recipe | `recovery-query-runtime-cohorts-source-20261024-002/` |
| Separate installed diagnostic source | `recovery-query-source1-hosted-composition-20261024-001/` |
| Diagnostic controls and isolated checkout | `recovery-query-source1-hosted-controls-source-20261024-001/` and `recovery-query-source1-hosted-checkout-20261024-001/` |
| Verified SDK 2.2.5 release evidence | `sdk-core-228-coherence-release-20261023-001/` |
