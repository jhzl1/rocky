import Foundation

public enum RunScriptMode: String, CaseIterable, Identifiable, Sendable {
    /// Run scripts may run in several workspaces at once.
    case concurrent
    /// Starting a run script first stops every other workspace's run script, for projects bound to one port,
    /// database or Docker stack.
    case nonconcurrent

    public var id: String { rawValue }
}

public struct ScriptConfig: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case conductorJSON
        case repoSettings
    }

    public var setup: String?
    public var run: String?
    public var archive: String?
    public var runMode: RunScriptMode
    public var source: Source
}

public enum ScriptConfigError: Error, Equatable, CustomStringConvertible {
    case invalidConductorJSON(String)

    public var description: String {
        switch self {
        case .invalidConductorJSON(let reason): "conductor.json is not valid: \(reason)"
        }
    }
}

/// Scripts come from `conductor.json` at the workspace root when it exists (Conductor's legacy format, which the
/// spec names), else from the repo settings in Rocky. The file replaces all of the settings, even for keys it
/// lacks. `.conductor/settings.toml`, Conductor's newer format, is not read.
public enum ScriptConfigResolver {
    public static let fileName = "conductor.json"

    private struct ConductorFile: Decodable {
        struct Scripts: Decodable {
            var setup: String?
            var run: String?
            var archive: String?
        }

        var scripts: Scripts?
        var runScriptMode: String?
    }

    public static func resolve(workspace: URL, repo: Repo) throws -> ScriptConfig {
        if let data = FileManager.default.contents(atPath: workspace.appendingPathComponent(fileName).path) {
            return try parse(data)
        }
        return ScriptConfig(
            setup: clean(repo.setupScript),
            run: clean(repo.runScript),
            archive: clean(repo.archiveScript),
            runMode: RunScriptMode(rawValue: repo.runScriptMode ?? "") ?? .concurrent,
            source: .repoSettings
        )
    }

    /// A blank script is no script.
    public static func clean(_ script: String?) -> String? {
        guard let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return script
    }

    static func parse(_ data: Data) throws -> ScriptConfig {
        let file: ConductorFile
        do {
            file = try JSONDecoder().decode(ConductorFile.self, from: data)
        } catch {
            throw ScriptConfigError.invalidConductorJSON(describe(error))
        }
        var runMode = RunScriptMode.concurrent
        if let raw = file.runScriptMode {
            guard let parsed = RunScriptMode(rawValue: raw) else {
                throw ScriptConfigError.invalidConductorJSON(#"runScriptMode must be "concurrent" or "nonconcurrent", got "\#(raw)""#)
            }
            runMode = parsed
        }
        return ScriptConfig(
            setup: clean(file.scripts?.setup),
            run: clean(file.scripts?.run),
            archive: clean(file.scripts?.archive),
            runMode: runMode,
            source: .conductorJSON
        )
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            return context.underlyingError.map { "\($0.localizedDescription)" } ?? context.debugDescription
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path): \(context.debugDescription)"
        default:
            return "\(error)"
        }
    }
}
