import Foundation
@testable import RockyKit

extension Fixtures {
    /// Launches `fake-acp-agent.sh`, a scripted ACP agent (see the script header).
    /// `agent`: whose models and effort levels it offers (AGM-02). `log`: a file the agent appends every line it
    /// receives to.
    static func fakeACPLaunch(
        agent: AgentKind = .claude,
        loadSession: Bool = true,
        loadFails: Bool = false,
        asks: Bool = false,
        commandsEarly: Bool = false,
        log: URL? = nil
    ) -> AgentLaunch {
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_ACP_AGENT"] = agent.rawValue
        environment["FAKE_ACP_LOAD_SESSION"] = loadSession ? "true" : "false"
        environment["FAKE_ACP_LOAD_FAILS"] = loadFails ? "true" : "false"
        environment["FAKE_ACP_ASKS"] = asks ? "true" : "false"
        environment["FAKE_ACP_COMMANDS_EARLY"] = commandsEarly ? "true" : "false"
        if let log { environment["FAKE_ACP_LOG"] = log.path }
        return AgentLaunch(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [url("fake-acp-agent").path],
            environment: environment,
            cwd: FileManager.default.temporaryDirectory,
            stderrLog: stderrLog()
        )
    }
}
