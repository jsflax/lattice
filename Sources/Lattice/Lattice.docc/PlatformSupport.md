# Platform Support

Support tiers, deployment floors, and toolchain requirements.

## Support tiers

| Tier | Platforms | Guarantee |
|------|-----------|-----------|
| 1 | macOS 14+, iOS 15+, Linux (Ubuntu 24.04+) | Built and tested. macOS and Linux run the full test suite in CI on every push; iOS is built for the simulator in CI (tests require a host app and run via the macOS suite). |
| 2 | tvOS, watchOS | Compile-only. Expected to build; not exercised in CI and not covered by the release gate. |

## Toolchain

- Swift 6.3+ toolchain (`swift-tools-version: 6.3`) — an older toolchain
  refuses the manifest at parse time.
- Xcode with a Swift 6.3 toolchain on Apple platforms.
- On Linux, install `libsqlite3-dev` before building.

## Deployment floors

- iOS 15.0
- macOS 14.0
- Linux: Ubuntu 24.04+ (the CI reference image is `swift:6.3-noble`)

## iOS 15/16 notes

The deployment floor is iOS 15. The full API surface is available on every
supported platform; three *convenience spellings* use variadic generics or
`SortDescriptor.keyPath` and therefore require iOS 17+, each with a
portable equivalent that works from iOS 15:

| iOS 17+ convenience | iOS 15+ portable equivalent |
|---|---|
| `Lattice(A.self, B.self, …)` beyond 6 model types (parameter packs) | Fixed-arity overloads up to 6 types, or `Lattice(for: [A.self, B.self, …])` |
| `Migration((from: V1.self, to: V2.self), blocks: …)` (parameter packs) | `Migration().add(from: V1.self, to: V2.self) { old, new in … }` |
| `sortedBy(SortDescriptor(\.age, order: .forward))` | `sortedBy(\.age, order: .forward)` |

A small amount of surface is additionally gated by OS capability: the geo
subsystem and `LatticeUnion` field accessors require iOS 16.4+.
