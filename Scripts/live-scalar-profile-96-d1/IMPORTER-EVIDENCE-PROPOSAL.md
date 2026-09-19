# Importer evidence proposal for review

The failed run remains failed. Its Swift dependency file directly names the CLatticeTestSQLite module map but omits that module's transitive headers. No PCM/module cache was uploaded. Requiring those headers in the Swift `.d` was an extra assumption in our diagnostic proof, not an application requirement.

Proposed successor evidence has two explicit categories:

1. Direct emitted dependency evidence: require all per-source object and concrete module/doc/source-info target rules; every rule includes all authenticated LatticeTests Swift sources and the exact CLatticeTestSQLite module-map path. Retain/hash the complete `.d`, every target, and every listed input. Preserve actual object-producing frontend, complete source/object sets, target, flags, native header dependencies, and final binary reachability checks.
2. Inferred importer header chain: authenticate the exact sealed module map (`module CLatticeTestSQLite [system]`, `header "shim.h"`, sqlite3 link, export); the exact sealed shim conditionally includes `<lattice/perf_live_profile.h>`; the actual driver and object-producing frontend each select that map, define LATTICE_PERF_LIVE_PROFILE=1, bind the Core include root, and use the same fresh owned scratch module-cache path. Rehash shim/header bytes from the already sealed overlay manifests. Record this explicitly as authenticated source/configuration inference. It is not a direct emitted transitive-header dependency or retained PCM proof.

The diagnostic measurement must still pass its existing ABI/enabled/fault checks and exact native counter expectations across all 210 canonical samples and16 separate calibration samples. A build without those samples does not establish a valid measured profile. Keep the original sample counts, workload, commands and overall resource/time limits unchanged.

Minimal implementation would add a separately labelled importerHeaderChain record, with exact source hashes, both actual importer argument lists and cache path, plus a statement that directSwiftTransitiveHeaderDependency=false and pcmCustody=false. Hash that chain at every custody check; do not replace absent header evidence with a claim that file presence proves import. Synthetic tests must reject changed map/shim/header, wrong macro or map/include argument, foreign/different cache path, and missing direct module-map dependencies. Actual saved `.d` tests should show grammar/target coverage and the honest absence of direct header entries.

The original importer-header `.d` check remains in the unsealed draft until root accepts this evidence contract. No new compiler invocation is proposed.
