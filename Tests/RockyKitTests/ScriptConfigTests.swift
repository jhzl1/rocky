import Foundation
import Testing
@testable import RockyKit

struct ScriptConfigTests {
    private func workspace(rockyJSON: String?) throws -> URL {
        let url = try Fixtures.temporaryDirectory("scripts")
        if let rockyJSON {
            try Data(rockyJSON.utf8).write(to: url.appendingPathComponent(ScriptConfigResolver.fileName))
        }
        return url
    }

    /// Unknown keys are ignored.
    @Test func readsRockyJSON() throws {
        let example = """
        {
            "scripts": {
                "setup": "pnpm install",
                "run": "pnpm dev --port $PORT",
                "archive": "./script/workspace-archive.sh"
            },
            "runScriptMode": "concurrent",
            "comment": "kept in git"
        }
        """
        let repo = Repo(name: "app", path: "/r/app", setupScript: "ignored", runScriptMode: "nonconcurrent")
        let config = try ScriptConfigResolver.resolve(workspace: try workspace(rockyJSON: example), repo: repo)
        #expect(config == ScriptConfig(
            setup: "pnpm install",
            run: "pnpm dev --port $PORT",
            archive: "./script/workspace-archive.sh",
            runMode: .concurrent,
            source: .rockyJSON
        ))
    }

    @Test func theFileReplacesRepoSettingsEvenForKeysItLacks() throws {
        let repo = Repo(name: "app", path: "/r/app", setupScript: "make deps", runScript: "make run")
        let config = try ScriptConfigResolver.resolve(workspace: try workspace(rockyJSON: #"{"scripts":{"setup":"pnpm i"}}"#), repo: repo)
        #expect(config == ScriptConfig(setup: "pnpm i", run: nil, archive: nil, runMode: .concurrent, source: .rockyJSON))
    }

    @Test func fallsBackToRepoSettingsAndDropsBlankScripts() throws {
        let repo = Repo(name: "app", path: "/r/app", setupScript: "make deps", runScript: "  \n", runScriptMode: "nonconcurrent")
        let config = try ScriptConfigResolver.resolve(workspace: try workspace(rockyJSON: nil), repo: repo)
        #expect(config == ScriptConfig(setup: "make deps", run: nil, archive: nil, runMode: .nonconcurrent, source: .repoSettings))
    }

    /// Links add up instead of replacing: the repo setting's first, then the file's, each once.
    @Test func linksAreTheRepoSettingsAndTheFilesTogether() throws {
        let repo = Repo(name: "app", path: "/r/app", linkedPaths: ".venv\n  \n.vscode/*\n")
        let withFile = try ScriptConfigResolver.resolve(
            workspace: try workspace(rockyJSON: #"{"links":[".vscode/*", " apps/api-core/celes-platform-*.json ", ""]}"#),
            repo: repo
        )
        #expect(withFile.links == [".venv", ".vscode/*", "apps/api-core/celes-platform-*.json"])
        let withoutFile = try ScriptConfigResolver.resolve(workspace: try workspace(rockyJSON: nil), repo: repo)
        #expect(withoutFile.links == [".venv", ".vscode/*"])
    }

    /// A default turned off ("!<pattern>") in either place reaches the linker, merged like any other link.
    @Test func negationsFromTheRepoSettingAndTheFileAddUp() throws {
        let repo = Repo(name: "app", path: "/r/app", linkedPaths: "!.env\n.venv")
        let config = try ScriptConfigResolver.resolve(
            workspace: try workspace(rockyJSON: #"{"links":[" !.envrc ", "!.env"]}"#),
            repo: repo
        )
        #expect(config.links == ["!.env", ".venv", "!.envrc"])
    }

    @Test func rejectsInvalidJSON() throws {
        let url = try workspace(rockyJSON: "{ not json")
        #expect(throws: ScriptConfigError.self) {
            try ScriptConfigResolver.resolve(workspace: url, repo: Repo(name: "app", path: "/r/app"))
        }
    }

    @Test func rejectsUnknownRunMode() throws {
        let url = try workspace(rockyJSON: #"{"runScriptMode":"parallel"}"#)
        #expect(throws: ScriptConfigError.invalidRockyJSON(#"runScriptMode must be "concurrent" or "nonconcurrent", got "parallel""#)) {
            try ScriptConfigResolver.resolve(workspace: url, repo: Repo(name: "app", path: "/r/app"))
        }
    }
}
