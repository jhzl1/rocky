import Foundation

/// A repository's monogram in the sidebar (SB-03): its first letter on the repository's color.
public enum RepoMonogram {
    /// How many colors `Theme.repoPalette` has.
    public static let paletteCount = 6

    /// A new repository's color: at random among the palette colors the other repositories use least, so colors
    /// repeat only once every one is taken. The user wanted random colors; a hash of the id put doculift, veritas and
    /// celes-platform all on pink (2026-09-23). `pick` chooses among the candidates, at random unless a test says.
    public static func pickColor(
        used: [Int],
        paletteCount: Int = paletteCount,
        pick: ([Int]) -> Int? = { $0.randomElement() }
    ) -> Int {
        precondition(paletteCount > 0, "The palette needs at least one color")
        var counts = Array(repeating: 0, count: paletteCount)
        for index in used where counts.indices.contains(index) { counts[index] += 1 }
        let least = counts.min() ?? 0
        let candidates = counts.indices.filter { counts[$0] == least }
        return pick(candidates) ?? candidates[0]
    }

    /// The color of a repository that has none stored yet, the same on every launch: FNV-1a 32-bit over the UTF-8
    /// bytes of the id. Never `hashValue`, which Swift seeds per launch.
    public static func paletteIndex(repoId: String, paletteCount: Int) -> Int {
        precondition(paletteCount > 0, "The palette needs at least one color")
        return Int(fnv1a32(repoId) % UInt32(paletteCount))
    }

    /// The repository name's first character, uppercased; empty for an empty name.
    public static func letter(repoName: String) -> String {
        repoName.first.map { String($0).uppercased() } ?? ""
    }

    static func fnv1a32(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}
