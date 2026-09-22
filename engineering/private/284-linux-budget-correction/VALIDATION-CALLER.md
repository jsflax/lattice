# One corrected full-order Linux diagnostic: preparation only

The predecessor run35721974566 at39bffe46 completed naturally with two native issues:203vs202 statements in the keyset budget fixture, and the vector performance fixture exceeding300s. Its original artifact and NONPASS remain retained. The source correction `f0afff07429aced7693843b1f981076b0e7b5c72` was reviewed by ROOT; its16 pure parser checks passed. Native behavior of the correction is still UNRUN.

## Exact admission

The caller binds the original baseline `7f1028ebfa9e5b4776a1aa6636a086107ca5de0a` to the exact reviewed correction commit, then permits only this workflow and this document to differ from that correction. It requires the exact13-path/status baseline→correction delta and exact2-path/status correction→current delta; no wildcard test/source exception is used. All inherited files other than the intentionally updated workflow must remain byte-identical to the reviewed correction. Actual checkout bytes must equal their committed current bytes.

Only two Swift fixture paths may differ from the original baseline:

| Fixture | Baseline SHA256 | Reviewed/current SHA256 |
|---|---|---|
| LiveResultsKeysetTests.swift | 5d4a54102707e02e6ef97a029f9d91bb7becb91f17a5031ff3a2f2424e5bcf16 | 00fb315e9d93ff854f0f8d607ba22f3ff6e345f909475e2ef71d205b30d90262 |
| VectorSearchTests.swift | 9edb9198f193a875b6a12668dd69f95466a3865a63e02dec8aaeddb85aa41c39 | be13bbbad142dc2e0f912c3062847744654d3686f53e406494c13217701c1a9f |

The workflow writes `SOURCE-ADMISSION.json` with baseline, reviewed-correction and current SHA256 for every admitted file; absent baseline files have null baseline hashes. That includes parser, census, pure parser fixtures, unchanged custody helper, diagnostic workflows and their exact documentation. Source107-file/census and six lock-integrity phases remain in the existing caller. Dependency locks and production libraries remain unchanged.

## Unchanged execution and limits

- Same immutable Swift6.3-noble container digest, ordinary tooling and security settings.
- One locked `swift build --force-resolved-versions --build-tests`, then unfiltered `swift test --force-resolved-versions --skip-build --no-parallel` with nativev0 event stream and JUnit.
- Same695 function definitions,690 executing functions, five exact inherited skips,106 suites and17 parameter cases. No new skips or dropped rows accepted.
- Existing300s vector benchmark limit;1800s process bound,660s native-event idle limit,30s capture/cleanup reserve and45-minute outer job bound.
- Existing direct process ownership/join/closure and bounded stack collection; ordinary output cannot reset the native-idle timer. Process timing remains explicitly measured before final publication.
- RequiredCI workflow, stableLinux90-minute bound, macOS/iOS and informational nightly remain unchanged. This diagnostic does not automatically qualify requiredCI.

## Dispatch custody

Preparation branch: `private/284-linux-budget-validation-prep` (matches no workflow push trigger). Intended one-run trigger branch: `private/284-linux-full-order-corrected-1`. ROOT must review the final exact commit/whole caller, then push that exact commit once:

`git push origin <reviewed-final-commit>:refs/heads/private/284-linux-full-order-corrected-1`

The final preparation receipt supplies the concrete commit in that command. No PR, default-branch workflow registration, dispatch or trigger-branch push is performed during preparation. The explicit trigger keeps the required gate from starting a second full run. Source preparation/static admission reads use no localSwift build, native test or model.
