// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Lattice",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Lattice",
            targets: ["Lattice"]),
        .library(name: "LatticeServerKit", targets: ["LatticeServerKit"]),
        .executable(name: "LatticeMain", targets: ["LatticeMain"])
    ],
    dependencies: [
        .package(path: "../LatticeCore"),
        .package(url: "https://github.com/apple/swift-syntax.git", from: "602.0.0"),
        .package(
          url: "https://github.com/apple/swift-collections.git",
          .upToNextMinor(from: "1.1.0") // or `.upToNextMajor
        ),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.76.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/jwt.git",    from: "4.0.0"),
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
                .product(name: "Collections", package: "swift-collections")],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(
            name: "LatticeTests",
            dependencies: [
                "Lattice",
                    .product(name: "Vapor", package: "vapor")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .target(
            name: "LatticeServerKit",
            dependencies: [
                "Lattice",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "JWT",      package: "jwt"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .executableTarget(name: "LatticeMain",
                          dependencies: ["Lattice"],
                          swiftSettings: [.interoperabilityMode(.Cxx)])
    ]
)
