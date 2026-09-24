import Foundation

public struct ProcessFailure: Error, Equatable, CustomStringConvertible {
    public let command: String
    public let status: Int32
    public let stderr: String

    public var description: String { "\(command) exited \(status): \(stderr)" }
}

/// Runs each job of a task that waits on blocking work (git, gh, npm, the login shell, a folder removal) on a thread
/// of its own, off Swift's cooperative pool. That pool has one thread per CPU core, and `Task.detached` runs on it.
/// Once every one of its threads waits in a syscall, macOS starts no thread for default-QoS Dispatch work: a
/// `DispatchQueue.global()` read never ran, and `DispatchIO`, which reads every terminal (SwiftTerm's `LocalProcess`),
/// stopped. A script whose shell exited meanwhile lost its output, because the kernel drops what a pseudo-terminal
/// still holds 0.6 s after its shell exits (2026-09-24).
public final class BlockingWorkExecutor: TaskExecutor {
    public static let shared = BlockingWorkExecutor()

    private init() {}

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        let thread = Thread { job.runSynchronously(on: executor) }
        thread.name = "rocky.blocking-work"
        thread.start()
    }
}

extension Task where Failure == Never {
    /// Runs `work` on `BlockingWorkExecutor`, not on the cooperative pool as `Task.detached` would.
    @discardableResult
    public static func blocking(_ work: @escaping @Sendable () -> Success) -> Task<Success, Never> {
        Task.detached(executorPreference: BlockingWorkExecutor.shared) { work() }
    }
}

extension Task where Failure == any Error {
    /// Runs `work` on `BlockingWorkExecutor`, not on the cooperative pool as `Task.detached` would.
    @discardableResult
    public static func blocking(_ work: @escaping @Sendable () throws -> Success) -> Task<Success, any Error> {
        Task.detached(executorPreference: BlockingWorkExecutor.shared) { try work() }
    }
}

/// A pipe read to its end on a thread of its own; `wait` blocks until it is.
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
    /// Blocking: call it from `Task.blocking`, never on the main actor or the cooperative pool.
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
        // Not `waitUntilExit()`: it can miss the exit and wait forever (see `ACPConnection.finish()`).
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Drain stderr while stdout is read: a full pipe would block the child forever.
        let errorOutput = PipeDrain(stderr.fileHandleForReading)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        errorOutput.wait()
        exited.wait()

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
