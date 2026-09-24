import Foundation
import Testing
@testable import RockyKit

@MainActor
struct AgentVersionsTests {
    private func install(_ kind: AgentKind, version: String, in prefix: URL) throws {
        let package = prefix.appendingPathComponent("node_modules/\(AgentLauncher.package(for: kind))/package.json")
        try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"x","version":"\#(version)"}"#.utf8).write(to: package)
    }

    @Test func comparesVersionsByTheirNumbers() {
        #expect(SemanticVersion.isNewer("0.81.1", than: "0.81.0"))
        #expect(SemanticVersion.isNewer("1.18.32", than: "1.18.4"))
        #expect(SemanticVersion.isNewer("2.0", than: "1.99.99"))
        #expect(!SemanticVersion.isNewer("1.18.32", than: "1.18.32"))
        #expect(!SemanticVersion.isNewer("1.18.32-beta.1", than: "1.18.32"))
        #expect(AgentVersion(installed: "0.81.0", latest: "0.81.1", tested: "0.81.0").updateAvailable)
        #expect(!AgentVersion(installed: nil, latest: "0.81.1", tested: "0.81.0").updateAvailable)
    }

    @Test func readsTheInstalledVersionAndReinstallsAnOlderOne() throws {
        let prefix = try Fixtures.temporaryDirectory("agents")
        #expect(AgentLauncher.installedVersion(.opencode, prefix: prefix) == nil)
        try install(.opencode, version: "1.0.0", in: prefix)
        #expect(AgentLauncher.installedVersion(.opencode, prefix: prefix) == "1.0.0")
        #expect(AgentLauncher.isOlderThanTested(.opencode, prefix: prefix))
        try install(.opencode, version: "99.0.0", in: prefix)
        // Updated from the settings past the tested version: kept.
        #expect(!AgentLauncher.isOlderThanTested(.opencode, prefix: prefix))
    }

    @Test func checksNpmAtMostOnceADayUnlessForcedAndUpdatesOnRequest() async throws {
        let root = try Fixtures.temporaryDirectory("app")
        let paths = RockyPaths(database: root.appendingPathComponent("rocky.sqlite"), adapterPrefix: root.appendingPathComponent("agents"), logs: root)
        try install(.claude, version: AgentLauncher.claudeAdapterVersion, in: paths.adapterPrefix)
        let calls = Counter()
        let installs = Recorder<String>()
        let model = AppModel(
            store: try RockyStore.inMemory(),
            paths: paths,
            captureEnvironment: { [:] },
            installAdapter: { kind, version, _, _ in
                Task { await installs.append("\(kind.rawValue)@\(version ?? "tested")") }
            },
            latestVersion: { package in
                await calls.increment()
                return package == AgentLauncher.claudeAdapterPackage ? "99.0.0" : AgentLauncher.openCodeVersion
            },
            defaults: UserDefaults(suiteName: "rocky-tests-\(UUID().uuidString)")!
        )

        await model.checkAgentUpdates()
        #expect(model.agentVersions[.claude]?.installed == AgentLauncher.claudeAdapterVersion)
        #expect(model.agentVersions[.claude]?.latest == "99.0.0")
        #expect(model.agentVersions[.claude]?.updateAvailable == true)
        #expect(model.agentVersions[.opencode]?.installed == nil)
        #expect(await calls.value == 2)

        await model.checkAgentUpdates()
        #expect(await calls.value == 2)
        await model.checkAgentUpdates(force: true)
        #expect(await calls.value == 4)

        await model.updateAgent(.claude)
        await model.updateAgent(.claude, toTested: true)
        for _ in 0..<100 where await installs.values.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await installs.values == ["claude@99.0.0", "claude@\(AgentLauncher.claudeAdapterVersion)"])
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
