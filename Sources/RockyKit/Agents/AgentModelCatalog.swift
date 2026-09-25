import Foundation

/// `AGM-04`, `KIT-12`: each agent's models as its sessions last reported them, so the model menu lists another agent's
/// models without starting its process. An agent reports its models only in a session (the `model` config option), so
/// every report is recorded here and the menu reads the last one.
///
/// Claude's lists are kept per Claude instance (the repository's `claudeConfigDir`, or "default"), since instances can
/// offer different models; OpenCode's per agent only. The file holds model names only: no tokens, no keys, and no effort
/// levels, which an agent reports only for its current model (`AGM-07`). Pure apart from its file, which is read once
/// by `init` and rewritten only when a list changes.
public struct AgentModelCatalog: Sendable, Equatable {
    public let file: URL
    private var lists: [String: [SessionConfigOption.Choice]]

    /// The Claude instance a repository without `claudeConfigDir` uses.
    static let defaultClaudeInstance = "default"

    /// The catalog stored in `file`; empty when the file is missing or cannot be read, as on a Mac where no agent has
    /// run yet.
    public init(file: URL) {
        self.file = file
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(StoredCatalog.self, from: $0) }
        lists = (stored?.agents ?? [:]).mapValues { $0.map(\.choice) }
    }

    /// The models `agent` last reported for this Claude instance (ignored for OpenCode); nil when it never reported any.
    public func models(agent: AgentKind, claudeInstance: String?) -> [SessionConfigOption.Choice]? {
        lists[Self.key(agent: agent, claudeInstance: claudeInstance)]
    }

    /// Keeps the choices of a session's `model` option. Any other option, or one with no choices, is ignored. A list
    /// equal to the stored one leaves the file untouched.
    public mutating func record(_ option: SessionConfigOption, agent: AgentKind, claudeInstance: String?) {
        guard option.id == SessionConfigOption.model, !option.choices.isEmpty else { return }
        let key = Self.key(agent: agent, claudeInstance: claudeInstance)
        guard lists[key] != option.choices else { return }
        lists[key] = option.choices
        save()
    }

    /// "claude:default", "claude:/Users/me/.claude-celes", "opencode".
    static func key(agent: AgentKind, claudeInstance: String?) -> String {
        switch agent {
        case .claude:
            let instance = claudeInstance.flatMap { $0.isEmpty ? nil : $0 } ?? defaultClaudeInstance
            return "\(agent.rawValue):\(instance)"
        case .opencode:
            return agent.rawValue
        }
    }

    /// A failed write keeps the list in memory: the menu still shows it until Rocky quits.
    private func save() {
        let stored = StoredCatalog(agents: lists.mapValues { $0.map(StoredChoice.init) })
        let encoder = JSONEncoder()
        // Sorted and one entry per line, so the file reads the same after every write.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private struct StoredCatalog: Codable {
        var version = 1
        var agents: [String: [StoredChoice]]
    }

    private struct StoredChoice: Codable {
        let value: String
        let name: String
        let detail: String?

        init(_ choice: SessionConfigOption.Choice) {
            value = choice.value
            name = choice.name
            detail = choice.detail
        }

        var choice: SessionConfigOption.Choice {
            SessionConfigOption.Choice(value: value, name: name, detail: detail)
        }
    }
}
