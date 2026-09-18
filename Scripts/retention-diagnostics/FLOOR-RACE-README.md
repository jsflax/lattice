# Retention floor publication race — source-only reproduction packet

This packet targets unchanged Core `7b11c282800d2bd6478538edb4e87de81953d315`, tree `18b482a47df9413e151887ef77a9dc5abb6be041`. No native code has been compiled or run for this packet. No active product file is changed.

The source has a check/use gap: both `safe_compact_audit_log()` and `prune_audit_log()` query the minimum non-observer upload floor, fully finalize that statement, and only later enter `delete_audit_below_()`. That helper creates the receipts table before acquiring its `BEGIN IMMEDIATE` write transaction. A second connection can publish a zero floor between the first read and the transaction. The subsequent delete uses the stale higher bound. Runtime reproduction remains pending; the source finding alone is not a completed test.

Relevant exact-source locations:

- `include/lattice/lattice.hpp:3458`: real `reset_sync_state()` helper, whose final update resets upload floor.
- `include/lattice/lattice.hpp:3487–3539`: slot compaction and pre-transaction floor read.
- `include/lattice/lattice.hpp:3568–3598`: age bound and pre-transaction floor read.
- `include/lattice/lattice.hpp:3660`: receipts CREATE followed by transaction and delete.
- `src/db.cpp:899–947`: query drains and finalizes the MIN statement.
- `src/db.cpp:1071`: `begin_transaction()` executes `BEGIN IMMEDIATE`.
- `src/sync.cpp:3107`: actual pending-upload query, with the caller's upload floor.
- `src/sync.cpp:3319`: real registration helper inserts a slot with default zero floor.

## Four independent cases

| Pruning API | Published change in the gap |
| --- | --- |
| `prune_audit_log(600)` | A new non-observer writer registered at floor zero |
| `prune_audit_log(600)` | An existing floor-12 writer reset to zero |
| `safe_compact_audit_log()` | A new non-observer writer registered at floor zero |
| `safe_compact_audit_log()` | An existing floor-12 writer reset to zero |

Each fresh owned fixture has twelve actual model INSERTs and twelve distinct audit identities. A resolved writer's floor is advanced to 12, matching the existing Core floor fixtures; this is a resolved-frontier setup, not evidence of network ACK delivery. Audit rows stay globally unsynchronized, so the newly pending writer's exact twelve IDs are visible through the real `query_audit_log_for_sync()` helper. Watermarks are backdated with the public test helper, without sleeping. Automatic maintenance is disabled in this diagnostic fixture; the two pruning APIs are invoked directly.

The pruner's trace callback recognizes the exact current floor SELECT and receipts CREATE. It requires one floor row with count=1/floor=12, one completed profile, no remaining prepared floor statement, autocommit enabled, `SQLITE_TXN_NONE`, and no preceding BEGIN. It emits one fixed barrier record and waits for a pipe byte. The callback uses fixed metadata getters and pipe I/O only: no SQL execution, logger, heap formatting or timing sleeps.

Only after this barrier does the supervisor start the mutation process. That process opens a separate Core owner, calls the real registration/reset helper, reports the exact pending IDs at durable floor zero, closes and exits. The supervisor then releases the pruner. A fresh read-only inspection checks pending IDs, retained audit IDs, model values, and AUTOINCREMENT sequence.

The safety assertion is **zero deletions and preservation of all twelve exact pending identities**. The expected baseline reproduction is **twelve deletions and disappearance of those same twelve identities**, with the zero-floor slot, model data and sequence unchanged. Counts alone cannot establish reproduction. Partial/unexpected outcomes are diagnostic failures, not accepted reproductions.

## Build and run seam

The preferred route is the upcoming hosted retention-phase diagnostic build owned by SourceSwift/root. It adds `harness/floor-race/probe.cpp` as a second executable using `harness/floor-race/target.cmake`, after the existing exact-source `LatticeCore` target is created. This reuses the same uniform Core compilation; there is no product overlay or second Core build. The phase sample and floor cases have separate commands, fixtures and results. The phase trace itself remains nonblocking; only this separate race executable has a blocking test barrier.

The shared `BUILD-PROOF.json` must retain full source/TU/archive/compiler provenance and add:

```
binaries.RetentionFloorRaceProbe = { path, sha256, linkArgv, mapSHA256 }
```

The floor runner verifies exact Core SHA/tree, uniform O3, the named binary path/hash and presence of the link proof. The hosting runner must verify the complete source/compile/map proof before invocation; this consumer does not reconstruct the compiler proof. Inherited `guarded_runner.py` is the same reviewed helper from the phase packet. The fragment does not select compilers or optimization flags.

Run once inside the hosting `GuardedRunner`:

```
python3 harness/run-floor-race.py \
  --probe <packet>/build/RetentionFloorRaceProbe \
  --build-proof <packet>/BUILD-PROOF.json \
  --packet <packet>/floor-race-run-001
```

No local native launch is authorized by this file. A local fallback would need its own explicit toolchain/source/build proof and coordination; the current runner deliberately requires the shared uniform O3 proof.

Bounds remain: 12.5 GiB free, 512 MiB full packet, one build job, existing 1200s compile limit, 120s outer floor-stage limit and owned-group cleanup. Internally the supervisor admits no new stage after 100s, each wait is bounded by 10s, aggregate child output by 1 MiB and each line by 64 KiB. It launches only four roles per case, sixteen finite processes total, all in the supervisor's outer-owned group. Launch ownership is published while TERM/INT are deferred. Cleanup signals only unreaped direct children; the outer guard supplies the required whole-group absence proof. All fixtures, original raw outputs, case results and final hashes are retained; there is no cleanup unlink, automatic retry or threshold increase.

On a precise baseline reproduction, `experimentCompleted=true`, `reproductionConfirmed=true`, `safetyAccepted=false`, `success=false`, and the runner exits **1** after collecting all four cases. Thus a successful diagnostic cannot be read as passing product qualification. The hosting workflow must retain artifacts on failure and keep the phase result separate. Missing source, barrier, cleanup or evidence proof fails closed.

## Proposed correction after preserved baseline evidence

The smallest correctness change is to validate the writer bound **inside the same `BEGIN IMMEDIATE` transaction that deletes history**. Re-read the non-observer slot count/minimum and clamp the prospective bound before any delete. A zero floor published before write-lock acquisition must stop deletion; a registration/reset after acquisition must wait and linearize after the prune. Preserve retention's no-writer behavior, compaction's no-writer return contract, observer exclusion, cursor preservation, atomic rollback and unchanged audit schema/wire.

The current helper also computes `preserve_cursor_row` and reads `_SyncControl.disabled` before BEGIN. Move or revalidate these decisions under the same transaction when designing the narrow helper refactor; avoid restoring a stale flag or applying an obsolete legacy-cursor decision. Watermark sampling/purge semantics and stale-slot eviction need explicit unchanged-return tests, not unrelated cleanup.

No proposed fix can restore history already pruned before a new registration/reset linearizes. The guarantee at issue is protection of retained pending history once its zero floor has committed before the prune's write transaction. General bootstrap/replay after already-pruned history is a separate contract.

Do not edit this frozen baseline probe in place to make a candidate pass. A corrected-source regression will need a versioned proof and a trace oracle that records the pre-BEGIN bound separately from its additional in-transaction revalidation. It should preserve the four red cases, add ordered after-BEGIN contention, no-writer/observer and rollback controls, and compare exact audit identity sets. No full event-stream, frame metadata or performance improvement is claimed here.

## Validation performed

`validation/ORACLE-RESULT.json`: Python syntax/import and ten pure result-classification cases passed. No subprocesses, C++ compilation, SQLite/Core execution, browser, network or user store access occurred. Native compilation, barrier timing, cleanup behavior under actual Core execution, and the source-level suspected data loss remain runtime gates.
