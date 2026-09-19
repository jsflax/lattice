# Two-source first-tick/manual-drain hosted packet — preparation

This is a new experiment, not a retry of the historical single-tick harness. Exact source manifests for d546 baseline and isolated bounded-retention beee were generated from local Git objects. The protocol source is reviewed separately in ../retention-firsttick-drain-002; no native launch is admitted here.

Use one hosted ubuntu24.04 allocation and preserve the existing clang18/systemSQLite toolchain and uniformO3/j1 build. Proposed fixed source order: baseline prepare/build/run, then bounded prepare/build/run. Each retains one warmup and five measured alternating A1/A2/B triplets and both held-reader controls. Separate per-source512MiB packet limits and all existing per-command limits stay intact. A future outer runner must enforce an explicit aggregate1.5GiB/240minute envelope including both source packets, fetch objects, logs and tools. No implicit sum of two independent packet caps is an aggregate limit. The packet still lacks that orchestration and hosted workflow integration.

This schedule controls the hosted allocation and source/workload specification; it does not prove physical host identity, eliminate source-order/thermal effects or establish the original frozen read/write2× target. Do not borrow historical7b11 timings as the d546 baseline. No trace callback, observer redesign, weakened final survivor assertion or automatic worker/scheduler claim enters this experiment.

Next: accept the corrected protocol source, then construct/review the concrete aggregate supervisor+installer against these manifests. Reuse GuardedRunner and existing registered retention-foreground workflow where suitable; preserve failures and never retry unchanged source automatically.
