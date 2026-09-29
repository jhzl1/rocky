import Foundation

/// One task of `.vscode/tasks.json` (TSK-01), with what Rocky reads of it; everything else in the file is ignored.
/// `osx` is already merged over it.
public struct VSCodeTask: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case shell, process
        /// TSK-07: npm, gulp and the other extensions' types, which Rocky does not run.
        case unsupported(String)
    }

    public enum DependsOrder: String, Equatable, Sendable {
        case parallel, sequence
    }

    /// TSK-03: which tab the task runs in.
    public enum Panel: String, Equatable, Sendable {
        case shared, dedicated, new
    }

    public enum Reveal: String, Equatable, Sendable {
        case always, silent, never
    }

    /// `presentation`, with VS Code's defaults for what the file leaves out.
    public struct Presentation: Equatable, Sendable {
        public var reveal: Reveal = .always
        public var focus = false
        public var panel: Panel = .shared
        public var clear = false
        public var echo = true

        public init(reveal: Reveal = .always, focus: Bool = false, panel: Panel = .shared, clear: Bool = false, echo: Bool = true) {
            self.reveal = reveal
            self.focus = focus
            self.panel = panel
            self.clear = clear
            self.echo = echo
        }
    }

    public var label: String
    public var kind: Kind
    /// nil for a task that only runs its dependencies.
    public var command: String?
    public var args: [String]
    public var cwd: String?
    public var env: [String: String]
    public var dependsOn: [String]
    public var dependsOrder: DependsOrder
    public var isBackground: Bool
    /// The first problem matcher's `background` patterns (TSK-05): regular expressions matched against output lines.
    public var beginsPattern: String?
    public var endsPattern: String?
    public var presentation: Presentation
    public var detail: String?
    public var hide: Bool
    /// `group: {kind: "build", isDefault: true}`: what Run's main part runs when nothing else is its default (TSK-02).
    public var isDefaultBuild: Bool

    public init(
        label: String,
        kind: Kind = .shell,
        command: String? = nil,
        args: [String] = [],
        cwd: String? = nil,
        env: [String: String] = [:],
        dependsOn: [String] = [],
        dependsOrder: DependsOrder = .parallel,
        isBackground: Bool = false,
        beginsPattern: String? = nil,
        endsPattern: String? = nil,
        presentation: Presentation = Presentation(),
        detail: String? = nil,
        hide: Bool = false,
        isDefaultBuild: Bool = false
    ) {
        self.label = label
        self.kind = kind
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.dependsOn = dependsOn
        self.dependsOrder = dependsOrder
        self.isBackground = isBackground
        self.beginsPattern = beginsPattern
        self.endsPattern = endsPattern
        self.presentation = presentation
        self.detail = detail
        self.hide = hide
        self.isDefaultBuild = isDefaultBuild
    }

    /// TSK-01: the Run menu lists every task whose label does not start with "_" and that has no `"hide": true`.
    /// Hidden tasks still run as dependencies.
    public var isListed: Bool {
        !label.hasPrefix("_") && !hide
    }

    /// TSK-07: the menu's tooltip for a task Rocky cannot run; nil for shell and process tasks.
    public var unsupportedReason: String? {
        guard case .unsupported(let type) = kind else { return nil }
        return "Type “\(type)” isn't supported: Rocky runs shell and process tasks"
    }
}

/// One of the file's `inputs` (TSK-04): what `${input:id}` asks before a run.
public struct TaskInput: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public enum Kind: Equatable, Sendable {
        case pickString(options: [Option])
        case promptString(password: Bool)
        /// A `command` input or a type VS Code's extensions add; a task that uses it does not run (TSK-07).
        case unsupported(String)
    }

    public let id: String
    public let kind: Kind
    public let description: String?
    public let defaultValue: String?

    public init(id: String, kind: Kind, description: String? = nil, defaultValue: String? = nil) {
        self.id = id
        self.kind = kind
        self.description = description
        self.defaultValue = defaultValue
    }
}

/// A parsed `tasks.json`: its tasks in file order and its inputs.
public struct TaskFile: Equatable, Sendable {
    public let tasks: [VSCodeTask]
    public let inputs: [TaskInput]

    public init(tasks: [VSCodeTask], inputs: [TaskInput] = []) {
        self.tasks = tasks
        self.inputs = inputs
    }

    /// The first task with that label, as VS Code picks it.
    public func task(_ label: String) -> VSCodeTask? {
        tasks.first { $0.label == label }
    }

    public func input(_ id: String) -> TaskInput? {
        inputs.first { $0.id == id }
    }

    /// TSK-02: the first `{kind: "build", isDefault: true}` task.
    public var defaultBuildTask: VSCodeTask? {
        tasks.first(where: \.isDefaultBuild)
    }
}

/// A task and its whole dependency chain, checked (TSK-05, TSK-07): every label exists, nothing depends on itself, every
/// type is shell or process, every pattern compiles and every variable is one Rocky resolves.
public struct TaskPlan: Equatable, Sendable {
    public let root: String
    /// Each task of the chain once, its dependencies before it: the order inputs are asked in (TSK-04).
    public let order: [VSCodeTask]
    /// The file's inputs, which `inputsNeeded(for:)` picks from.
    public let fileInputs: [TaskInput]

    public func task(_ label: String) -> VSCodeTask? {
        order.first { $0.label == label }
    }

    /// Every label of the chain, root included: what a run needs to keep running (TSK-06).
    public var labels: Set<String> {
        Set(order.map(\.label))
    }
}

/// `tasks.json` does not parse, or its `version` is not 2.0.0 (TSK-07): the menu shows `message`, "Line 41: …".
public struct TaskFileError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

/// TSK-07's reasons for starting nothing, worded as its toasts.
public enum TaskError: Error, Equatable, CustomStringConvertible {
    /// `${file}`, `${config:…}`, a `command` input, or an `${input:id}` the file has no input for.
    case unsupportedVariable(task: String, variable: String)
    case missingDependency(task: String, dependency: String)
    case cycle(String, String)
    case invalidPattern(task: String, name: String)
    case unsupportedType(task: String, type: String)
    /// The label is not in the file any more.
    case noSuchTask(String)

    public var description: String {
        switch self {
        case .unsupportedVariable(let task, let variable):
            "“\(task)” uses \(variable), which Rocky doesn't support"
        case .missingDependency(let task, let dependency):
            "“\(task)” depends on “\(dependency)”, which tasks.json doesn't have"
        case .cycle(let first, let second) where first == second:
            "“\(first)” depends on itself"
        case .cycle(let first, let second):
            "“\(first)” and “\(second)” depend on each other"
        case .invalidPattern(let task, let name):
            "“\(task)” has an invalid \(name)"
        case .unsupportedType(let task, let type):
            "“\(task)” is of type “\(type)”, which Rocky doesn't run: it runs shell and process tasks"
        case .noSuchTask(let label):
            "tasks.json has no task “\(label)”"
        }
    }
}

/// What `${…}` resolves against (TSK-04).
public struct VariableContext: Sendable {
    /// The worktree: `${workspaceFolder}`, `${workspaceRoot}` and `${cwd}`, even when the file is the main clone's.
    public var workspaceFolder: String
    public var userHome: String
    /// The task's environment, for `${env:NAME}`.
    public var environment: [String: String]
    /// Each input id's answer.
    public var inputs: [String: String]

    public init(workspaceFolder: String, userHome: String, environment: [String: String], inputs: [String: String] = [:]) {
        self.workspaceFolder = workspaceFolder
        self.userHome = userHome
        self.environment = environment
        self.inputs = inputs
    }
}

/// KIT-16: `.vscode/tasks.json` as VS Code reads it, JSON with comments and trailing commas (`allowsJSON5`), for Run's
/// menu (TSK-01…TSK-07). Read each time the menu opens or Run's main part is clicked, never watched.
public enum VSCodeTasks {
    public static let relativePath = ".vscode/tasks.json"

    /// A variable Rocky does not resolve, or an input with no answer.
    public struct UnsupportedVariable: Error, Equatable {
        public let variable: String
    }

    /// TSK-01: the worktree's file; when it has none, the main clone's, since `.vscode` is often ignored and
    /// `WorktreeLinker` links only what `links` names. nil when neither has one.
    public static func fileURL(worktree: URL, mainClone: URL) -> URL? {
        [worktree, mainClone]
            .map { $0.appendingPathComponent(relativePath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Reads and parses the file `fileURL` finds. Blocking: run it through `Task.blocking`.
    public static func read(worktree: URL, mainClone: URL) -> RunMenuState.Tasks {
        guard let url = fileURL(worktree: worktree, mainClone: mainClone) else { return .missing }
        do {
            return .loaded(try parse(Data(contentsOf: url)))
        } catch let error as TaskFileError {
            return .invalid(error.message)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// KIT-16: JSON5, `version` 2.0.0, `osx` merged over each task.
    public static func parse(_ data: Data) throws -> TaskFile {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let raw: RawFile
        do {
            raw = try decoder.decode(RawFile.self, from: data)
        } catch {
            throw TaskFileError(describe(error))
        }
        guard raw.version == "2.0.0" else {
            throw TaskFileError(raw.version.map { "version must be “2.0.0”, not “\($0)”" } ?? "version “2.0.0” is missing")
        }
        let tasks = (raw.tasks ?? []).enumerated().map { index, task in task.merged().task(fallbackLabel: "Task \(index + 1)") }
        return TaskFile(tasks: tasks, inputs: (raw.inputs ?? []).map(\.input))
    }

    /// TSK-01: the listed tasks, in file order.
    public static func listed(_ file: TaskFile) -> [VSCodeTask] {
        file.tasks.filter(\.isListed)
    }

    /// TSK-05: `label` and its dependencies, recursively, each once, checked for TSK-07's errors before anything starts.
    public static func plan(_ label: String, in file: TaskFile) throws -> TaskPlan {
        var order: [VSCodeTask] = []
        var done: Set<String> = []
        var path: [String] = []

        func visit(_ label: String, namedBy parent: String?) throws {
            if done.contains(label) { return }
            if path.contains(label) { throw TaskError.cycle(label, parent ?? label) }
            guard let task = file.task(label) else {
                throw parent.map { TaskError.missingDependency(task: $0, dependency: label) } ?? TaskError.noSuchTask(label)
            }
            try check(task, in: file)
            path.append(label)
            for dependency in task.dependsOn {
                try visit(dependency, namedBy: label)
            }
            path.removeLast()
            done.insert(label)
            order.append(task)
        }

        try visit(label, namedBy: nil)
        return TaskPlan(root: label, order: order, fileInputs: file.inputs)
    }

    /// TSK-04: every input the chain reads, once per id, in order of first use (dependencies first).
    public static func inputsNeeded(for plan: TaskPlan) -> [TaskInput] {
        var ids: [String] = []
        for task in plan.order {
            for variable in texts(of: task).flatMap(variables(in:)) {
                guard variable.hasPrefix("input:") else { continue }
                let id = String(variable.dropFirst("input:".count))
                if !ids.contains(id) { ids.append(id) }
            }
        }
        return ids.compactMap { id in plan.fileInputs.first { $0.id == id } }
    }

    /// TSK-04: replaces every `${…}` in `text`. Any variable but the supported ones throws `UnsupportedVariable`.
    public static func resolve(_ text: String, context: VariableContext) throws -> String {
        var result = ""
        var rest = text[...]
        while let start = rest.range(of: "${") {
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else { break }
            result += rest[..<start.lowerBound]
            let name = String(rest[start.upperBound..<end])
            result += try value(of: name, context: context)
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    /// TSK-03: a shell task's command line, its args after the command, each in single quotes when it holds a space or
    /// a character the shell would read (VS Code's "strong" quoting). The command itself is shell text, left as it is.
    public static func shellCommand(command: String, args: [String]) -> String {
        ([command] + args.map(quoted)).joined(separator: " ")
    }

    /// One argument as `shellCommand` writes it: bare when every character is plain, else `'…'` with each `'` closed,
    /// escaped and reopened.
    public static func quoted(_ argument: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-+=/.,:@%")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: Checks

    private static func check(_ task: VSCodeTask, in file: TaskFile) throws {
        if case .unsupported(let type) = task.kind {
            throw TaskError.unsupportedType(task: task.label, type: type)
        }
        for (name, pattern) in [("beginsPattern", task.beginsPattern), ("endsPattern", task.endsPattern)] {
            guard let pattern else { continue }
            if (try? NSRegularExpression(pattern: pattern)) == nil {
                throw TaskError.invalidPattern(task: task.label, name: name)
            }
        }
        for variable in texts(of: task).flatMap(variables(in:)) where !isSupported(variable, in: file) {
            throw TaskError.unsupportedVariable(task: task.label, variable: "${\(variable)}")
        }
    }

    /// Where variables are resolved (TSK-04): `command`, `args`, `options.cwd` and `options.env`, the environment in
    /// its keys' order so the inputs' order does not depend on a dictionary's.
    private static func texts(of task: VSCodeTask) -> [String] {
        [task.command, task.cwd].compactMap { $0 } + task.args + task.env.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The names between `${` and `}`, in order.
    private static func variables(in text: String) -> [String] {
        var names: [String] = []
        var rest = text[...]
        while let start = rest.range(of: "${"), let end = rest[start.upperBound...].firstIndex(of: "}") {
            names.append(String(rest[start.upperBound..<end]))
            rest = rest[rest.index(after: end)...]
        }
        return names
    }

    private static let plainVariables: Set<String> = [
        "workspaceFolder", "workspaceRoot", "workspaceFolderBasename", "userHome", "cwd", "pathSeparator",
    ]

    private static func isSupported(_ variable: String, in file: TaskFile) -> Bool {
        if plainVariables.contains(variable) { return true }
        if variable.hasPrefix("env:") { return variable.count > "env:".count }
        if variable.hasPrefix("input:") {
            guard let input = file.input(String(variable.dropFirst("input:".count))) else { return false }
            if case .unsupported = input.kind { return false }
            return true
        }
        return false
    }

    private static func value(of name: String, context: VariableContext) throws -> String {
        switch name {
        case "workspaceFolder", "workspaceRoot", "cwd": return context.workspaceFolder
        case "workspaceFolderBasename": return URL(fileURLWithPath: context.workspaceFolder).lastPathComponent
        case "userHome": return context.userHome
        case "pathSeparator": return "/"
        default:
            if name.hasPrefix("env:") {
                // VS Code reads a variable the environment lacks as empty.
                return context.environment[String(name.dropFirst("env:".count))] ?? ""
            }
            if name.hasPrefix("input:"), let answer = context.inputs[String(name.dropFirst("input:".count))] {
                return answer
            }
            throw UnsupportedVariable(variable: "${\(name)}")
        }
    }

    // MARK: Errors

    /// TSK-07's "Line 41: …": the decoder's "… around line 41, column 5." rewritten, and a wrong type as the path to it.
    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            guard let underlying = context.underlyingError as NSError? else { return context.debugDescription }
            let text = underlying.userInfo[NSDebugDescriptionErrorKey] as? String ?? underlying.localizedDescription
            return lineForm(text)
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        case DecodingError.keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])) is missing"
        default:
            return "\(error)"
        }
    }

    /// "Unexpected character '}' in array around line 5, column 5." → "Line 5: Unexpected character “}” in array".
    static func lineForm(_ text: String) -> String {
        guard let match = text.firstMatch(of: /^(.*?)\s*around line (\d+), column \d+\.?$/) else { return text }
        let message = String(match.1).replacing(/'(.)'/) { "“\($0.1)”" }
        return "Line \(match.2): \(message)"
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.reduce(into: "") { path, key in
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }
}

// MARK: The file's shape

/// What Rocky decodes of the file. Every key is optional, so a key it does not know or need never fails the file.
private struct RawFile: Decodable {
    var version: String?
    var tasks: [RawTask]?
    var inputs: [RawInput]?
}

private struct RawTask: Decodable {
    var label: String?
    var type: String?
    var command: Text?
    var args: [Text]?
    var options: RawOptions?
    var dependsOn: OneOrMany<String>?
    var dependsOrder: String?
    var isBackground: Bool?
    var problemMatcher: OneOrMany<RawMatcher>?
    var presentation: RawPresentation?
    var detail: String?
    var hide: Bool?
    var group: RawGroup?
    var osx: Platform?

    /// `osx` holds the same keys as a task, and a nested one is not read: a class breaks the recursion.
    final class Platform: Decodable {
        let task: RawTask

        init(from decoder: Decoder) throws {
            task = try RawTask(from: decoder)
        }
    }

    /// VS Code's platform properties: `osx`'s keys win, and its environment adds to the task's.
    func merged() -> RawTask {
        guard let osx = osx?.task else { return self }
        var merged = self
        merged.type = osx.type ?? type
        merged.command = osx.command ?? command
        merged.args = osx.args ?? args
        merged.dependsOn = osx.dependsOn ?? dependsOn
        merged.dependsOrder = osx.dependsOrder ?? dependsOrder
        merged.isBackground = osx.isBackground ?? isBackground
        merged.problemMatcher = osx.problemMatcher ?? problemMatcher
        merged.presentation = osx.presentation ?? presentation
        if let options = osx.options {
            var env = self.options?.env ?? [:]
            env.merge(options.env ?? [:]) { _, new in new }
            merged.options = RawOptions(cwd: options.cwd ?? self.options?.cwd, env: env)
        }
        merged.osx = nil
        return merged
    }

    func task(fallbackLabel: String) -> VSCodeTask {
        let kind: VSCodeTask.Kind = switch type {
        // VS Code runs a task without a type as a process.
        case "process"?, nil: .process
        case "shell"?: .shell
        case let other?: .unsupported(other)
        }
        let background = problemMatcher?.values.lazy.compactMap(\.background).first
        return VSCodeTask(
            label: label ?? fallbackLabel,
            kind: kind,
            command: command?.joined,
            args: (args ?? []).map(\.joined),
            cwd: options?.cwd,
            env: options?.env ?? [:],
            dependsOn: dependsOn?.values ?? [],
            dependsOrder: dependsOrder == "sequence" ? .sequence : .parallel,
            isBackground: isBackground ?? false,
            beginsPattern: background?.beginsPattern?.regexp,
            endsPattern: background?.endsPattern?.regexp,
            presentation: presentation?.presentation ?? VSCodeTask.Presentation(),
            detail: detail,
            hide: hide ?? false,
            isDefaultBuild: group?.isDefaultBuild ?? false
        )
    }
}

private struct RawOptions: Decodable {
    var cwd: String?
    var env: [String: String]?
}

private struct RawPresentation: Decodable {
    var reveal: String?
    var focus: Bool?
    var panel: String?
    var clear: Bool?
    var echo: Bool?

    var presentation: VSCodeTask.Presentation {
        VSCodeTask.Presentation(
            reveal: reveal.flatMap(VSCodeTask.Reveal.init(rawValue:)) ?? .always,
            focus: focus ?? false,
            panel: panel.flatMap(VSCodeTask.Panel.init(rawValue:)) ?? .shared,
            clear: clear ?? false,
            echo: echo ?? true
        )
    }
}

/// `"group": "build"` or `{ "kind": "build", "isDefault": true }`. A glob in `isDefault` (the active file's) is not a
/// default: Rocky has no active file.
private struct RawGroup: Decodable {
    var kind: String?
    var isDefault = false

    private enum CodingKeys: String, CodingKey {
        case kind, isDefault
    }

    init(from decoder: Decoder) throws {
        if let kind = try? decoder.singleValueContainer().decode(String.self) {
            self.kind = kind
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        isDefault = (try? container.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? false
    }

    var isDefaultBuild: Bool {
        kind == "build" && isDefault
    }
}

/// A problem matcher: a name such as "$tsc" (not read), or an object whose `background` Rocky reads.
private struct RawMatcher: Decodable {
    struct Background: Decodable {
        var beginsPattern: Pattern?
        var endsPattern: Pattern?
    }

    /// A pattern, as a string or as `{ "regexp": … }`.
    struct Pattern: Decodable {
        var regexp: String

        private enum CodingKeys: String, CodingKey {
            case regexp
        }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                regexp = text
            } else {
                regexp = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .regexp)
            }
        }
    }

    var background: Background?

    private enum CodingKeys: String, CodingKey {
        case background
    }

    init(from decoder: Decoder) throws {
        if (try? decoder.singleValueContainer().decode(String.self)) != nil { return }
        background = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Background.self, forKey: .background)
    }
}

private struct RawInput: Decodable {
    var id: String
    var type: String
    var description: String?
    var options: [Option]?
    var `default`: String?
    var password: Bool?

    /// An option as a string, or as `{ "label": …, "value": … }`.
    struct Option: Decodable {
        var label: String
        var value: String

        private enum CodingKeys: String, CodingKey {
            case label, value
        }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                label = text
                value = text
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(String.self, forKey: .value)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? value
        }
    }

    var input: TaskInput {
        let kind: TaskInput.Kind = switch type {
        case "pickString": .pickString(options: (options ?? []).map { TaskInput.Option(label: $0.label, value: $0.value) })
        case "promptString": .promptString(password: password ?? false)
        default: .unsupported(type)
        }
        return TaskInput(id: id, kind: kind, description: description, defaultValue: `default`)
    }
}

/// A command or an argument: a string, or `{ "value": …, "quoting": … }` whose value may be a list of words.
private struct Text: Decodable {
    var words: [String]

    private enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            words = [text]
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .value) {
            words = [text]
        } else {
            words = try container.decode([String].self, forKey: .value)
        }
    }

    var joined: String {
        words.joined(separator: " ")
    }
}

/// `"dependsOn": "A"` or `["A", "B"]`; `problemMatcher` the same way.
private struct OneOrMany<Value: Decodable>: Decodable {
    var values: [Value]

    init(from decoder: Decoder) throws {
        if let one = try? Value(from: decoder) {
            values = [one]
        } else {
            values = try [Value](from: decoder)
        }
    }
}
