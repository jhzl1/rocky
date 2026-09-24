import Foundation

/// What `WorktreeLinker.link` did to a new worktree.
public struct WorktreeLinkResult: Sendable, Equatable {
    /// Repo-relative paths now symlinked into the worktree, in the order they were linked.
    public let linked: [String]
    /// Extra entries left alone because they are absolute or reach outside the main clone.
    public let rejected: [String]

    public init(linked: [String], rejected: [String]) {
        self.linked = linked
        self.rejected = rejected
    }
}

/// Symlinks the main clone's untracked environment files into a new worktree, which git leaves without them: secrets,
/// direnv and Wrangler files, Claude Code's local settings, plus the repo's extra entries (`Repo.linkedPaths` and the
/// `links` of rocky.json), where `!<pattern>` turns one of those defaults off (`LinkedPaths`). Replaces the per-repo
/// `setup-worktree.sh` scripts that did this from a post-checkout hook.
///
/// Symlinks, not copies: each file keeps a single owner in the main clone, so rotating a secret there reaches every
/// worktree. Each link is absolute. A destination that exists in any form, even a dangling symlink, is left alone,
/// which also keeps tracked files as checkout wrote them and makes running after such a hook harmless.
///
/// Blocking: call off the main actor.
public struct WorktreeLinker: Sendable {
    /// File names linked when git lists them as ignored in the main clone. `.dev.vars` holds Cloudflare Wrangler's
    /// local secrets.
    public static let environmentFilePatterns = [".env", ".env.*", ".envrc", ".dev.vars", ".dev.vars.*"]
    /// Endings of the committed templates of those files, which are never linked.
    public static let templateSuffixes = [".example", ".sample", ".template", ".dist"]
    /// Repo-relative paths linked when git lists them as ignored, whatever their name.
    public static let alwaysLinkedPaths = [".claude/settings.local.json"]

    private static let git = URL(fileURLWithPath: "/usr/bin/git")
    private static let globCharacters: Set<Character> = ["*", "?", "["]

    public let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// Links the automatic candidates, then `extraEntries`: repo-relative paths (a directory links as a whole) or
    /// globs (each match links on its own). An entry that is absolute or climbs out of the main clone is rejected. An
    /// entry `!<pattern>` links nothing: naming one of `LinkedPaths.defaults`, it turns that default off, and naming
    /// anything else, it is ignored.
    public func link(mainClone: URL, into worktree: URL, extraEntries: [String]) throws -> WorktreeLinkResult {
        let root = mainClone.path
        var paths = try automaticCandidates(mainClone: mainClone, disabled: LinkedPaths.disabledDefaults(in: extraEntries))
        var rejected: [String] = []
        for entry in LinkedPaths.linkedEntries(in: extraEntries) {
            guard let relative = Self.relativePath(entry) else {
                rejected.append(entry)
                continue
            }
            if relative.contains(where: Self.globCharacters.contains) {
                paths += Self.matches(of: relative, in: root).compactMap(Self.relativePath)
            } else {
                paths.append(relative)
            }
        }
        var linked: [String] = []
        var seen: Set<String> = []
        for path in paths where seen.insert(path).inserted {
            if try Self.linkIfMissing(path, from: root, to: worktree.path) { linked.append(path) }
        }
        return WorktreeLinkResult(linked: linked, rejected: rejected)
    }

    /// Whether a path git lists as ignored is linked without being asked for: an environment file that is not a
    /// template, or one of `alwaysLinkedPaths`. The patterns and paths in `disabled` pick nothing, so a name only they
    /// match is not linked.
    public static func isLinkedAutomatically(_ path: String, disabled: Set<String> = []) -> Bool {
        if alwaysLinkedPaths.contains(path) { return !disabled.contains(path) }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if templateSuffixes.contains(where: name.hasSuffix) { return false }
        return environmentFilePatterns.contains { !disabled.contains($0) && fnmatch($0, name, 0) == 0 }
    }

    /// The ignored files of the main clone that `isLinkedAutomatically` picks. `--directory` collapses an ignored
    /// directory such as `node_modules/` into one entry ending in "/", so its contents are never listed, and those
    /// entries are dropped: a directory is linked only when asked for. With every default turned off, git does not run.
    private func automaticCandidates(mainClone: URL, disabled: Set<String>) throws -> [String] {
        guard !disabled.isSuperset(of: LinkedPaths.defaults) else { return [] }
        let listing = try ProcessRunner.run(
            Self.git,
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
            in: mainClone,
            environment: environment
        )
        return listing.split(separator: "\0").map(String.init).filter {
            !$0.hasSuffix("/") && Self.isLinkedAutomatically($0, disabled: disabled)
        }
    }

    /// `entry` as a clean repo-relative path, or nil when it is absolute, names the repo itself or climbs out of it.
    /// Lexical only: a symlink inside the main clone is linked as itself, never followed.
    static func relativePath(_ entry: String) -> String? {
        guard !entry.hasPrefix("/") else { return nil }
        var components: [Substring] = []
        for component in entry.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// The repo-relative paths under `root` that match `pattern`, with glob(3)'s rules: `*` skips names starting
    /// with a dot unless the pattern spells the dot.
    private static func matches(of pattern: String, in root: String) -> [String] {
        // The root is literal: escape what glob(3) would read as a pattern in a folder name.
        let escapedRoot = root.reduce(into: "") { escaped, character in
            if globCharacters.contains(character) || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        var found = glob_t()
        defer { globfree(&found) }
        guard glob(escapedRoot + "/" + pattern, 0, nil, &found) == 0 else { return [] }
        let prefix = root + "/"
        return (0..<Int(found.gl_pathc)).compactMap { index in
            guard let match = found.gl_pathv[index].map({ String(cString: $0) }), match.hasPrefix(prefix) else { return nil }
            return String(match.dropFirst(prefix.count))
        }
    }

    /// Creates `worktreeRoot/path` pointing at `mainRoot/path`. Returns false, changing nothing, when the source does
    /// not exist or the destination exists in any form.
    private static func linkIfMissing(_ path: String, from mainRoot: String, to worktreeRoot: String) throws -> Bool {
        let source = mainRoot + "/" + path
        let destination = worktreeRoot + "/" + path
        guard FileManager.default.fileExists(atPath: source), !existsWithoutFollowing(destination) else { return false }
        let parent = (destination as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: source)
        return true
    }

    /// lstat(2): true for a dangling symlink too, which `FileManager.fileExists` reports as missing.
    private static func existsWithoutFollowing(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
