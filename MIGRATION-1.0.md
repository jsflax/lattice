# Migrating to Lattice 1.0

One line per breaking change, appended in the same commit that lands it. This
ledger becomes the consumer migration guide and the 1.0.0 CHANGELOG body.

- `Lattice.attach(lattice:)`, `Lattice.attaching(lattice:)`, and the `LatticeBackend.attach` requirement now `throw` (`LatticeError.attachFailed`) instead of terminating the process on schema mismatch / alias collision; new `Lattice.detach(lattice:) throws` (`LatticeError.detachFailed`) drops the attachment's views, DETACHes, and rebuilds the merged schema — wrap call sites in `try` and add `detach` to teardown paths.
