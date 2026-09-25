import Foundation
import Testing
@testable import RockyKit

/// `FIL-09`'s lookup, one test per step in its order, on small handmade manifests; then the vendored manifest itself,
/// with the requirement's examples, and the SVGs it needs.
struct FileIconsTests {
    private let manifest = FileIconManifest(
        fileNames: [
            "package.json": "nodejs",
            "tsconfig.json": "tsconfig",
            "README.md": "readme",
            "graphqlrc": "graphql",
            ".config/graphqlrc": "graphql-config",
            "a/b/c.json": "deep",
            "b/c.json": "shallow",
            ".github/FUNDING.yml": "github-sponsors",
        ],
        fileExtensions: [
            "ts": "typescript",
            "test.ts": "test-ts",
            "d.ts": "typescript-def",
            "tsx": "react_ts",
            "json": "json",
            "yml": "yaml",
            "yaml": "yaml",
            "env": "tune",
            "gz": "zip",
            "md": "markdown",
        ],
        file: "file"
    )

    private func icon(_ path: String) -> String {
        FileIcons.iconId(forPath: path, manifest: manifest)
    }

    /// Step 1: the longest path tail wins, on whole components, relative or absolute, in any case; a tail beats the
    /// file name alone.
    @Test func aPathTailMatchesOnWholeComponents() {
        #expect(icon(".config/graphqlrc") == "graphql-config")
        #expect(icon("app/.config/graphqlrc") == "graphql-config")
        #expect(icon("/Users/me/rocky-worktrees/tokyo/.config/graphqlrc") == "graphql-config")
        #expect(icon("/Users/me/tokyo/.CONFIG/GraphQLrc") == "graphql-config")
        #expect(icon("x/a/b/c.json") == "deep")
        #expect(icon("/tmp/b/c.json") == "shallow")
        #expect(icon(".github/funding.yml") == "github-sponsors")
        // Not on a component boundary, or not the tail: the name and the extension decide.
        #expect(icon("x.config/graphqlrc") == "graphql")
        #expect(icon("xb/c.json") == "json")
        #expect(icon(".config/graphqlrc/other.ts") == "typescript")
    }

    /// Step 2: the file name, in any folder and in any case, before its extension.
    @Test func theFileNameComesBeforeItsExtension() {
        #expect(icon("package.json") == "nodejs")
        #expect(icon("apps/web/Package.JSON") == "nodejs")
        #expect(icon("/Users/me/tokyo/tsconfig.json") == "tsconfig")
        #expect(icon("readme.md") == "readme")
        #expect(icon("docs/guide.md") == "markdown")
    }

    /// Step 3: the longest compound extension, before the plain one.
    @Test func theLongestCompoundExtensionWins() {
        #expect(icon("src/api.test.ts") == "test-ts")
        #expect(icon("types/global.d.ts") == "typescript-def")
        #expect(icon("SRC/API.TEST.TS") == "test-ts")
        // A compound extension the manifest lacks falls back to the plain one.
        #expect(icon("src/api.spec.ts") == "typescript")
        #expect(icon("backup.tar.gz") == "zip")
    }

    /// Step 4: the extension, in any case; a dotfile's name after its dot counts as one.
    @Test func theExtensionComesNext() {
        #expect(icon("src/main.ts") == "typescript")
        #expect(icon("src/App.TSX") == "react_ts")
        #expect(icon("config/app.yml") == "yaml")
        #expect(icon(".env") == "tune")
        #expect(icon("/Users/me/tokyo/.ENV") == "tune")
    }

    /// Step 5: no name, tail or extension matches: the default, also with no extension or an empty one.
    @Test func anythingElseGetsTheDefault() {
        #expect(icon("Makefile") == "file")
        #expect(icon("bin/run") == "file")
        #expect(icon("notes.unknown") == "file")
        #expect(icon("trailing.") == "file")
        #expect(icon("") == "file")
        #expect(icon("/") == "file")
    }

    /// The emulated `languageIds` rule: a `.yml` or `.yaml` anywhere under `.github/workflows/`, relative or absolute,
    /// in any case, before every other step; the same files elsewhere keep their own icon.
    @Test func workflowsUnderGitHubWorkflowsGetTheActionsIcon() {
        #expect(icon(".github/workflows/ci.yml") == FileIcons.workflowIcon)
        #expect(icon(".github/workflows/release.YAML") == FileIcons.workflowIcon)
        #expect(icon(".GitHub/Workflows/CI.yml") == FileIcons.workflowIcon)
        #expect(icon("/Users/me/tokyo/.github/workflows/deploy.yaml") == FileIcons.workflowIcon)
        #expect(icon(".github/workflows/reusable/build.yml") == FileIcons.workflowIcon)
        #expect(icon("packages/api/.github/workflows/ci.yml") == FileIcons.workflowIcon)
        // Outside `.github/workflows/`, or not YAML.
        #expect(icon("workflows/ci.yml") == "yaml")
        #expect(icon(".github/ci.yml") == "yaml")
        #expect(icon("github/workflows/ci.yml") == "yaml")
        #expect(icon(".github/workflows.yml") == "yaml")
        #expect(icon(".github/workflows/README.md") == "readme")
        #expect(icon(".github/workflows/notes.txt") == "file")
    }

    /// Keys are lowercased when the manifest is made, and two keys equal but for case keep the smaller id, whatever the
    /// dictionary's order; path tails lose empty components.
    @Test func theManifestIgnoresCaseInItsKeys() {
        let mixed = FileIconManifest(
            fileNames: ["APKBUILD": "alpine", "apkbuild": "alpha", "/.Config//PostCSSrc": "postcss"],
            fileExtensions: ["YAML-tmLanguage": "yaml-tm", "": "none"],
            file: "file"
        )
        #expect(mixed.fileNames == ["apkbuild": "alpha"])
        #expect(mixed.fileExtensions == ["yaml-tmlanguage": "yaml-tm"])
        #expect(mixed.pathTails == [".config/postcssrc": "postcss"])
        #expect(mixed.tailDepth == 2)
        #expect(FileIcons.iconId(forPath: "syntaxes/Rocky.YAML-tmLanguage", manifest: mixed) == "yaml-tm")
        #expect(FileIcons.iconId(forPath: "tokyo/.config/postcssrc", manifest: mixed) == "postcss")
    }

    // MARK: - The vendored manifest

    /// `Sources/RockyUI/Resources/FileIcons/`, which `scripts/vendor-file-icons.py` writes.
    private static let vendored = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RockyUI/Resources/FileIcons")

    private func vendoredManifest() throws -> FileIconManifest {
        let data = try Data(contentsOf: Self.vendored.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(FileIconManifest.self, from: data)
    }

    /// FIL-09's examples, on Material Icon Theme 5.38.1's own associations: 2,135 file names, 204 of them path tails.
    @Test func theVendoredManifestGivesTheRequirementsExamples() throws {
        let manifest = try vendoredManifest()
        #expect(manifest.fileNames.count + manifest.pathTails.count == 2135)
        #expect(manifest.pathTails.count == 204)
        #expect(manifest.fileExtensions.count == 1377)
        let expected = [
            "package.json": "nodejs",
            "tsconfig.json": "tsconfig",
            ".gitignore": "git",
            "README.md": "readme",
            "src/api.test.ts": "test-ts",
            "types/global.d.ts": "typescript-def",
            "src/openapi.ts": "typescript",
            "src/App.tsx": "react_ts",
            "config/app.yml": "yaml",
            ".env": "tune",
            ".config/graphqlrc": "graphql",
            ".github/workflows/ci.yml": FileIcons.workflowIcon,
            "notes/draft.unknown": "file",
        ]
        for (path, id) in expected {
            #expect(FileIcons.iconId(forPath: path, manifest: manifest) == id, "\(path)")
        }
    }

    /// Every icon the manifest can return has its SVG next to it, the workflow icon and the default included, so no
    /// file falls back to `FileKind`'s symbol for a missing resource.
    @Test func everyIconTheVendoredManifestNamesShips() throws {
        let manifest = try vendoredManifest()
        let ids = Set(manifest.fileNames.values)
            .union(manifest.pathTails.values)
            .union(manifest.fileExtensions.values)
            .union([manifest.file, FileIcons.workflowIcon])
        let shipped = try FileManager.default.contentsOfDirectory(atPath: Self.vendored.path)
        let svgs = Set(shipped.filter { $0.hasSuffix(".svg") }.map { String($0.dropLast(4)) })
        #expect(ids.subtracting(svgs).isEmpty)
        #expect(svgs == ids)
        #expect(shipped.contains("LICENSE"))
    }
}
