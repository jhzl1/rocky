import Foundation
import Testing
@testable import RockyKit

/// WSC-05: the Setup tab's one script, its step lines and what a failing step stops. The script runs in a real zsh here,
/// without a terminal.
@Suite(.blockingWork)
struct SetupStepsTests {
    private static let head = "ae1d50e5dd3134ec50016d089875905427f6e9fa"

    private func hook(_ body: String, in folder: URL) throws -> SetupSteps.Hook {
        let file = folder.appendingPathComponent(".husky/post-checkout")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorktreeServiceTests.writeHook(body, to: file)
        return SetupSteps.Hook(path: file, label: SetupSteps.Hook.label(of: file, worktree: folder, mainClone: folder), head: Self.head)
    }

    /// The script's output without its colors, and how it ended.
    private func run(_ steps: SetupSteps, in folder: URL) throws -> (output: String, status: Int32) {
        do {
            let output = try ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-c", steps.command + " 2>&1"], in: folder, environment: GitFixture.environment)
            return (TaskOutputWatcher.stripANSI(output), 0)
        } catch let failure as ProcessFailure {
            return ("", failure.status)
        }
    }

    @Test func theStepsAndTheirLines() throws {
        let folder = try Fixtures.temporaryDirectory("setup")
        let hook = try hook("true", in: folder)
        let both = SetupSteps(hook: hook, script: "pnpm db:migrate\npnpm seed\n")
        #expect(both.steps == [.hook, .script])
        #expect(both.hookLine == "▸ post-checkout hook · .husky/post-checkout")
        #expect(both.scriptLine == "▸ Setup · pnpm db:migrate …")
        #expect(SetupSteps(hook: nil, script: "  pnpm install  ").scriptLine == "▸ Setup · pnpm install")
        #expect(SetupSteps(hook: hook, script: " \n ").steps == [.hook])
        #expect(SetupSteps(hook: nil, script: nil).isEmpty)
        #expect(SetupSteps.Hook.label(of: URL(fileURLWithPath: "/elsewhere/post-checkout"), worktree: folder, mainClone: folder) == "/elsewhere/post-checkout")
    }

    /// The hook gets git's arguments for a new worktree and runs in the worktree, then the script; each step opens with
    /// its line, and the hook, not being last, ends with its own.
    @Test func theHookRunsThenTheScript() throws {
        let folder = try Fixtures.temporaryDirectory("setup")
        // The folder's name: `pwd -P` spells /var as /private/var, which Foundation's paths do not.
        let steps = SetupSteps(hook: try hook(#"echo "hook $@ in $(basename "$(pwd -P)")""#, in: folder), script: "echo script")
        let (output, status) = try run(steps, in: folder)
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines == [
            "▸ post-checkout hook · .husky/post-checkout",
            "hook \(SetupSteps.nullCommit) \(Self.head) 1 in \(folder.lastPathComponent)",
            "post-checkout exited with code 0",
            "▸ Setup · echo script",
            "script",
        ])
    }

    /// A failing hook ends the tab with its code, and the script never runs.
    @Test func aFailingHookStopsTheScript() throws {
        let folder = try Fixtures.temporaryDirectory("setup")
        let steps = SetupSteps(hook: try hook("exit 4", in: folder), script: "touch ran")
        #expect(try run(steps, in: folder).status == 4)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("ran").path))

        let alone = SetupSteps(hook: try hook("exit 5", in: folder), script: nil)
        #expect(try run(alone, in: folder).status == 5)
    }
}
