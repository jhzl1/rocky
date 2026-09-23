import Foundation

public struct ProcessFailure: Error, Equatable, CustomStringConvertible {
    public let command: String
    public let status: Int32
    public let stderr: String

    public var description: String { "\(command) exited \(status): \(stderr)" }
}

private final class OutputBox: @unchecked Sendable {
    var data = Data()
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

        // Drain stderr concurrently: a full pipe would block the child forever.
        let errorOutput = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorOutput.data = stderr.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
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
