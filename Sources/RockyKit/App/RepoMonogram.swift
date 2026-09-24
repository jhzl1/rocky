import Foundation

/// A repository's monogram in the sidebar (SB-03): its first letter on a color picked from the repository id.
public enum RepoMonogram {
    /// The palette color of the repository, the same on every launch: FNV-1a 32-bit over the UTF-8 bytes of the id.
    /// Never `hashValue`, which Swift seeds per launch.
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
