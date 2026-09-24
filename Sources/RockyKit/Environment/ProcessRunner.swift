import Foundation

public struct ProcessFailure: Error, Equatable, CustomStringConvertible {
    public let command: String
    public let status: Int32
    public let stderr: String

    public var description: String { "\(command) exited \(status): \(stderr)" }
}

/// A pipe read to its end on a thread of its own; `wait` blocks until it is. Not a Dispatch queue: callers block
/// Swift's cooperative threads while they wait, and with enough of them waiting (tests running git in parallel), a
/// read queued on `DispatchQueue.global()` never got a thread and every caller waited forever.
final class PipeDrain: @unchecked Sendable {
    /// Read only after `wait` returned.
    private(set) var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        Thread { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }.start()
    }

    func wait() {
        done.wait()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        done.wait(timeout: timeout)
    }
}

public enum ProcessRunner {
    /// Runs a command to completion and returns stdout without trailing whitespace.
    /// Blocking: call it off the main actor.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment { process.environment = environment }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain stderr while stdout is read: a full pipe would block the child forever.
        let errorOutput = PipeDrain(stderr.fileHandleForReading)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        errorOutput.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ProcessFailure(
                command: ([executable.lastPathComponent] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                stderr: String(decoding: errorOutput.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
