# Original/corrected attached correctness supervisor

Source preparation only. The runner has not materialized a graph, fetched dependencies, compiled Swift/Core, or executed a native test. The original two-case Swift overlay952e4b75 and one-condition product patch2b4827d6 are unchanged. The original SDK/Core repositories, frozen benchmark and physical benchmark runner are never edited.

The proposed command after root review is:

```
/opt/homebrew/opt/python@3.14/bin/python3.14 -B /Users/jason/localdev/lattice-perf-refinement-20260917/execution/preparation/attached-baseline-qualification/runner-002/qualify.py --root /Users/jason/localdev/lattice-perf-refinement-20260917/execution/validation/attached-baseline-d18-f8-001 --packet-seal-sha256 <reviewed PACKET-SEAL digest>
```

The output root must not exist. Its parent must resolve under that host's localdev. The source is path-independent: absent optional `--sdk-seed`/`--core-seed` paths, it fetches only the reviewed official repository URLs and exact commits. Local seed repositories may avoid those two network fetches; dependency resolution can still require network. No output directory or native command is created by this preparation. This source packet does not independently authorize execution.

## Source and build custody

Both arms are separate fresh clones of exact SDKd18f804 / tree995487ab and exact committed34-pin graph containing Coref8f72e9 / tree38ba9b58. Separate pristine SDK/Core clones provide immutable comparison manifests. The corrected arm receives only the reviewed single TableResults predicate change. Both receive the same new test file. No dependency edits, candidate APIs, archive substitution, candidate Core or reused build cache.

The fixed guard is copied byte-identically (SHA c31626b5). Per-arm explicit scratch/cache/config/security/TMP/module/log paths belong to the owned root. SwiftPM resolves with forced committed versions. Every effective graph node and checkout state/path/revision/URL must match all34 complete pin records. Core's full tracked-file manifest and tree must match the pristine exact source. SDK source manifests exclude only the named overlay, corrected product file, and Package.resolved metadata; the complete original pin records remain exact and current file hashes are bound before/after build/tests. The actual host/toolchain is recorded; this correctness check does not require or claim a physical benchmark host.

Both Release `swift build --build-tests -j2 -v` builds finish before either correctness test run. Build evidence requires actual verbose Core/bridge compile inputs, source and object hashes, Release optimization, actual Lattice/LatticeTests output-file maps and object hashes, overlay membership, and a transitive link graph consuming those objects into the selected Lattice test binary. It records linked archives where present and all final test bundles. The parser covers both direct SwiftPM object lists and the retained Xcode `builtin-SwiftDriver`/partial-link `.o` format. Unknown formats reject provenance. The final successful build command receipt, source proof and compiler proof form each arm's build identity. No case runs from a missing/failed/mismatched build identity.

The fixed limits are12GiB raw free,30GiB owned packet,512MiB command logs,0.5-second polls,5400s per fresh Release build,600s resolve,60s discovery,180s per focused case command,18000s overall with600s finalization reserve. Whole owned process groups are terminated/reaped and proved absent on every command path. Admission requires each unchanged command timeout to fit in remaining work time. There is no retry, timeout growth, reduced test selection, or other-owner cleanup.

## Test and evidence acceptance

Actual Swift Testing discovery must include exactly the two selected case identifiers. `swift test --skip-build --disable-xctest --enable-swift-testing` uses only the new suite filter and retains full output plus xUnit. No manual test-function invocation and no benchmark run. Framework output format drift fails closed.

Original requires normal exit1, clean process cleanup, exactly one failing display case/issue `ATTACHED_DISPLAY_ORACLE`, green priming control, zero skips/global errors, and its exact100-row even-rank duplication/50-object/50-ID pattern. Six live fields must still cost600; priming must remain one collection statement plus100 per-row primes and600 live fields. Corrected requires normal exit0, both complete cases and all original assertions, including warm identity/zeroSQL, live600SQL, routed commit, rollback, other-owner live update and fresh post-close physical reads.

The runner authenticates the two bounded case receipts and master/copy seed hash claims. After clean native process-group disappearance, additional fresh independent read-only Python SQLite connections check all40,000 master/copy rows across both case fixtures. Only the corrected display fixture may contain the exact two committed counter/date updates and one attached owner title update. These reads use no immutable shortcut for potentially WAL-backed copies and perform no writes.

`original-correctness-result.json` always has safetyAccepted=false and success=false, even when its precise expected failure is reproduced. `corrected-correctness-result.json` is green only when the corrected arm passes. Overall `success` means the requested red/green experiment completed and all evidence checks passed; it never means the original is safe. `originalSafetyAccepted`, `legacyChecksQualified`, `performanceQualified`, and `fullContractQualified` remain false. Root must inspect `reproductionConfirmed` and `correctedFocusedAccepted`, not infer release/performance qualification from process exit0.

The four previously identified unchanged legacy tests are deliberately not run by this two-case packet. Their inherited BaseTest log path needs its own reviewed owned-output overlay. They, the unchanged frozen local/attached benchmark invariants, corrected A/A, physical-host continuity and later performance comparison remain separate mandatory gates. No threshold or frozen workload is changed here.

## Validation state

The preparation uses source parsing and synthetic Python oracle rejection tests only. Real SwiftPM compile/link/file-map and xUnit formats must be confirmed by the actual first run. Unknown formats or incomplete source/object joins stop rather than weaken provenance. No actual discovery, test count, failure reproduction or corrected native pass is claimed by this packet.

## Remote option and existing artifact reuse

The separate `workflow-proposal-002` directory proposes a macOS26 qualification job. Root owns installation in the qualification-workflows checkout, reviewed seal substitution, push and dispatch. It creates all task/build/cache/fixture artifacts beneath remote `$HOME/localdev`; exact workflow commit and packet seal are recorded. It performs correctness only and leaves physical A/A/B local. No workflow or repository has been edited by this packet.

The running physical benchmark's original binary lacks the new attached correctness overlay and its compiled test cases. It cannot directly satisfy discovery or these assertions. Reusing old Core/SDK objects would require an additional exact toolchain/flags/header/module/object/link custody adapter and changed-test compilation. This first supervisor deliberately does fresh builds remotely; it never mutates or consumes the running physical packet as a build destination. Retained local build logs were read only to support parser formats, not to claim this overlay was compiled.

Revision002 preserves001 and corrects final acceptance flags: any final custody, signal, deadline or result-write failure clears overall experimentCompleted and correctedFocusedAccepted while retaining raw per-arm observations.
