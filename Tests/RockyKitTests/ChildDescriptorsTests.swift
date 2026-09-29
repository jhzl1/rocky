import Darwin
import Foundation
import Testing
@testable import RockyKit

/// Part E of M2.9: a process Rocky starts keeps none of Rocky's descriptors open (the database, each agent's ACP pipes,
/// the other terminals' pseudo-terminals), only its own 0, 1 and 2. Each test holds a canary pipe open without
/// `FD_CLOEXEC`, as the pipes and files Foundation and SwiftTerm open are, and has the child list `/dev/fd`.
@MainActor
struct ChildDescriptorsTests {
    /// "end" comes after the listing, so a pseudo-terminal's output is known to be whole.
    private static let listing = "/bin/ls -1 /dev/fd; printf end"
    /// No `.zshenv` to read in a temporary HOME: the user's could open descriptors of its own.
    private static let environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path]

    /// Both ends of a pipe, moved to 64 and up by `F_DUPFD`, which leaves `FD_CLOEXEC` off: a number the child's own
    /// listing never takes.
    private func openCanary() throws -> [Int32] {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        defer { ends.forEach { close($0) } }
        let moved = ends.map { fcntl($0, F_DUPFD, 64) }
        try #require(moved.allSatisfy { $0 >= 64 })
        return moved
    }

    /// The canary, open since before the spawn and without `FD_CLOEXEC`, must never reach the child: that is what the
    /// fix proves, and before it every child listed it. The listing must also hold the child's own 0, 1 and 2. It is not
    /// required to be exactly those and the two `ls` opens itself (0 to 4, what a `POSIX_SPAWN_CLOEXEC_DEFAULT` child
    /// lists): a descriptor another thread opens between the marking and the fork still reaches a pseudo-terminal's
    /// child (`FileDescriptors.closeAllOnExec()`), and a parallel test run opens pipes all the time, two for each git
    /// run, so an exact listing failed now and then with nothing wrong (2026-09-29).
    private func expectNothingInherited(_ list: () async throws -> [Int32]) async throws {
        let canary = try openCanary()
        defer { canary.forEach { close($0) } }
        let seen = try await list()
        #expect(!seen.contains(where: canary.contains), "the canary \(canary) reached the child, which lists \(seen)")
        #expect(Set([0, 1, 2]).isSubset(of: Set(seen)), "the child lists \(seen), without its own 0, 1 and 2")
    }

    /// The numbers of `ls -1`'s lines, from a pipe ("\n"), a pseudo-terminal ("\r\n") or one line of them (" ").
    private static func descriptors(_ output: String) -> [Int32] {
        output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }.sorted()
    }

    private func listInPseudoTerminal(_ command: PTYCommand) async throws -> [Int32] {
        let session = PTYSession(title: "descriptors", command: command)
        session.start()
        #expect(await session.waitForExit() == .exited(0))
        // Output can arrive after the exit event (`PTYSessionTests.waitForOutput`).
        let deadline = ContinuousClock.now + .seconds(3)
        while !session.outputText.hasSuffix("end"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.outputText.hasSuffix("end"))
        return Self.descriptors(session.outputText)
    }

    /// A terminal tab: a shell in SwiftTerm's pseudo-terminal (`openTerminal`, `openEmbeddedTerminal`). A task's tab is
    /// the same `PTYSession`.
    @Test func aTerminalKeepsNoneOfRockysDescriptors() async throws {
        let command = PTYCommand(
            executable: "/bin/sh",
            arguments: ["-c", Self.listing],
            environment: Self.environment,
            cwd: FileManager.default.temporaryDirectory
        )
        try await expectNothingInherited { try await listInPseudoTerminal(command) }
    }

    /// A Setup, Run or Archive script: `/bin/zsh -c` in a pseudo-terminal.
    @Test func aScriptKeepsNoneOfRockysDescriptors() async throws {
        let command = PTYCommand.script(Self.listing, environment: Self.environment, cwd: FileManager.default.temporaryDirectory)
        try await expectNothingInherited { try await listInPseudoTerminal(command) }
    }

    /// git, gh and the other commands of `ProcessRunner`: `run` and `stream` (a hook's output), through Foundation's
    /// `Process`.
    @Test func gitKeepsNoneOfRockysDescriptors() async throws {
        let ls = URL(fileURLWithPath: "/bin/ls")
        try await expectNothingInherited {
            Self.descriptors(try await Task.blocking { try ProcessRunner.run(ls, ["-1", "/dev/fd"]) }.value)
        }
        try await expectNothingInherited {
            let output = try await Task.blocking { () throws -> String in
                var data = Data()
                _ = try ProcessRunner.stream(ls, ["-1", "/dev/fd"]) { data.append($0) }
                return String(decoding: data, as: UTF8.self)
            }.value
            return Self.descriptors(output)
        }
    }

    /// An agent: `ACPConnection`'s process, whose answer to `initialize` is the listing of what it inherited.
    @Test func anAgentKeepsNoneOfRockysDescriptors() async throws {
        let agent = #"read -r _; printf '{"jsonrpc":"2.0","id":1,"result":{"fds":"%s"}}\n' "$(/bin/ls -1 /dev/fd | /usr/bin/tr '\n' ' ')""#
        try await expectNothingInherited {
            let connection = try ACPConnection(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", agent],
                environment: Self.environment,
                cwd: FileManager.default.temporaryDirectory,
                stderrLog: Fixtures.stderrLog()
            )
            try await connection.start()
            let answer = try await connection.call("initialize", [:])
            await connection.terminate()
            return Self.descriptors(answer["fds"]?.stringValue ?? "")
        }
    }
}
