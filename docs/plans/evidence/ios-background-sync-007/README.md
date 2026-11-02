# Background sync checkpoint 007 — merged implementation and release record

**Candidate record: Core 2.5.1 is published and verified. SDK 2.6.1 is not yet published; its actual new-pin full and strict tests pass, while candidate CI and consumer notices remain pending.** Updated November 1, 2026 local time (November 2 UTC). SDK tag 2.6.0 remains immutable and unpublished after its required release job failed. This is a progress record, not a completed SDK release receipt.

## Merged source and CI

[PR 38](https://github.com/jsflax/lattice/pull/38) merged at **2026-11-02T03:11:46Z** into main commit `d0ca27e4c1b98501dec4215f11403f281962691a`. Its tree, `708c33c7483a298a760d4f9135a774a707b6aa5f`, exactly matches PR commit `009edebcc146d185af2a898ea0c882ad02015a1d`.

All four legs of [PR CI 41380305623](https://github.com/jsflax/lattice/actions/runs/41380305623) passed. Principal test observations are:

| Leg | XCTest | Swift Testing |
| --- | --- | --- |
| macOS | 12 passed, 10.862s | 832 tests / 125 suites passed, 104.981s |
| Stable Linux | 12 passed, 5.453s | 810 tests / 122 suites passed, 103.646s |
| Nightly | 12 passed, 5.6s | 803 tests / 119 suites passed, 97.530s |
| iOS | Build passed | No device test execution implied |

The supplemental macOS strict cooperative-worker run passed **10 XCTest cases in 10.457s** and **15 Swift Testing cases in 0.172s**. Nightly also reports separate auxiliary runs of 1, 4, and 2 tests; those are kept separate from the principal suite count. These durations are observations of these CI runs, not performance guarantees.

[Main CI 41381739897](https://github.com/jsflax/lattice/actions/runs/41381739897) concluded **success overall**: required macOS, stable Linux, and iOS passed. The **optional nightly leg failed**, so this is not an all-legs-green claim. The workflow marks nightly experimental with `continue-on-error`; stable Linux remains required.

Nightly's principal run reported 803 tests in 119 suites, 99.261s, and one issue: the fake-backend test `lineageResumesDistinctNativeMembersButOnlyOwnerRefreshes` did not return `.completed` under its two-second refresh budget. Its later owner-command and borrower-suspension postconditions recorded no further issues. The fake backend returns `.completed`, while the binding uses a real monotonic deadline and downgrades a completion after late cleanup. **Inference from source and postconditions:** post-settlement budget exhaustion under parallel load is consistent with the sole mismatch. The actual enum value and isolated refresh duration were not printed; do not describe them as directly observed. This is a fake-backend, clock-sensitive assertion, not a demonstrated network-sync failure. The failure and source hashes are retained in the CI record.

Production `Sources`, `Package.swift`, and `Package.resolved` are unchanged between `edb48f3` and merged main. Later changes isolate ordering/finite-conformance tests while retaining actors, harnesses, budgets, and deadlines; they do not exclude cases. Earlier failures and the unproven macOS result attribution remain preserved in checkpoints 005 and 006. Passing later CI does not retroactively identify the previously unlogged enum value.

## Published guide

[Docs workflow 41381739885](https://github.com/jsflax/lattice/actions/runs/41381739885) built and deployed successfully for exact main commit `d0ca27e4c1b98501dec4215f11403f281962691a`. The published [Background Sync on iOS guide](https://jsflax.github.io/lattice/documentation/lattice/backgroundsync/) was verified, including its DocC data digest. This verifies documentation deployment; it does not establish SDK package publication.

[ci-and-docs-verification.json](ci-and-docs-verification.json) contains exact source/tree IDs, safe CI/job results, test counts, source-diff proof, documentation URLs/digest, and hashes of immutable local receipts.

## Physical-device qualification and limits

The corrected managed and manual iOS 15 hosts build and run on the lab phone. Evidence covers early-expiration completion with one false completion hit, actual system background entry, independent WAL cleanup, lazy unbound delivery without a database, later binding/rescheduling, and manual relay failure/pre-admission cancellation. Ordinary callbacks and process reopen preserve 25 local rows; rebuilt dispatch-worker binaries repeat cleanup/reopen checks.

After the user accepted Local Network permission, the unchanged corrected managed binary became active and connected at **03:45:14 UTC on November 2**. Its progress changed from **25 pending to 25 acknowledged / zero pending**, then reported **2,001 received rows by 03:45:19**. An ordinary foreground callback at **03:47:52** snapshotted **2,026 rows, including 25 fixture rows**, with zero pending. Foreground network progress is now verified; a transient socket disconnect/reconnection is also logged without a causal claim.

Actual system background entry occurred at **03:47:54**, with debugger-cached application state 2. A later foreground/active/connected sequence is recorded. The debugger's first task-delivery attempt had one completion callback hit, but **the success BOOL was not captured**; a second attempt had no observed completion hit. The snapshot expression stalled until foreground, and an extra debugger-owned UIKit assertion was explicitly ended before detach/quit and restoring the managed app. **That attempt did not qualify successful finite BGTask sync.** The later candidate run below provides a separate successful debug-delivery receipt.

[phone-network-followup.json](phone-network-followup.json) retains safe events and hashes of private local snapshots, including the live relay log. That attempt adds no independent post-network WAL checkpoint; previous WAL receipts keep their earlier scopes. Later manual/candidate checks below add their own checkpoints. Expiration during active transfer, foreground takeover during active work, locked-phone protected-data behavior, natural scheduling, and true OS cold launch remain coverage gaps. Debugger-triggered delivery is labeled separately from system scheduling. UI automation failed before test bodies; that tooling failure is not classified as a production defect. Checkpoints 004–006 remain historical evidence.

The public manual finite path is now also verified with a reachable relay. In a fresh fixture on the existing Core 2.5.0 / corrected SDK binary, `syncOnce` returned `.completed` after **1.967s observed**: 25 inserted rows were acknowledged, progress recorded 2,026 received rows, and a later ordinary callback observed 2,051 rows. An independent WAL truncate checkpoint qualified with return code 0 and 0/0 frames, then close/open preserved all 2,051 rows including the 25 fixture rows. [phone-manual-success.json](phone-manual-success.json) contains the sanitized receipt and frozen private evidence hashes.

This manual pass used the managed bundle in manual mode with its declared background identifier unbound. It does **not** establish successful Apple BGTask completion or a successful network pass in the separate plist-without-background-identifiers binary. The source predates the native bootstrap candidate; no candidate release validation is inferred from it.

### Candidate phone qualification

A freshly signed host built against Core correction `820f0ba022d23531f9b4525f623e514f3e4c50b0`, with SDK production source unchanged from `edb48f3`, passed its iOS build. The recorded executable, debug-library, and plist hashes match the local built files. The physical run used a local Core candidate binding. That identical source has since been published and verified as Core 2.5.1; this remains evidence for the candidate build, separate from the new SDK published-pin test run.

Public manual `syncOnce` returned `.completed` after **1.738s observed**, acknowledging 25 uploads and reporting 2,051 received rows. Independent WAL cleanup qualified at 0/0 frames, and ordinary callback close/open preserved **2,076 rows, including 25 fixture rows**. This still uses the managed plist in manual mode with its declared identifier unbound.

The same candidate then completed an actual `BGAppRefreshTask` successfully after **debugger-triggered delivery** while the app was in background state 2. The actual completion selector received `true` (`x2 = 1`); SDK stack frames show `AppleBackgroundTaskDelivery.complete(success: true)` and `BackgroundTaskSession.finish(success: true)`. The completion breakpoint recorded **one hit**, including the final check after foreground restoration and reopen.

An independent WAL checkpoint qualified at **04:12:51 UTC**, with mode `wal`, return code 0, and 0/0 frames, **after completion and before foreground restoration at 04:13:09**. Actual foreground/active/connected callbacks followed. Ordinary callback snapshot/close/open preserved 2,076 rows and 25 fixture rows. A temporary host-only UIKit assertion supported debugger setup and was explicitly ended; all debuggers were closed afterward.

[phone-candidate-success.json](phone-candidate-success.json) preserves sanitized events, build/source provenance, exact completion evidence, and frozen private receipt hashes. This qualifies successful debug delivery, settlement, and reopen; it is **not natural OS scheduling**, and does not claim new payloads arrived during that BGTask. Natural delivery, true cold launch, locked-phone behavior, active-transfer expiration, and foreground takeover during active work remain unqualified.

## Required release-job failure

The required [macOS job 125079754321](https://github.com/jsflax/lattice/actions/runs/41383687634/job/125079754321) in release workflow 41383687634 **failed**. Twelve XCTest cases passed in 8.404s; the Swift Testing run failed with **one issue across 832 tests / 125 suites in 92.388s**. `ObserverPushTests.pushAndCatchupComposeExactlyOnceAcrossRedial` caught an opaque `lattice::cxx_error`; the log does not render readable error-name/message contents or identify the throwing operation. **The exact cause is unproven.**

[release-failure-summary.json](release-failure-summary.json) records the failure and frozen raw-log hash. Other release legs were still running at the coordinator update; preflight or iOS success does not establish publication after a required job failed. SDK 2.6.0 is not published, and there have been no consumer notices.

The coordinator is investigating on `codex/bg-release-followup-20261101`. Test-only open-error diagnostics and two additional binding-test isolation changes now pass local full and strict SDK runs. The Core correction passed all PR, exact-main, and release checks and is **published and verified as Core 2.5.1**. The actual SDK published pin and full/strict test passes are verified. SDK 2.6.1 remains intended and unpublished, with candidate CI, publication, and artifact verification pending. Tag 2.6.0 remains immutable at `d0ca27e4c1b98501dec4215f11403f281962691a`.

## Native bootstrap investigation and focused correction

A native probe uses 100 simultaneous two-opener rounds per case, with disposable fresh files and initialized-file controls. One opener has the existing 30-second statement budget and the other a two-second budget. Both raw database and `lattice_db` construction are exercised. The Core 2.4.2 baseline compiles its own implementation objects and headers; current/candidate manifests preserve the matching source/object hashes. The probe does not include the Swift model-schema/cache layer.

| Native source | Raw fresh-file failures | Store fresh-file failures | Initialized-file failures, raw / store |
| --- | --- | --- | --- |
| Core 2.4.2, independently rebuilt | 24 / 200 | 12 / 200 | 0 / 200 each |
| Core 2.5.0 | 22 / 200 | 18 / 200 | 0 / 200 each |
| Bootstrap correction, now published as Core 2.5.1 | 0 / 200 | 0 / 200 | 0 / 200 each |

Every baseline/current failure reports `SQL execution failed: database is locked (SQL: PRAGMA journal_mode = WAL)`. Median failure times range from 239.5 to 498 microseconds; the largest observed failure is 2,413 microseconds, far below either configured statement budget. The failure class therefore reproduces in the old source as well as the new source in this toolchain/SQLite environment. These samples are diagnostic evidence, not a rate comparison or performance guarantee.

SQLite documents that it may return `SQLITE_BUSY` without invoking a configured busy handler when invoking it could cause deadlock. That explains why a busy timeout alone is not a universal waiting guarantee; it does not prove the exact internal lock state of these runs. [SQLite busy-handler documentation](https://www.sqlite.org/c3ref/busy_handler.html).

The bootstrap candidate passes **all 800 probe opens**, including 400 fresh-file opens, and **23 focused native tests in 0.767s**: seven bootstrap cases and 16 existing cancellation cases. The new cases cover held-reader release, one configured budget, zero budget, cancellation, non-busy errors, memory/read-only behavior, and concurrent constructors. These bounded passes support the correction. **They do not prove that the opaque error in the original Swift release job came from this operation**, nor replace SDK qualification against the published Core pin.

The correction is committed as `820f0ba022d23531f9b4525f623e514f3e4c50b0`. [Core PR 79](https://github.com/jsflax/LatticeCore/pull/79) passed all four checks and merged at **2026-11-02T04:13:32Z** as `d2241191c1a630e0aaf0d8a5a38b0520c9614c4c`; the coordinator verified identical trees. Exact-main CI subsequently passed, and Core 2.5.1 is published and verified. The candidate host also passes the physical checks above.

The SDK diagnostic/isolation follow-up passes **14 XCTest cases in 5.830s** and **830 Swift Testing cases / 125 suites in 84.831s**, after a 125.22s build. Its strict cooperative-worker run passes **12 XCTest cases in 5.807s** and **13 Swift Testing cases in 0.110s**. These runs validate the test-only SDK follow-up before the pending Core pin, not the complete successor release.

[fresh-open-investigation.json](fresh-open-investigation.json) contains exact setup, per-case results/timing, source and object provenance, focused native and SDK results, and hashes of frozen harnesses, compile/link receipts, raw runs, and the SQLite primary source.

## Published Core and verified SDK dependency

[Core 2.5.1](https://github.com/jsflax/LatticeCore/releases/tag/2.5.1) was published at **2026-11-02T04:26:27Z** from `d2241191c1a630e0aaf0d8a5a38b0520c9614c4c`. Exact-main CI and every required job in [release workflow 41387813073](https://github.com/jsflax/LatticeCore/actions/runs/41387813073) passed. Verification matches the tag, source, workflow, receipt digest, and all **911 source-archive files including Git modes**. The downloaded release-receipt SHA-256 is `98387165dccb7ff40286c4e5713389d0bdc7dbe04542f09689e201ae757eccde`. [Full verification](core-2.5.1-verification.json).

The SDK manifest now requires Core 2.5.1, and the actual resolved checkout is `d2241191c1a630e0aaf0d8a5a38b0520c9614c4c`, with **34 pins and every other dependency unchanged**, without an edit override. The lock and checkout `db.cpp` hashes were independently rechecked while recording this update. [Source and pin proof](source-and-pin-verification.json).

**Provenance correction:** an optional earlier desktop run named `sdk-wal-core-integration-*` actually compiled published Core 2.5.0 after SwiftPM restored its resolved state. Its passing full run (14 XCTest, 5.582s; 830 Swift Testing / 125 suites, 85.975s; build 312.35s) and strict run (12 XCTest, 5.545s; 13 Swift Testing, 0.065s) are **not Core 2.5.1 integration qualification**. [The correction](desktop-provenance-correction.json) freezes those receipts. The native probe, focused tests, Core CI, and candidate phone source provenance remain valid.

The real full SDK run against the verified published Core 2.5.1 pin **passed** after a 162.11s build: **14 XCTest cases in 6.225s** (outer suite 6.228s), plus **830 Swift Testing cases / 125 suites in 72.437s**. The strict cooperative-worker run also **passed**: **12 XCTest cases in 6.078s** (outer suite 6.080s), plus **13 Swift Testing cases / one suite in 0.162s**. The pin and actual checkout hashes were rechecked after the full run. These are distinct frozen receipts from the corrected older Core 2.5.0 runs, not substitutes from them. Durations are run observations. The [structured test provenance receipt](sdk-published-core-2.5.1-tests-verification.json) ties both complete logs to the unchanged lock and the linked test binary containing the bootstrap fix. These local runs use the native SwiftPM build backend; hosted default-backend CI remains separate. Candidate CI, SDK 2.6.1 publication/artifacts, and consumer delivery remain **pending**.

## Publication and delivery — SDK qualification pending

| Required receipt | Current state |
| --- | --- |
| Core 2.5.0 historical release | Published and verified at `c3fcb7dd24f75740b6559ec84fe0d5086f4569f1`; see checkpoint 005. |
| Core 2.5.1 | Published and verified at `d2241191c1a630e0aaf0d8a5a38b0520c9614c4c`; source/tag/archive/receipt checks pass. |
| Exact-main CI | Overall success; required macOS/stable Linux/iOS passed, optional nightly failed as detailed above. |
| SDK 2.6.0 tag/source match | Tag pushed at `d0ca27e4c1b98501dec4215f11403f281962691a`; immutable, no retag. |
| SDK release workflow and published artifact/receipt verification | Required macOS job failed in [workflow 41383687634](https://github.com/jsflax/lattice/actions/runs/41383687634). **SDK remains unpublished.** |
| SDK 2.6.1 candidate with published Core 2.5.1 | Actual pin and local full/strict tests verified; candidate CI, SDK publication, and artifact verification **pending**. |
| Engram integration notice | **UNSENT; pending verified publication.** |
| Orbital notice | **UNSENT; pending verified publication.** |
| HUD notice | **UNSENT; pending verified publication.** |

[release-and-delivery-status.json](release-and-delivery-status.json) records the main-CI outcome, immutable tag/source match, and required release-job failure. Published release URL, downloaded artifact/receipt verification, and safe delivery confirmations remain pending. The coordinator must complete SDK qualification and record actual publication before describing this as a completed release record or marking the goal complete. Delivery is distinct from verified downstream adoption. Keep private chat identifiers outside repository-facing receipts. No direct or indirect shock-trooper contact is permitted.
