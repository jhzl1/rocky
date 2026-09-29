import Darwin
import Foundation
import Testing
@testable import RockyKit

/// A task's process the test ends by hand.
@MainActor
final class FakeTaskProcess: TaskProcess {
    let id = UUID()
    let launch: TaskLaunch
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    private(set) var state: PTYState = .running
    private(set) var isWatched = true
    private let log: FakeTaskLauncher
    private var exitWaiters: [CheckedContinuation<PTYState, Never>] = []

    init(launch: TaskLaunch, onOutput: ((ArraySlice<UInt8>) -> Void)?, log: FakeTaskLauncher) {
        self.launch = launch
        self.onOutput = onOutput
        self.log = log
    }

    var isRunning: Bool { state.isRunning }

    func write(_ text: String) {
        if isWatched { onOutput?(Array(text.utf8)[...]) }
    }

    func exit(_ code: Int32) {
        finish(.exited(code))
    }

    func waitForExit() async -> PTYState {
        guard state.isRunning else { return state }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    func stop() async {
        guard state.isRunning else { return }
        log.stops.append(launch.label)
        finish(.signaled(SIGTERM))
    }

    func stopWatchingOutput() {
        isWatched = false
    }

    private func finish(_ final: PTYState) {
        guard state.isRunning else { return }
        state = final
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: final) }
    }
}

/// The inputs a run asked for, in order.
@MainActor
final class AskLog {
    var ids: [String] = []
}

/// Records what the runner starts, in order, and what it stops.
@MainActor
final class FakeTaskLauncher: TaskLauncher {
    private(set) var started: [FakeTaskProcess] = []
    var stops: [String] = []

    func start(_ launch: TaskLaunch, onOutput: ((ArraySlice<UInt8>) -> Void)?) -> any TaskProcess {
        let process = FakeTaskProcess(launch: launch, onOutput: onOutput, log: self)
        started.append(process)
        return process
    }

    var labels: [String] {
        started.map(\.launch.label)
    }

    func process(_ label: String) -> FakeTaskProcess? {
        started.last { $0.launch.label == label }
    }
}

/// KIT-17 with the fake launcher: sequences, background waits, failures, shared dependencies, inputs and Stop.
@MainActor
struct TaskRunnerTests {
    private let context = TaskContext(
        worktree: URL(fileURLWithPath: "/tmp/repo-worktrees/lima"),
        userHome: "/Users/me",
        environment: ["PATH": "/usr/bin:/bin", "PORT": "41000"]
    )

    private func plan(_ label: String, _ json: String) throws -> TaskPlan {
        try VSCodeTasks.plan(label, in: VSCodeTasks.parse(Data(json.utf8)))
    }

    private func tasks(_ tasks: String, inputs: String = "[]") -> String {
        #"{ "version": "2.0.0", "tasks": [\#(tasks)], "inputs": \#(inputs) }"#
    }

    /// Lets the runner's tasks move; fails the test after about 2 seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 where !condition() {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(condition())
    }

    /// Gives the runner's tasks turns without anything to wait for.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func start(
        _ runner: TaskRunner,
        _ plan: TaskPlan,
        ask: @escaping @MainActor (TaskInput) async -> String? = { $0.defaultValue }
    ) -> Task<TaskRunOutcome, Never> {
        let context = self.context
        return Task { await runner.run(plan, context: context, ask: ask) }
    }

    /// A sequence starts each step once the one before exited with 0.
    @Test func aSequenceWaitsForEachExitZero() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try plan("root", tasks("""
        { "label": "root", "type": "shell", "command": "r", "dependsOn": ["a", "b"], "dependsOrder": "sequence" },
        { "label": "a", "type": "shell", "command": "a" },
        { "label": "b", "type": "shell", "command": "b" }
        """))
        let run = start(runner, plan)
        try await waitUntil { launcher.labels == ["a"] }
        await settle()
        #expect(launcher.labels == ["a"])
        launcher.process("a")?.exit(0)
        try await waitUntil { launcher.labels == ["a", "b"] }
        launcher.process("b")?.exit(0)
        let outcome = await run.value
        #expect(launcher.labels == ["a", "b", "root"])
        #expect(outcome == .started(launcher.process("root")?.id))
        #expect(runner.isRunning("root"))
    }

    /// Parallel dependencies start together, and the task starts when all are done.
    @Test func parallelDependenciesStartTogether() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try plan("root", tasks("""
        { "label": "root", "type": "shell", "command": "r", "dependsOn": ["a", "b"] },
        { "label": "a", "type": "shell", "command": "a" },
        { "label": "b", "type": "shell", "command": "b" }
        """))
        let run = start(runner, plan)
        try await waitUntil { Set(launcher.labels) == ["a", "b"] }
        launcher.process("b")?.exit(0)
        await settle()
        #expect(!launcher.labels.contains("root"))
        launcher.process("a")?.exit(0)
        #expect(await run.value == .started(launcher.process("root")?.id))
    }

    /// TSK-05: a background step is done once a line of its output, escapes removed, matches its `endsPattern`; it keeps
    /// running, and the runner stops reading its output.
    @Test func aBackgroundStepWaitsForItsPattern() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try plan("root", tasks(#"""
        { "label": "root", "type": "shell", "command": "r", "dependsOn": "server" },
        { "label": "server", "type": "shell", "command": "s", "isBackground": true,
          "problemMatcher": [ { "pattern": { "regexp": "^$" }, "background": { "beginsPattern": "vite v", "endsPattern": "ready in \\d+" } } ] }
        """#))
        let run = start(runner, plan)
        try await waitUntil { launcher.labels == ["server"] }
        let server = try #require(launcher.process("server"))
        server.write("vite v7.1.2 dev server\r\n")
        await settle()
        #expect(launcher.labels == ["server"])
        server.write("  \u{1B}[32mready\u{1B}[39m in 812 ms")
        #expect(await run.value == .started(launcher.process("root")?.id))
        #expect(server.isRunning)
        #expect(!server.isWatched)
    }

    /// TSK-05: without an `endsPattern`, a background step is done as soon as it starts; Rocky does not guess a wait.
    @Test func aBackgroundStepWithoutAPatternDoesNotWait() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try plan("root", tasks("""
        { "label": "root", "type": "shell", "command": "r", "dependsOn": "api" },
        { "label": "api", "type": "shell", "command": "uvicorn", "isBackground": true, "problemMatcher": [] }
        """))
        #expect(await start(runner, plan).value == .started(launcher.process("root")?.id))
        #expect(launcher.labels == ["api", "root"])
        #expect(launcher.process("api")?.onOutput == nil)
    }

    /// TSK-05: a step that exits non-zero stops the chain: what has not started does not start.
    @Test func aFailureMidwayStopsTheChain() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try plan("Run: Web", tasks("""
        { "label": "Run: Web", "type": "shell", "command": "pnpm dev", "dependsOn": ["_Dev: Stop stray processes", "_next"], "dependsOrder": "sequence" },
        { "label": "_Dev: Stop stray processes", "type": "shell", "command": "cleanup" },
        { "label": "_next", "type": "shell", "command": "next" }
        """))
        let run = start(runner, plan)
        try await waitUntil { launcher.labels == ["_Dev: Stop stray processes"] }
        let cleanup = try #require(launcher.process("_Dev: Stop stray processes"))
        cleanup.exit(1)
        #expect(await run.value == .failed(dependency: "_Dev: Stop stray processes", process: cleanup.id))
        #expect(launcher.labels == ["_Dev: Stop stray processes"])
    }

    /// TSK-05: a background step that ends before its pattern fails the chain too, and a parallel sibling already running
    /// keeps running.
    @Test func aBackgroundStepEndingBeforeItsPatternFails() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try plan("root", tasks("""
        { "label": "root", "type": "shell", "command": "r", "dependsOn": ["server", "watch"] },
        { "label": "server", "type": "shell", "command": "s", "isBackground": true,
          "problemMatcher": { "background": { "endsPattern": "listening" } } },
        { "label": "watch", "type": "shell", "command": "w", "isBackground": true,
          "problemMatcher": { "background": { "endsPattern": "watching" } } }
        """))
        let run = start(runner, plan)
        try await waitUntil { Set(launcher.labels) == ["server", "watch"] }
        let server = try #require(launcher.process("server"))
        server.write("error: port in use\n")
        server.exit(1)
        #expect(await run.value == .failed(dependency: "server", process: server.id))
        #expect(launcher.process("watch")?.isRunning == true)
        #expect(!launcher.labels.contains("root"))
    }

    /// TSK-05: a task reached twice in one chain runs once.
    @Test func aDiamondRunsItsSharedTaskOnce() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try plan("root", tasks("""
        { "label": "root", "type": "shell", "command": "r", "dependsOn": ["left", "right"] },
        { "label": "left", "type": "shell", "command": "l", "dependsOn": "shared" },
        { "label": "right", "type": "shell", "command": "r", "dependsOn": "shared" },
        { "label": "shared", "type": "shell", "command": "s" }
        """))
        let run = start(runner, plan)
        try await waitUntil { launcher.labels == ["shared"] }
        launcher.process("shared")?.exit(0)
        try await waitUntil { Set(launcher.labels) == ["shared", "left", "right"] }
        launcher.process("left")?.exit(0)
        launcher.process("right")?.exit(0)
        _ = await run.value
        #expect(launcher.labels.filter { $0 == "shared" }.count == 1)
        #expect(launcher.labels.last == "root")
    }

    /// TSK-05 and TSK-06: a dependency two tasks share starts once; Stop of the first leaves it to the second, whose Stop
    /// then stops it, newest first.
    @Test func aDependencySharedByTwoTasksIsStoppedOnlyOnce() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let json = tasks("""
        { "label": "Run: Web", "type": "shell", "command": "web", "dependsOn": ["_cleanup", "_api"], "dependsOrder": "sequence" },
        { "label": "Run: Admin", "type": "shell", "command": "studio", "dependsOn": ["_cleanup", "_api"], "dependsOrder": "sequence" },
        { "label": "_cleanup", "type": "shell", "command": "cleanup" },
        { "label": "_api", "type": "shell", "command": "api", "isBackground": true,
          "problemMatcher": { "background": { "endsPattern": "Application startup complete" } } }
        """)
        let first = start(runner, try plan("Run: Web", json))
        try await waitUntil { launcher.labels == ["_cleanup"] }
        launcher.process("_cleanup")?.exit(0)
        try await waitUntil { launcher.labels == ["_cleanup", "_api"] }
        let api = try #require(launcher.process("_api"))
        api.write("INFO:     Application startup complete.\n")
        _ = await first.value

        let second = start(runner, try plan("Run: Admin", json))
        try await waitUntil { launcher.labels.count == 4 }
        launcher.process("_cleanup")?.exit(0)
        _ = await second.value
        #expect(launcher.labels == ["_cleanup", "_api", "Run: Web", "_cleanup", "Run: Admin"])

        await runner.stop("Run: Web")
        #expect(launcher.stops == ["Run: Web"])
        #expect(api.isRunning)
        await runner.stop("Run: Admin")
        #expect(launcher.stops == ["Run: Web", "Run: Admin", "_api"])
        #expect(!runner.isRunning("_api"))
    }

    /// TSK-04: every input of the chain once, before anything starts, one answer per id for the whole chain.
    @Test func inputsAreAskedOnceBeforeAnythingStarts() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try VSCodeTasks.plan("Run: API + Web", in: VSCodeTasks.parse(Fixtures.json("sample-tasks")))
        let asked = AskLog()
        let run = start(runner, plan) { input in
            asked.ids.append(input.id)
            #expect(launcher.started.isEmpty)
            return "staging-local"
        }
        try await waitUntil { launcher.labels == ["_Dev: Cleanup"] }
        #expect(asked.ids == ["stackMode"])
        launcher.process("_Dev: Cleanup")?.exit(0)
        try await waitUntil { launcher.labels.count == 3 }
        launcher.process("_API: Ensure venv")?.exit(0)
        launcher.process("_API: Ensure hooks")?.exit(0)
        try await waitUntil { launcher.labels.count == 4 }
        let api = try #require(launcher.process("_API: Run (mode)"))
        #expect(api.launch.commandLine.hasPrefix("MODE='staging-local' "))
        api.write("INFO:     Application startup complete.\r\n")
        _ = await run.value
        let web = try #require(launcher.process("Run: API + Web"))
        #expect(web.launch.commandLine == "pnpm staging-local")
        #expect(web.launch.command.cwd.path == "/tmp/repo-worktrees/lima/apps/web")
        #expect(web.launch.panel == .dedicated)
        #expect(web.launch.focus)
        #expect(asked.ids == ["stackMode"])
    }

    /// TSK-04: Esc on an input cancels the whole run.
    @Test func aCancelledInputStartsNothing() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try VSCodeTasks.plan("Run: Web", in: VSCodeTasks.parse(Fixtures.json("sample-tasks")))
        #expect(await start(runner, plan) { _ in nil }.value == .cancelled)
        #expect(launcher.started.isEmpty)
    }

    /// TSK-02: a running task is not started twice.
    @Test func aRunningTaskIsNotStartedAgain() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try plan("server", tasks(#"{ "label": "server", "type": "shell", "command": "s" }"#))
        let first = await start(runner, plan).value
        let server = try #require(launcher.process("server"))
        #expect(first == .started(server.id))
        #expect(await start(runner, plan).value == .alreadyRunning(server.id))
        #expect(launcher.started.count == 1)
        server.exit(0)
        _ = await start(runner, plan).value
        #expect(launcher.started.count == 2)
    }

    /// TSK-06: Stop while a chain waits on a dependency starts nothing more.
    @Test func stopWhileAChainStartsStartsNothingMore() async throws {
        let launcher = FakeTaskLauncher()
        let runner = TaskRunner(launcher: launcher)
        let plan = try plan("root", tasks("""
        { "label": "root", "type": "shell", "command": "r", "dependsOn": "server" },
        { "label": "server", "type": "shell", "command": "s", "isBackground": true,
          "problemMatcher": { "background": { "endsPattern": "ready" } } }
        """))
        let run = start(runner, plan)
        try await waitUntil { launcher.labels == ["server"] }
        await runner.stop("root")
        #expect(await run.value == .stopped)
        #expect(launcher.stops == ["server"])
        #expect(launcher.labels == ["server"])
    }

    /// TSK-03: the workspace's environment with `options.env` on top, `options.cwd` against the worktree, the echo
    /// line, and a process task's executable run directly (after the echo, through `exec`).
    @Test func aStepIsResolvedIntoItsProcess() throws {
        let file = try VSCodeTasks.parse(Data(tasks("""
        { "label": "shell", "type": "shell", "command": "pnpm ${input:mode}", "args": ["--port", "$PORT", "${env:API}"],
          "options": { "cwd": "apps/web", "env": { "API": "${env:PORT}-api" } } },
        { "label": "quiet", "type": "shell", "command": "make", "options": { "cwd": "/abs" }, "presentation": { "echo": false } },
        { "label": "process", "type": "process", "command": "node", "args": ["server.js", "a b"] },
        { "label": "direct", "type": "process", "command": "./bin/run", "presentation": { "echo": false, "reveal": "silent", "panel": "new" } }
        """).utf8))
        let resolver: (String, String?) -> String? = { name, path in name == "node" && path == "/usr/bin:/bin" ? "/usr/local/bin/node" : nil }

        let shell = try TaskRunner.launch(for: try #require(file.task("shell")), context: context, inputs: ["mode": "dev"], resolveExecutable: resolver)
        #expect(shell.commandLine == "pnpm dev --port '$PORT' 41000-api")
        #expect(shell.command.executable == "/bin/zsh")
        #expect(shell.command.arguments == ["-c", #"printf '\033[90m%s\033[0m\n' '> pnpm dev --port '\''$PORT'\'' 41000-api'; pnpm dev --port '$PORT' 41000-api"#])
        #expect(shell.command.environment == ["PATH": "/usr/bin:/bin", "PORT": "41000", "API": "41000-api"])
        #expect(shell.command.cwd.path == "/tmp/repo-worktrees/lima/apps/web")
        #expect(shell.echoLine == "> pnpm dev --port '$PORT' 41000-api")
        #expect(shell.panel == .shared)
        #expect(shell.reveal == .always)

        let quiet = try TaskRunner.launch(for: try #require(file.task("quiet")), context: context, inputs: [:], resolveExecutable: resolver)
        #expect(quiet.command == .script("make", environment: context.environment, cwd: URL(fileURLWithPath: "/abs")))
        #expect(quiet.echoLine == nil)

        let process = try TaskRunner.launch(for: try #require(file.task("process")), context: context, inputs: [:], resolveExecutable: resolver)
        #expect(process.command.executable == "/bin/sh")
        #expect(process.command.arguments == ["-c", #"printf '\033[90m%s\033[0m\n' '> node server.js '\''a b'\'''; exec "$0" "$@""#, "/usr/local/bin/node", "server.js", "a b"])

        let direct = try TaskRunner.launch(for: try #require(file.task("direct")), context: context, inputs: [:], resolveExecutable: resolver)
        #expect(direct.command.executable == "/tmp/repo-worktrees/lima/./bin/run")
        #expect(direct.command.arguments == [])
        #expect(direct.reveal == .silent)
        #expect(direct.panel == .new)
    }
}
