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

    /// Rocky's own OpenCode, with its own data folder: never the one on the PATH, never the shared data.
    @Test func opencodeRunsRockysCopyWithItsOwnData() throws {
        let root = try Fixtures.temporaryDirectory("rocky")
        let prefix = root.appendingPathComponent("agents")
        let bin = try Fixtures.temporaryDirectory("bin")
        try makeExecutable("opencode", in: bin)
        let cwd = URL(fileURLWithPath: "/tmp/ws")
        #expect(throws: AgentLauncherError.adapterNotInstalled(.opencode)) {
            try AgentLauncher.launch(.opencode, cwd: cwd, environment: ["PATH": bin.path], adapterPrefix: prefix, logsDirectory: bin)
        }
        let binary = AgentLauncher.openCodeBinary(prefix: prefix)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeExecutable(binary.lastPathComponent, in: binary.deletingLastPathComponent())

        let launch = try AgentLauncher.launch(.opencode, cwd: cwd, environment: ["PATH": bin.path], adapterPrefix: prefix, logsDirectory: bin)
        #expect(launch.executable == binary)
        #expect(launch.arguments == ["acp"])
        #expect(launch.cwd == cwd)
        #expect(launch.environment["XDG_DATA_HOME"] == root.appendingPathComponent("opencode-data").path)
    }

    @Test func copiesTheOpenCodeLoginOnceAndPrivately() throws {
        let shared = try Fixtures.temporaryDirectory("shared")
        let dataHome = try Fixtures.temporaryDirectory("rocky-data")
        let login = shared.appendingPathComponent("opencode/auth.json")
        try FileManager.default.createDirectory(at: login.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"anthropic":{"key":"k1"}}"#.utf8).write(to: login)

        AgentLauncher.copyOpenCodeLogin(into: dataHome, environment: ["XDG_DATA_HOME": shared.path])
        let copy = dataHome.appendingPathComponent("opencode/auth.json")
        #expect(try String(contentsOf: copy, encoding: .utf8) == #"{"anthropic":{"key":"k1"}}"#)
        #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)

        // Once: a later change of the shared login does not overwrite Rocky's.
        try Data(#"{"anthropic":{"key":"k2"}}"#.utf8).write(to: login)
        AgentLauncher.copyOpenCodeLogin(into: dataHome, environment: ["XDG_DATA_HOME": shared.path])
        #expect(try String(contentsOf: copy, encoding: .utf8) == #"{"anthropic":{"key":"k1"}}"#)
    }

    @Test func claudeNeedsNodeAndTheInstalledAdapter() throws {
        let bin = try Fixtures.temporaryDirectory("bin")
        let prefix = try Fixtures.temporaryDirectory("agents")
        #expect(throws: AgentLauncherError.executableNotFound("node")) {
            try AgentLauncher.launch(.claude, cwd: bin, environment: ["PATH": bin.path], adapterPrefix: prefix, logsDirectory: bin)
        }
        try makeExecutable("node", in: bin)
        #expect(throws: AgentLauncherError.adapterNotInstalled(.claude)) {
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
