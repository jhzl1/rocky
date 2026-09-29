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
        let gh = FakeGH(tokens: ["jhzl1": "gho_personal", "work-user": "gho_work"])
        let launches = LaunchBox()
        let remotes = FakeRemotes([
            "alpha": GitHubRepository(owner: "jhzl1", name: "alpha"),
            "beta": GitHubRepository(owner: "work-user", name: "beta"),
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
        #expect(gh.tokenCalls(for: "work-user") == 1)
        let stored = "\(try model.store.repos())\(try model.store.workspaces(repoId: alphaId))\(try model.store.workspaces(repoId: betaId))"
        #expect(!stored.contains("gho_"))
        await model.stopAllProcesses()
    }

    // MARK: VS Code tasks (TSK-01…TSK-06, M2.9)

    /// Writes `tasks.json` into the main clone only, untracked, so the worktree has none and Rocky reads the clone's
    /// (TSK-01).
    private func writeTasks(_ json: String, in model: AppModel, repoId: String) throws {
        let clone = URL(fileURLWithPath: try #require(model.repo(id: repoId)).path)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: clone.appendingPathComponent(VSCodeTasks.relativePath))
    }

    /// The wiring on real `/bin/zsh` sessions: the main clone's file; the input asked once; a hidden dependency in a
    /// silent shared tab, with its echo line; a background dependency done on its pattern and still running; the task in
    /// its dedicated tab, selected, in `options.cwd` with the workspace's environment plus `options.env`; then Stop of
    /// the task and of the dependency it started.
    @Test func aTaskRunsItsChainInTabs() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        #expect(!FileManager.default.fileExists(atPath: workspace.path + "/.vscode"))
        try writeTasks(#"""
        { "version": "2.0.0",
          "tasks": [
            { "label": "Run: App", "type": "shell",
              "command": "printf '%s %s' \"$GREETING\" \"$PORT\" > greeting.txt; sleep 30",
              "options": { "cwd": "${workspaceFolder}/app", "env": { "GREETING": "hello ${input:who}" } },
              "dependsOn": ["_prepare", "_server"], "dependsOrder": "sequence",
              "presentation": { "panel": "dedicated" } },
            // A shell, as VS Code's are, and a server that says when it is ready.
            { "label": "_prepare", "type": "shell", "command": "mkdir -p app", "presentation": { "reveal": "silent" } },
            { "label": "_server", "type": "shell", "command": "echo \"serving ${input:who}\"; echo 'ready in 5 ms'; sleep 30",
              "isBackground": true, "problemMatcher": { "background": { "endsPattern": "ready in \\d+" } },
              "presentation": { "panel": "dedicated", "reveal": "silent" } },
          ],
          "inputs": [ { "id": "who", "type": "pickString", "options": ["world", "rocky"], "default": "world" } ]
        }
        """#, in: model, repoId: repoId)

        await model.lookForTasks(workspaceId: workspace.id)
        #expect(model.runMenus[workspace.id]?.tasks == .unread)
        let asked = AskLog()
        let outcome = await model.runTask(workspaceId: workspace.id, label: "Run: App") { input in
            asked.ids.append(input.id)
            return "rocky"
        }
        #expect(asked.ids == ["who"])
        let tasks = try #require(model.existingProcesses(for: workspace.id)?.tasks)
        #expect(tasks.map(\.title) == ["_prepare", "_server", "Run: App"])
        let (prepare, server, app) = (tasks[0], tasks[1], tasks[2])
        #expect(outcome == .started(app.id))
        #expect(model.terminalRevealRequests[workspace.id]?.sessionId == app.id)
        #expect(prepare.state == .exited(0))
        try await waitUntil { prepare.outputText.contains("> mkdir -p app") }
        #expect(server.state.isRunning)
        #expect(server.outputText.contains("serving rocky"))
        #expect(model.taskSession(workspaceId: workspace.id, label: "Run: App") === app)
        try await waitUntil { FileManager.default.fileExists(atPath: workspace.path + "/app/greeting.txt") }
        try await waitUntil { (try? String(contentsOfFile: workspace.path + "/app/greeting.txt", encoding: .utf8)) == "hello rocky 41000" }

        // Chosen again, it is not started twice: its tab shows.
        #expect(await model.runTask(workspaceId: workspace.id, label: "Run: App") { _ in nil } == .alreadyRunning(app.id))

        await model.stopTask(workspaceId: workspace.id, label: "Run: App")
        #expect(!app.state.isRunning && app.stopRequested)
        #expect(!server.state.isRunning && server.stopRequested)
        #expect(model.taskSession(workspaceId: workspace.id, label: "Run: App") == nil)
        await model.stopAllProcesses()
    }

    /// Decision 7: a shared tab whose task ended is reused in place, and the selection follows it; "new" opens a tab
    /// each run; closing a task's tab stops it and removes it.
    @Test func finishedTaskTabsAreReusedInPlace() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        try writeTasks("""
        { "version": "2.0.0", "tasks": [
          { "label": "Build", "type": "shell", "command": "echo built" },
          { "label": "Once", "type": "shell", "command": "echo once", "presentation": { "panel": "new" } },
          { "label": "Serve", "type": "shell", "command": "sleep 30" }
        ] }
        """, in: model, repoId: repoId)
        await model.readRunMenu(workspaceId: workspace.id)
        _ = await model.runTask(workspaceId: workspace.id, label: "Build") { _ in nil }
        let processes = try #require(model.existingProcesses(for: workspace.id))
        let first = try #require(processes.tasks.first)
        #expect(await first.waitForExit() == .exited(0))

        _ = await model.runTask(workspaceId: workspace.id, label: "Build") { _ in nil }
        let second = try #require(processes.tasks.first)
        #expect(processes.tasks.count == 1)
        #expect(second !== first)
        #expect(processes.current(first.id) == second.id)
        #expect(await second.waitForExit() == .exited(0))

        for _ in 0..<2 {
            _ = await model.runTask(workspaceId: workspace.id, label: "Once") { _ in nil }
            #expect(await processes.tasks.last?.waitForExit() == .exited(0))
        }
        #expect(processes.tasks.map(\.title) == ["Build", "Once", "Once"])

        // "Build" ended, so "Serve" takes its shared tab.
        _ = await model.runTask(workspaceId: workspace.id, label: "Serve") { _ in nil }
        let serve = try #require(model.taskSession(workspaceId: workspace.id, label: "Serve"))
        #expect(processes.tasks.map(\.title) == ["Serve", "Once", "Once"])
        #expect(processes.current(first.id) == serve.id)
        await model.closeTask(workspaceId: workspace.id, sessionId: serve.id)
        #expect(serve.stopRequested)
        #expect(processes.tasks.map(\.title) == ["Once", "Once"])
    }

    /// TSK-03, Decision 10: in `nonconcurrent` mode a task stops the Run script and the tasks of every other workspace.
    @Test func aNonconcurrentTaskStopsOtherWorkspacesRunsAndTasks() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        model.setScripts(repoId: repoId, setup: "", run: "sleep 30", archive: "", runMode: .nonconcurrent)
        await model.createWorkspace(repoId: repoId)
        await model.createWorkspace(repoId: repoId)
        let all = try #require(model.workspaces[repoId])
        try #require(all.count == 2)
        try writeTasks(#"{ "version": "2.0.0", "tasks": [ { "label": "Serve", "type": "shell", "command": "sleep 30" } ] }"#, in: model, repoId: repoId)

        await model.startRun(workspaceId: all[0].id)
        let run = try #require(model.existingProcesses(for: all[0].id)?.run)
        _ = await model.runTask(workspaceId: all[1].id, label: "Serve") { _ in nil }
        let firstTask = try #require(model.taskSession(workspaceId: all[1].id, label: "Serve"))
        #expect(run.stopRequested)

        _ = await model.runTask(workspaceId: all[0].id, label: "Serve") { _ in nil }
        #expect(firstTask.stopRequested)
        #expect(model.taskSession(workspaceId: all[0].id, label: "Serve")?.state.isRunning == true)

        // The Run script keeps the same rule: it stops the other workspace's task too.
        await model.startRun(workspaceId: all[1].id)
        #expect(model.taskSession(workspaceId: all[0].id, label: "Serve") == nil)
        await model.stopAllProcesses()
    }

    /// TSK-07: a chain Rocky cannot run starts nothing, and a failed dependency stops it.
    @Test func brokenAndFailingChainsStartNothing() async throws {
        let model = try makeModel()
        let repoId = try await addRepo(model)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        try writeTasks("""
        { "version": "2.0.0", "tasks": [
          { "label": "Open", "type": "shell", "command": "open ${file}" },
          { "label": "Run: Web", "type": "shell", "command": "echo web", "dependsOn": "_Dev: Stop stray processes" },
          { "label": "_Dev: Stop stray processes", "type": "shell", "command": "exit 4" }
        ] }
        """, in: model, repoId: repoId)
        #expect(await model.runTask(workspaceId: workspace.id, label: "Open") { _ in nil } == .invalid(.unsupportedVariable(task: "Open", variable: "${file}")))
        #expect(model.existingProcesses(for: workspace.id)?.tasks.isEmpty != false)

        let outcome = await model.runTask(workspaceId: workspace.id, label: "Run: Web") { _ in nil }
        let cleanup = try #require(model.existingProcesses(for: workspace.id)?.tasks.first)
        #expect(outcome == .failed(dependency: "_Dev: Stop stray processes", process: cleanup.id))
        #expect(cleanup.state == .exited(4))
        #expect(model.existingProcesses(for: workspace.id)?.tasks.map(\.title) == ["_Dev: Stop stray processes"])
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

    // MARK: CMD-08's embedded terminal

    /// Puts a fake Claude Code where Rocky's own is: it prints what it was started with, then waits for a line.
    private func installFakeClaudeCode(_ model: AppModel) throws {
        let binary = AgentLauncher.claudeCodeBinary(prefix: model.paths.adapterPrefix)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        printf 'count=<%s> args=<%s> config=<%s> cwd=<%s> update=<%s>\\n' "$#" "$*" "$CLAUDE_CONFIG_DIR" "$(pwd -P)" "$DISABLE_AUTOUPDATER"
        IFS= read -r line
        printf 'finished\\n'
        """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    /// A workspace of a repository with its own Claude instance, and a Claude Code conversation in it.
    private func claudeConversation(_ model: AppModel) async throws -> (workspace: Workspace, conversationId: String) {
        let repoId = try await addRepo(model)
        await model.setClaudeConfigDir(repoId: repoId, "/Users/me/.claude-work")
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        try #require(await model.newConversation(workspace: workspace, agent: .claude) != nil)
        return (workspace, try #require(model.selectedConversationIds[workspace.id]))
    }

    /// It runs Rocky's Claude Code directly, with the command as its one argument, in the worktree, with the
    /// workspace environment (the repository's Claude instance); its exit is the "finished" signal, and it stays open
    /// until Done or ×.
    @Test func embeddedTerminalRunsRockysClaudeCodeInTheWorkspace() async throws {
        let model = try makeModel()
        let (workspace, conversationId) = try await claudeConversation(model)
        try installFakeClaudeCode(model)
        #expect(model.embeddedTerminal(conversationId: conversationId) == nil)

        let session = try #require(await model.openEmbeddedTerminal(conversationId: conversationId, command: TerminalOnlyCommand(name: "mcp", arguments: "extra")))
        #expect(model.embeddedTerminal(conversationId: conversationId) === session)
        #expect(session.title == "/mcp")
        #expect(session.command.executable == AgentLauncher.claudeCodeBinary(prefix: model.paths.adapterPrefix).path)
        #expect(session.command.arguments == ["/mcp extra"])
        try await waitUntil { session.outputText.contains("update=") }
        #expect(session.hasOutput)
        // `pwd -P` reports /private/var…, which `resolvingSymlinksInPath()` would turn back into /var….
        let resolved = try #require(realpath(workspace.path, nil))
        let worktree = String(cString: resolved)
        free(resolved)
        #expect(session.outputText.contains("count=<1> args=</mcp extra> config=</Users/me/.claude-work> cwd=<\(worktree)> update=<1>"))
        #expect(session.state.isRunning)

        session.send("\n")
        #expect(await session.waitForExit() == .exited(0))
        try await waitUntil { session.outputText.contains("finished") }
        #expect(model.embeddedTerminal(conversationId: conversationId) === session)

        await model.closeEmbeddedTerminal(conversationId: conversationId)
        #expect(model.embeddedTerminal(conversationId: conversationId) == nil)
        await model.stopAllProcesses()
    }

    /// One per conversation; Done or × stops it, and so do closing the conversation, removing the workspace and
    /// quitting. Nothing runs once it is closed.
    @Test func embeddedTerminalsStopWithTheirConversationWorkspaceAndRocky() async throws {
        let model = try makeModel()
        let (workspace, conversationId) = try await claudeConversation(model)
        try installFakeClaudeCode(model)
        let mcp = TerminalOnlyCommand(name: "mcp")

        let first = try #require(await model.openEmbeddedTerminal(conversationId: conversationId, command: mcp))
        let second = try #require(await model.openEmbeddedTerminal(conversationId: conversationId, command: TerminalOnlyCommand(name: "hooks")))
        #expect(!first.state.isRunning)
        #expect(first.stopRequested)
        #expect(second.state.isRunning)
        #expect(model.embeddedTerminal(conversationId: conversationId) === second)
        await model.closeEmbeddedTerminal(conversationId: conversationId)
        #expect(!second.state.isRunning)
        #expect(model.embeddedTerminal(conversationId: conversationId) == nil)

        let beforeQuit = try #require(await model.openEmbeddedTerminal(conversationId: conversationId, command: mcp))
        await model.stopAllProcesses()
        #expect(!beforeQuit.state.isRunning)
        #expect(model.embeddedTerminal(conversationId: conversationId) == nil)

        let beforeClosing = try #require(await model.openEmbeddedTerminal(conversationId: conversationId, command: mcp))
        await model.closeConversation(workspace: workspace, conversationId: conversationId)
        #expect(!beforeClosing.state.isRunning)
        #expect(model.embeddedTerminal(conversationId: conversationId) == nil)

        let current = try #require(model.selectedConversationIds[workspace.id])
        let beforeRemoving = try #require(await model.openEmbeddedTerminal(conversationId: current, command: mcp))
        await model.removeWorkspace(id: workspace.id)
        #expect(!beforeRemoving.state.isRunning)
        #expect(model.embeddedTerminal(conversationId: current) == nil)
        #expect(model.workspace(id: workspace.id) == nil)
    }

    @Test func embeddedTerminalWithoutClaudeCodeSaysSo() async throws {
        let model = try makeModel()
        let (_, conversationId) = try await claudeConversation(model)
        #expect(await model.openEmbeddedTerminal(conversationId: conversationId, command: TerminalOnlyCommand(name: "mcp")) == nil)
        #expect(model.errorMessage == "Rocky's Claude Code is not installed yet. Start a Claude Code conversation, then run /mcp again.")
        #expect(model.embeddedTerminal(conversationId: conversationId) == nil)
        await model.stopAllProcesses()
    }
}
