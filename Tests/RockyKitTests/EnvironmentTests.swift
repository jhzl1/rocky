import Foundation
import Testing
@testable import RockyKit

@Suite(.blockingWork)
struct EnvironmentTests {
    @Test func parseIgnoresShellNoiseBeforeTheMarker() {
        var output = Data("Last login: Tue\nwelcome to oh-my-zsh\n".utf8)
        output += Data([0]) + Data(LoginEnvironment.marker.utf8) + Data([0])
        output += Data("PATH=/opt/homebrew/bin:/usr/bin\0HOME=/Users/me\0EMPTY=\0".utf8)
        #expect(LoginEnvironment.parse(output) == ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/me", "EMPTY": ""])
    }

    @Test func parseKeepsEqualsSignsAndNewlinesInsideValues() {
        var output = Data([0]) + Data(LoginEnvironment.marker.utf8) + Data([0])
        output += Data("OPTS=a=b=c\0MULTI=line1\nline2\0".utf8)
        #expect(LoginEnvironment.parse(output) == ["OPTS": "a=b=c", "MULTI": "line1\nline2"])
    }

    @Test func parseReturnsEmptyWithoutMarker() {
        #expect(LoginEnvironment.parse(Data("PATH=/usr/bin\0".utf8)).isEmpty)
    }

    @Test func captureReadsARealShell() throws {
        let environment = try LoginEnvironment.capture(
            shell: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo noise; printf '\\0\(LoginEnvironment.marker)\\0'; env -0"]
        )
        #expect(environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
        #expect(environment["TERM"] == "dumb")
    }

    @Test func captureTimesOutOnAHangingShell() {
        #expect(throws: LoginEnvironmentError.timedOut) {
            try LoginEnvironment.capture(shell: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.5)
        }
    }

    @Test func workspaceEnvironmentNeverInheritsClaudeConfigDir() {
        let login = ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-celes", "SHLVL": "2"]
        #expect(WorkspaceEnvironment.make(login: login, claudeConfigDir: nil) == ["PATH": "/usr/bin"])
        #expect(WorkspaceEnvironment.make(login: login, claudeConfigDir: "/Users/me/.claude-rentek")
            == ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-rentek"])
    }

    @Test func detectsClaudeInstancesWithSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        for name in [".claude", ".claude-celes", ".claude-empty", ".config"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in [".claude", ".claude-celes"] {
            FileManager.default.createFile(atPath: home.appendingPathComponent("\(name)/settings.json").path, contents: Data("{}".utf8))
        }
        #expect(ClaudeInstances.detect(home: home) == [home.appendingPathComponent(".claude").path, home.appendingPathComponent(".claude-celes").path])
    }

    @Test func processRunnerReturnsTrimmedStdoutAndThrowsOnFailure() throws {
        #expect(try ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hello"]) == "hello")
        #expect(throws: ProcessFailure.self) {
            try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo boom >&2; exit 4"])
        }
    }

    @Test func processRunnerDoesNotDeadlockOnLargeStderr() throws {
        let output = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo done"])
        #expect(output == "done")
    }
}
