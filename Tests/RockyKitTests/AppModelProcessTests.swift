import Darwin
import Foundation
import Testing
@testable import RockyKit

@MainActor
struct AppModelProcessTests {
    /// Tests never run the real `gh`: by default it has no account and no repository is on GitHub.
    private func makeModel(
        secrets: InMemorySecretStore = InMemorySecretStore(),
        launches: LaunchBox = LaunchBox(),
        capture: @escaping @Sendable () throws -> [String: String] = { GitFixture.environment },
        gh: FakeGH = FakeGH(status: #"{"hosts":{}}"#),
        remotes: FakeRemotes = FakeRemotes()
    ) throws -> AppModel {
        let root = try Fixtures.temporaryDirectory("app")
        let paths = RockyPaths(database: root.appendingPathComponent("rocky.sqlite"), adapterPrefix: root.appendingPathComponent("agents"), logs: root)
        return AppModel(
            store: try RockyStore.inMemory(),
            paths: paths,
            captureEnvironment: capture,
            makeLaunch: { _, cwd, environment, _ in
                launches.record(environment)
                let fake = Fixtures.fakeACPLaunch()
                return AgentLaunch(executable: fake.executable, arguments: fake.arguments, environment: fake.environment, cwd: cwd, stderrLog: fake.stderrLog)
            },
            installAdapter: { _, _, _, _ in },
            latestVersion: { _ in "0.0.0" },
            defaults: UserDefaults(suiteName: "rocky-tests-\(UUID().uuidString)")!,
            secrets: secrets,
            // `-f` skips the rc files, so the tests do not depend on this machine's shell setup.
            terminalShell: { _ in ("/bin/zsh", ["-f"]) },
            processStopGracePeriod: .milliseconds(500),
            runGH: { arguments, environment in try gh.run(arguments, environment: environment) },
            lookUpGitHubRepository: { clone, environment in remotes.lookUp(clone, environment) },
            githubSession: OfflineURLProtocol.session()
        )
    }

    /// Adds a fixture repo (optionally committing extra files) and returns its id.
    private func addRepo(_ model: AppModel, committing files: [String: String] = [:]) async throws -> String {
        await model.bootstrap()
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
        for (name, content) in files {
            try Data(content.utf8).write(to: repo.appendingPathComponent(name))
            try await GitFixture.gitOffMain(["add", name], in: repo)
        }
        if !files.isEmpty { try await GitFixture.gitOffMain(["commit", "-q", "-m", "add files"], in: repo) }
        await model.addRepo(at: repo)
        return try #require(model.repos.first?.id)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func setupRunsOnceInTheNewWorkspaceWithItsOwnPort() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        model.setScripts(repoId: repoId, setup: #"printf '%s' "$PORT" > setup-port.txt"#, run: "", archive: "", runMode: .concurrent)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let setup = try #require(model.existingProcesses(for: workspace.id)?.setup)

        #expect(await setup.waitForExit() == .exited(0))
        #expect(try String(contentsOfFile: workspace.path + "/setup-port.txt", encoding: .utf8) == "41000")
        #expect(workspace.port == 41000)
        #expect(workspace.baseRef == "main")
    }

    /// ROW-03: a Setup that exits non-zero is the workspace's error state.
    @Test func failedSetupIsAnError() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        model.setScripts(repoId: repoId, setup: "exit 3", run: "", archive: "", runMode: .concurrent)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let setup = try #require(model.existingProcesses(for: workspace.id)?.setup)

        #expect(await setup.waitForExit() == .exited(3))
        #expect(model.status(workspaceId: workspace.id) == .failed("Setup exited with 3. See the Setup tab."))
    }

    @Test func rockyJSONInTheWorkspaceWinsOverRepoSettings() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model, committing: ["rocky.json": #"{"scripts":{"setup":"touch from-json"}}"#])
        model.setScripts(repoId: repoId, setup: "touch from-settings", run: "", archive: "", runMode: .concurrent)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let setup = try #require(model.existingProcesses(for: workspace.id)?.setup)

        #expect(await setup.waitForExit() == .exited(0))
        #expect(FileManager.default.fileExists(atPath: workspace.path + "/from-json"))
        #expect(!FileManager.default.fileExists(atPath: workspace.path + "/from-settings"))
    }

    @Test func nonconcurrentRunStopsTheOtherWorkspacesRun() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        model.setScripts(repoId: repoId, setup: "", run: "sleep 30", archive: "", runMode: .nonconcurrent)
        await model.createWorkspace(repoId: repoId)
        await model.createWorkspace(repoId: repoId)
        let all = try #require(model.workspaces[repoId])
        try #require(all.count == 2)

        await model.startRun(workspaceId: all[0].id)
        let firstRun = try #require(model.existingProcesses(for: all[0].id)?.run)
        await model.startRun(workspaceId: all[1].id)
        let secondRun = try #require(model.existingProcesses(for: all[1].id)?.run)
        #expect(firstRun.state == .signaled(SIGTERM))
        #expect(secondRun.state == .running)

        await model.stopRun(workspaceId: all[1].id)
        #expect(secondRun.state == .signaled(SIGTERM))
    }

    @Test func runWithoutAScriptExplainsWhereToAddOne() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)

        await model.startRun(workspaceId: workspace.id)
        #expect(model.errorMessage == "\(workspace.name) has no run script. Add one in the repo settings or in rocky.json.")
        #expect(model.existingProcesses(for: workspace.id)?.run == nil)
    }

    @Test func failedArchiveKeepsTheWorkspaceUntilRemoveAnyway() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        model.setScripts(repoId: repoId, setup: "", run: "", archive: "echo archiving; exit 7", runMode: .concurrent)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)

        await model.removeWorkspace(id: workspace.id)
        #expect(model.archiveFailure == ArchiveFailure(workspaceId: workspace.id, workspaceName: workspace.name, message: "The archive script exited with 7."))
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        #expect(model.workspaces[repoId]?.count == 1)

        await model.removeWorkspace(id: workspace.id, skipArchive: true)
        #expect(model.archiveFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(model.workspaces[repoId]?.isEmpty == true)
    }

    @Test func repoVariablesReachAgentsAndTerminalsAndSecretsStayOutOfTheDatabase() async throws {
        let secrets = InMemorySecretStore()
        let launches = LaunchBox()
        let model = try makeModel(secrets: secrets, launches: launches)
        let repoId = try await addRepo(model)
        model.setRepoVar(repoId: repoId, name: "API_URL", value: "http://localhost:9", isSecret: false)
        model.setRepoVar(repoId: repoId, name: "API_TOKEN", value: "s3cret", isSecret: true)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)

        _ = await model.openChat(workspace: workspace, agent: .opencode)
        #expect(launches.last?["API_URL"] == "http://localhost:9")
        #expect(launches.last?["API_TOKEN"] == "s3cret")
        #expect(launches.last?["ROCKY_PORT"] == "41000")
        #expect(launches.last?.keys.contains { $0.hasPrefix("CONDUCTOR_") } == false)
        #expect(try model.store.repoVars(repoId: repoId).first { $0.name == "API_TOKEN" }?.value == nil)
        #expect(try secrets.read(account: "\(repoId)/API_TOKEN") == "s3cret")

        let terminal = try #require(await model.openTerminal(workspaceId: workspace.id))
        terminal.send(#"printf '<%s>' "$API_TOKEN"; exit"# + "\n")
        #expect(await terminal.waitForExit() == .exited(0))
        try await waitUntil { terminal.outputText.contains("<s3cret>") }

        await model.removeRepo(id: repoId)
        #expect(try secrets.read(account: "\(repoId)/API_TOKEN") == nil)
    }

    @Test func stopAllProcessesEndsTerminalsAndScripts() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        model.setScripts(repoId: repoId, setup: "", run: "sleep 30", archive: "", runMode: .concurrent)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        await model.startRun(workspaceId: workspace.id)
        let terminal = try #require(await model.openTerminal(workspaceId: workspace.id))
        let run = try #require(model.existingProcesses(for: workspace.id)?.run)

        await model.stopAllProcesses()
        #expect(!run.state.isRunning)
        #expect(!terminal.state.isRunning)
    }

    /// ENV-01: two repositories bound to two accounts of gh; an agent, a script and a terminal each get their
    /// repository's token as GH_TOKEN over the login shell's. gh itself never sees the shell's token, each token is
    /// fetched once, and none reaches the store.
    @Test func terminalsScriptsAndAgentsGetTheRepoAccountToken() async throws {
        let gh = FakeGH(tokens: ["jhzl1": "gho_personal", "ocampos-biai": "gho_work"])
        let launches = LaunchBox()
        let remotes = FakeRemotes([
            "alpha": GitHubRepository(owner: "jhzl1", name: "alpha"),
            "beta": GitHubRepository(owner: "ocampos-biai", name: "beta"),
        ])
        let model = try makeModel(
            launches: launches,
            capture: { GitFixture.environment.merging(["GH_TOKEN": "gho_shell", "GITHUB_TOKEN": "ghp_shell"]) { _, new in new } },
            gh: gh,
            remotes: remotes
        )
        await model.bootstrap()
        let parent = try Fixtures.temporaryDirectory("repos")
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: parent, name: "alpha"))
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: parent, name: "beta"))
        let alphaId = try #require(model.repos.first { $0.name == "alpha" }?.id)
        let betaId = try #require(model.repos.first { $0.name == "beta" }?.id)
        model.setScripts(repoId: betaId, setup: "", run: #"printf '%s' "$GH_TOKEN" > run-token.txt"#, archive: "", runMode: .concurrent)
        await model.createWorkspace(repoId: alphaId)
        await model.createWorkspace(repoId: betaId)
        let alpha = try #require(model.workspaces[alphaId]?.first)
        let beta = try #require(model.workspaces[betaId]?.first)

        _ = await model.openChat(workspace: alpha, agent: .opencode)
        #expect(launches.last?["GH_TOKEN"] == "gho_personal")

        await model.startRun(workspaceId: beta.id)
        let run = try #require(model.existingProcesses(for: beta.id)?.run)
        #expect(await run.waitForExit() == .exited(0))
        #expect(try String(contentsOfFile: beta.path + "/run-token.txt", encoding: .utf8) == "gho_work")

        let terminal = try #require(await model.openTerminal(workspaceId: alpha.id))
        terminal.send(#"printf '<%s>' "$GH_TOKEN"; exit"# + "\n")
        #expect(await terminal.waitForExit() == .exited(0))
        try await waitUntil { terminal.outputText.contains("<gho_personal>") }

        #expect(!gh.environments.isEmpty)
        #expect(gh.environments.allSatisfy { $0["GH_TOKEN"] == nil && $0["GITHUB_TOKEN"] == nil && $0["PATH"] != nil })
        #expect(gh.tokenCalls(for: "jhzl1") == 1)
        #expect(gh.tokenCalls(for: "ocampos-biai") == 1)
        let stored = "\(try model.store.repos())\(try model.store.workspaces(repoId: alphaId))\(try model.store.workspaces(repoId: betaId))"
        #expect(!stored.contains("gho_"))
        await model.stopAllProcesses()
    }

    @Test func rejectsInvalidVariableNames() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        for name in ["1ABC", "A-B", ""] {
            model.errorMessage = nil
            model.setRepoVar(repoId: repoId, name: name, value: "x", isSecret: false)
            #expect(model.errorMessage?.contains("is not a valid variable name") == true)
        }
        #expect(model.repoVars(repoId: repoId).isEmpty)
    }
}
