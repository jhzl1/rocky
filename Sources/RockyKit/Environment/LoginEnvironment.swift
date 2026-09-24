import Foundation

public enum LoginEnvironmentError: Error, Equatable {
    case timedOut
    case markerMissing
}

/// Captures the user's login-shell environment once, so agents see the same PATH as a terminal.
/// Conductor spawned `zsh -l` repeatedly; Rocky runs it once per launch (spec Section 1).
public enum LoginEnvironment {
    public static let marker = "__ROCKY_ENV_BEGIN__"

    /// `-i` is required: PATH entries such as pnpm's live in `.zshrc`, which a non-interactive login shell skips.
    public static let zshArguments = ["-l", "-i", "-c", "printf '\\0\(marker)\\0'; env -0"]

    /// Parses `env -0` output that follows the NUL-wrapped marker; shell startup noise before it is ignored.
    public static func parse(_ output: Data) -> [String: String] {
        let separator = Data([0]) + Data(marker.utf8) + Data([0])
        guard let range = output.range(of: separator) else { return [:] }
        var environment: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }

    /// Blocking: call it off the main actor.
    public static func capture(
        shell: URL = URL(fileURLWithPath: "/bin/zsh"),
        arguments: [String] = zshArguments,
        timeout: TimeInterval = 15
    ) throws -> [String: String] {
        let process = Process()
        process.executableURL = shell
        process.arguments = arguments
        let current = ProcessInfo.processInfo.environment
        var environment = ["TERM": "dumb", "SHELL": shell.path]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] { environment[key] = current[key] }
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let output = PipeDrain(stdout.fileHandleForReading)
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw LoginEnvironmentError.timedOut
        }
        // A background job started by the profile can hold stdout open; do not wait for it forever.
        guard output.wait(timeout: .now() + 2) == .success else { throw LoginEnvironmentError.markerMissing }
        let parsed = parse(output.data)
        guard !parsed.isEmpty else { throw LoginEnvironmentError.markerMissing }
        return parsed
    }
}
