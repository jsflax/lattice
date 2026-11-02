# Observer destruction hang: baseline / build-engine isolation

The released Core 2.4.2 baseline reproduces the hang when linked through SwiftBuild's combined `LatticeCore.o`. The same standalone caller object, same baseline Core source, same baseline raw Core objects, and same SQLite-Vec dependency pass when linked directly. This isolates the failure to symbol canonicalization at the combined-object boundary, rather than the new cancellation/outbox source changes.

## Results

| Binary / linkage | Result | Observed callback state |
| --- | --- | --- |
| Candidate exact existing GoogleTest, isolated | 8-second subprocess timeout | Test never returns from synchronous write |
| Baseline native-engine raw Core objects | exit 0, 0.31 s | one TLS map entry, own depth 1 / notify refs 1; destruction returns |
| Baseline SwiftBuild raw Core objects | exit 0, 0.14 s | one TLS map entry, own depth 1 / notify refs 1; destruction returns |
| Baseline SwiftBuild combined Core object | SIGALRM after 7.14 s | callback's TLS map empty; destruction does not return |

Each child process was bounded by a Python timeout of at most 10 seconds. The standalone repro additionally uses alarm(7). No production files or active checkouts were changed. The isolated candidate run uses the existing executable; it does not rebuild anything.

## Exact evidence

- `candidate-isolated.{json,log}`: exact GoogleTest filter and bounded isolated outcome.
- `observer_repro.cpp`: two stores on one file; an AuditLog observer destroys its store during the other store's synchronous write. No sync configuration or server is used.
- `repro-compile.json`: full compile argv, compiler exit, elapsed time. One caller object is reused in all three baseline links.
- `link-{native,swiftbuild,aggregate}.json`: full link argv and outcomes.
- `run-{native,swiftbuild,aggregate}.{json,log}`: exact executable/database paths, exit status, elapsed time, callback observations.
- `nm-*.txt`: selected symbol tables from each object/executable.
- `baseline-head.txt`, `baseline-status.txt`: baseline is clean at `6afbe41b6ea4de63b27bb40e042ad9e455ba72ed`.
- `header-sha256.json`: candidate and baseline lattice.hpp hashes are equal.
- `candidate-core-compile-args.resp`: SwiftBuild uses `-fvisibility-inlines-hidden`.
- `clang-version.txt`, `swift-version.txt`: Apple Clang 21 / Swift 6.4 on arm64 macOS27.

## Mechanism

`instance_registry::for_each_alive` increments the guard's global notify reference count and a per-thread depth in `instance_guard::tls_depths`. The inline destructor subtracts this thread's own depth from its drain wait. That is necessary because destroying a store from inside its callback must not wait for the callback itself.

The native raw object exports weak `tls_depths` symbols. The SwiftBuild raw object uses weak private extern symbols; direct final linking still canonicalizes these in the passing repro. SwiftBuild's combined `LatticeCore.o` has already localized `tls_depths`, `tls_depth`, and their TLS variable (`non-external (was a private external)`). A caller compiled from the header has another copy. The candidate final executable contains three function/TLS copies (Core, bridge, caller). The Core callback increments its copy; caller-side destruction reads zero from another and waits forever on its own notify reference.

`instance_registry::instance()` is already intentionally out of line in lattice.cpp to avoid exactly this class of singleton ODR issue. The TLS depth accessor lacks that protection.

## Recommendation

1. Complete the candidate correctness run with the native build engine, including the isolated failing test and full affected suite. This validates the new changes without the already-reproduced SwiftBuild packaging failure.
2. Consider a focused separate correction: declare `instance_guard::tls_depths()` in the header and provide its one externally visible out-of-line definition in lattice.cpp. Keeping `tls_depth()` inline is sufficient if every caller invokes that canonical accessor. A public/default-visibility override on the existing inline accessor could also coalesce it, but the out-of-line design matches the registry precedent and is easier to audit.
3. Validate any correction with a caller/Core combined-object boundary repro and both build engines. The existing single test is a useful regression case only if the packaging under test actually crosses that boundary.
4. Do not claim the SwiftBuild path is fixed until such a change and packaging validation pass. No production fix has been made by this diagnostic.

The evidence establishes that the hang predates the current changes and depends on the aggregate object boundary. It does not establish that all release/package/link configurations are affected, nor that the new features are otherwise regression-free.
