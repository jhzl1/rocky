import Foundation
import ACPProbeCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fake-agent.sh")

private func connect(mode: String, environment: [String: String] = [:]) throws -> ACPConnection {
    var env = ProcessInfo.processInfo.environment
    env.merge(environment) { _, new in new }
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("fake-agent-\(UUID()).log")
    return try ACPConnection(command: ["bash", fixture.path, mode], environment: env,
                             cwd: FileManager.default.temporaryDirectory, stderrLog: log)
}

func runACPConnectionTests() {
    test("testCallSkipsNoiseHandlesNotificationAndAnswersPermission") {
        let connection = try connect(mode: "ok")
        defer { connection.terminate() }
        var notifications: [String] = []
        connection.onNotification = { method, _ in notifications.append(method) }
        var requestedMethod: String?
        connection.onRequest = { method, _ in
            requestedMethod = method
            return ["outcome": ["outcome": "selected", "optionId": "allow"]]
        }

        let result = try connection.call("initialize", ["protocolVersion": 1])

        check(requestedMethod == "session/request_permission", "onRequest method should be session/request_permission")
        check(notifications == ["session/update"], "notifications should be [session/update]")
        check(connection.skippedLines == ["fake-agent booting"], "skippedLines should be [fake-agent booting]")
        let echo = result["echo"] as? JSONObject
        check(echo?["id"] as? String == "p1", "echo id should be p1")
        let outcome = (echo?["result"] as? JSONObject)?["outcome"] as? JSONObject
        check(outcome?["optionId"] as? String == "allow", "outcome optionId should be allow")
    }

    test("testCallThrowsAgentExitedWithStderrInsteadOfHanging") {
        let connection = try connect(mode: "exit")
        do {
            _ = try connection.call("initialize", [:])
            check(false, "expected call to throw agentExited")
        } catch ACPConnectionError.agentExited(let status, let stderr) {
            check(status == 3, "exit status should be 3")
            check(stderr.contains("missing credentials"), "stderr should contain missing credentials")
        } catch {
            check(false, "expected agentExited, got \(error)")
        }
    }

    test("testEnvironmentReachesAgentProcess") {
        let connection = try connect(mode: "env", environment: ["ROCKY_PROBE": "probe-123"])
        defer { connection.terminate() }
        let result = try connection.call("initialize", [:])
        check(result["probe"] as? String == "probe-123", "probe should be probe-123")
    }
}
