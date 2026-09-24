// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rocky",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Rocky", targets: ["Rocky"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0"),
    ],
    targets: [
        .target(name: "RockyKit", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .target(
            name: "RockyUI",
            dependencies: [
                "RockyKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Textual", package: "textual"),
            ],
            // Claude, OpenCode, GitHub and Vercel logos, from Simple Icons (simpleicons.org, CC0); the git glyphs
            // (git-branch, git-pull-request, git-merge) are the design's own strokes. Prism 1.30.0 (MIT), the syntax
            // highlighter of the diff and the editor (DIFF-04; version and license in README.md).
            resources: [.copy("Resources/Icons"), .copy("Resources/Prism")]
        ),
        .executableTarget(name: "Rocky", dependencies: ["RockyKit", "RockyUI"]),
        .testTarget(
            name: "RockyKitTests",
            dependencies: ["RockyKit", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
