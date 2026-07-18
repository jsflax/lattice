# SPI audit for Lattice 1.0 (H1)

Computed macro-support set + tiering for every underscored/public support
symbol, ahead of the 1.0 semver freeze.

## Method (reproducible)

The TRUE macro-support set is whatever the macro *expansions* reference —
macro-generated code compiles in the CLIENT module, so `@_spi` cannot cover
macro-referenced symbols (the client has no SPI import).

1. `swift build --target LatticeTests -Xswiftc -Xfrontend -Xswiftc
   -dump-macro-expansions` — the repo's own test fixtures exercise `@Model`
   (183 uses), `@Property`, `@Detached` (13), `@Union` (9), `@LatticeEnum`,
   `@VirtualLinkProperty` (emitted by `@Model` for virtual members),
   `@Unique`/`@Indexed`/`@FullText`/`@CodableIgnored` — 45k+ expansion
   records harvested.
2. `@Codable` has zero uses in-repo and in all consumers, so it was expanded
   standalone: a scratch file with local macro declarations pointed at the
   built plugin (`swiftc -typecheck -load-plugin-executable
   .build/debug/LatticeMacros-tool#LatticeMacros -Xfrontend
   -dump-macro-expansions`). Its support set is a subset of `@Model`'s (plus
   Foundation `Codable` machinery) — no new symbols.
3. Marker macros verified to emit `[]` (no support set): `@Transient`,
   `@FullText`, `@Indexed`, `@Unique`, `@CodingKey`, `@CodableIgnored`,
   `@EmbeddedModel`, `@VirtualModel` (see the `VirtualModelMacro` comment —
   deliberately empty since SE-0402).
4. Expansion bodies were extracted (awk on the `@__swiftmacro_*` delimited
   blocks), tokenized, and intersected with the declared public surface of
   `Sources/Lattice`; the emitted-string universe of
   `Sources/LatticeMacros/LatticeMacros.swift` was grepped as a belt to catch
   emission paths not exercised by fixtures (none found beyond the set below).
5. Consumer greps (Engram, Orbital, Nest, engram-server + Examples/NotesApp)
   before every Tier-2 demotion.

Non-Lattice tokens that look like support symbols but are not:
`_$observationRegistrarBox`, `_empty` (emitted BY the macros into the client
type), `_key`, `_M`, `_MR`, `_0`, `_name`, `_value` (expansion locals /
generic parameters / enum cases).

## Tier 1 — macro plumbing (public-with-underscore, SEMVER-EXEMPT, must stay public)

Referenced by macro expansions that compile in the client module. Renaming or
demoting ANY of these breaks every already-expanded consumer binary/source.
Underscore prefix + this artifact + VERSIONING.md document the exemption.

| Symbol | Declared | Referenced by |
|---|---|---|
| `Model._$observationRegistrar` (req) | Model.swift | `@Model` (iOS 17 Observation branch) |
| `Model._objectWillChange` (req) | Model.swift | `@Model` |
| `Model._objectWillChange_send()` (req) | Model.swift | `@Model` emitted accessors |
| `Model._triggerObservers_send(keyPath:)` (req) | Model.swift | `@Model` emitted accessors |
| `Model._lastKeyPathUsed` (req) | Model.swift | `@Model` |
| `Model._nameForKeyPath(_:)` (req) | Model.swift | `@Model` |
| `Model._dynamicObject` (req) | Model.swift | `@Model`, `@Property` accessors |
| `Model._instanceObservers` (req) | Model.swift | `@Model` |
| `_ModelObserver` (struct) | Model.swift | type of `_instanceObservers` |
| `Model._fireObservers(propertyName:)` | Model.swift | `@Property` emitted setters |
| `Model._notifyOtherInstances(propertyName:changedColumn:)` | Model.swift | `@Property` emitted setters |
| `Model._deregisterFromInstanceRegistry()` | Model.swift | `@Model` emitted deinit |
| `ModelStorage._default(_:)` | Accessor.swift | `@Model` emitted storage default |
| `Query._column(_:)` | Query.swift | `@Union` emitted `_makeQueryVariants` |
| `_getVirtualLink(from:named:)` | VirtualLink.swift | `@VirtualLinkProperty` accessors |
| `_setVirtualLink(on:named:_:)` | VirtualLink.swift | `@VirtualLinkProperty` accessors |
| `LatticeUnion._makeQueryVariants(parentKeyPath:)` (req) | Property/UnionProperty.swift | `@Union` conformance |
| `LatticeUnion._toCxxUnionValue()` (req) | Property/UnionProperty.swift | `@Union` conformance |
| `LatticeUnion._fromCxxUnionValue(_:)` (req) | Property/UnionProperty.swift | `@Union` conformance |
| `_LatticeUnionQueryEnum` (protocol) | Property/UnionProperty.swift | `@Union` emitted QueryEnum |
| `Detachable._detachedOptional(remainingDepth:visited:)` (req) | Detached.swift | `@Detached` expansions |
| `_detached(remainingDepth:visited:)` overload family | Detached.swift | `@Detached` expansions |
| `Model._detachKey` | Detached.swift | `@Detached` expansions |

Plus the *conventionally named* public API the expansions compile against
(already normal surface, listed so the freeze review sees the full support
set): `Property` (wrapper), `AnyProperty`, `ModelStorage`, `Constraint`,
`List`, `VirtualList`, `VirtualLinkMarker`, `DetachKey`, `Detachable` /
`DetachableLeaf` / `DetachedRef`, `LatticeUnion` / `LatticeEnum` /
`UnionCaseDescriptor`, `FloatVector`, `Query`, `ObservableObjectPublisher`
(re-export), the `Model` requirements `entityName` / `properties` /
`primaryKey` / `globalId` / `constraints` / `fullTextProperties` /
`indexedProperties`, and `SchemaProperty.defaultValue` / `getField` /
`setField`. The `@Union` path additionally spells `lattice.union_value` and
`std.string` in client code — see Tier 3.

## Tier 1b — structural public (NOT macro-referenced, but cannot be demoted)

Requirements of public protocols (a requirement cannot carry `@_spi`), types
appearing in public signatures, or symbols with live external users. Also
semver-exempt by underscore convention, but kept public for the stated reason.

| Symbol | Declared | Why it stays public |
|---|---|---|
| `LinkListable._makeLinkList(from:named:)` (req + 4 impls) | List.swift:46 | protocol requirement |
| `GeoboundsProperty._trace(keyPath:)` (req + impls) | Geobounds.swift:5 | protocol requirement |
| `Results._ladderPlaceholder()` (req + impls) | Results/Results.swift:94 | protocol requirement |
| `VirtualResults._addType(_:)` (req + impls) | Results/VirtualResults.swift:15 | protocol requirement |
| `_Query` (protocol) + `_virtualMember(_:)` | VirtualModel.swift | appears in public `where` closure signatures |
| `_VirtualQuery`, `_VirtualQueryCompat` | VirtualModel.swift | public DSL machinery in signatures |
| `_QueryNumeric`, `_QueryString`, `_QueryBinary` | Query.swift | public generic constraints on Query operators |
| `_NearestMatch` | Results/Results.swift:112 | `NearestResults.Element` in public signature |
| `Lattice._vacuumVec0(_:for:)` | Lattice.swift | consumer-used: Engram MemoryTools+Core.swift:1202/1206/1215, PerfTests.swift:285 |
| `ModelStorage._ref` | Accessor.swift:9 | reached via `_dynamicObject._ref` in 10 in-repo test sites; escape hatch to the backend |

## Tier 2 — demoted in this change (not macro-referenced, no external users)

Consumer grep = Engram, Orbital, Nest, engram-server, Examples/NotesApp: ZERO
hits for every row (verified per symbol before demotion).

| Symbol | Was | Now | In-module callers |
|---|---|---|---|
| `Query._constructForTesting()` | public | internal | none (dead test hook) |
| `Query._constructPredicate()` | public | internal | Query.swift:412, TableResults.swift:927 |
| `Query._unionSubquery(...)` | public | internal | TableResults.swift:921,928 |
| `Query._caseWhen(whens:elseResult:)` | public | internal | TableResults.swift:935 |
| `Query._unionAccessTracker` + class `_UnionAccessTracker` | public | internal | Query.swift:328, TableResults.swift:899,912 |
| `Query._unionOverrides` | public | internal | Query.swift:325, TableResults.swift:918 |
| `Lattice._isolation` | public | internal | none |
| `Model._registerIfNeeded()` | public | internal | Lattice.swift:1193,1206,1238 |
| `_ModelStorage` (enum) | public | internal | none (dead) |
| `_defaultCxxLatticeObject(_:)` | public | internal | Accessor.swift:14 |
| `_pushDefaultToStorage(_:name:value:)` | public | internal | none (dead) |
| `_UncheckedSendable` | public | `@_spi(LatticeInternals)` public | Tests/InstanceRegistryTests.swift (import updated) |

`@_spi(LatticeInternals)` is the designated SPI group name for anything that
later needs test-visible-but-not-API treatment.

## Tier 3 — C++ interop contract (documented, NOT restructured)

- `.interoperabilityMode(.Cxx)` on the `Lattice` target is a **documented 1.0
  contract**: every client target must enable C++ interoperability. This is
  structural — macro-emitted client code spells C++ types directly
  (`lattice.union_value`, `std.string`, `CxxDynamicObject` typealiases), so
  the bridge must be importable from the client module.
- `@_exported import LatticeSwiftCppBridge` / `LatticeSwiftModule`
  (Lattice.swift:8-9, Model.swift:6, LinuxWebSocket.swift:6-7) is therefore
  REQUIRED leakage, not accidental: without it `@Union`/`@Model` expansions
  would not compile in clients that only `import Lattice`. Minimizing is not
  trivially possible without restructuring interop — out of 1.0 scope.
  (`@_exported import Observation` / `Combine` in Model.swift are likewise
  load-bearing for `@Model`'s emitted Observable/ObservableObject plumbing.)
- The duplicate `@_exported` spellings across files are no-ops (same modules);
  harmless, left as-is.

## Observations (non-blocking, noted for 1.1)

- `@Codable` currently includes `@Transient` properties in `CodingKeys` /
  `init(from:)` (the `isTransient` filter did not fire in the standalone
  expansion probe) and emits `init(from decoder: Decoder)` with a bare
  existential spelling (client-side `ExistentialAny` warning). Macro-emission
  fixes are source-compatible for clients; deferred.
