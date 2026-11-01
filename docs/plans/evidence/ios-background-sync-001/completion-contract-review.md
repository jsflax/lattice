# Finite sync completion contract: source review

2026-11-01. SDK source: `751950358f49b934dfa8af1dcfd493b683cd9d0a` plus documentation. Core source: `6afbe41b6ea4de63b27bb40e042ad9e455ba72ed`. Source review only; no runtime qualification or production modification.

## Recommendation

Use a small, explicitly requested **initial catch-up completion marker**. A local idle interval cannot prove whether another initial page is still being prepared, delayed by the network, or awaiting apply. A deadline remains a fallback and never becomes successful completion.

Define one finite operation as:

1. Acquire the background/finite-sync ownership for this store. If an existing foreground session owns live sync, return `alreadyRunning`/`notNeeded`; do not restart it to manufacture a completion checkpoint.
2. Resume a fresh connection with a query capability such as `lattice-catch-up-complete=1`. Scope all receipt state to its connection generation.
3. On its sync scheduler, complete existing initial filter reconciliation, then capture the finite upload horizon `H = MAX(AuditLog.id)` before the first upload pass.
4. Enumerate only eligible pending audit entries `<= H` for this operation. Existing continuous sync keeps its present unbounded behavior. Writes created later remain durable for another opportunity.
5. The server emits a negotiated `{"kind":"catchUpComplete","catchUpComplete":true}` only after all initial catch-up pages have been enqueued in order, without cancellation/revocation/send failure. Empty history still emits it immediately. Send it before activating live push so an ongoing stream does not extend the finite work unit.
6. Core receives the marker through the SAME serial scheduler as incoming applies. A marker is usable only after preceding applies committed and no preceding frame/entry failed. Any parse/apply failure, stale generation, or lost connection prevents successful completion.
7. Upload completion requires both no eligible pending entries through `H` and no in-flight sends. Synthetic filter transitions have audit ID zero, so checking only a persisted upload floor is insufficient.
8. Return `completed` only after the owned cleanup contract also settles. This means the finite upload prefix and that connection's initial replay have completed; it never promises an indefinitely current/global server state.

An old server that ignores the query will not emit the marker. The client must return an incomplete/unconfirmed result at its deadline (or an explicitly named best-effort partial result after a separately validated idle rule), not `completed`. Negotiation keeps old clients from receiving a new wire case. Do not add a second feature handshake just to optimize this fallback until measurements justify it.

For a later true "fresh pull" on an already-live connection, add a per-operation request/response barrier; reusing a marker received hours earlier would be dishonest. That capability is not required for the minimal background-owned fresh connection contract.

## Existing mechanisms and traps

- `Sources/LatticeCore/src/sync.cpp:1155` drain runs an upload pass and checks `progress_pending_upload_ <= 0`; it does not wait for incoming initial pages.
- `sync.cpp:2616` explicitly defines pending as **sent but unACKed**, rather than total backlog. ACK processing queues the next upload window at approximately line 2750. The transient zero between windows cannot establish backlog completion.
- `sync.cpp:3358` pending-query SQL already has indexed per-channel predicates, two UNION branches, ascending IDs, and an optional limit. A finite upper-bound parameter belongs on **both** branches; otherwise explicitly pending sync-state rows can escape it. Use the same eligibility predicate for the completion probe.
- `sync.cpp:2034` and `:2205` can create synthetic filter-transition sends with ID zero and mark the original audit ID superseded. `send_entries` tracks these synthetic IDs in its in-flight map (`:2439`); include them in finite completion.
- `sync.cpp:648` counts known payload keys and validates `kind`. `on_transport_message` reports unknown kinds as errors (`:1274`). The older comments claiming unknown events are silently ignored are not the full current behavior.
- `sync.cpp:1322` incoming audit applies and ACK bookkeeping run on the scheduler. The new marker must be queued there too and fenced by the captured connection generation, not applied immediately on the transport thread.
- Existing incoming apply lambdas do not consistently fence connection generation. The finite receiver must not allow a prior connection's queued apply/marker/failure to certify the successor.
- SDK `Sources/Lattice/Sync.swift:145` has additional `rejected` and `floorReset` wire kinds beyond the Core enum. Include the new marker in strict payload exclusivity validation, and inspect other callers before broadening public cases.
- `Sources/LatticeServerKit/LatticeServerKit.swift:1434–1478` already performs finite initial pagination, computes the last emitted boundary, then activates parked observer push. The marker belongs at that transition. A revocation can currently break the loop; ensure that path never falls through to a successful marker.
- The existing server page-count capture is not a global convergence barrier. Describe the completed initial replay pass without promising a globally atomic distributed snapshot.
- Public state/error/progress hooks are single slots. Add private finite-operation state/notification; do not replace app subscribers or consume `syncProgressStream`.

## Minimal implementation surface

- Core `include/lattice/sync.hpp` + `src/sync.cpp`: negotiated marker decode, per-generation finite status, fixed upload horizon, bounded pending query, completion inspection/private callback. Keep normal sync unchanged.
- SDK `Sources/Lattice/Sync.swift`: matching wire encoding/decoding if public event case is chosen.
- SDK `Sources/LatticeServerKit/LatticeServerKit.swift`: recognize request capability and emit ordered marker after successful catch-up, before live push activation.
- Existing Core/Swift bridges: expose private finite-operation start/status/cancel capability without changing app callback ownership. Root selects exact names with the lifecycle implementation.
- Core `Tests/LatticeCoreTests/SyncUnitTests.cpp`: mock transports and queued schedulers already exist for deterministic generation/window tests.
- SDK real-relay tests: reuse the raw websocket `PushFrameCollector`/harness in `Tests/LatticeTests/SyncTests/ObserverPushTests.swift` or the ingress fixture. The in-process `TestSyncServer` in `SyncTestHelpers.swift` has a separate implementation; updating only it would not qualify the shipping relay.

## Required deterministic regressions

1. Empty store: connection/open plus marker and settled upload probe complete without consuming the duration cap.
2. One upload: no completion before the matching ACK commits locally; unrelated ACKs do not finish it.
3. Multi-window upload: block between window ACK and queued next upload; no false completion at pending=0.
4. Continued local writes above `H`: operation completes its original prefix; later writes stay pending/durable.
5. Filter-generated synthetic send: floor past original entry does not complete until synthetic send ACK.
6. 2,001 download entries: marker arrives after all three server pages; queue applies behind a gate; callback cannot complete before the last gate is released.
7. Partial or failed apply/invalid frame followed by marker: never completed and no ACK/cursor advancement past unapplied work.
8. Marker from old generation, expiration, disconnect, or cancellation racing marker: stale work cannot complete or disconnect a successor.
9. Old client/new server: no marker without opt-in. New client/old server: useful progress may occur but result stays unconfirmed/incomplete.
10. Server revocation or catch-up failure: no success marker, parked watcher is cleaned up using existing failure path.
11. Existing app state/error/progress subscribers continue receiving their events.

## Separate existing risk found

Classification can replace a real pending event with a synthetic ID-zero send and mark the real event synchronized before `send_entries` applies its window cap. Synthetic entries truncated by a full window are not obviously persisted for retry. This source shape predates the proposed feature; it needs a focused regression before claiming finite filtered-upload durability. Avoid silently treating upload-floor advancement as sufficient proof. Root should decide whether to cover this existing correctness gap in the required work or explicitly reject unsupported finite filtered sessions until qualified.
