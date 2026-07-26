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
        .package(url: "https://github.com/jsflax/LatticeCore.git", from: "1.0.1"),
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
                    .product(name: "Vapor", package: "vapor")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
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
