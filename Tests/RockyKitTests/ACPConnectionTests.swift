import Foundation
import Testing
@testable import RockyKit

struct ACPConnectionTests {
    private func connect(_ mode: String, environment: [String: String] = [:]) throws -> ACPConnection {
        let env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        return try ACPConnection(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [Fixtures.url("fake-agent").path, mode],
            environment: env,
            cwd: FileManager.default.temporaryDirectory,
            stderrLog: Fixtures.stderrLog()
        )
    }

    @Test func skipsNoiseDeliversNotificationsAndAnswersPermissionWithoutDeadlock() async throws {
        let connection = try connect("ok")
        let notifications = Recorder<ACPNotification>()
        let requests = Recorder<String>()
        await connection.setHandlers(ACPHandlers(
            onNotification: { await notifications.append($0) },
            onRequest: { method, _ in
                await requests.append(method)
                return ["outcome": ["outcome": "selected", "optionId": "allow"]]
            }
        ))
        try await connection.start()

        let result = try await connection.call("initialize", ["protocolVersion": 1])

        #expect(await requests.values == ["session/request_permission"])
        #expect(await notifications.values == [ACPNotification(method: "session/update", params: ["text": "a\u{2028}b"])])
        #expect(await connection.skippedLines == ["fake-agent booting"])
        #expect(result["echo"]?["id"] == "p1")
        #expect(result["echo"]?["result"]?["outcome"]?["optionId"] == "allow")
        await connection.terminate()
    }

    @Test func agentExitFailsPendingAndLaterCallsWithStderrTail() async throws {
        let connection = try connect("exit")
        let exits = Recorder<ACPConnectionError>()
        await connection.setHandlers(ACPHandlers(onExit: { await exits.append($0) }))
        try await connection.start()

        await #expect(throws: ACPConnectionError.self) { try await connection.call("initialize", [:]) }
        do {
            _ = try await connection.call("session/new", [:])
            Issue.record("expected the second call to throw")
        } catch let ACPConnectionError.agentExited(status, stderrTail) {
            #expect(status == 3)
            #expect(stderrTail.contains("missing credentials"))
        }
        #expect(await exits.values.count == 1)
    }

    @Test func rpcErrorIsThrownAsRpc() async throws {
        let connection = try connect("error")
        try await connection.start()
        await #expect(throws: ACPConnectionError.rpc(code: -32000, message: "Authentication required")) {
            try await connection.call("session/new", [:])
        }
        await connection.terminate()
    }

    @Test func environmentReachesTheAgentProcess() async throws {
        let connection = try connect("env", environment: ["ROCKY_PROBE": "probe-123"])
        try await connection.start()
        #expect(try await connection.call("initialize", [:])["probe"] == "probe-123")
        await connection.terminate()
    }

    /// With `FileHandle.bytes`, an idle agent's blocked read held Foundation's one shared read queue, so a second
    /// agent's answer was never read (a new conversation stuck on "Starting…").
    @Test func anIdleAgentDoesNotBlockAnotherAgentsReplies() async throws {
        let idle = try connect("env")   // started and never sent anything: it waits silently
        try await idle.start()
        try await Task.sleep(for: .milliseconds(200))
        let other = try connect("env", environment: ["ROCKY_PROBE": "second"])
        try await other.start()

        let replies = Recorder<JSONValue>()
        Task {
            if let reply = try? await other.call("initialize", [:]) { await replies.append(reply) }
        }
        for _ in 0..<300 where await replies.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await replies.values.first?["probe"] == "second")
        await idle.terminate()
        await other.terminate()
    }
}
