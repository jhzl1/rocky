// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rocky",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Rocky", targets: ["Rocky"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "RockyKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "RockyUI", dependencies: ["RockyKit"]),
        .executableTarget(name: "Rocky", dependencies: ["RockyKit", "RockyUI"]),
        .testTarget(name: "RockyKitTests", dependencies: ["RockyKit"], resources: [.copy("Fixtures")]),
    ]
)
