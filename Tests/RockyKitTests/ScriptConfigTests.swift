import Foundation
import Testing
@testable import RockyKit

struct ScriptConfigTests {
    private func workspace(conductorJSON: String?) throws -> URL {
        let url = try Fixtures.temporaryDirectory("scripts")
        if let conductorJSON {
            try Data(conductorJSON.utf8).write(to: url.appendingPathComponent(ScriptConfigResolver.fileName))
        }
        return url
    }

    /// The example from https://www.conductor.build/docs/core/conductor-json, verbatim.
    @Test func readsTheConductorDocsExample() throws {
        let example = """
        {
            "scripts": {
                "setup": "pnpm install",
                "run": "pnpm dev --port $CONDUCTOR_PORT",
                "archive": "./script/workspace-archive.sh"
            },
            "runScriptMode": "concurrent",
            "enterpriseDataPrivacy": true
        }
        """
        let repo = Repo(name: "app", path: "/r/app", setupScript: "ignored", runScriptMode: "nonconcurrent")
        let config = try ScriptConfigResolver.resolve(workspace: try workspace(conductorJSON: example), repo: repo)
        #expect(config == ScriptConfig(
            setup: "pnpm install",
            run: "pnpm dev --port $CONDUCTOR_PORT",
            archive: "./script/workspace-archive.sh",
            runMode: .concurrent,
            source: .conductorJSON
        ))
    }

    @Test func theFileReplacesRepoSettingsEvenForKeysItLacks() throws {
        let repo = Repo(name: "app", path: "/r/app", setupScript: "make deps", runScript: "make run")
        let config = try ScriptConfigResolver.resolve(workspace: try workspace(conductorJSON: #"{"scripts":{"setup":"pnpm i"}}"#), repo: repo)
        #expect(config == ScriptConfig(setup: "pnpm i", run: nil, archive: nil, runMode: .concurrent, source: .conductorJSON))
    }

    @Test func fallsBackToRepoSettingsAndDropsBlankScripts() throws {
        let repo = Repo(name: "app", path: "/r/app", setupScript: "make deps", runScript: "  \n", runScriptMode: "nonconcurrent")
        let config = try ScriptConfigResolver.resolve(workspace: try workspace(conductorJSON: nil), repo: repo)
        #expect(config == ScriptConfig(setup: "make deps", run: nil, archive: nil, runMode: .nonconcurrent, source: .repoSettings))
    }

    @Test func rejectsInvalidJSON() throws {
        let url = try workspace(conductorJSON: "{ not json")
        #expect(throws: ScriptConfigError.self) {
            try ScriptConfigResolver.resolve(workspace: url, repo: Repo(name: "app", path: "/r/app"))
        }
    }

    @Test func rejectsUnknownRunMode() throws {
        let url = try workspace(conductorJSON: #"{"runScriptMode":"parallel"}"#)
        #expect(throws: ScriptConfigError.invalidConductorJSON(#"runScriptMode must be "concurrent" or "nonconcurrent", got "parallel""#)) {
            try ScriptConfigResolver.resolve(workspace: url, repo: Repo(name: "app", path: "/r/app"))
        }
    }
}
