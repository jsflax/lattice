# Background sync checkpoint 004 — iOS build and first launch

November 1, 2026. The iOS 15 deployment-target build passes, and the private lab app is installed and launches on the physical iPhone. Debugger-triggered offline and early-expiration paths return `success=false`; the corrected independent probe confirms WAL cleanup. A fresh process and an ordinary callback both reopen the same 25 durable rows. **Successful network background sync and full lifecycle qualification remain pending. This is not a release receipt.**

## Platform ABI correction

The first full iOS 15 host build exposed bridge types imported as requiring iOS 16.4. Raising the deployment target produced a provisional build but did not meet the supported-target requirement. Review found a deeper mismatch: bridge layout selection depended on deployment-version macros, while Swift's explicit Clang modules and native object compilation could use different deployment targets.

[Core PR 78](https://github.com/jsflax/LatticeCore/pull/78), source `8d0c86d7d5b21fab741547e644e2ef2c4c18cc3a`, selects the existing shared-pointer-backed value handles consistently for all iOS builds, including simulator and Catalyst. macOS/Linux keep the existing foreign-reference handles. The C API now follows that dependency layout instead of forcing foreign-reference handles in one target; private wrappers preserve the public opaque-handle retain/release contract. Linked-object getters return an owned reference consistently. Native bridge objects and Swift consumers must be rebuilt together; precompiled objects using different iOS bridge layouts must not be mixed.

The local native C API suite passed **37 tests in 1.481 seconds**. A second runtime run forced the consistent value layout and passed the same **37 tests in 1.547 seconds**. That run freshly compiled all seven ABI-sensitive translation units and reused 14 unchanged Core/support objects. It ran on macOS, so it tests value-handle ownership behavior without claiming device C API runtime coverage. Counts, source hashes, and raw receipt hashes are in [capi-runtime-summary.json](capi-runtime-summary.json). The two runs are 37 distinct cases exercised under two layouts.

PR 78 is merged at `c3fcb7dd24f75740b6559ec84fe0d5086f4569f1`, and the coordinator verified all required CI green for that exact main commit. The [Core 2.5.0 release workflow](https://github.com/jsflax/LatticeCore/actions/runs/41373486648) is running. Publication and downloadable artifacts have not yet been verified.

## Phone build and installation

The full host build returned `TEST BUILD SUCCEEDED` with the **iOS 15 deployment target** after the platform fix. Subsequent signed builds adding the host-only Objective-C debugger entry point and the corrected WAL probe also passed. The managed builds have successful `devicectl` installation and direct-launch receipts for the fresh lab bundle. The separate manual host's signed iOS 15 build and updated WAL-probe build also passed; it is installed but no manual runtime result is claimed yet. The workspace resolves candidate Core through `ios-host/local-packages/LatticeCore`, preserving the package identity alongside the candidate SDK.

The exported host log confirms the initial store open with **zero rows**, plus scene connection and foreground entry. It also records a later **25-row write and snapshot**, followed by a fresh-process open retaining **25 rows**. In that fresh process, an ordinary `NSOperationQueue` callback closes the store, reopens it, and snapshots the same **25 rows**. The phone showed its standard local-network permission prompt, awaiting the user's response, and sync callbacks reported an offline connection. No screenshot, network address, device identifier, private app-container path, or signing metadata is copied here.

A prior synchronous LLDB reopen expression was interrupted at a normally caught C++ `ALTER` exception. That debugger-tainted process was discarded; its interrupted evaluation is not evidence of a production reopen bug. The fresh-process ordinary callback supplies the reopen result reported here.

The debugger bridge forwards only existing lab controls. It does not synthesize lifecycle notifications or task delivery. Debugger-driven calls must run on the main thread, and the process must continue for asynchronous operations to settle.

## UI automation did not execute the tests

Both XCTest attempts failed before any eager, lazy, or manual test body ran. Each reports only runner initialization: “Timed out while enabling automation mode,” with zero passes, one synthetic runner failure, and `xcodebuild` exit 65. These are not app assertion failures or successful lifecycle tests. No further retry is planned until the initialization cause changes. The local-network prompt is a separate observation; it is not established as the cause of the automation timeouts.

[phone-qualification-summary.json](phone-qualification-summary.json) records sanitized build/install/launch results, result-bundle summaries, and hashes of the local raw receipts. Referenced raw files are frozen into content-hashed snapshots under `/Users/jason/localdev/lattice-bg-sync-evidence-20261101/checkpoint004-receipts`; later saves to the live LLDB transcripts cannot alter this checkpoint's evidence. Raw device receipts remain local because they contain personal device or network metadata.

## First debugger-triggered delivery

The saved LLDB transcript shows a real `BGAppRefreshTask` reaching `setTaskCompletedWithSuccess:` with register `x2=0`, through `AppleBackgroundTaskDelivery.complete(success=false)`, `BackgroundTaskSession.finish(success=false)`, and the SDK driver's run path. This confirms delivery and a failure callback while network communication was unavailable. It does not establish successful synchronization, natural scheduling, true OS cold launch, or complete exactly-once race coverage.

The initial independent SQLite checkpoint returned `SQLITE_OK` but frame counts `-1/-1`; that initial result remains **unqualified for WAL lock release**. The corrected direct SQLite follow-up reads WAL mode, finalizes that statement, then completes a truncate checkpoint with return code 0 and frame counts 0/0 after the offline task.

In a separate fresh-process run, the debugger stopped SDK `receive` at line 446, after expiration handling was installed and before work began, then invoked Apple's debug expiration selector. The real `BGAppRefreshTask` completed with `success=false`; the completion breakpoint recorded **one hit** for this task, with no base-class completion hit. After completion, the corrected host probe recorded **`qualified=true`, `journalMode=wal`, return code 0, frames 0, checkpointed 0**. This verifies the tested early-expiration path and its independent WAL cleanup. It does not cover late expiration during active upload/download or every cancellation race.

## Remaining qualification and release work

Normal background/foreground survival beyond the recorded callback paths, successful network background sync, late expiration during active work, protected-data behavior, and the manual/lazy paths still need device evidence. Natural scheduling and true OS cold launch must be labeled separately from debugger-triggered delivery.

Core exact-main CI is green. Complete coherent Core/SDK version pinning, remaining SDK CI/runtime qualification, publication and artifact verification, and the authorized Engram/Orbital/HUD notices before closing the goal. Core 2.5.0 is in its release workflow; SDK 2.6.0 remains intended. This checkpoint does not assert either has shipped. Do not contact shock trooper directly or indirectly.
