# Full-order Linux diagnostic — prepared, not dispatched

The focused diagnostic at `6086e0e78627d1f53bdec10717a0f362e22b63c4` passed all32 selected functions in run35718118691. It did not reproduce the full-suite stall. This additive successor runs the complete unchanged Linux test selection in the runner's normal sequential order, so effects from earlier suites remain present. Production, test source, package locks, required CI and the successful focused controller/workflow are unchanged from that commit. No retry, push, PR, tag or default-branch change is authorized by this preparation.

The existing stable command is `swift test --force-resolved-versions --no-parallel`. This diagnostic builds the same locked graph first, then uses `swift test --force-resolved-versions --skip-build --no-parallel` with native v0 event and XML output. There is **no filter, shard, custom ordering, skipped test addition or second runner invocation**. Test-internal concurrency and child-process stress bodies remain unchanged. Source hashes bind all107 checked-in Swift test source files.

## Census and exact completion

The retained full log from run35702579915 reports695 test functions in106 suites. Its690 function starts plus five inherited skips match that total. Seventeen additional console starts are parameter cases: seven LocalizedError arguments, four keyset functions with two sort orders each, and the two cancellation targets. The census names every function label, the exact five skipped identities and the six parameterized function/argument sets. It does not infer695 expanded cases.

Swift Testing6.3.3's JUnit recorder emits one row per function, including skipped functions; therefore full XML must contain695 unique function rows, `tests=690`, `skipped=5`, and zero failures/errors. Native events must independently contain all695 function definitions and106 suite definitions; exactly690 paired, sequential function starts/ends; precisely the five inherited skips; and17 paired parameter-case starts/ends with original `_testCase.id` and exact argument display names. That represents701 executed argument/nonparameterized cases. A new/missing skip, argument substitution, duplicate identity, changed label, partial run, issue, overlap or missing XML cannot qualify.

Inherited skips are the empty external conformance corpus, disabled IVF correctness, disabled IPC blob round-trip, disabled IPC vector bulk-nearest, and the existing narrowed-filter relay quarantine. Their source remains unchanged and their full native IDs are pinned in `Scripts/linux-full-order-census.json`. These skips are reported explicitly; this diagnostic does not waive any new failure or skip. If the environment unexpectedly gains a corpus, the changed census fails qualification and must be reviewed.

## Bounds and custody

| Boundary | Full diagnostic | Reason |
| --- | ---: | --- |
| Native-event no-progress limit |660seconds|Existing tests/suites declare up to10minutes; retain that opportunity plus60seconds. Ordinary stdout/stderr cannot reset this timer.|
| Process/cleanup budget |1800seconds|Allows30minutes for full serial execution, well beyond the retained parallel237.575seconds and the first195 serial passes'88.572seconds; it is a diagnostic bound, not a prediction of total passing time.|
| Capture and cleanup reserve |30seconds|At1770seconds, stop accepting continued execution and retain stacks/process state before teardown.|
| Debugger |At most8seconds per exact target|Same bounded gdb/proc capture as the focused controller; shared22second capture ceiling leaves teardown time.|
| Outer job |45minutes|Includes the ordinary clean build, setup, process phase and final artifact publication; required CI keeps its90minute bound.|

The full controller imports the exact frozen focused custody helpers by SHA256. Its process loop is copied with only scope/argument/output/bound changes and a direct-child stack selection: full scope includes watchdog tests that launch the same test binary, so the stalled main test target must be SwiftPM's direct `LatticePackageTests.xctest` child. This parent relationship was present in the actual successful Linux focused receipt. Nested fixture processes remain within observed owned custody.

PID/start-tick/UID/session checks, per-command checkout admission, denied-read errors, subreaper adoption, identity-checked pidfds, direct joins and group-absence checks are retained. Signals never use broad process-name matching. No sudo, added ptrace capability, seccomp override, privileged container or global Git/security configuration is introduced. Stack denial remains explicit; the passing focused run did not exercise or qualify forced teardown or stack access.

The timer observes the native event file only. On idle or total bound, the last event tail identifies the current boundary; exact process/proc/gdb receipts show whatever state the runner permits reading. `processSecondsBeforePublication` is sampled after process closure/qualification but before RESULT serialization/print, as in the focused control. Final publication/upload is covered by the45minute job bound, not claimed inside that field. Incomplete custody or timeout remains a nonpass.

## Dispatch and retained evidence

After ROOT receives and authorizes the exact frozen successor, one normal push of `HEAD` to `private/284-linux-full-order-diagnostic` would trigger only `.github/workflows/linux-full-order-diagnostic.yml`. Its exact branch/path filter does not trigger the preserved focused workflow, main-only required CI/docs or tag-only release. No push is performed by this preparation. The manual route still requires default-branch registration and is not proposed here.

The same immutable Swift6.3 Noble image, strict source/lock phases and always-run artifact retention are reused. A successful full diagnostic would establish its actual full Linux test scope, not automatically satisfy the repository's required CI check. A stall or failure remains preserved with native events, XML if complete, exact source/process identities, stack availability and bounds. No source fix is inferred until that evidence identifies a cause.

Local validation consists of pure parser/census fixtures and source/YAML comparisons. It neither compiles Swift nor starts a process controller. Original focused success, zero-test setup failure and full-gate failures remain separate.

Primary implementation references: [SwiftPM6.3.3 test command](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3.3-RELEASE/Sources/Commands/SwiftTestCommand.swift), [Swift Testing6.3.3 native events](https://github.com/swiftlang/swift-testing/blob/swift-6.3.3-RELEASE/Sources/Testing/ABI/Encoded/ABI.EncodedEvent.swift), [v0 experimental field compatibility](https://github.com/swiftlang/swift-testing/blob/swift-6.3.3-RELEASE/Sources/Testing/ABI/ABI.swift), [JUnit function-row semantics](https://github.com/swiftlang/swift-testing/blob/swift-6.3.3-RELEASE/Sources/Testing/Events/Recorder/Event.JUnitXMLRecorder.swift).
