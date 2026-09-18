# Retention diagnostics sharing one exact Core build

This packet combines the separately reviewed one-shot SQL phase trace and four retained-history registration/reset cases. It builds unchanged Core7b11c282800d2bd6478538edb4e87de81953d315 (tree18b482a47df9413e151887ef77a9dc5abb6be041) once with uniform O3/g0/DNDEBUG and links two separate probes. The original uninstrumented five-triplet timing run35365051287 is preserved and is not rerun or pooled with this sample.

The phase and floor steps each require the successful shared source/build proof. They run separately even if the other diagnostic fails. A demonstrated loss of any of the twelve exact pending audit identities is a failed safety result; diagnostic reproduction is never product acceptance. Unknown SQL phases, unfinished records, or trace overflow prevent phase qualification. Time before/after statement callbacks remains explicitly unattributed.

SOURCE-READY.json remains false until root's concrete source review and packet activation. This flag controls source readiness for the diagnostic run; it does not assert that product safety or performance has passed. All original receipts, source manifests, per-step results, failed fixtures and bounded process-group cleanup evidence are retained. The source-only preparation has not compiled or run native code.

Guards: 12.5GiB free,512MiB packet,32MiB logs,-j1,1200-second shared compile,120-second phase sample and120-second floor supervisor. No retry or threshold change. The separate floor supervisor has four finite cases and a100-second admission deadline. Both binaries' hashes, link maps, exact object compilation flags, shared archive hashes, source manifests and runtime SQLite identities are recorded. Build and run cannot choose replacement sources or binaries.

See harness/README.md for phase callback/clock limits and FLOOR-RACE-README.md for the four deterministic cases and exact identity oracle. The latter remains frozen baseline source; a future corrected candidate needs separate provenance and revised in-transaction test controls.
