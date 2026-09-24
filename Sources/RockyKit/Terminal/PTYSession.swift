import Foundation
import Observation
@preconcurrency import SwiftTerm

/// What to run in a pseudo-terminal.
public struct PTYCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let cwd: URL

    public init(executable: String, arguments: [String], environment: [String: String], cwd: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
    }

    /// Setup, run and archive scripts run in a non-interactive zsh, as Conductor's do: only `~/.zshenv` is read.
    public static func script(_ script: String, environment: [String: String], cwd: URL) -> PTYCommand {
        PTYCommand(executable: "/bin/zsh", arguments: ["-c", script], environment: environment, cwd: cwd)
    }
}

public enum PTYState: Equatable, Sendable, CustomStringConvertible {
    case running
    case exited(Int32)
    case signaled(Int32)
    case failedToStart

    /// Decodes a `waitpid` status. SwiftTerm's `LocalProcess` passes the raw status to
    /// `processTerminated(_:exitCode:)`, not the exit code.
    public init(waitStatus status: Int32) {
        let signal = status & 0x7f
        self = signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }

    public var isRunning: Bool { self == .running }

    public var description: String {
        switch self {
        case .running: "Running"
        case .exited(let code): "Exited \(code)"
        case .signaled(let signal): "Stopped by signal \(signal)"
        case .failedToStart: "Could not start"
        }
    }
}

/// One process in a pseudo-terminal: a terminal tab or a setup/run/archive script.
///
/// The session keeps its last `maxOutputBytes` of output so a view attached later (after switching tab or
/// workspace) replays it. While no view is attached, output is only appended (spec Section 1: hidden
/// sessions buffer and render on open).
@MainActor
@Observable
public final class PTYSession: Identifiable {
    public let id = UUID()
    public let title: String
    public let command: PTYCommand
    public private(set) var state: PTYState = .running
    /// Rocky asked it to stop (Stop, closing the tab, removing the workspace): however it then ends, by the signal or
    /// with a code from a script that caught it, the panel says "stopped", not "failed" (TERM-03).
    public private(set) var stopRequested = false

    @ObservationIgnored public private(set) var output: [UInt8] = []
    @ObservationIgnored private let stopSignal: Int32
    @ObservationIgnored private let stopGracePeriod: Duration
    @ObservationIgnored private let maxOutputBytes: Int
    /// Kept after the exit: its read handlers hold it weakly, and output can still arrive after the exit event.
    @ObservationIgnored private var process: LocalProcess?
    @ObservationIgnored private var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    /// Every view showing this session. SwiftUI can build two views of one session and dismantle either, in any
    /// order: with a single viewer, dismantling the second one left the view on screen without output.
    @ObservationIgnored private var viewers: [UUID: (ArraySlice<UInt8>) -> Void] = [:]
    @ObservationIgnored private var exitWaiters: [CheckedContinuation<PTYState, Never>] = []

    public init(
        title: String,
        command: PTYCommand,
        stopSignal: Int32 = SIGTERM,
        stopGracePeriod: Duration = .seconds(5),
        maxOutputBytes: Int = 2_000_000
    ) {
        self.title = title
        self.command = command
        self.stopSignal = stopSignal
        self.stopGracePeriod = stopGracePeriod
        self.maxOutputBytes = maxOutputBytes
    }

    public var outputText: String {
        String(decoding: output, as: UTF8.self)
    }

    public var pid: pid_t {
        process?.shellPid ?? 0
    }

    public func start() {
        guard process == nil else { return }
        var environment = command.environment
        // The login environment was captured with TERM=dumb; a PTY is a real terminal.
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        let process = LocalProcess(delegate: self, dispatchQueue: .main)
        self.process = process
        process.startProcess(
            executable: command.executable,
            args: command.arguments,
            environment: environment.map { "\($0.key)=\($0.value)" }.sorted(),
            currentDirectory: command.cwd.path
        )
        // forkpty failed: there is no child, so no exit event will ever come.
        if process.shellPid == 0 { finish(.failedToStart) }
    }

    /// Attaches a view that shows this session and returns the output so far, for it to replay.
    public func attach(_ viewerId: UUID, onOutput: @escaping (ArraySlice<UInt8>) -> Void) -> [UInt8] {
        viewers[viewerId] = onOutput
        return output
    }

    /// Detaches `viewerId` only; the session's other views keep their output.
    public func detach(_ viewerId: UUID) {
        viewers[viewerId] = nil
    }

    public func send(_ bytes: ArraySlice<UInt8>) {
        process?.send(data: bytes)
    }

    public func send(_ text: String) {
        send(Array(text.utf8)[...])
    }

    public func resize(cols: Int, rows: Int) {
        windowSize = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        guard let process, process.running, process.childfd >= 0 else { return }
        var size = windowSize
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    public func waitForExit() async -> PTYState {
        guard state.isRunning else { return state }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// Sends `stopSignal` to the whole process group, then SIGKILL after the grace period (Conductor stops scripts
    /// the same way), and waits for the exit. Background jobs a script started with `&` share the group.
    /// `LocalProcess.terminate()` is never used: it cancels the exit monitor, so the exit would never be
    /// reported and the child never reaped.
    public func stop() async {
        guard state.isRunning, pid > 0 else { return }
        stopRequested = true
        signalProcessGroup(stopSignal)
        let grace = stopGracePeriod
        let escalation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.state.isRunning else { return }
            self.signalProcessGroup(SIGKILL)
        }
        _ = await waitForExit()
        escalation.cancel()
    }

    /// forkpty makes the child a session leader, so its pid is also its process group id. Right after `start()` the
    /// child has usually not called `setsid()` yet and the group does not exist (`ESRCH` in 294 of 300 tries): then the
    /// child is the only process to signal. A Stop that came that early waited out the grace period and ended in
    /// SIGKILL (2026-09-24).
    private func signalProcessGroup(_ signal: Int32) {
        if kill(-pid, signal) != 0, errno == ESRCH {
            kill(pid, signal)
        }
    }

    private func finish(_ final: PTYState) {
        guard state.isRunning else { return }
        state = final
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: final) }
    }

    private func receive(_ bytes: ArraySlice<UInt8>) {
        output.append(contentsOf: bytes)
        if output.count > maxOutputBytes {
            output.removeFirst(output.count - maxOutputBytes)
        }
        for onOutput in viewers.values { onOutput(bytes) }
    }
}

// LocalProcess delivers on DispatchQueue.main (see `start()`), so these run on the main actor.
extension PTYSession: @preconcurrency LocalProcessDelegate {
    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        finish(exitCode.map(PTYState.init(waitStatus:)) ?? .failedToStart)
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
        receive(slice)
    }

    public func getWindowSize() -> winsize {
        windowSize
    }
}

