import Foundation
@testable import RockyKit

extension Fixtures {
    /// Launches `fake-acp-agent.sh`, a scripted ACP agent (see the script header).
    static func fakeACPLaunch(loadSession: Bool = true, loadFails: Bool = false) -> AgentLaunch {
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_ACP_LOAD_SESSION"] = loadSession ? "true" : "false"
        environment["FAKE_ACP_LOAD_FAILS"] = loadFails ? "true" : "false"
        return AgentLaunch(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [url("fake-acp-agent").path],
            environment: environment,
            cwd: FileManager.default.temporaryDirectory,
            stderrLog: stderrLog()
        )
    }
}
