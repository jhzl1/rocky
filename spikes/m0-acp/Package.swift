// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "m0-acp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ACPProbeCore"),
        .executableTarget(name: "rocky-probe", dependencies: ["ACPProbeCore"]),
        .executableTarget(name: "acp-probe-tests", dependencies: ["ACPProbeCore"], path: "Tests/ACPProbeCoreTests", exclude: ["Fixtures"]),
    ]
)
