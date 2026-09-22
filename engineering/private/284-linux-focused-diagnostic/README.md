# Temporary Linux stall diagnostic

This source-only successor preserves production, tests, dependency locks and every existing workflow at `7f1028ebfa9e5b4776a1aa6636a086107ca5de0a`. It adds one diagnostic workflow, its owned process controller, pure controller fixtures and this note. It has not been dispatched. The required full CI still runs all tests with its existing 90-minute limit. Diagnostic success cannot qualify that gate.

## Evidence and scope

Stable Linux run `35705106207`, job `106672035932`, was cancelled at the declared 90-minute job deadline. It recorded 196 test starts and 195 completed passes; normal console progress stopped near `test_GroupBy_WithNearestQuery()`. That test's short pass was partially flushed at cancellation. This does not establish whether the stall was inside the next test, teardown, Swift Testing or SwiftPM's output/child handling. The new close regression and original concurrent-close stress both completed in the retained log. No production fix is inferred from that log.

The diagnostic runs all 16 `FullTextSearchTests` functions and all 16 `GeoboundsTests` functions, including nearest-query and bounds-query, in serial mode. The controller derives and hashes exact membership from the unchanged two source files. It requires exactly those 32 XML cases with zero errors, failures or skips, valid retained native JSON events, a naturally successful directly joined SwiftPM process and no remaining recorded owned processes. It does not rewrite assertions, add retries, remove required coverage or reinterpret a timed-out run as passing.

## Dispatch route — requires ROOT authorization

The intended route is **one normal push of this exact reviewed commit** to the otherwise unused branch `private/284-linux-focused-diagnostic` in `jsflax/lattice`. The new workflow matches only that branch and changes to its workflow or two controller files. There is no pull-request trigger and no PR is to be created for dispatch.

After ROOT reviews the frozen commit, the exact dispatch command is:

```sh
git push origin HEAD:refs/heads/private/284-linux-focused-diagnostic
```

Do not run it before that authorization. Do not force-push or retry a run automatically. Record the actual pushed head/run identity and preserve its terminal result before choosing a next action.

Existing triggers were read at the preserved baseline: `ci.yml` matches pushes to `main`, PRs targeting `main`, and `workflow_call`; `docs.yml` matches selected paths on `main` and manual dispatch; `release.yml` matches version tags. A branch-only push with no PR/tag does not invoke those workflows. Their files are unchanged. The new workflow also contains `workflow_dispatch` as a documented alternative, but GitHub requires registration on the default branch before that route is callable; this proposal does not authorize such registration or a default-branch change. [GitHub's manual dispatch documentation](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).

## Execution and bounds

One Ubuntu job, at most 20 minutes including package installation, clean build and artifact upload, uses the same immutable Swift 6.3 Noble image digest retained from the failed job. It builds the unchanged locked test graph once with `swift build --force-resolved-versions --build-tests`. Existing strict-consumer lock/binding checks run before and after the build/test. No successful local Mac/iOS/native D5 check is repeated.

The test phase invokes exactly:

```sh
swift test --force-resolved-versions --skip-build --no-parallel \
  --filter 'LatticeTests\.(FullTextSearchTests|GeoboundsTests)' \
  --event-stream-output-path <run>/focused-events.jsonl \
  --event-stream-version 0 --xunit-output <run>/focused.xml
```

The hidden event flags are defined and forwarded by the retained SwiftPM 6.3.3 source (`SwiftTestCommand.swift`, event options and `runTestProducts`), and handled by the matching Swift Testing entry point. The native event file is independent of console framing. SwiftPM may suffix the XML filename `-swift-testing`; both paths are retained.

The Linux controller owns a new SwiftPM session/process group, records PID/PGID/session/start-ticks/UID/executable plus boot identity, and follows only that tree. A dedicated child subreaper retains orphaned owned descendants; it does not change ptrace permissions. After 60 seconds with no native-event progress, or 270 seconds of total test-phase time, it records the last event tail and tries bounded `/proc` and gdb stacks of the exact test child and SwiftPM parent. Gdb gets at most 8 seconds per target, with a shared capture deadline leaving teardown time. It then resumes/stops only its original group, directly joins SwiftPM, and reaps owned children; any escaped observed child is signalled through its identity-checked pidfd. PID/session changes cause refusal, not a broad process-name kill.

The process/cleanup budget is 300 seconds. A deadline, external cancellation, signal, diagnostic failure or incomplete closure is a nonpass. `processSecondsBeforePublication` measures setup through closure and qualification **before** RESULT serialization/print; final publication and always-run artifact upload remain under the separate 20-minute job deadline. No longer total-controller timing claim is made from that field. Diagnostic output has explicit file/process/thread limits. A pathological kernel operation or unavailable process control is recorded as a control failure rather than claimed closure.

Ordinary package installation adds gdb, Python and existing SQLite build dependencies. There is no sudo, privileged container, `SYS_PTRACE` capability addition, seccomp override or sysctl/security change. Container ptrace policy may prevent user-space stacks; denied/absent stacks and gdb/proc errors are retained explicitly. This supersedes the earlier investigation note's suggestion of adding a ptrace capability.

## Retained result and next decision

The always-run artifact holds source/tool/lock receipts, exact build and test arguments, stdout/stderr, native events, complete XML if produced, START/RESULT process receipts, progress at stop, proc/gdb output and step outcomes. Setup failures retain whatever exists through the same artifact route. No absent diagnostic is treated as a successful stack capture.

If the focused scope passes, the conclusion is only that these 32 functions did not reproduce in isolation. Earlier-suite effects remain possible. If it stalls, native last-start/end events plus available stacks distinguish a test/teardown boundary from a runner/output wait. Missing stacks leave that distinction uncertain; they do not justify a production patch or a second full-CI rerun.

Local validation uses only the standard-library pure controller fixtures: parsing birth identities, PID reuse/session refusal, exact test membership, event/XML qualification and progress retention. These fixtures do not launch processes, read live procfs, compile Swift or execute Lattice tests. The workflow/controller itself remains unrun until ROOT authorizes the exact diagnostic dispatch.
