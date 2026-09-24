import Foundation
import Testing
@testable import RockyKit

struct RecordsTests {
    private let commands = [SlashCommand(name: "compact"), SlashCommand(name: "init"), SlashCommand(name: "mcp:linear:triage")]

    /// Review Focus 5 (TITLE-01): a command never names a conversation; a "/" word that is no command does.
    @Test func titleSkipsCommands() {
        #expect(ChatSessionRecord.title(from: "/compact", commands: commands) == nil)
        #expect(ChatSessionRecord.title(from: "/mcp:linear:triage web-42", commands: commands) == nil)
        #expect(ChatSessionRecord.title(from: "/notacommand hi", commands: commands) == "/notacommand hi")
        #expect(ChatSessionRecord.title(from: "hello", commands: commands) == "hello")
        #expect(ChatSessionRecord.title(from: "look at /compact", commands: commands) == "look at /compact")
    }

    /// Before the conversation's list is known, any "/name" first token counts as a command.
    @Test func titleWithAnUnknownListSkipsEveryLeadingSlashName() {
        #expect(AppModel.title(from: "/compact", commands: nil) == nil)
        #expect(AppModel.title(from: "/notacommand hi", commands: nil) == nil)
        #expect(AppModel.title(from: "src/app.ts is broken", commands: nil) == "src/app.ts is broken")
        #expect(AppModel.title(from: "/notacommand hi", commands: commands) == "/notacommand hi")
    }
}
