import Foundation
import Testing
@testable import RockyKit

/// KIT-16: `tasks.json` as VS Code reads it.
struct VSCodeTasksTests {
    private func file(_ json: String) throws -> TaskFile {
        try VSCodeTasks.parse(Data(json.utf8))
    }

    private var sample: TaskFile {
        get throws { try VSCodeTasks.parse(Fixtures.json("sample-tasks")) }
    }

    /// A made-up monorepo's file in a real one's shapes: 10 tasks, 6 of them "_", `//` comments and trailing commas,
    /// shell tasks with `dependsOn` in sequence and in parallel, background tasks with patterns, and pickString
    /// inputs, as label/value objects and as strings. (It replaced a copy of a work repository's file, which a public
    /// repository must not carry, 2026-09-25.)
    @Test func aRealisticFileReadsWhole() throws {
        let file = try sample
        #expect(file.tasks.count == 10)
        #expect(file.tasks.filter { $0.label.hasPrefix("_") }.count == 6)
        #expect(VSCodeTasks.listed(file).map(\.label) == ["Setup: Local DB", "Run: API + Web", "Run: API", "Run: Web"])
        let web = try #require(file.task("Run: API + Web"))
        #expect(web.kind == .shell)
        #expect(web.command == "pnpm ${input:runMode}")
        #expect(web.cwd == "${workspaceFolder}/apps/web")
        #expect(web.dependsOn == ["_Dev: Cleanup", "_API: Run (mode)"])
        #expect(web.dependsOrder == .sequence)
        #expect(web.isBackground)
        #expect(web.beginsPattern == "vite v")
        #expect(web.endsPattern == #"ready in \d+"#)
        #expect(web.presentation == VSCodeTask.Presentation(reveal: .always, focus: true, panel: .dedicated, clear: true, echo: true))
        // "group": "build" is a group, not a default.
        #expect(!web.isDefaultBuild)
        #expect(file.defaultBuildTask == nil)

        let cleanup = try #require(file.task("_Dev: Cleanup"))
        #expect(cleanup.presentation.reveal == .silent)
        #expect(cleanup.presentation.panel == .shared)
        #expect(cleanup.cwd == nil)
        #expect(!cleanup.isBackground)
        #expect(file.task("_API: Run (mode)")?.dependsOrder == .parallel)
        #expect(file.task("_API: Run (mode)")?.endsPattern == "Application startup complete")
        #expect(file.task("_API: Start Redis")?.args == ["--daemonize", "yes", "--port", "6390"])

        #expect(file.inputs.map(\.id) == ["runMode", "apiEnv", "webMode"])
        let mode = try #require(file.input("runMode"))
        #expect(mode.description == "Select environment and mode")
        #expect(mode.defaultValue == "dev-local")
        #expect(mode.kind == .pickString(options: [
            TaskInput.Option(label: "DEV — Local", value: "dev-local"),
            TaskInput.Option(label: "QA — Local", value: "qa-local"),
        ]))
        #expect(file.input("apiEnv")?.kind == .pickString(options: [
            TaskInput.Option(label: "dev", value: "dev"),
            TaskInput.Option(label: "qa", value: "qa"),
        ]))
    }

    @Test func commentsAndTrailingCommasParse() throws {
        let parsed = try file("""
        {
          // VS Code's own comments
          "version": "2.0.0",
          "tasks": [
            { "label": "a", "type": "shell", "command": "echo a", /* inline */ },
          ],
        }
        """)
        #expect(parsed.tasks.map(\.label) == ["a"])
    }

    @Test func aFileThatDoesNotParseSaysWhereAsTheMenuShowsIt() {
        let broken = """
        {
          "version": "2.0.0",
          "tasks": [
            { "label": "a" }
            }
          ]
        }
        """
        #expect(throws: TaskFileError("Line 5: Unexpected character “}” in array")) { try file(broken) }
        #expect(throws: TaskFileError("tasks[0].label: Expected to decode String but found number instead.")) {
            try file(#"{ "version": "2.0.0", "tasks": [ { "label": 3 } ] }"#)
        }
        #expect(throws: TaskFileError("version must be “2.0.0”, not “0.1.0”")) { try file(#"{ "version": "0.1.0" }"#) }
        #expect(throws: TaskFileError("version “2.0.0” is missing")) { try file(#"{ "tasks": [] }"#) }
    }

    /// TSK-01: "_" and `hide` stay out of the menu, in file order otherwise.
    @Test func hiddenLabelsAndHideStayOutOfTheMenu() throws {
        let parsed = try file("""
        { "version": "2.0.0", "tasks": [
          { "label": "b", "type": "shell", "command": "b" },
          { "label": "_helper", "type": "shell", "command": "h" },
          { "label": "hidden", "type": "shell", "command": "x", "hide": true },
          { "label": "a", "type": "shell", "command": "a" }
        ] }
        """)
        #expect(VSCodeTasks.listed(parsed).map(\.label) == ["b", "a"])
    }

    @Test func osxIsMergedOverTheTask() throws {
        let parsed = try file("""
        { "version": "2.0.0", "tasks": [ {
          "label": "t", "type": "shell", "command": "linux-cmd", "args": ["x"],
          "options": { "cwd": "sub", "env": { "A": "1", "B": "2" } },
          "osx": { "command": "mac-cmd", "options": { "env": { "B": "mac" } } }
        } ] }
        """)
        let task = try #require(parsed.task("t"))
        #expect(task.command == "mac-cmd")
        #expect(task.args == ["x"])
        #expect(task.cwd == "sub")
        #expect(task.env == ["A": "1", "B": "mac"])
    }

    /// The shapes VS Code allows besides celes-platform's: a lone `dependsOn`, `problemMatcher` as a name or an object,
    /// a pattern as `{regexp}`, an argument as `{value}`, a default build group, string options, a promptString.
    @Test func theOtherShapesVSCodeAllows() throws {
        let parsed = try file("""
        { "version": "2.0.0",
          "tasks": [
            { "label": "watch", "type": "process", "command": "tsc", "args": [{ "value": "-w", "quoting": "escape" }],
              "isBackground": true, "problemMatcher": { "background": { "endsPattern": { "regexp": "Watching" } } } },
            { "label": "build", "type": "shell", "command": "make", "dependsOn": "watch", "problemMatcher": "$gcc",
              "group": { "kind": "build", "isDefault": true } },
            { "label": "npm", "type": "npm", "script": "dev", "detail": "the dev server" }
          ],
          "inputs": [
            { "id": "name", "type": "promptString", "description": "Your name", "default": "me", "password": true },
            { "id": "flavor", "type": "pickString", "options": ["a", "b"] },
            { "id": "cmd", "type": "command", "command": "extension.pick" }
          ]
        }
        """)
        let watch = try #require(parsed.task("watch"))
        #expect(watch.kind == .process)
        #expect(watch.args == ["-w"])
        #expect(watch.endsPattern == "Watching")
        #expect(watch.beginsPattern == nil)
        #expect(parsed.task("build")?.dependsOn == ["watch"])
        #expect(parsed.defaultBuildTask?.label == "build")
        let npm = try #require(parsed.task("npm"))
        #expect(npm.kind == .unsupported("npm"))
        #expect(npm.unsupportedReason == "Type “npm” isn't supported: Rocky runs shell and process tasks")
        #expect(npm.detail == "the dev server")
        #expect(parsed.input("name") == TaskInput(id: "name", kind: .promptString(password: true), description: "Your name", defaultValue: "me"))
        #expect(parsed.input("flavor")?.kind == .pickString(options: [TaskInput.Option(label: "a", value: "a"), TaskInput.Option(label: "b", value: "b")]))
        #expect(parsed.input("cmd")?.kind == .unsupported("command"))
    }

    /// TSK-01: the worktree's file, else the main clone's.
    @Test func theFileComesFromTheMainCloneWhenTheWorktreeLacksIt() throws {
        let worktree = try Fixtures.temporaryDirectory("tasks-worktree")
        let clone = try Fixtures.temporaryDirectory("tasks-clone")
        #expect(VSCodeTasks.read(worktree: worktree, mainClone: clone) == .missing)

        let tasks = #"{ "version": "2.0.0", "tasks": [ { "label": "from-clone", "type": "shell", "command": "x" } ] }"#
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        try Data(tasks.utf8).write(to: clone.appendingPathComponent(VSCodeTasks.relativePath))
        #expect(VSCodeTasks.read(worktree: worktree, mainClone: clone) == .loaded(try file(tasks)))

        let own = #"{ "version": "2.0.0", "tasks": [ { "label": "own", "type": "shell", "command": "x" } ] }"#
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        try Data(own.utf8).write(to: worktree.appendingPathComponent(VSCodeTasks.relativePath))
        #expect(VSCodeTasks.read(worktree: worktree, mainClone: clone) == .loaded(try file(own)))

        try Data("{".utf8).write(to: worktree.appendingPathComponent(VSCodeTasks.relativePath))
        guard case .invalid = VSCodeTasks.read(worktree: worktree, mainClone: clone) else {
            Issue.record("a broken file reads as invalid")
            return
        }
    }

    // MARK: Plans

    private let graph = """
    { "version": "2.0.0", "tasks": [
      { "label": "root", "type": "shell", "command": "r", "dependsOn": ["left", "right"], "dependsOrder": "sequence" },
      { "label": "left", "type": "shell", "command": "l", "dependsOn": ["shared"] },
      { "label": "right", "type": "shell", "command": "r", "dependsOn": ["shared"] },
      { "label": "shared", "type": "shell", "command": "s" },
      { "label": "loop-a", "type": "shell", "command": "a", "dependsOn": "loop-b" },
      { "label": "loop-b", "type": "shell", "command": "b", "dependsOn": "loop-a" },
      { "label": "self", "type": "shell", "command": "s", "dependsOn": "self" },
      { "label": "orphan", "type": "shell", "command": "o", "dependsOn": "_missing" },
      { "label": "uses-npm", "type": "shell", "command": "u", "dependsOn": "npm" },
      { "label": "npm", "type": "npm", "script": "x" },
      { "label": "bad-pattern", "type": "shell", "command": "b", "isBackground": true,
        "problemMatcher": { "background": { "endsPattern": "([" } } }
    ] }
    """

    /// TSK-05: dependencies first, each once; a diamond's shared task runs once.
    @Test func aDiamondPlansItsSharedTaskOnce() throws {
        let plan = try VSCodeTasks.plan("root", in: try file(graph))
        #expect(plan.order.map(\.label) == ["shared", "left", "right", "root"])
        #expect(plan.labels == ["shared", "left", "right", "root"])
    }

    /// TSK-07: nothing starts on a cycle, an unknown label, another type or a pattern that is not a regular expression.
    @Test func brokenChainsAreRefusedBeforeAnythingStarts() throws {
        let parsed = try file(graph)
        #expect(throws: TaskError.cycle("loop-a", "loop-b")) { try VSCodeTasks.plan("loop-a", in: parsed) }
        #expect(TaskError.cycle("loop-a", "loop-b").description == "“loop-a” and “loop-b” depend on each other")
        #expect(throws: TaskError.cycle("self", "self")) { try VSCodeTasks.plan("self", in: parsed) }
        #expect(throws: TaskError.missingDependency(task: "orphan", dependency: "_missing")) { try VSCodeTasks.plan("orphan", in: parsed) }
        #expect(TaskError.missingDependency(task: "Run: X", dependency: "_Y").description == "“Run: X” depends on “_Y”, which tasks.json doesn't have")
        #expect(throws: TaskError.unsupportedType(task: "npm", type: "npm")) { try VSCodeTasks.plan("uses-npm", in: parsed) }
        #expect(throws: TaskError.invalidPattern(task: "bad-pattern", name: "endsPattern")) { try VSCodeTasks.plan("bad-pattern", in: parsed) }
        #expect(TaskError.invalidPattern(task: "_API Core: Run (mode)", name: "endsPattern").description == "“_API Core: Run (mode)” has an invalid endsPattern")
        #expect(throws: TaskError.noSuchTask("gone")) { try VSCodeTasks.plan("gone", in: parsed) }
    }

    /// TSK-04: every input of the chain once, dependencies first; "Run: API + Web" and its dependency
    /// "_API: Run (mode)" both read `runMode`, which is asked once.
    @Test func oneAnswerPerInputAcrossAChain() throws {
        let file = try sample
        let web = try VSCodeTasks.plan("Run: API + Web", in: file)
        #expect(web.order.map(\.label) == [
            "_Dev: Cleanup", "_API: Ensure venv", "_API: Ensure hooks", "_API: Run (mode)", "Run: API + Web",
        ])
        #expect(VSCodeTasks.inputsNeeded(for: web).map(\.id) == ["runMode"])
        let api = try VSCodeTasks.plan("Run: API", in: file)
        #expect(VSCodeTasks.inputsNeeded(for: api).map(\.id) == ["apiEnv"])
        let chained = try VSCodeTasks.plan("root", in: try self.file("""
        { "version": "2.0.0", "tasks": [
          { "label": "root", "type": "shell", "command": "${input:b} ${input:a}", "dependsOn": "dep" },
          { "label": "dep", "type": "shell", "command": "${input:a}", "options": { "env": { "Z": "${input:c}", "A": "${input:b}" } } }
        ], "inputs": [
          { "id": "a", "type": "promptString" }, { "id": "b", "type": "promptString" }, { "id": "c", "type": "promptString" }
        ] }
        """))
        #expect(VSCodeTasks.inputsNeeded(for: chained).map(\.id) == ["a", "b", "c"])
    }

    /// TSK-04 and TSK-07: an unknown variable, a `command` input and an input the file lacks start nothing.
    @Test func unsupportedVariablesAreRefused() throws {
        let parsed = try file("""
        { "version": "2.0.0", "tasks": [
          { "label": "Run: X", "type": "shell", "command": "open ${file}" },
          { "label": "picks", "type": "shell", "command": "echo ${input:cmd}" },
          { "label": "lacks", "type": "shell", "command": "echo", "args": ["${input:nope}"] },
          { "label": "env", "type": "shell", "command": "echo", "options": { "env": { "A": "${config:editor.tabSize}" } } },
          { "label": "fine", "type": "shell", "command": "echo ${workspaceFolder} ${workspaceRoot} ${workspaceFolderBasename} ${userHome} ${cwd} ${pathSeparator} ${env:HOME}" }
        ], "inputs": [ { "id": "cmd", "type": "command", "command": "x" } ] }
        """)
        #expect(throws: TaskError.unsupportedVariable(task: "Run: X", variable: "${file}")) { try VSCodeTasks.plan("Run: X", in: parsed) }
        #expect(TaskError.unsupportedVariable(task: "Run: X", variable: "${file}").description == "“Run: X” uses ${file}, which Rocky doesn't support")
        #expect(throws: TaskError.unsupportedVariable(task: "picks", variable: "${input:cmd}")) { try VSCodeTasks.plan("picks", in: parsed) }
        #expect(throws: TaskError.unsupportedVariable(task: "lacks", variable: "${input:nope}")) { try VSCodeTasks.plan("lacks", in: parsed) }
        #expect(throws: TaskError.unsupportedVariable(task: "env", variable: "${config:editor.tabSize}")) { try VSCodeTasks.plan("env", in: parsed) }
        _ = try VSCodeTasks.plan("fine", in: parsed)
    }

    // MARK: Run's default (TSK-02)

    /// The last item run from the menu, else the Run script, else the default build task, else the menu; a label the
    /// file lost, or a file that cannot be read, falls back.
    @Test func runsDefaultFallsBackInTSK02sOrder() throws {
        let file = try file("""
        { "version": "2.0.0", "tasks": [
          { "label": "Run: Web Client", "type": "shell", "command": "w" },
          { "label": "Build", "type": "shell", "command": "b", "group": { "kind": "build", "isDefault": true } }
        ] }
        """)
        let withScript = RunMenuState(tasks: .loaded(file), runScript: "pnpm dev", hasReadRunScript: true)
        let withoutScript = RunMenuState(tasks: .loaded(file), hasReadRunScript: true)
        #expect(withScript.defaultItem(last: .task("Run: Web Client")) == .task("Run: Web Client"))
        #expect(withScript.defaultItem(last: .task("Gone")) == .runScript)
        #expect(withScript.defaultItem(last: nil) == .runScript)
        #expect(withoutScript.defaultItem(last: .runScript) == .task("Build"))
        #expect(withoutScript.defaultItem(last: nil) == .task("Build"))
        #expect(RunMenuState(tasks: .loaded(TaskFile(tasks: [])), hasReadRunScript: true).defaultItem(last: nil) == nil)
        #expect(RunMenuState(tasks: .invalid("Line 3: …"), hasReadRunScript: true).defaultItem(last: .task("Run: Web Client")) == nil)
        // rocky.json that does not parse is still a Run script: clicking it says why.
        #expect(RunMenuState(tasks: .loaded(file), hasReadRunScript: true, runScriptFailure: "rocky.json is not valid").defaultItem(last: nil) == .runScript)
        // Before the first read, the last item and a Run script are taken on trust.
        #expect(RunMenuState(tasks: .unread).defaultItem(last: .task("Run: Web Client")) == .task("Run: Web Client"))
        #expect(RunMenuState(tasks: .unread).defaultItem(last: nil) == .runScript)
    }

    /// `@AppStorage("lastRunItemByRepo")`: repository id → task label or "run-script".
    @Test func lastRunItemsRoundTrip() {
        let items: [String: RunItem] = ["repo-a": .runScript, "repo-b": .task("Run: Web Client")]
        let json = RunItem.encodeAll(items)
        #expect(json == #"{"repo-a":"run-script","repo-b":"Run: Web Client"}"#)
        #expect(RunItem.decodeAll(json) == items)
        #expect(RunItem.decodeAll("") == [:])
        #expect(RunItem.decodeAll("not json") == [:])
    }

    // MARK: Variables and quoting

    @Test func everySupportedVariableResolves() throws {
        let context = VariableContext(
            workspaceFolder: "/tmp/repo-worktrees/lima",
            userHome: "/Users/me",
            environment: ["API": "dev", "HOME": "/Users/me"],
            inputs: ["mode": "dev-local"]
        )
        #expect(try VSCodeTasks.resolve("${workspaceFolder}/apps", context: context) == "/tmp/repo-worktrees/lima/apps")
        #expect(try VSCodeTasks.resolve("${workspaceRoot}|${cwd}", context: context) == "/tmp/repo-worktrees/lima|/tmp/repo-worktrees/lima")
        #expect(try VSCodeTasks.resolve("${workspaceFolderBasename}", context: context) == "lima")
        #expect(try VSCodeTasks.resolve("${userHome}${pathSeparator}x", context: context) == "/Users/me/x")
        #expect(try VSCodeTasks.resolve("${env:API}-${env:MISSING}.", context: context) == "dev-.")
        #expect(try VSCodeTasks.resolve("pnpm ${input:mode}", context: context) == "pnpm dev-local")
        #expect(try VSCodeTasks.resolve("no variables, $HOME and ${ unclosed", context: context) == "no variables, $HOME and ${ unclosed")
        #expect(throws: VSCodeTasks.UnsupportedVariable(variable: "${file}")) { try VSCodeTasks.resolve("${file}", context: context) }
        #expect(throws: VSCodeTasks.UnsupportedVariable(variable: "${input:other}")) { try VSCodeTasks.resolve("${input:other}", context: context) }
    }

    /// TSK-03: VS Code's strong quoting of a shell task's arguments; the command stays shell text.
    @Test func shellArgumentsAreQuotedWhenTheShellWouldReadThem() {
        #expect(VSCodeTasks.shellCommand(command: "redis-server", args: ["--daemonize", "yes", "--port", "6379"]) == "redis-server --daemonize yes --port 6379")
        #expect(VSCodeTasks.shellCommand(command: "echo $HOME && ls", args: ["two words", "$HOME", "it's", ""]) == #"echo $HOME && ls 'two words' '$HOME' 'it'\''s' ''"#)
        #expect(VSCodeTasks.shellCommand(command: "cp", args: ["a/b.txt", "user@host:/tmp", "x=1,y=2"]) == "cp a/b.txt user@host:/tmp x=1,y=2")
    }
}
