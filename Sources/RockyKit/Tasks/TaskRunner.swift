import Foundation

/// A task's process as the runner sees it (KIT-17, Decision 9 of M2.9): a `PTYSession` in the app, a fake in tests.
@MainActor
public protocol TaskProcess: AnyObject, Sendable {
    var id: UUID { get }
    var isRunning: Bool { get }
    func waitForExit() async -> PTYState
    func stop() async
    /// The runner has what it needed from the output (the task matched its `endsPattern`): stop handing it over.
    func stopWatchingOutput()
}

/// Starts a step's process in its tab (TSK-03). `onOutput`, when given, gets every chunk of the output from the first
/// byte on: the launcher attaches it before the process starts (Decision 8).
@MainActor
public protocol TaskLauncher: AnyObject {
    func start(_ launch: TaskLaunch, onOutput: ((ArraySlice<UInt8>) -> Void)?) -> any TaskProcess
}

/// One step, resolved (TSK-03, TSK-04): what runs, where, with which environment, and how its tab behaves.
public struct TaskLaunch: Equatable, Sendable {
    public let label: String
    public let command: PTYCommand
    /// The resolved command line.
    public let commandLine: String
    /// "> command line", which the task's shell prints first when `presentation.echo` is on; nil when it is off.
    public let echoLine: String?
    public let panel: VSCodeTask.Panel
    public let reveal: VSCodeTask.Reveal
    public let focus: Bool
}

/// Where a run happens.
public struct TaskContext: Sendable {
    public var worktree: URL
    public var userHome: String
    /// The workspace's environment (ENV-01, with `PORT` and `ROCKY_*`); each task's `options.env` goes on top.
    public var environment: [String: String]

    public init(worktree: URL, userHome: String = NSHomeDirectory(), environment: [String: String]) {
        self.worktree = worktree
        self.userHome = userHome
        self.environment = environment
    }
}

/// How `TaskRunner.run` ended.
public enum TaskRunOutcome: Equatable, Sendable {
    /// The task started, its process's id; nil for a task that only runs its dependencies, which are done.
    case started(UUID?)
    /// TSK-02: it was already running, and did not start twice.
    case alreadyRunning(UUID)
    /// TSK-04: Esc on one of its inputs; nothing started.
    case cancelled
    /// TSK-07: nothing started.
    case invalid(TaskError)
    /// TSK-05: `dependency` exited non-zero, or ended before its pattern, so what had not started did not start. Its
    /// process's id, for the toast's Show.
    case failed(dependency: String, process: UUID?)
    /// Stopped while its chain was starting: Stop, the run mode, the workspace's removal.
    case stopped
}

/// KIT-17: runs a `TaskPlan` in one workspace (TSK-03…TSK-06). It asks the chain's inputs once, before anything starts;
/// runs `dependsOn` in sequence or in parallel, each task once; waits for a normal step's exit and for a background
/// step's `endsPattern` on its output (or not at all without one); starts nothing more once a step failed; never starts
/// a dependency that already runs here; and remembers which run started which dependency, for Stop (TSK-06).
@MainActor
public final class TaskRunner {
    private let launcher: any TaskLauncher
    private let resolveExecutable: @Sendable (_ name: String, _ path: String?) -> String?
    /// The newest process of each label.
    private var instances: [String: Instance] = [:]
    /// The runs that are starting or whose processes still run, oldest first.
    private var runs: [Run] = []

    public init(
        launcher: any TaskLauncher,
        resolveExecutable: @escaping @Sendable (_ name: String, _ path: String?) -> String? = { name, path in
            AgentLauncher.resolve(name, path: path)?.path
        }
    ) {
        self.launcher = launcher
        self.resolveExecutable = resolveExecutable
    }

    /// The label's process while it runs.
    public func process(of label: String) -> (any TaskProcess)? {
        guard let process = instances[label]?.process, process.isRunning else { return nil }
        return process
    }

    public func isRunning(_ label: String) -> Bool {
        process(of: label) != nil
    }

    /// Runs `plan`: asks `ask` for each input the chain reads (TSK-04), awaits `beforeStart` (the run mode's stop of
    /// other workspaces, TSK-03), then starts the chain. Returns once the root has started, or the chain failed.
    public func run(
        _ plan: TaskPlan,
        context: TaskContext,
        ask: @MainActor (TaskInput) async -> String?,
        beforeStart: @MainActor () async -> Void = {}
    ) async -> TaskRunOutcome {
        if let running = process(of: plan.root) { return .alreadyRunning(running.id) }
        var answers: [String: String] = [:]
        for input in VSCodeTasks.inputsNeeded(for: plan) {
            guard let answer = await ask(input) else { return .cancelled }
            answers[input.id] = answer
        }
        await beforeStart()
        // Answered twice meanwhile (two clicks): the first run wins.
        if let running = process(of: plan.root) { return .alreadyRunning(running.id) }
        runs.removeAll { !$0.isInProgress && !$0.started.contains { $0.process.isRunning } }
        let run = Run(plan: plan, context: context, answers: answers)
        runs.append(run)
        let result = await step(plan.root, in: run, isRoot: true)
        run.isInProgress = false
        switch result {
        case .done: return .started(run.started.last { $0.label == plan.root }?.process.id)
        case .failed(let label, let process): return .failed(dependency: label, process: process)
        case .invalid(let error): return .invalid(error)
        case .stopped: return .stopped
        }
    }

    /// TSK-06: stops `label` and the dependencies its newest run started that no other running task needs, newest
    /// first. A chain still starting starts nothing more. A dependency another run needs goes on running, and that run
    /// takes it over, so its own Stop stops it: a dependency two tasks share is stopped once, with the last of them.
    public func stop(_ label: String) async {
        guard let run = runs.last(where: { $0.plan.root == label }) else {
            await instances[label]?.process.stop()
            return
        }
        run.isStopped = true
        let others = runs.filter { $0 !== run && $0.isActive }
        for instance in run.started.reversed() where instance.process.isRunning {
            if instance.label != label, let heir = others.last(where: { $0.plan.labels.contains(instance.label) }) {
                if !heir.started.contains(where: { $0 === instance }) { heir.started.insert(instance, at: 0) }
                continue
            }
            await instance.process.stop()
        }
        run.started.removeAll()
    }

    /// TSK-06's "Always", and the run mode: every chain stops starting, and every process here stops.
    public func stopAll() async {
        for run in runs { run.isStopped = true }
        let running = instances.values.map(\.process).filter(\.isRunning)
        await withTaskGroup(of: Void.self) { group in
            for process in running {
                group.addTask { await process.stop() }
            }
        }
    }

    // MARK: Steps

    /// A task reached twice in one run runs once: the second caller waits for the first (TSK-05).
    private func step(_ label: String, in run: Run, isRoot: Bool = false) async -> StepResult {
        if let existing = run.steps[label] { return await existing.value }
        let step = Task { await self.perform(label, in: run, isRoot: isRoot) }
        run.steps[label] = step
        return await step.value
    }

    private func perform(_ label: String, in run: Run, isRoot: Bool) async -> StepResult {
        guard let task = run.plan.task(label) else { return .invalid(.noSuchTask(label)) }
        // TSK-05: a dependency already running here is not started again, and counts once it is done.
        if !isRoot, let instance = instances[label], instance.process.isRunning {
            return await finish(instance, in: run)
        }
        switch task.dependsOrder {
        case .sequence:
            for dependency in task.dependsOn {
                let result = await step(dependency, in: run)
                guard result == .done else { return result }
            }
        case .parallel:
            let steps = task.dependsOn.map { dependency in Task { await self.step(dependency, in: run) } }
            let result = await Self.allDone(steps)
            guard result == .done else { return result }
        }
        if let stop = run.stopReason { return stop }
        // A task of dependencies only is done with them.
        guard task.command != nil else { return .done }
        let launch: TaskLaunch
        do {
            let context = run.context, answers = run.answers, resolveExecutable = self.resolveExecutable
            launch = try await Task.blocking {
                try Self.launch(for: task, context: context, inputs: answers, resolveExecutable: resolveExecutable)
            }.value
        } catch let unsupported as VSCodeTasks.UnsupportedVariable {
            return .invalid(.unsupportedVariable(task: label, variable: unsupported.variable))
        } catch let error as TaskError {
            return .invalid(error)
        } catch {
            return .invalid(.unsupportedVariable(task: label, variable: "\(error)"))
        }
        // Another branch failed, or Stop came, while this one was resolved.
        if let stop = run.stopReason { return stop }
        let instance = start(task, launch)
        run.started.append(instance)
        if isRoot { return .done }
        return await finish(instance, in: run)
    }

    /// Parallel dependencies: done once all are, or the first failure as soon as it comes. A sibling still waiting for
    /// its pattern must not hold the failure back, and it keeps running (TSK-05).
    private static func allDone(_ steps: [Task<StepResult, Never>]) async -> StepResult {
        guard !steps.isEmpty else { return .done }
        return await withCheckedContinuation { continuation in
            let collector = StepCollector(count: steps.count, continuation: continuation)
            for step in steps {
                Task { collector.add(await step.value) }
            }
        }
    }

    /// A dependency done, failed, or ended by Stop, which is no failure of its own.
    private func finish(_ instance: Instance, in run: Run) async -> StepResult {
        if await instance.waitUntilDone() { return .done }
        return run.isStopped ? .stopped : run.fail(instance.label, instance.process.id)
    }

    private func start(_ task: VSCodeTask, _ launch: TaskLaunch) -> Instance {
        let instance = Instance(label: task.label, isBackground: task.isBackground)
        var onOutput: ((ArraySlice<UInt8>) -> Void)?
        // Only what waits for an `endsPattern` reads the output, and only until it matches.
        if task.isBackground, task.endsPattern != nil {
            instance.watcher = try? TaskOutputWatcher(
                beginsPattern: task.beginsPattern,
                endsPattern: task.endsPattern,
                ignoringFirstLine: launch.echoLine
            )
            instance.waitsForPattern = true
            onOutput = { [weak instance] bytes in instance?.feed(bytes) }
        }
        let process = launcher.start(launch, onOutput: onOutput)
        instance.process = process
        instances[task.label] = instance
        Task { [weak instance] in
            let state = await process.waitForExit()
            instance?.ended(state)
        }
        return instance
    }

    // MARK: Resolving a step

    /// TSK-03, TSK-04: the step's variables resolved, its environment (the workspace's, then `options.env`), its folder
    /// (`options.cwd`, relative to the worktree, else the worktree), and its process: a shell task's command line
    /// through `/bin/zsh -c`, as scripts run; a process task's executable, found on `PATH`, with its arguments and no
    /// shell. `presentation.echo` first prints "> command" in the terminal's dim gray, from the shell that starts it;
    /// for a process task a `/bin/sh` that then `exec`s it, so the process is still the task's own.
    nonisolated static func launch(
        for task: VSCodeTask,
        context: TaskContext,
        inputs: [String: String],
        resolveExecutable: (_ name: String, _ path: String?) -> String?
    ) throws -> TaskLaunch {
        var variables = VariableContext(
            workspaceFolder: context.worktree.path,
            userHome: context.userHome,
            environment: context.environment,
            inputs: inputs
        )
        var environment = context.environment
        for (key, value) in task.env {
            environment[key] = try VSCodeTasks.resolve(value, context: variables)
        }
        variables.environment = environment
        let command = try VSCodeTasks.resolve(task.command ?? "", context: variables)
        let args = try task.args.map { try VSCodeTasks.resolve($0, context: variables) }
        var cwd = context.worktree
        if let raw = task.cwd {
            let path = try VSCodeTasks.resolve(raw, context: variables)
            cwd = path.hasPrefix("/") ? URL(fileURLWithPath: path) : context.worktree.appendingPathComponent(path)
        }
        let line = VSCodeTasks.shellCommand(command: command, args: args)
        let echoLine = task.presentation.echo ? "> " + line : nil
        let echo = echoLine.map(echoCommand) ?? ""
        let process: PTYCommand
        switch task.kind {
        case .shell:
            process = .script(echo + line, environment: environment, cwd: cwd)
        case .process:
            let executable = if command.contains("/") {
                command.hasPrefix("/") ? command : cwd.appendingPathComponent(command).path
            } else {
                resolveExecutable(command, environment["PATH"]) ?? command
            }
            process = task.presentation.echo
                ? PTYCommand(executable: "/bin/sh", arguments: ["-c", echo + #"exec "$0" "$@""#, executable] + args, environment: environment, cwd: cwd)
                : PTYCommand(executable: executable, arguments: args, environment: environment, cwd: cwd)
        case .unsupported(let type):
            throw TaskError.unsupportedType(task: task.label, type: type)
        }
        return TaskLaunch(
            label: task.label,
            command: process,
            commandLine: line,
            echoLine: echoLine,
            panel: task.presentation.panel,
            reveal: task.presentation.reveal,
            focus: task.presentation.focus
        )
    }

    /// Prints `echoLine`, like VS Code's "Executing task", in ANSI bright black: the terminal's `textTertiary`.
    nonisolated static func echoCommand(_ echoLine: String) -> String {
        #"printf '\033[90m%s\033[0m\n' "# + VSCodeTasks.quoted(echoLine) + "; "
    }
}

/// How one step of a run ended.
private enum StepResult: Equatable {
    case done
    case failed(String, UUID?)
    case invalid(TaskError)
    case stopped
}

/// Gathers parallel steps' results for `TaskRunner.allDone`, and answers once.
@MainActor
private final class StepCollector {
    private var remaining: Int
    private var continuation: CheckedContinuation<StepResult, Never>?

    init(count: Int, continuation: CheckedContinuation<StepResult, Never>) {
        remaining = count
        self.continuation = continuation
    }

    func add(_ result: StepResult) {
        guard let continuation else { return }
        remaining -= 1
        guard result != .done || remaining == 0 else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}

/// One process of a label, and whether it counts as done for what depends on it (TSK-05).
@MainActor
private final class Instance {
    let label: String
    let isBackground: Bool
    /// Set by `TaskRunner.start` right after the launcher returns, before anything else can read it.
    var process: (any TaskProcess)!
    var watcher: TaskOutputWatcher?
    /// A background task with an `endsPattern`: done once a line matches it. Without one it is done once it starts.
    var waitsForPattern = false
    private var isReady = false
    private var exit: PTYState?
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []

    init(label: String, isBackground: Bool) {
        self.label = label
        self.isBackground = isBackground
    }

    /// A normal task: it exited with 0. A background task: its pattern matched (it keeps running), or at once without
    /// one; it failed when it ended before.
    func waitUntilDone() async -> Bool {
        guard isBackground else { return await process.waitForExit() == .exited(0) }
        guard waitsForPattern, !isReady else { return true }
        if exit != nil { return false }
        return await withCheckedContinuation { readyWaiters.append($0) }
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        guard var watcher else { return }
        let matches = watcher.feed(bytes)
        self.watcher = watcher
        if waitsForPattern, matches.contains(.ends) { becameReady() }
    }

    func ended(_ state: PTYState) {
        exit = state
        resume(false)
    }

    private func becameReady() {
        isReady = true
        watcher = nil
        process?.stopWatchingOutput()
        resume(true)
    }

    private func resume(_ done: Bool) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: done) }
    }
}

/// One run of a task: its chain, its answers, its steps and what it started (TSK-06).
@MainActor
private final class Run {
    let plan: TaskPlan
    let context: TaskContext
    let answers: [String: String]
    var steps: [String: Task<StepResult, Never>] = [:]
    var started: [Instance] = []
    var failure: (label: String, process: UUID?)?
    var isStopped = false
    var isInProgress = true

    init(plan: TaskPlan, context: TaskContext, answers: [String: String]) {
        self.plan = plan
        self.context = context
        self.answers = answers
    }

    /// Still starting, or its task still running: what it needs keeps running when another run stops (TSK-06).
    var isActive: Bool {
        !isStopped && (isInProgress || started.contains { $0.label == plan.root && $0.process.isRunning })
    }

    /// Why nothing more of this run starts: Stop, or a step that failed (TSK-05).
    var stopReason: StepResult? {
        if isStopped { return .stopped }
        return failure.map { .failed($0.label, $0.process) }
    }

    /// Records the run's first failure, which stops what has not started.
    func fail(_ label: String, _ process: UUID?) -> StepResult {
        if failure == nil { failure = (label, process) }
        return .failed(label, process)
    }
}
