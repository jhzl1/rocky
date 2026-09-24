import Foundation
import Testing
@testable import RockyKit

struct WorktreeLinkerTests {
    private let linker = WorktreeLinker(environment: GitFixture.environment)

    private struct Checkout {
        let parent: URL
        let main: URL
        let worktree: URL
    }

    /// A main clone with ignored environment files, a tracked `.env.shared`, ignored `.venv/` and `.vscode/`
    /// directories, and a worktree made from it, which has none of the ignored files.
    private func makeCheckout() throws -> Checkout {
        let parent = try Fixtures.temporaryDirectory("links")
        let main = try GitFixture.localRepo(in: parent)
        try write(".env*\n.envrc\n.dev.vars*\n.venv/\n.vscode/\n.claude/settings.local.json\n", to: ".gitignore", in: main)
        try write("name = \"api\"\n", to: "apps/api/wrangler.toml", in: main)
        try write("SHARED=1\n", to: ".env.shared", in: main)
        try GitFixture.git(["add", ".gitignore", "apps/api/wrangler.toml"], in: main)
        try GitFixture.git(["add", "-f", ".env.shared"], in: main)
        try GitFixture.git(["commit", "-q", "-m", "config"], in: main)
        let ignored = [
            ".env", ".env.local", ".env.production", ".env.example", ".envrc", "apps/api/.dev.vars",
            ".claude/settings.local.json", ".venv/bin/python", ".vscode/settings.json", ".vscode/launch.json",
        ]
        for path in ignored {
            try write("main\n", to: path, in: main)
        }
        let worktree = try WorktreeService(environment: GitFixture.environment).create(repo: main, name: "lisbon").path
        return Checkout(parent: parent, main: main, worktree: worktree)
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func symlinkDestination(_ path: String, in root: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(path).path)
    }

    @Test func linksTheIgnoredEnvironmentFilesAsAbsoluteSymlinks() throws {
        let checkout = try makeCheckout()
        let result = try linker.link(mainClone: checkout.main, into: checkout.worktree, extraEntries: [])
        let expected = [".env", ".env.local", ".env.production", ".envrc", "apps/api/.dev.vars", ".claude/settings.local.json"]
        #expect(result.linked.sorted() == expected.sorted())
        #expect(result.rejected.isEmpty)
        for path in expected {
            #expect(symlinkDestination(path, in: checkout.worktree) == checkout.main.appendingPathComponent(path).path)
        }
    }

    @Test func skipsTemplatesAndLeavesTrackedFilesAlone() throws {
        let checkout = try makeCheckout()
        let result = try linker.link(mainClone: checkout.main, into: checkout.worktree, extraEntries: ["README.md"])
        #expect(!FileManager.default.fileExists(atPath: checkout.worktree.appendingPathComponent(".env.example").path))
        #expect(!result.linked.contains(".env.example"))
        for tracked in [".env.shared", "README.md"] {
            #expect(!result.linked.contains(tracked))
            #expect(symlinkDestination(tracked, in: checkout.worktree) == nil)
            #expect(FileManager.default.fileExists(atPath: checkout.worktree.appendingPathComponent(tracked).path))
        }
    }

    @Test func leavesAnExistingFileAndADanglingSymlinkAlone() throws {
        let checkout = try makeCheckout()
        try write("worktree\n", to: ".env.production", in: checkout.worktree)
        try FileManager.default.createSymbolicLink(
            atPath: checkout.worktree.appendingPathComponent(".envrc").path,
            withDestinationPath: "/nonexistent/rocky-envrc"
        )

        let result = try linker.link(mainClone: checkout.main, into: checkout.worktree, extraEntries: [])

        #expect(!result.linked.contains(".env.production"))
        #expect(!result.linked.contains(".envrc"))
        let production = try String(contentsOf: checkout.worktree.appendingPathComponent(".env.production"), encoding: .utf8)
        #expect(production == "worktree\n")
        #expect(symlinkDestination(".envrc", in: checkout.worktree) == "/nonexistent/rocky-envrc")
    }

    @Test func linksAnExtraDirectoryAsAWholeAndEachMatchOfAGlob() throws {
        let checkout = try makeCheckout()
        let result = try linker.link(mainClone: checkout.main, into: checkout.worktree, extraEntries: [".venv", "  .vscode/*  ", ""])

        #expect(result.linked.contains(".venv"))
        #expect(result.linked.contains(".vscode/launch.json"))
        #expect(result.linked.contains(".vscode/settings.json"))
        #expect(result.rejected.isEmpty)
        #expect(symlinkDestination(".venv", in: checkout.worktree) == checkout.main.appendingPathComponent(".venv").path)
        // The glob links the files, so the directory holding them is the worktree's own.
        #expect(symlinkDestination(".vscode", in: checkout.worktree) == nil)
        #expect(symlinkDestination(".vscode/settings.json", in: checkout.worktree) == checkout.main.appendingPathComponent(".vscode/settings.json").path)
    }

    @Test func rejectsEntriesOutsideTheMainClone() throws {
        let checkout = try makeCheckout()
        try write("secret\n", to: "outside", in: checkout.parent)

        let result = try linker.link(
            mainClone: checkout.main,
            into: checkout.worktree,
            extraEntries: ["../outside", "/etc/hosts", "apps/../../outside"]
        )

        #expect(result.rejected == ["../outside", "/etc/hosts", "apps/../../outside"])
        #expect(!result.linked.contains { $0.contains("outside") || $0.contains("hosts") })
        let escaped = checkout.worktree.deletingLastPathComponent().appendingPathComponent("outside").path
        #expect(!FileManager.default.fileExists(atPath: escaped))
    }

    @Test func picksEnvironmentFilesByNameAndSkipsTemplates() {
        for path in [".env", "apps/web/.env.local", ".envrc", "apps/api/.dev.vars", ".dev.vars.staging", ".claude/settings.local.json"] {
            #expect(WorktreeLinker.isLinkedAutomatically(path), "\(path)")
        }
        for path in [".env.example", ".env.local.sample", ".dev.vars.template", ".env.dist", "env", ".environment", ".claude/settings.json"] {
            #expect(!WorktreeLinker.isLinkedAutomatically(path), "\(path)")
        }
    }
}
