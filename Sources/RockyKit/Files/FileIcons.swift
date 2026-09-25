import Foundation

/// Material Icon Theme's file associations (`FIL-09`), as `scripts/vendor-file-icons.py` trims them from the theme's
/// `dist/material-icons.json`: file names and extensions to icon ids, and the default. Keys are lowercased when it is
/// made, since the lookup ignores case, and the file names that are path tails (`.config/graphqlrc`) are kept apart,
/// by their number of components, so a lookup checks only its own path's tails.
public struct FileIconManifest: Sendable, Equatable {
    /// File names without a folder, lowercased: `package.json`, `.gitignore`.
    public let fileNames: [String: String]
    /// Extensions without their first dot, lowercased: `ts`, and compound ones such as `test.ts` and `d.ts`.
    public let fileExtensions: [String: String]
    /// The icon of a file nothing else matches.
    public let file: String
    /// The file names with a folder, lowercased and with no empty component: `.config/graphqlrc`.
    let pathTails: [String: String]
    /// The most components in a key of `pathTails`; 0 when there is none.
    let tailDepth: Int

    public init(fileNames: [String: String], fileExtensions: [String: String], file: String) {
        var names: [String: String] = [:]
        var tails: [String: String] = [:]
        var depth = 0
        for (key, icon) in fileNames {
            let components = key.lowercased().split(separator: "/")
            guard let last = components.last else { continue }
            if components.count == 1 {
                Self.add(String(last), icon, to: &names)
            } else {
                Self.add(components.joined(separator: "/"), icon, to: &tails)
                depth = max(depth, components.count)
            }
        }
        var extensions: [String: String] = [:]
        for (key, icon) in fileExtensions where !key.isEmpty {
            Self.add(key.lowercased(), icon, to: &extensions)
        }
        self.fileNames = names
        self.fileExtensions = extensions
        self.file = file
        self.pathTails = tails
        self.tailDepth = depth
    }

    /// Two keys equal but for case keep the smaller id, so the result never depends on the dictionary's order. The
    /// vendoring script refuses such a manifest, so this only guards a handmade one.
    private static func add(_ key: String, _ icon: String, to map: inout [String: String]) {
        if let existing = map[key], existing <= icon { return }
        map[key] = icon
    }
}

extension FileIconManifest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case fileNames, fileExtensions, file
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fileNames: try container.decode([String: String].self, forKey: .fileNames),
            fileExtensions: try container.decode([String: String].self, forKey: .fileExtensions),
            file: try container.decode(String.self, forKey: .file)
        )
    }
}

/// Which Material Icon Theme icon a file draws (`FIL-09`). Pure, so tests pass small handmade manifests; RockyUI
/// decodes the bundled one once and draws the id's SVG (`FileIcon`).
public enum FileIcons {
    /// The icon of the one VS Code `languageIds` rule Rocky emulates: a `.yml` or `.yaml` under `.github/workflows/`.
    public static let workflowIcon = "github-actions-workflow"

    /// The icon id of the file at `path`, relative or absolute, case-insensitive; the first match wins:
    /// 1. a `.yml` or `.yaml` file anywhere under a `.github/workflows/` folder: `workflowIcon`;
    /// 2. the longest path tail of `fileNames`, matched on whole components (`.config/graphqlrc`, and not
    ///    `x.config/graphqlrc`);
    /// 3. the file name (`package.json`);
    /// 4. the longest compound extension (`test.ts`, `d.ts`), then the extension (`ts`): the name after each of its
    ///    dots, from the first;
    /// 5. `manifest.file`.
    ///
    /// Every step is one dictionary hit per candidate, with no scan of the manifest, since the tree asks for every row
    /// it draws.
    public static func iconId(forPath path: String, manifest: FileIconManifest) -> String {
        let components = path.lowercased().split(separator: "/")
        guard let name = components.last else { return manifest.file }
        if isWorkflow(components) { return workflowIcon }
        if manifest.tailDepth > 1, components.count > 1 {
            for depth in stride(from: min(manifest.tailDepth, components.count), through: 2, by: -1) {
                if let icon = manifest.pathTails[components.suffix(depth).joined(separator: "/")] { return icon }
            }
        }
        if let icon = manifest.fileNames[String(name)] { return icon }
        var rest = name[...]
        while let dot = rest.firstIndex(of: ".") {
            let suffix = rest[rest.index(after: dot)...]
            if !suffix.isEmpty, let icon = manifest.fileExtensions[String(suffix)] { return icon }
            rest = suffix
        }
        return manifest.file
    }

    /// GitHub reads workflows from `.github/workflows/`; the GitHub Actions extension, whose language id the theme
    /// maps, also takes its subfolders (`**/.github/workflows/**/*.yml`).
    private static func isWorkflow(_ components: [Substring]) -> Bool {
        guard let name = components.last, name.hasSuffix(".yml") || name.hasSuffix(".yaml") else { return false }
        let folders = components.dropLast()
        return zip(folders, folders.dropFirst()).contains { $0 == ".github" && $1 == "workflows" }
    }
}
