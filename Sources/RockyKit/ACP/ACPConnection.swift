import Foundation

public struct ACPNotification: Sendable, Equatable {
    public let method: String
    public let params: JSONValue
}

public enum ACPConnectionError: Error, Equatable {
    case agentExited(status: Int32, stderrTail: String)
    case rpc(code: Int, message: String)
}

public struct ACPHandlers: Sendable {
    /// Awaited in stream order before the next line is read, so a response is never
    /// processed ahead of the notifications that preceded it.
    public var onNotification: @Sendable (ACPNotification) async -> Void
    /// Runs on its own task: a permission prompt waiting on the user must not stall reading.
    public var onRequest: @Sendable (String, JSONValue) async -> JSONValue
    public var onExit: @Sendable (ACPConnectionError) async -> Void

    public init(
        onNotification: @escaping @Sendable (ACPNotification) async -> Void = { _ in },
        onRequest: @escaping @Sendable (String, JSONValue) async -> JSONValue = { _, _ in [:] },
        onExit: @escaping @Sendable (ACPConnectionError) async -> Void = { _ in }
    ) {
        self.onNotification = onNotification
        self.onRequest = onRequest
        self.onExit = onExit
    }
}

/// One agent process speaking ACP over stdio.
public actor ACPConnection {
    /// Writing to a pipe whose reader died raises SIGPIPE, which kills the app by default.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public private(set) var skippedLines: [String] = []

    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderrLog: URL
    private var handlers = ACPHandlers()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextID = 1
    private var exitError: ACPConnectionError?

    public init(executable: URL, arguments: [String], environment: [String: String], cwd: URL, stderrLog: URL) throws {
        _ = Self.ignoreSIGPIPE
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // stderr goes to a file: an unread pipe fills at 64 KB and blocks the agent.
        process.standardError = try FileHandle(forWritingTo: stderrLog)
        self.process = process
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderrLog = stderrLog
    }

    public func setHandlers(_ handlers: ACPHandlers) {
        self.handlers = handlers
    }

    public func start() throws {
        try process.run()
        let stdout = stdout
        Task { [weak self] in
            // Split on "\n" only: JSON text may contain U+2028, which `bytes.lines` would treat as a line break.
            var line: [UInt8] = []
            do {
                for try await byte in stdout.bytes {
                    if byte == 0x0A {
                        await self?.receive(String(decoding: line, as: UTF8.self))
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(byte)
                    }
                }
            } catch {}
            await self?.finish()
        }
    }

    public func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        if let exitError { throw exitError }
        let id = nextID
        nextID += 1
        let data = try RPCCodec.encode(.request(id: .int(id), method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdin.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: ACPConnectionError.agentExited(status: -1, stderrTail: "\(error)"))
            }
        }
    }

    public func notify(_ method: String, _ params: JSONValue) throws {
        if let exitError { throw exitError }
        try stdin.write(contentsOf: RPCCodec.encode(.notification(method: method, params: params)))
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func receive(_ line: String) async {
        guard let message = try? RPCCodec.decode(line) else {
            if !line.isEmpty { skippedLines.append(line) }
            return
        }
        switch message {
        case let .response(.int(id), result):
            pending.removeValue(forKey: id)?.resume(returning: result)
        case let .errorResponse(.int(id), code, message):
            pending.removeValue(forKey: id)?.resume(throwing: ACPConnectionError.rpc(code: code, message: message))
        case .response, .errorResponse:
            break
        case let .notification(method, params):
            await handlers.onNotification(ACPNotification(method: method, params: params))
        case let .request(id, method, params):
            let onRequest = handlers.onRequest
            Task { [weak self] in
                let result = await onRequest(method, params)
                await self?.reply(id: id, result: result)
            }
        }
    }

    private func reply(id: RPCID, result: JSONValue) {
        guard exitError == nil, let data = try? RPCCodec.encode(.response(id: id, result: result)) else { return }
        try? stdin.write(contentsOf: data)
    }

    private func finish() async {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let log = (try? String(contentsOf: stderrLog, encoding: .utf8)) ?? ""
        let error = ACPConnectionError.agentExited(status: process.terminationStatus, stderrTail: String(log.suffix(2000)))
        exitError = error
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        await handlers.onExit(error)
    }
}
