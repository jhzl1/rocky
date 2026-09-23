import Foundation

public enum ACPConnectionError: Error {
    case agentExited(status: Int32, stderr: String)
    case rpcError(JSONObject)
}

/// Synchronous ACP client over a child process's stdio. One call in flight at a time.
public final class ACPConnection {
    public var onNotification: (String, JSONObject) -> Void = { _, _ in }
    public var onRequest: (String, JSONObject) -> JSONObject = { _, _ in [:] }
    public private(set) var skippedLines: [String] = []

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrLog: URL
    private var buffer = Data()
    private var nextID = 1

    public init(command: [String], environment: [String: String], cwd: URL, stderrLog: URL) throws {
        self.stderrLog = stderrLog
        // stderr goes to a file: an unread pipe fills at 64 KB and blocks the agent.
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = try FileHandle(forWritingTo: stderrLog)
        try process.run()
    }

    public func call(_ method: String, _ params: JSONObject) throws -> JSONObject {
        let id = nextID
        nextID += 1
        try write(JSONRPC.encodeRequest(id: id, method: method, params: params))
        while true {
            guard let line = readLine() else {
                process.waitUntilExit()
                let stderr = (try? String(contentsOf: stderrLog, encoding: .utf8)) ?? ""
                throw ACPConnectionError.agentExited(status: process.terminationStatus, stderr: stderr)
            }
            guard let message = try? JSONRPC.decode(line) else {
                skippedLines.append(line)
                continue
            }
            switch message {
            case let .response(responseID, result, error) where responseID == id:
                if let error { throw ACPConnectionError.rpcError(error) }
                return result ?? [:]
            case .response:
                continue
            case let .notification(method, params):
                onNotification(method, params)
            case let .request(requestID, method, params):
                try write(JSONRPC.encodeResponse(id: requestID, result: onRequest(method, params)))
            }
        }
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func write(_ data: Data) throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            let chunk = stdoutPipe.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
