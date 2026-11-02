# Background sync checkpoint 003 — integration qualification in progress

November 1, 2026. This checkpoint is not a release receipt.

## Native implementation

Core `df7a90a122cd5857e7a26e6d8ae2b681ca9c0beb` contains finite sync with a fixed upload horizon, negotiated replay completion, generation-fenced cancellation and settlement, managed autonomous-work suspension, foreground resumption, and Swift-importable receipts. All 173 affected native tests passed in 12.738 seconds before the bridge-only importer correction. The actual Swift bridge consumption check then passed. [Core PR 77](https://github.com/jsflax/LatticeCore/pull/77) passed macOS, Linux, and C ABI CI for that commit.

Follow-up `aa4407c` fixes callback replacement/destructor reentry, UUID acknowledgement case matching, local foreground observation when another handle owns WSS, and local-only managed borrowers. All 185 affected native tests passed in 11.815 seconds. Test-only follow-up `39eec87` adds an actual retention-tick cancellation regression; all 24 lifecycle tests passed in 1.358 seconds, including that new case. These are 186 distinct covered native cases across the two runs; no production changes occurred between them. CI is being rerun for the final commit.

## SDK integration

The config-first registration, weak actor/store binding, command serialization, automatic lifecycle adapter, manual `syncOnce`, and native integration are implemented in the working branch. Portable scheduler/binding probes cover 27 cases; these use enclosing SDK type stubs and do not replace full integration tests. Full SDK compilation found and corrected a nested C++ receipt import issue, then a new test's actor-isolation error. The third full selected-suite run passed 69 tests in 54.596 seconds. It exposed a ten-second delay per uploading finite pass: Foundation's uppercase UUID ACKs persisted successfully but failed to clear lowercase Core in-flight keys until the watchdog. The native follow-up fixes that mismatch, including durable synthetic outbox ACK cleanup. Post-fix SDK timing remains pending.

Further review identified missing shared lifecycle control for cross-actor/query handles. Internal inherited lifecycle groups are being wired so those handles resume in foreground, settle on background, and cannot reopen a closed account lineage. New actual-Core cross-actor tests are prepared. This later SDK working-tree state is not yet runtime-qualified.

The new shipping-relay integration suite covers empty completion, upload, paged replay, cancellation, ordinary-reader behavior, progress callback survival, and an older server's unconfirmed/budget outcome.

## Physical device

The user-supplied iPhone 13 Pro (iOS 26.0.1) is paired, connected, and developer services are available. A separate private lab host and disposable local relay are prepared under the evidence root. The Xcode workspace has resolved both candidate local packages. Build/install, real lifecycle execution, debugger-triggered task delivery/expiration, and natural scheduling remain unqualified. A debugger-triggered delivery must never be described as natural scheduling or true OS cold launch.

## Release gate

Core 2.5.0 and SDK 2.6.0 are intended versions, not published artifacts. Complete callback regression, SDK/runtime and phone qualification, exact-commit CI, coherent version pinning, release verification, and Engram/Orbital/HUD notices before marking the goal complete. Do not contact shock trooper directly or indirectly.


## Completed SDK integration checkpoint

The final selected SDK run passed **87 tests in 10 suites in 8.323 seconds**, including both real-Core cross-actor lineage tests. Its seven-row upload case completed in **0.359 seconds**, versus **10.049 seconds** before UUID ACK normalization. These are individual local test runs, not a general speedup claim. The enclosing scheduler/binding probe also passed 41 tests and the iOS 15 extension compiler check. An initial new test used an isolated reference resolution directly inside a testing macro; moving the call outside the macro fixed that test compilation issue without changing production behavior.

Core PR 77 is merged at `62fc557a9543218904b3043c542565ce9dbe9e1a`; branch CI passed all three platforms before merge. Main/release CI and publication are still required. The disposable relay was built from the qualified SDK dependency objects, and the phone host's Xcode build is running. Installation, device task delivery/expiration, and publication remain pending.
