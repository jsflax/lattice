# Migrating to Lattice 1.0

One line per breaking change, appended in the same commit that lands it. This
ledger becomes the consumer migration guide and the 1.0.0 CHANGELOG body.

- `Lattice.attach(lattice:)`, `Lattice.attaching(lattice:)`, and the `LatticeBackend.attach` requirement now `throw` (`LatticeError.attachFailed`) instead of terminating the process on schema mismatch / alias collision; new `Lattice.detach(lattice:) throws` (`LatticeError.detachFailed`) drops the attachment's views, DETACHes, and rebuilds the merged schema — wrap call sites in `try` and add `detach` to teardown paths.
- `Configuration.isStoredInMemoryOnly` is replaced by `Configuration.storage`: `.file(URL)` | `.memory(named: String)` (+ `.memory()` for a fresh private database). Migrate `.init(isStoredInMemoryOnly: true)` → `.init(storage: .memory())`; `.init(fileURL:)` spellings keep working. Same-name `.memory(named:)` handles share one same-process database with cross-handle observation; every `.memory()` is isolated. `configuration.fileURL` remains as a computed accessor (setter switches storage to `.file`).
- `LatticeBackend` gained a `detach(_:)` requirement and its `attach(_:)` requirement now throws — custom backend conformers (none known outside this repo) must implement both.
- `.memory(named:)` names are percent-encoded into the backing SQLite URI: names are no longer required to be URI-safe, and two names that differ only by URI-hostile characters ('?', '#', '%', space) are distinct databases.
