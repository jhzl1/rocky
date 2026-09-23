import ACPProbeCore
import Foundation

let agents: [String: [String]] = [
    "claude": ["npx", "-y", "@agentclientprotocol/claude-agent-acp@0.81.0"],
    "codex": ["npx", "-y", "@agentclientprotocol/codex-acp@1.13.0"],
    "opencode": ["opencode", "acp"],
]

func probe(agent: String, command: [String], workdir: URL) throws {
    let probeValue = "rocky-\(UUID().uuidString.prefix(8))"
    var environment = ProcessInfo.processInfo.environment
    environment["ROCKY_PROBE"] = probeValue
    let stderrLog = FileManager.default.temporaryDirectory.appendingPathComponent("rocky-probe-\(agent).log")
    let connection = try ACPConnection(command: command, environment: environment, cwd: workdir, stderrLog: stderrLog)
    defer { connection.terminate() }

    var agentText = ""
    var toolUpdates: [String] = []
    connection.onNotification = { method, params in
        guard method == "session/update", let update = params["update"] as? JSONObject,
              let kind = update["sessionUpdate"] as? String else { return }
        if kind == "agent_message_chunk", let content = update["content"] as? JSONObject,
           let text = content["text"] as? String {
            agentText += text
        }
        if kind.hasPrefix("tool_call"), let data = try? JSONSerialization.data(withJSONObject: update) {
            toolUpdates.append(String(decoding: data, as: UTF8.self))
        }
    }
    connection.onRequest = { method, params in
        guard method == "session/request_permission", let options = params["options"] as? [JSONObject] else {
            return [:]
        }
        let allow = options.first { ($0["kind"] as? String)?.hasPrefix("allow") == true } ?? options.first
        return ["outcome": ["outcome": "selected", "optionId": allow?["optionId"] ?? ""]]
    }

    let initResult = try connection.call("initialize", [
        "protocolVersion": 1,
        "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
    ])
    let capabilities = initResult["agentCapabilities"] as? JSONObject ?? [:]
    print("loadSession:", capabilities["loadSession"] as? Bool ?? false)
    print("authMethods:", initResult["authMethods"] ?? [])

    let session = try connection.call("session/new", ["cwd": workdir.path, "mcpServers": []])
    guard let sessionID = session["sessionId"] as? String else {
        print("no sessionId in:", session)
        return
    }
    let prompt = "Run this exact shell command and reply with only its output: printenv ROCKY_PROBE"
    let result = try connection.call("session/prompt", [
        "sessionId": sessionID,
        "prompt": [["type": "text", "text": prompt]],
    ])
    print("stopReason:", result["stopReason"] ?? "none")
    print("agentText:", agentText)
    let reached = agentText.contains(probeValue) || toolUpdates.contains { $0.contains(probeValue) }
    print("envReachedTools:", reached, "(expected \(probeValue))")
    print("skippedStdoutLines:", connection.skippedLines.count, "stderrLog:", stderrLog.path)
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let command = agents[arguments[1]] else {
    FileHandle.standardError.write(Data("usage: rocky-probe <claude|codex|opencode> <workdir>\n".utf8))
    exit(64)
}
do {
    try probe(agent: arguments[1], command: command, workdir: URL(fileURLWithPath: arguments[2]))
} catch {
    print("probe failed:", error)
    exit(1)
}
