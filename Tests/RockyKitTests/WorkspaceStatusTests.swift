import Testing
@testable import RockyKit

struct WorkspaceStatusTests {
    /// Every pair of states resolves to the one listed first in ROW-03: needs you › error › working › unread › idle.
    @Test func priorityOrder() {
        #expect(WorkspaceStatus.resolve(needsYou: true, failure: "x", working: true, unread: true) == .needsYou)
        #expect(WorkspaceStatus.resolve(needsYou: true, failure: nil, working: false, unread: false) == .needsYou)
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: "x", working: true, unread: true) == .failed("x"))
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: "x", working: false, unread: false) == .failed("x"))
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: true, unread: true) == .working)
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: false, unread: true) == .unread)
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: false, unread: false) == .idle)
    }

    @Test func aFoldedRepositoryShowsItsMostUrgentWorkspace() {
        #expect(WorkspaceStatus.mostUrgent([.working, .failed("setup"), .idle]) == .failed("setup"))
        #expect(WorkspaceStatus.mostUrgent([.idle, .unread]) == .unread)
        #expect(WorkspaceStatus.mostUrgent([]) == .idle)
    }
}
