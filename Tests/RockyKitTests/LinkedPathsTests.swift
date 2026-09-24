import Testing
@testable import RockyKit

/// The linked files setting's entries (user request, 2026-09-23): the add field's checks, and the "!<pattern>" lines
/// that turn a default off.
struct LinkedPathsTests {
    @Test func theDefaultsAreTheLinkersPatternsThenItsPaths() {
        #expect(LinkedPaths.defaults == [".env", ".env.*", ".envrc", ".dev.vars", ".dev.vars.*", ".claude/settings.local.json"])
    }

    @Test func validateAcceptsARelativePathOrGlobAndCleansIt() {
        #expect(LinkedPaths.validate(".venv", existing: []) == .success(".venv"))
        #expect(LinkedPaths.validate(" ./.vscode/* ", existing: []) == .success(".vscode/*"))
        #expect(LinkedPaths.validate("apps/api/.venv/", existing: [".venv"]) == .success("apps/api/.venv"))
        // A path under a default's name is not the default.
        #expect(LinkedPaths.validate(".env.local", existing: []) == .success(".env.local"))
    }

    @Test func validateRejectsEmptyAbsoluteOutsideAndNegatedEntries() {
        #expect(LinkedPaths.validate("", existing: []) == .failure(.empty))
        #expect(LinkedPaths.validate("   ", existing: []) == .failure(.empty))
        #expect(LinkedPaths.validate("/etc/hosts", existing: []) == .failure(.absolute))
        #expect(LinkedPaths.validate("~/.aws", existing: []) == .failure(.absolute))
        #expect(LinkedPaths.validate("../outside", existing: []) == .failure(.outsideRepository))
        #expect(LinkedPaths.validate("apps/../../outside", existing: []) == .failure(.outsideRepository))
        #expect(LinkedPaths.validate(".", existing: []) == .failure(.outsideRepository))
        #expect(LinkedPaths.validate("!.env", existing: []) == .failure(.negation))
    }

    @Test func validateRejectsDuplicatesAndDefaults() {
        #expect(LinkedPaths.validate(".venv", existing: [".venv"]) == .failure(.duplicate))
        #expect(LinkedPaths.validate("./.venv/", existing: [".venv"]) == .failure(.duplicate))
        #expect(LinkedPaths.validate(".env.*", existing: []) == .failure(.isDefault))
        #expect(LinkedPaths.validate("./.claude/settings.local.json", existing: []) == .failure(.isDefault))
    }

    @Test func everyProblemHasAMessage() {
        let problems: [LinkedPathProblem] = [.empty, .negation, .absolute, .outsideRepository, .isDefault, .duplicate]
        for problem in problems {
            #expect(!problem.message.isEmpty)
        }
    }

    @Test func onlyNegationsOfADefaultTurnItOff() {
        let entries = ["!.env", " ! .envrc ", "!./.dev.vars", "!.venv", "!.env.local", ".env.*", ""]
        #expect(LinkedPaths.disabledDefaults(in: entries) == [".env", ".envrc", ".dev.vars"])
        #expect(LinkedPaths.linkedEntries(in: entries) == [".env.*"])
    }

    @Test func theSettingReadsSwitchesAndEntriesFromTheStoredText() {
        let setting = LinkedPaths.Setting(text: "!.env.*\n.venv\n!.unknown\n\n  .vscode/*  \n.venv")
        #expect(setting.disabledDefaults == [".env.*"])
        #expect(setting.entries == [".venv", ".vscode/*"])
        #expect(LinkedPaths.Setting(text: nil) == LinkedPaths.Setting())
    }

    /// Negations first, in the defaults' order, then the entries: one per line, the format `setLinkedPaths` stores.
    @Test func theSettingWritesNegationsThenEntries() {
        let setting = LinkedPaths.Setting(disabledDefaults: [".claude/settings.local.json", ".env"], entries: [".venv", ".vscode/*"])
        #expect(setting.text == "!.env\n!.claude/settings.local.json\n.venv\n.vscode/*")
        #expect(LinkedPaths.Setting(text: setting.text) == setting)
        #expect(LinkedPaths.Setting().text.isEmpty)
    }
}
