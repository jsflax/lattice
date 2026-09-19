// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "LatticeReleaseConsumer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ReleaseConsumer", targets: ["ReleaseConsumer"])],
    dependencies: [
        .package(url: "https://github.com/jsflax/lattice.git", exact: "2.0.0"),
        // Constrain the exact released pair; no target imports Core directly.
        .package(url: "https://github.com/jsflax/LatticeCore.git", exact: "2.0.6"),
    ],
    targets: [
        .executableTarget(
            name: "ReleaseConsumer",
            dependencies: [.product(name: "Lattice", package: "lattice")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ]
)
