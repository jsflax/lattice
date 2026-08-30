// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Lattice",
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Lattice",
            targets: ["Lattice"]),
        .library(name: "LatticeServerKit", targets: ["LatticeServerKit"]),
        .library(name: "LatticeMCP", targets: ["LatticeMCP"]),
        .executable(name: "LatticeMain", targets: ["LatticeMain"]),
        .executable(name: "lattice-mcp", targets: ["lattice-mcp"]),
    ],
    dependencies: [
        // Versioned so lattice tags are consumable via `from:` (SwiftPM forbids
        // unversioned deps inside version-required packages). For the two-repo
        // dev loop use an UNCOMMITTED override:
        //   swift package edit LatticeCore --path ../LatticeCore
        // (or drag the local LatticeCore package into the Xcode workspace).
        // 0.10.4 floor is required: materialized reads consume the row-cache
        // bridge APIs introduced there.
        // 1.3.0 floor was REQUIRED, not preferred: the bridge's sync-progress
        // callback gained a sync_id parameter there, and this wrapper passes
        // a 6-argument @convention(c) closure. Pairing this wrapper with an
        // older core fails to compile deep inside a consumer's build with a
        // closure-arity error that names neither package (it bit
        // engram-server within minutes of the 1.3.0 tag). The floor makes
        // SwiftPM refuse the bad pair instead.
        // 1.4.0 floor (0.14.2 wave): raised for COHERENCE, not compilation.
        // This wrapper's observer/relay fixes are one half of a fix set whose
        // other half — upload floors that can pin forever, redundant applies
        // minting audit rows, apply-loop logging that cost 11-20s per frame —
        // lives in the core. A consumer resolving 1.6.x against a 1.3.x core
        // would get a partially-fixed fleet with no error to explain why.
        // 1.4.2 floor (0.14.3 hotfix): same coherence rule. This wrapper's
        // keeper-interlock fix pairs with the core's begin_transaction
        // busy-timeout fix, vec0 reconcile idempotence, and apply-chunk ack
        // survival — a 1.6.2 wrapper on a 1.4.1 core would still livelock
        // IPC sync under the vec0 storm it claims to have fixed.
        .package(url: "https://github.com/jsflax/LatticeCore.git", from: "1.4.2"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(
          url: "https://github.com/apple/swift-collections.git",
          .upToNextMinor(from: "1.1.0") // or `.upToNextMajor
        ),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.76.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.0"),
        // Docs-time only: enables `swift package generate-documentation` over
        // the catalog at Sources/Lattice/Lattice.docc (and the docs.yml Pages
        // deploy). No target depends on it; it adds nothing to consumer builds.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .macro(
            name: "LatticeMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "Lattice",
            dependencies: ["LatticeMacros",
                .product(name: "LatticeSwiftCppBridge", package: "LatticeCore"),
                .product(name: "LatticeSwiftModule", package: "LatticeCore"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "WebSocketKit", package: "websocket-kit", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .linkedLibrary("FoundationInternationalization", .when(platforms: [.linux])),
            ]),
        .testTarget(
            name: "LatticeTests",
            dependencies: [
                "Lattice",
                "LatticeMCP",
                "LatticeServerKit",
                "WalEpochWriterChild",
                    .product(name: "Vapor", package: "vapor")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // Child-process writer for the WAL-epoch forensics harness
        // (Tests/LatticeTests/SyncTests/WalEpochForensicsTests.swift): kill -9
        // semantics need a real separate process holding a relay-shaped handle.
        // Test-only support; not a shipped product.
        .executableTarget(
            name: "WalEpochWriterChild",
            dependencies: ["Lattice"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        // Cross-SDK conformance runner (plan WS-C item C4a): interprets the
        // declarative corpus in latticecore/conformance/corpus against the
        // public Lattice API. Skips gracefully when the corpus checkout is
        // absent (LATTICE_CONFORMANCE_DIR overrides the default sibling path).
        .testTarget(
            name: "LatticeConformanceTests",
            dependencies: ["Lattice"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .target(
            name: "LatticeServerKit",
            dependencies: [
                "Lattice",
                .product(name: "Vapor", package: "vapor"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .executableTarget(name: "LatticeMain",
                          dependencies: ["Lattice"],
                          swiftSettings: [.interoperabilityMode(.Cxx)]),
        // Generic, file-agnostic MCP query server over the dynamic Lattice API.
        // LatticeMCP owns the Lattice/C++ boundary (Cxx interop); the executable
        // shell imports the MCP SDK WITHOUT Cxx interop so the SDK's dependency
        // graph (EventSource/swift-numerics) compiles normally.
        .target(name: "LatticeMCP",
                dependencies: ["Lattice"],
                swiftSettings: [.interoperabilityMode(.Cxx)]),
        .executableTarget(name: "lattice-mcp",
                          dependencies: [
                            "LatticeMCP",
                            .product(name: "MCP", package: "swift-sdk"),
                          ],
                          swiftSettings: [.interoperabilityMode(.Cxx)])
    ]
)
