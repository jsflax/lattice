# Background sync checkpoint 006 — second CI failure and test isolation

November 1, 2026. **Core 2.5.0 is published; SDK 2.6.0 is not published.** This checkpoint records the failed CI after the local passes in [checkpoint 005](../ios-background-sync-005/README.md), which remains unchanged. The test-isolation follow-up now passes complete local and strict SDK runs; fresh exact-commit CI remains required.

## What the second CI run established

[PR 38](https://github.com/jsflax/lattice/pull/38), commit `edb48f3702675b55143a51fe30856590e28d8a54`, failed [CI run 41377435800](https://github.com/jsflax/lattice/actions/runs/41377435800). The iOS build passed. The test legs reported:

| Leg | Swift Testing result | Observed failure |
| --- | --- | --- |
| Stable Linux | 818 tests / 123 suites, 101.962s, one issue | `invalidationCancelsBeforeAQueuedActorHopCanStartNativeWork`: `didEnter` fixture-entry assertion. |
| Nightly | 811 tests / 120 suites, 102.272s, one issue | The same binding fixture-entry assertion. |
| macOS | 840 tests / 126 suites, 99.717s, one issue | `emptyStoreCompletesAndSettlesItsPrivateSession`: `syncOnce(maximumDuration: 10)` result differed from `.completed`. |

The macOS log **does not record the actual returned enum value**. It therefore does not establish budget exhaustion, a relay regression, or a production fault. The observed assertion and its unproven cause must remain separate.

[ci-isolation-followup.json](ci-isolation-followup.json) retains exact counts, safe failure excerpts, and content hashes of frozen raw CI logs. The nightly log contains one NUL byte; the snapshot/hash preserves it, while readable excerpts omit that character.

## Test-isolation follow-up and local results

There are **no production, package-manifest, or lock changes after `edb48f3`** in this follow-up; an empty diff receipt is retained. The third ordering-sensitive binding case moved into the default serial XCTest phase with its original **two-second entry deadline**. All seven finite-sync conformance tests also moved into serial XCTest, retaining the same actor, shipping-relay harness, sync budgets, and per-test limits. Current test files and workflow are frozen with source hashes.

The change isolates these tests' execution from unrelated parallel work. It excludes no tests and extends no budgets/timeouts. The complete local run exits **0** after a **39.37-second build**:

- **XCTest: 12 cases passed in 6.308 seconds** — three binding ordering cases (0.002s), seven finite conformance cases (6.305s), and two existing child-runner entry cases.
- **Swift Testing: 832 tests in 125 suites passed in 75.473 seconds**, with no issues.

The finite cases observed empty completion at 0.171s, upload at 0.355s, paged replay at 0.915s, cancellation at 0.577s, legacy relay at 3.141s, ordinary-reader behavior at 0.459s, and progress subscriptions at 0.687s. These are **individual local observations, not benchmark guarantees**.

The actual-SDK strict run also exits **0** under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`: all **10 selected XCTest cases** pass (three bindings in 0.002s plus seven finite cases in 5.961s; 5.963s total), followed by all **15 binding Swift Testing cases in 0.157s**. The macOS CI strict filter now covers both `BackgroundSyncBindingTests` and `FiniteSyncIntegrationTests` after the unchanged complete test invocation. `actionlint` passes.

These local results validate the follow-up locally; they do not retroactively prove the macOS CI failure's cause or establish a new CI pass. Fresh exact-commit CI remains required. The earlier strict 18-test counterfactual and local pass remain historical evidence in checkpoint 005.

## Corrected manual iOS binary

[manual-dispatch-device-summary.json](manual-dispatch-device-summary.json) incorporates the sanitized follow-up prepared outside the repository. The corrected manual host built, installed, and launched with minimum iOS 15 and **no BG task identifiers or background modes**. It reopened the existing **25 local rows**.

The unreachable-relay attempt throws after settlement; a separate pre-admission cancellation reports cancellation after settlement. The independent WAL probe records **`qualified=true`, mode `wal`, return code 0, and frame counts 0/0**. Ordinary callbacks close, reopen, and snapshot all **25 rows**. These results validate the tested local failure/cleanup/reopen paths on the corrected binary; they do not establish successful network sync or active-transfer cancellation.

Raw manual receipts and built artifacts remain frozen under the local `sdk-final-followup/raw` directory. Only safe fields and hash references are copied here. The coordinator restored the managed app through system activation and detached/quit both debuggers. The local-network permission prompt remains pending; a fully active UI and successful phone network connection are not claimed.

## Release status and coverage limits

Final exact-commit CI, SDK publication/artifact verification, and consumer notices remain outstanding. Successful phone network sync, active-work expiration, full foreground takeover, locked-phone behavior, natural scheduling, and true OS cold launch remain documented coverage gaps. No screenshot, device identifier, network address, private app-container path, or signing metadata is included in this checkpoint. No direct or indirect shock-trooper contact is permitted.
