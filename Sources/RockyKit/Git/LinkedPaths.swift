import Foundation

/// Why repository settings refuse a path typed into the linked files' add field.
public enum LinkedPathProblem: Error, Equatable, Sendable {
    case empty
    /// Starts with "!": turning a default off is its switch, and a negation of anything else does nothing.
    case negation
    case absolute
    /// Climbs out of the repository with "..", or names the repository itself.
    case outsideRepository
    /// One of `LinkedPaths.defaults`, which have a row of their own.
    case isDefault
    case duplicate

    public var message: String {
        switch self {
        case .empty: "Enter a path or a glob."
        case .negation: "Turn a default off with its switch."
        case .absolute: "Use a path relative to the repository."
        case .outsideRepository: "Name a path inside the repository."
        case .isDefault: "Rocky links this by default."
        case .duplicate: "Already in the list."
        }
    }
}

/// The entries of the linked files setting (`Repo.linkedPaths`) and of rocky.json's `links`, one per line and
/// gitignore-style: a path or glob links that path, and `!<pattern>` naming one of `defaults` turns that default off
/// (user request, 2026-09-23). A negation naming anything else is ignored, and no negation is ever linked. Turning a
/// default off needs no migration: it is one more line of the same column.
public enum LinkedPaths {
    /// What `WorktreeLinker` links without being asked, in the order repository settings list them.
    public static let defaults = WorktreeLinker.environmentFilePatterns + WorktreeLinker.alwaysLinkedPaths

    /// The defaults that `entries` turn off: each `!<pattern>` whose pattern is one of `defaults`.
    public static func disabledDefaults(in entries: [String]) -> Set<String> {
        Set(entries.compactMap(negatedPattern).filter { defaults.contains($0) })
    }

    /// The entries that name something to link: every entry but the negations, trimmed, blank ones dropped.
    public static func linkedEntries(in entries: [String]) -> [String] {
        entries.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("!") }
    }

    /// The pattern of a `!<pattern>` entry, as a clean repo-relative path when it is one ("!./.env" is ".env"); nil
    /// for any other entry.
    static func negatedPattern(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!") else { return nil }
        let pattern = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return WorktreeLinker.relativePath(pattern) ?? pattern
    }

    /// Checks a path or glob typed into repository settings against the user's `existing` entries and the defaults.
    /// Succeeds with the entry to store, cleaned ("./.venv/" is ".venv").
    public static func validate(_ entry: String, existing: [String]) -> Result<String, LinkedPathProblem> {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard !trimmed.hasPrefix("!") else { return .failure(.negation) }
        // "~" is not expanded: the linker would read it as a folder of the repository named "~".
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return .failure(.absolute) }
        guard let relative = WorktreeLinker.relativePath(trimmed) else { return .failure(.outsideRepository) }
        guard !defaults.contains(relative) else { return .failure(.isDefault) }
        let taken = existing.map { existingEntry in
            let trimmedEntry = existingEntry.trimmingCharacters(in: .whitespaces)
            return WorktreeLinker.relativePath(trimmedEntry) ?? trimmedEntry
        }
        guard !taken.contains(relative) else { return .failure(.duplicate) }
        return .success(relative)
    }

    /// `Repo.linkedPaths` as repository settings edit it: a switch per default and the user's own entries.
    public struct Setting: Equatable, Sendable {
        /// The defaults turned off.
        public var disabledDefaults: Set<String>
        /// The user's paths and globs, in the order they were added.
        public var entries: [String]

        public init(disabledDefaults: Set<String> = [], entries: [String] = []) {
            self.disabledDefaults = disabledDefaults
            self.entries = entries
        }

        /// Reads the stored text. A negation naming no default is dropped: it changes nothing and has no row. An entry
        /// written twice, which the free-form field of earlier versions allowed, is kept once.
        public init(text: String?) {
            let lines = ScriptConfigResolver.linkEntries(text)
            var seen: Set<String> = []
            let entries = LinkedPaths.linkedEntries(in: lines).filter { seen.insert($0).inserted }
            self.init(disabledDefaults: LinkedPaths.disabledDefaults(in: lines), entries: entries)
        }

        /// The text `AppModel.setLinkedPaths` stores: "!<pattern>" for each default turned off, in the defaults'
        /// order, then the entries.
        public var text: String {
            let negations = LinkedPaths.defaults.filter { disabledDefaults.contains($0) }.map { "!" + $0 }
            return (negations + entries).joined(separator: "\n")
        }
    }
}
