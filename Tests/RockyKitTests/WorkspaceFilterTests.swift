import Testing
@testable import RockyKit

/// SB-02: the sidebar search matches a row's title, branch, workspace name or repository name, ignoring case.
struct WorkspaceFilterTests {
    private func matches(_ query: String) -> Bool {
        WorkspaceFilter.matches(
            query: query,
            title: "Fix invoice rounding",
            branch: "jhzl/invoice-rounding",
            name: "lima",
            repo: "celes-platform"
        )
    }

    @Test func anEmptyQueryMatchesEverything() {
        #expect(matches(""))
        #expect(matches("   "))
    }

    @Test func matchingIgnoresCase() {
        #expect(matches("ROU"))
        #expect(matches("Lima"))
        #expect(matches("CELES"))
    }

    @Test func matchesTheTitleBranchNameOrRepository() {
        #expect(matches("invoice rounding"))
        #expect(matches("jhzl/invoice"))
        #expect(matches("lim"))
        #expect(matches("platform"))
        #expect(!matches("tokyo"))
    }

    /// The acceptance check of SB-02: "rou" leaves only "Fix invoice rounding".
    @Test func rouLeavesOnlyTheInvoiceRow() {
        #expect(matches("rou"))
        #expect(!WorkspaceFilter.matches(
            query: "rou",
            title: "OpenAPI export for providers",
            branch: "jhzl/openapi-export",
            name: "tokyo",
            repo: "celes-platform"
        ))
    }
}
