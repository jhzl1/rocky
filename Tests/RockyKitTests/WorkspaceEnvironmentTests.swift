import Testing
@testable import RockyKit

struct WorkspaceEnvironmentTests {
    private let context = WorkspaceContext(
        name: "lisbon",
        path: "/r/app-worktrees/lisbon",
        rootPath: "/r/app",
        defaultBranch: "main",
        port: 41010
    )

    /// Only Rocky's names: no CONDUCTOR_* variable since Rocky stopped reading conductor.json.
    @Test func workspaceVariablesUseRockyNames() {
        let environment = WorkspaceEnvironment.make(login: ["PATH": "/usr/bin"], workspace: context, claudeConfigDir: nil)
        #expect(environment == [
            "PATH": "/usr/bin",
            "PORT": "41010",
            "ROCKY_PORT": "41010",
            "ROCKY_WORKSPACE_NAME": "lisbon",
            "ROCKY_WORKSPACE_PATH": "/r/app-worktrees/lisbon",
            "ROCKY_ROOT_PATH": "/r/app",
            "ROCKY_DEFAULT_BRANCH": "main",
        ])
    }

    @Test func laterLayersWin() {
        let environment = WorkspaceEnvironment.make(
            login: ["PORT": "3000", "API_URL": "from-shell"],
            workspace: context,
            repoVariables: ["API_URL": "from-repo", "PORT": "5173"],
            claudeConfigDir: nil
        )
        #expect(environment["API_URL"] == "from-repo")
        #expect(environment["PORT"] == "5173")
        #expect(environment["ROCKY_PORT"] == "41010")
    }

    @Test func repoVariableCannotSetClaudeConfigDir() {
        let withoutSetting = WorkspaceEnvironment.make(login: [:], repoVariables: ["CLAUDE_CONFIG_DIR": "/var"], claudeConfigDir: nil)
        #expect(withoutSetting["CLAUDE_CONFIG_DIR"] == nil)
        let withSetting = WorkspaceEnvironment.make(
            login: ["CLAUDE_CONFIG_DIR": "/shell"],
            repoVariables: ["CLAUDE_CONFIG_DIR": "/var"],
            claudeConfigDir: "/Users/me/.claude-rentek"
        )
        #expect(withSetting["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-rentek")
    }

    @Test func branchNameDropsOrigin() {
        #expect(WorkspaceContext.branchName(fromBaseRef: "origin/main") == "main")
        #expect(WorkspaceContext.branchName(fromBaseRef: "main") == "main")
    }

    @Test func portsComeInBlocksOfTenAndReuseGaps() {
        #expect(PortAllocator.next(taken: []) == 41000)
        #expect(PortAllocator.next(taken: [41000, 41010]) == 41020)
        #expect(PortAllocator.next(taken: [41000, 41020]) == 41010)
    }
}
