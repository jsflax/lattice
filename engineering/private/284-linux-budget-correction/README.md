# Linux budget-fixture and diagnostic identity correction

Source-only successor to `39bffe46ee4bc359683a7b517ae7e08dc4c0cf3a`, based on retained full-order run35721974566. The prior run remains NONPASS: all690 executing functions completed, five inherited skips were unchanged, and native/XML agree on two issues. Its artifact digest is `fbbb5b74e2d7c36d3a6bff08a69da5f42d4b81ac93d27fd3f4bc920f71cfffda`.

## Changes and causal limits

- The exact keyset SQL-budget fixture opens its own temporary store with the existing `crossProcessBeltIntervalMs=nil` control. Default500ms freshness probes issue SQL unrelated to collection page fills; the former fixture included those in an exact total. The observed203vs202 is compatible with one probe, but the failed run did not trace the extra statement. This change controls the measurement boundary without changing production tuning, exact OFFSET/keyset counts, exact statement budgets, warm-read budget or row assertions. The separate cross-process belt tests remain unchanged.
- The vector performance fixture seeds the same5000 random128-dimensional vectors in one existing atomic transaction. The dataset,1000-neighbor query, ten-repetition count/endIndex/snapshot workload, measured50 standalone inserts before training, IVF training, measured50 batched inserts afterward and final70%-of-k assertion remain unchanged. The existing300s test deadline is unchanged. The observed432.996s includes128.720s training; no phase trace attributes all remaining time to seed commits, so this has not yet been shown to fit the deadline.
- JUnit identity reconciliation now maps native top-level `Module.function()` to JUnit `Module/function()`. Suite-member IDs retain their spelling. A reverse map preserves original native skip identities and rejects normalized collisions; duplicates, missing identities and incorrect skips still fail. This repairs a latent diagnostic failure, not either native test issue: the original native exit1 meant full XML qualification was never reached.
- The census retains the same695 function labels,690 executing functions,106 suites, five inherited skips and17 parameter cases. Only the two fixture source hashes are updated, with original/current hash provenance recorded in `sourceOverrides`.

No production library, dependency lock, required workflow or process-custody helper changed. The source branch `private/284-linux-budget-correction` matches none of the existing push triggers. No workflow dispatch or PR is created.

## Validation and receiving boundary

The pure Python parser suite passed all16 tests (including actual five top-level spellings, a member function, exact skip mapping, duplicate/missing/changed rows and collision rejection). The run used an explicitly localdev scratch directory and did not start a child/native process. `git diff --check` passed. Swift compilation and actual Linux behavior remain UNRUN.

The frozen diagnostic workflow still enforces its original unchanged-production/test delta allowlist. Before any authorized future diagnostic execution, the receiving owner must explicitly bind this reviewed fixture delta into that caller; do not silently widen that allowlist or dispatch this source as if the previous seal applied. Required stableLinux CI remains open, with its90-minute job limit unchanged. Preserve original failures and run admission separately.
