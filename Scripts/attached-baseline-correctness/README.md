# Attached correctness runner 005

Complete prepared successor to sealed 004 (`15a95380…`), with exact SDK d18f804 / Core f8f72e9 / 34-pin graph, unchanged two-case 952e4b75 overlay and 2b4827d6 one-condition product patch. This is original/corrected attached correctness only, not a benchmark, whole SDK qualification or release. Root owns workflow installation/push/execution. No native Swift/Core build or network occurred during this preparation.

The previous hosted 004 run 35386062763 compiled the first original Release build successfully (1242.299s, normal exit0, clean process group), then failed its compiler proof before building corrected or running either arm. See RUNNER004-FAILURE.md and observed-link-commands.json; all original evidence remains immutable. Its missing traceback prevents exact-PC reconstruction, and no remote list/map/object/binary bytes are reconstructed or retroactively accepted.

## Narrow correction

The canonical Swift driver link record must still read/hash its real owned stable object list and all members, and join actual Core/SDK/test objects transitively into the final test binary. Its matching Clang child may name a temporary file list under the exact owned tmp directory. This child is recorded as a derived invocation only after matching output, compiler directory, target and SDK and rejecting unexplained explicit objects/archives. Its missing temporary-list bytes have no invented hash and are explicitly not independently verified. Unmatched or duplicate children reject. General input containment is not widened.

Successful compiler proof includes stable-list paths/hashes, expanded member/object hashes, Swift output-map paths/hashes and source/object inventories, selected link graph and final binary/bundle hashes. On failure the supervisor retains an original-compiler-proof-failure.json (or corrected equivalent) with stage, arm, exception, up to 8 source frames and build-log hash; its primary error names file/line/function. No extra object dump or partial-proof collector is added. A failed proof still cannot admit an arm.

## Unchanged execution and acceptance

Both fresh independent Release builds use `swift build -c release --force-resolved-versions --build-tests -Xswiftc -enable-testing -j2 -v` before any tests. Source manifests, complete committed graph/checkouts and final build/receipt identities remain authenticated. The original product is unmodified; corrected receives only the approved predicate patch; both receive the identical test overlay. No reused binaries, prewarming, changed frozen workload, dependency update or candidate API.

Limits remain 12GiB free,30GiB owned packet,512MiB command log,5400s/build,600s resolve,60s discovery,180s focused command,18000s overall/600s finalization reserve. Every owned command group must be reaped/gone. All paths are under the execution host's localdev. Tests keep existing filter/assertions/deadlines and source-based exact discovery. Original requires clean expected exit1, exactly the display-oracle issue and green priming case; corrected requires clean exit0/two passes. Independent physical postimage checks remain unchanged. Signals, timeouts, wrong failures, missing evidence or final custody failures reject. Failure clears completed/accepted flags; raw observations remain.

`originalSafetyAccepted`, `performanceQualified`, `legacyChecksQualified`, `fullContractQualified` remain false. Legacy cases, original workload/attached invariants, corrected A/A and later performance comparison are separate gates.

## Validation and invocation

All 29 bounded Python checks passed: the previous 22 plus 7 tests covering the actual five hosted driver/child command pairs, nine altered/unmatched command cases, missing temporary bytes, duplicate/unmatched children, unlinked objects, canonical-list drift and exact failure-receipt execution. Synthetic file contents exercise parser behavior only; they are never native provenance. Actual run elapsed 13.848s; owned group was reaped/gone without signals/errors. Swift/Core tests remain unrun. SYNTHETIC-VALIDATION.json and STATIC-CHECKS.json bind that scope.

After root review, install exactly the files listed in PACKET-SEAL.json plus PACKET-SEAL.json into qualification-workflows/Scripts/attached-baseline-correctness. Use the separate workflow-proposal-005 (only packet seal changes from 004). No stale 005 source file may be omitted, and installed hashes must match. Root controls one changed-source workflow run, with no rerun of 004.

The workflow calls `python3 -B Scripts/attached-baseline-correctness/qualify.py --root <fresh-owned-localdev-root> --packet-seal-sha256 <exact-seal-hash>`. Paths are derived from the host; optional exact local SDK/Core seed repositories remain supported. Without seeds the existing reviewed fetch/resolve behavior remains. The workflow preserves receipts and bounded case/log outputs on success or failure; it does not archive all build objects.
