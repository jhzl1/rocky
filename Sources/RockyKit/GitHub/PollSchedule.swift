import Foundation

/// `PR-07`'s wait between refreshes of the selected workspace's pull request (user decision, 2026-09-24): a flat 30 s
/// while the window can be seen, so a change made outside Rocky shows within 30 s, and 15 s while checks or
/// deployments run. No backoff: 120 GraphQL queries an hour at rest (240 while something runs), one `URLSession`
/// request each and no process, well inside GitHub's 5,000-point hourly budget per account.
public enum PollSchedule {
    public static let idleWait: Duration = .seconds(30)
    /// While something runs, its result is what the user waits for.
    public static let runningWait: Duration = .seconds(15)

    /// The wait before the next refresh, given whether the last one saw checks or deployments running.
    public static func wait(running: Bool) -> Duration {
        running ? runningWait : idleWait
    }
}
