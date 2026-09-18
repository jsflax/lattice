// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "FilterProbe",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [.testTarget(name: "FilterProbeTests")]
)
