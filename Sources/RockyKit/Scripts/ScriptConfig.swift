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
        case rockyJSON
        case repoSettings
    }

    public var setup: String?
    public var run: String?
    public var archive: String?
    public var runMode: RunScriptMode
    public var source: Source
    /// Extra paths or globs `WorktreeLinker` links into a new workspace: the repo setting's, then rocky.json's.
    public var links: [String] = []
}

public enum ScriptConfigError: Error, Equatable, CustomStringConvertible {
    case invalidRockyJSON(String)

    public var description: String {
        switch self {
        case .invalidRockyJSON(let reason): "rocky.json is not valid: \(reason)"
        }
    }
}

/// Scripts come from `rocky.json` at the workspace root when it exists, so a repo can keep them in git, else from the
/// repo settings in Rocky. The file replaces all of the settings, even for keys it lacks:
///
///     { "scripts": { "setup": "pnpm install", "run": "pnpm dev --port $PORT", "archive": "…" },
///       "runScriptMode": "concurrent", "links": [".venv", ".vscode/*"] }
///
/// Links are the exception: each entry only adds a file to link, so the repo setting's and the file's add up.
///
/// Same shape as Conductor's conductor.json, which Rocky no longer reads (user decision, 2026-09-23).
public enum ScriptConfigResolver {
    public static let fileName = "rocky.json"

    private struct RockyFile: Decodable {
        struct Scripts: Decodable {
            var setup: String?
            var run: String?
            var archive: String?
        }

        var scripts: Scripts?
        var runScriptMode: String?
        var links: [String]?
    }

    public static func resolve(workspace: URL, repo: Repo) throws -> ScriptConfig {
        let repoLinks = linkEntries(repo.linkedPaths)
        if let data = FileManager.default.contents(atPath: workspace.appendingPathComponent(fileName).path) {
            var config = try parse(data)
            var seen: Set<String> = []
            config.links = (repoLinks + config.links).filter { seen.insert($0).inserted }
            return config
        }
        return ScriptConfig(
            setup: clean(repo.setupScript),
            run: clean(repo.runScript),
            archive: clean(repo.archiveScript),
            runMode: RunScriptMode(rawValue: repo.runScriptMode ?? "") ?? .concurrent,
            source: .repoSettings,
            links: repoLinks
        )
    }

    /// The entries of `Repo.linkedPaths`: one per line, trimmed, blank lines dropped.
    public static func linkEntries(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A blank script is no script.
    public static func clean(_ script: String?) -> String? {
        guard let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return script
    }

    static func parse(_ data: Data) throws -> ScriptConfig {
        let file: RockyFile
        do {
            file = try JSONDecoder().decode(RockyFile.self, from: data)
        } catch {
            throw ScriptConfigError.invalidRockyJSON(describe(error))
        }
        var runMode = RunScriptMode.concurrent
        if let raw = file.runScriptMode {
            guard let parsed = RunScriptMode(rawValue: raw) else {
                throw ScriptConfigError.invalidRockyJSON(#"runScriptMode must be "concurrent" or "nonconcurrent", got "\#(raw)""#)
            }
            runMode = parsed
        }
        return ScriptConfig(
            setup: clean(file.scripts?.setup),
            run: clean(file.scripts?.run),
            archive: clean(file.scripts?.archive),
            runMode: runMode,
            source: .rockyJSON,
            links: (file.links ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
