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
        let data = try Self.output(executable, arguments, in: directory, environment: environment)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a command to completion and returns stdout exactly as it was written. For output whose first or last
    /// characters matter: a diff whose last context line is a lone space, or `git status -z`, whose first entry can
    /// start with one. Blocking, like `run`.
    public static func output(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> Data {
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
        return output
    }

    /// Runs a command to completion and hands `onOutput` what it writes as it writes it (`GIT-04`'s hook output).
    /// stdout and stderr share one pipe, so a hook's lines keep their place among git's. Returns the exit status:
    /// the caller has already shown the output, so a failure is not thrown. Blocking, like `run`; `onOutput` runs on
    /// the calling thread.
    public static func stream(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        onOutput: (Data) -> Void
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // `availableData` waits for the next write and is empty only at the end of the pipe.
        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            onOutput(chunk)
        }
        exited.wait()
        return process.terminationStatus
    }
}

/// What a running command writes, as lines to show (`GIT-04`): whole lines as they complete, so a UTF-8 character
/// that two reads split comes back whole; terminal escapes (colors, cursor moves) and other control characters left
/// out; and a line that carriage returns rewrote (a progress counter) as the terminal would have left it.
public struct CommandOutputDecoder: Sendable {
    private var pending = Data()

    public init() {}

    /// The lines `data` completes, without their line ends; empty while none is complete.
    public mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        guard let newline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = pending[pending.startIndex..<newline]
        let lines = Self.lines(of: complete)
        pending = Data(pending[pending.index(after: newline)...])
        return lines
    }

    /// The last line, once the command ended without a newline after it; empty otherwise.
    public mutating func finish() -> [String] {
        guard !pending.isEmpty else { return [] }
        defer { pending = Data() }
        return Self.lines(of: pending)
    }

    /// Split on the newline byte: Swift reads "\r\n" as one character, which a split on "\n" would never find.
    static func lines(of data: Data) -> [String] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { line in
            // A carriage return starts the line over, as a terminal draws it: what the last one left is what shows.
            // CRLF's return ends the line and leaves it as it was.
            let rewrites = line.split(separator: UInt8(ascii: "\r"), omittingEmptySubsequences: true)
            let kept = rewrites.last.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return withoutEscapes(kept)
        }
    }

    /// `text` without ANSI escape sequences (CSI: ESC [ … final byte; OSC: ESC ] … BEL or ESC \; any other ESC and
    /// the character after it) and without control characters other than tabs.
    static func withoutEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) else { return text }
        enum State {
            case text, escape, csi, osc, oscEscape
        }
        var state = State.text
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch state {
            case .text:
                if scalar == "\u{1B}" {
                    state = .escape
                } else if scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F) {
                    kept.append(scalar)
                }
            case .escape:
                state = scalar == "[" ? .csi : scalar == "]" ? .osc : .text
            case .csi:
                // Parameters and intermediates run from 0x20 to 0x3F; a byte from 0x40 to 0x7E ends the sequence.
                if (0x40...0x7E).contains(scalar.value) { state = .text }
            case .osc:
                if scalar == "\u{07}" { state = .text } else if scalar == "\u{1B}" { state = .oscEscape }
            case .oscEscape:
                state = .text
            }
        }
        return String(kept)
    }
}
