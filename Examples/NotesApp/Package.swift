// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "NotesApp",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .executable(name: "NotesApp", targets: ["NotesApp"])
    ],
    dependencies: [
        .package(path: "../.."),  // Lattice
    ],
    targets: [
        .executableTarget(
            name: "NotesApp",
            dependencies: [
                .product(name: "Lattice", package: "Lattice")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)
