# Versioning policy (1.0 stub)

Lattice follows semantic versioning from 1.0.0. Scope notes:

- **Semver surface**: the public API of the `Lattice`, `LatticeServerKit`, and
  `LatticeMCP` library products.
- **Underscore exemption**: public symbols whose name begins with `_` (or
  `_$`) are macro-support / structural plumbing and are **exempt from semver**
  — they exist because macro-generated code compiles in the client module (so
  they cannot be `@_spi`) or because a public protocol requirement cannot be
  hidden. The audited list and tiering live in `docs/spi-audit-1.0.md`.
  Consumers must not call them directly.
- **`@_spi(LatticeInternals)`**: SPI-gated symbols are exempt from semver.
- **C++ interop contract**: clients must compile with
  `.interoperabilityMode(.Cxx)`; the bridge modules
  (`LatticeSwiftCppBridge`, `LatticeSwiftModule`) are `@_exported` by design
  (macro expansions spell C++ types). See `docs/spi-audit-1.0.md` Tier 3.
- **Breaking changes** during the 1.0 cycle are ledgered one line per change
  in `MIGRATION-1.0.md`, in the same commit that lands them.
