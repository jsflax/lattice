# Diagnostic SPI access probes

These probes test a built module with the real Swift compiler. They do not
inspect source spelling and do not use `@testable`. Run them separately from
`swift test`, after building `Lattice` and `LatticeMCP` at the reviewed commit.
There is no environment gate or zero-selected-test success path.

Use the same compiler, SDK, target triple, Swift version, C++ interoperability
mode, module search paths, Clang module maps and header search paths as that
build. Save those import/compiler flags as a JSON string array. Do not include
the original source list, output paths, module name, module cache path or
emit/build actions: this checker supplies its own `-typecheck` invocation.
Save `swift package dump-package` output for the reviewed checkout as the
manifest JSON. Neither preparation step changes dependency pins.

```sh
python3 Scripts/test-debug-spi.py \
  --swiftc "$REVIEWED_SWIFTC" \
  --manifest-json "$REVIEWED_MANIFEST_JSON" \
  --compiler-arguments-json "$REVIEWED_IMPORT_ARGUMENTS_JSON" \
  --scratch-path "$FRESH_PROBE_BUILD_DIRECTORY"
```

The scratch path must be a fresh caller-owned build directory. It contains a
compiler module cache, five compiler logs and `result.json`; it is build output,
not a receipt-only folder. Retain the small logs/result with the compiler version,
reviewed build SHA and exact argument JSON, then remove this probe's owned build
directory when qualification finishes. No package or dependency build is started
by the checker.

Required results:

- `PublicControl.swift` compiles using ordinary `import Lattice`, establishing
  that module loading and the public `DynamicObject` type work.
- `Allowed.swift` compiles using `@_spi(LatticeInternals) import Lattice` and
  references both debug methods and `DynamicDebugReadError`.
- Each `Hidden*.swift` file fails under ordinary import with a diagnostic naming
  its guarded symbol. A missing dependency or SDK does not qualify as a pass.
- The manifest contains the `LatticeDebugBridge` implementation target and no
  library product with that name. The target already was not a product before
  this change; this check is a retained packaging guard, not a failing-first case.

Against the old public declarations, the positive probes pass but the three
negative probes compile, making this checker fail. Rebuild the changed `Lattice`
module before running the corrected comparison; do not test stale modules.

SwiftPM has no product-level SPI annotation. Diagnostic consumers depend on the
`Lattice` product and opt into `LatticeInternals` with the import above. They must
not import the bridge target directly. The existing `LatticeMCP` implementation
is an explicit SPI consumer and must still build after the boundary changes.
