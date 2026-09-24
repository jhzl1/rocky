import Testing
@testable import RockyKit

/// SB-03: a repository keeps its monogram color across launches, because the index comes from FNV-1a and not from
/// `hashValue`.
struct RepoMonogramTests {
    /// The published FNV-1a 32-bit test vectors, so the indexes below rest on the reference algorithm.
    @Test func hashMatchesTheFNV1aReferenceValues() {
        #expect(RepoMonogram.fnv1a32("") == 0x811C_9DC5)
        #expect(RepoMonogram.fnv1a32("a") == 0xE40C_292C)
        #expect(RepoMonogram.fnv1a32("foobar") == 0xBF9C_F968)
    }

    /// Computed by hand: FNV-1a("3F2504E0-4F89-11D3-9A0C-0305E82C3301") = 0xDA1B48A0 = 3659221152, and
    /// 3659221152 % 6 = 0; FNV-1a("rocky") = 0x45F6C0B7 = 1173799095, and 1173799095 % 6 = 3.
    @Test func paletteIndexIsStable() {
        #expect(RepoMonogram.paletteIndex(repoId: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", paletteCount: 6) == 0)
        #expect(RepoMonogram.paletteIndex(repoId: "rocky", paletteCount: 6) == 3)
    }

    @Test func letterIsTheUppercasedFirstCharacter() {
        #expect(RepoMonogram.letter(repoName: "celes-platform") == "C")
        #expect(RepoMonogram.letter(repoName: "Rocky") == "R")
        #expect(RepoMonogram.letter(repoName: "élan") == "É")
        #expect(RepoMonogram.letter(repoName: "") == "")
    }
}
