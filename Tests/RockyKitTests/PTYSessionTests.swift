import Darwin
import Foundation
import Testing
@testable import RockyKit

@MainActor
struct PTYSessionTests {
    private func session(
        _ script: String,
        environment: [String: String] = [:],
        cwd: URL = FileManager.default.temporaryDirectory,
        grace: Duration = .seconds(5),
        maxOutputBytes: Int = 2_000_000
    ) -> PTYSession {
        let merged = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        return PTYSession(
            title: "test",
            command: .script(script, environment: merged, cwd: cwd),
            stopGracePeriod: grace,
            maxOutputBytes: maxOutputBytes
        )
    }

    /// Output can arrive after the exit event: LocalProcess has no end-of-output callback. Up to 3 s by the clock; it
    /// returns as soon as the text is there. Output that never came in a full run was not late but lost: see
    /// `BlockingWorkExecutor` (2026-09-24).
    private func waitForOutput(_ session: PTYSession, containing text: String) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !session.outputText.contains(text), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.outputText.contains(text))
    }

    @Test func decodesWaitStatus() {
        #expect(PTYState(waitStatus: 3 << 8) == .exited(3))
        #expect(PTYState(waitStatus: 0) == .exited(0))
        #expect(PTYState(waitStatus: SIGKILL) == .signaled(SIGKILL))
    }

    /// SwiftUI built two views of one terminal and dismantled the second: the one on screen stayed blank.
    @Test func dismantlingOneViewKeepsTheOtherFed() async throws {
        let pty = session("sleep 0.3; printf 'late output'")
        var first: [UInt8] = []
        _ = pty.attach(UUID()) { first.append(contentsOf: $0) }
        let second = UUID()
        _ = pty.attach(second) { _ in }
        pty.detach(second)
        pty.start()
        _ = await pty.waitForExit()
        try await waitForOutput(pty, containing: "late output")
        #expect(String(decoding: first, as: UTF8.self).contains("late output"))
    }

    /// TERM-03: what Rocky stopped reads "stopped", even when the script catches the signal and exits with a code.
    @Test func stopRecordsThatRockyAskedForIt() async throws {
        let caught = session("trap 'exit 143' TERM; while true; do sleep 0.1; done")
        caught.start()
        try await Task.sleep(for: .milliseconds(200))
        await caught.stop()
        #expect(caught.stopRequested)
        #expect(caught.state == .exited(143))

        let finished = session("exit 0")
        finished.start()
        _ = await finished.waitForExit()
        #expect(!finished.stopRequested)
    }

    @Test func runsAScriptAndReportsItsExitCode() async throws {
        let pty = session("printf 'hi from pty'; exit 3")
        pty.start()
        #expect(await pty.waitForExit() == .exited(3))
        try await waitForOutput(pty, containing: "hi from pty")
    }

    @Test func passesEnvironmentWorkingDirectoryAndARealTerm() async throws {
        let cwd = try Fixtures.temporaryDirectory("pty")
        // zsh reports the physical path (/private/var/…); resolvingSymlinksInPath() strips the /private prefix.
        let pointer = try #require(realpath(cwd.path, nil))
        let physicalCwd = String(cString: pointer)
        free(pointer)
        let pty = session(#"printf '%s|%s|%s' "$ROCKY_PROBE" "$PWD" "$TERM""#, environment: ["ROCKY_PROBE": "probe-7", "TERM": "dumb"], cwd: cwd)
        pty.start()
        #expect(await pty.waitForExit() == .exited(0))
        try await waitForOutput(pty, containing: "probe-7|\(physicalCwd)|xterm-256color")
    }

    @Test func inputReachesTheProcess() async throws {
        let pty = session(#"read line; printf 'got:%s' "$line""#)
        pty.start()
        pty.send("abc\n")
        #expect(await pty.waitForExit() == .exited(0))
        try await waitForOutput(pty, containing: "got:abc")
    }

    @Test func stopEndsTheWholeProcessGroup() async throws {
        let pty = session("sleep 30 & printf 'child:%s;' $!; wait")
        pty.start()
        try await waitForOutput(pty, containing: ";")
        let text = try #require(pty.outputText.components(separatedBy: "child:").last?.components(separatedBy: ";").first)
        let child = try #require(pid_t(text))

        await pty.stop()
        #expect(pty.state == .signaled(SIGTERM))
        var alive = true
        for _ in 0..<200 where alive {
            alive = kill(child, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(!alive)
    }

    /// Right after `start()` the child has not made its process group yet; the Stop still sends SIGTERM.
    @Test func stopRightAfterStartSendsTERM() async {
        let pty = session("sleep 30")
        pty.start()
        await pty.stop()
        #expect(pty.state == .signaled(SIGTERM))
    }

    @Test func stopEscalatesToSIGKILLWhenTERMIsIgnored() async throws {
        let pty = session("trap '' TERM; printf ready; sleep 30", grace: .milliseconds(300))
        pty.start()
        try await waitForOutput(pty, containing: "ready")
        await pty.stop()
        #expect(pty.state == .signaled(SIGKILL))
    }

    @Test func keepsOnlyTheLastOutputBytes() async throws {
        let pty = session("head -c 5000 /dev/zero | tr '\\0' x; printf END", maxOutputBytes: 1000)
        pty.start()
        #expect(await pty.waitForExit() == .exited(0))
        try await waitForOutput(pty, containing: "END")
        #expect(pty.output.count == 1000)
        #expect(pty.outputText.hasSuffix("END"))
    }

    @Test func missingExecutableExitsWith127() async {
        let pty = PTYSession(
            title: "missing",
            command: PTYCommand(executable: "/nonexistent/tool", arguments: [], environment: [:], cwd: FileManager.default.temporaryDirectory)
        )
        pty.start()
        #expect(await pty.waitForExit() == .exited(127))
    }
}
