import Foundation
import Testing
@testable import RockyKit

/// PR-07 (user decision, 2026-09-24): a flat 30 s, with no backoff, and 15 s while checks or deployments run.
struct PollScheduleTests {
    @Test func waitsThirtySecondsAndFifteenWhileSomethingRuns() {
        #expect(PollSchedule.wait(running: false) == .seconds(30))
        #expect(PollSchedule.wait(running: true) == .seconds(15))
    }
}
