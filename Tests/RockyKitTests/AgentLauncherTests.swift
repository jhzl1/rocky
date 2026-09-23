import Foundation
import Testing
@testable import RockyKit

struct AgentLauncherTests {
    private func makeExecutable(_ name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func resolveFindsFirstExecutableOnPath() throws {
        let first = try Fixtures.temporaryDirectory("bin1")
        let second = try Fixtures.temporaryDirectory("bin2")
        try makeExecutable("opencode", in: second)
        #expect(AgentLauncher.resolve("opencode", path: "\(first.path):\(second.path)") == second.appendingPathComponent("opencode"))
        #expect(AgentLauncher.resolve("opencode", path: first.path) == nil)
        #expect(AgentLauncher.resolve("opencode", path: nil) == nil)
    }

    @Test func opencodeLaunchesWithAcpSubcommand() throws {
        let bin = try Fixtures.temporaryDirectory("bin")
        try makeExecutable("opencode", in: bin)
        let cwd = URL(fileURLWithPath: "/tmp/ws")
        let launch = try AgentLauncher.launch(.opencode, cwd: cwd, environment: ["PATH": bin.path], adapterPrefix: bin, logsDirectory: bin)
        #expect(launch.executable == bin.appendingPathComponent("opencode"))
        #expect(launch.arguments == ["acp"])
        #expect(launch.cwd == cwd)
    }

    @Test func claudeNeedsNodeAndTheInstalledAdapter() throws {
        let bin = try Fixtures.temporaryDirectory("bin")
        let prefix = try Fixtures.temporaryDirectory("agents")
        #expect(throws: AgentLauncherError.executableNotFound("node")) {
            try AgentLauncher.launch(.claude, cwd: bin, environment: ["PATH": bin.path], adapterPrefix: prefix, logsDirectory: bin)
        }
        try makeExecutable("node", in: bin)
        #expect(throws: AgentLauncherError.adapterNotInstalled) {
            try AgentLauncher.launch(.claude, cwd: bin, environment: ["PATH": bin.path], adapterPrefix: prefix, logsDirectory: bin)
        }
        let script = AgentLauncher.claudeAdapterScript(prefix: prefix)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: script.path, contents: Data())
        let launch = try AgentLauncher.launch(.claude, cwd: bin, environment: ["PATH": bin.path], adapterPrefix: prefix, logsDirectory: bin)
        #expect(launch.executable == bin.appendingPathComponent("node"))
        #expect(launch.arguments == [script.path])
    }
}
