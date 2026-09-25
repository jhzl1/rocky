import Foundation
import Testing
@testable import RockyKit

/// `KIT-12`, `AGM-04`: the models each agent last reported, in a file next to the database.
struct AgentModelCatalogTests {
    private func modelOption(_ choices: [(value: String, name: String, detail: String?)], current: String? = nil) -> SessionConfigOption {
        let list = choices.map { SessionConfigOption.Choice(value: $0.value, name: $0.name, detail: $0.detail) }
        return SessionConfigOption(id: SessionConfigOption.model, name: "Model", category: "model", current: current ?? list[0].value, choices: list)
    }

    private func catalogFile() throws -> URL {
        try Fixtures.temporaryDirectory("catalog").appendingPathComponent("agent-models.json")
    }

    @Test func aRecordedListComesBackFromTheFile() throws {
        let file = try catalogFile()
        var catalog = AgentModelCatalog(file: file)
        #expect(catalog.models(agent: .opencode, claudeInstance: nil) == nil)

        let option = modelOption([
            ("claude-sonnet-5", "Claude Sonnet 5", "Anthropic"),
            ("gpt-5.5", "GPT-5.5", nil),
        ])
        catalog.record(option, agent: .opencode, claudeInstance: nil)
        #expect(catalog.models(agent: .opencode, claudeInstance: nil) == option.choices)

        let reread = AgentModelCatalog(file: file)
        #expect(reread.models(agent: .opencode, claudeInstance: nil) == option.choices)
        #expect(reread.models(agent: .opencode, claudeInstance: nil)?.first?.detail == "Anthropic")
        // OpenCode has one list whatever the repository's Claude instance.
        #expect(reread.models(agent: .opencode, claudeInstance: "/Users/me/.claude-celes") == option.choices)
        #expect(reread.models(agent: .claude, claudeInstance: nil) == nil)
    }

    @Test func claudeInstancesKeepTheirOwnLists() throws {
        let file = try catalogFile()
        var catalog = AgentModelCatalog(file: file)
        let personal = modelOption([("opus", "Opus 5.5", nil), ("sonnet", "Sonnet 5", nil)])
        let work = modelOption([("sonnet", "Sonnet 5", nil)])
        catalog.record(personal, agent: .claude, claudeInstance: nil)
        catalog.record(work, agent: .claude, claudeInstance: "/Users/me/.claude-celes")

        let reread = AgentModelCatalog(file: file)
        #expect(reread.models(agent: .claude, claudeInstance: nil) == personal.choices)
        // An empty setting is the default instance, as for a repository without one.
        #expect(reread.models(agent: .claude, claudeInstance: "") == personal.choices)
        #expect(reread.models(agent: .claude, claudeInstance: "/Users/me/.claude-celes") == work.choices)
        #expect(reread.models(agent: .claude, claudeInstance: "/Users/me/.claude-rentek") == nil)
    }

    @Test func anUnchangedListLeavesTheFileUntouched() throws {
        let file = try catalogFile()
        var catalog = AgentModelCatalog(file: file)
        let option = modelOption([("opus", "Opus 5.5", nil), ("sonnet", "Sonnet 5", nil)])
        catalog.record(option, agent: .claude, claudeInstance: nil)
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Gone from disk, it would come back only with a write.
        try FileManager.default.removeItem(at: file)
        // Another current model is the same list.
        catalog.record(modelOption([("opus", "Opus 5.5", nil), ("sonnet", "Sonnet 5", nil)], current: "sonnet"), agent: .claude, claudeInstance: nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        catalog.record(modelOption([("opus", "Opus 5.5", nil)]), agent: .claude, claudeInstance: nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Only the model option is a list of models; an empty one tells nothing.
    @Test func otherOptionsAndEmptyListsAreIgnored() throws {
        let file = try catalogFile()
        var catalog = AgentModelCatalog(file: file)
        let effort = SessionConfigOption(
            id: SessionConfigOption.effort, name: "Effort", category: "thought_level", current: "high",
            choices: [.init(value: "high", name: "High")]
        )
        catalog.record(effort, agent: .claude, claudeInstance: nil)
        catalog.record(SessionConfigOption(id: SessionConfigOption.model, name: "Model", category: "model", current: "", choices: []), agent: .claude, claudeInstance: nil)
        #expect(catalog.models(agent: .claude, claudeInstance: nil) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Nothing but the names: no effort levels, tokens or keys reach the file.
    @Test func theFileHoldsModelNamesOnly() throws {
        let file = try catalogFile()
        var catalog = AgentModelCatalog(file: file)
        catalog.record(modelOption([("opus", "Opus 5.5", "Most capable")]), agent: .claude, claudeInstance: nil)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let agents = try #require(json["agents"] as? [String: [[String: String]]])
        #expect(agents == ["claude:default": [["value": "opus", "name": "Opus 5.5", "detail": "Most capable"]]])
    }
}
