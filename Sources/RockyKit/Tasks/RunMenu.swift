import Foundation

/// What Run's split button runs (TSK-02): the workspace's Run script or a task of its `tasks.json`.
public enum RunItem: Hashable, Sendable {
    case runScript
    case task(String)

    /// How `@AppStorage("lastRunItemByRepo")` writes it: "run-script" or the task's label.
    public var storageValue: String {
        switch self {
        case .runScript: Self.runScriptValue
        case .task(let label): label
        }
    }

    public init(storageValue: String) {
        self = storageValue == Self.runScriptValue ? .runScript : .task(storageValue)
    }

    private static let runScriptValue = "run-script"

    /// `lastRunItemByRepo`'s JSON, repository id → item; anything unreadable is no item.
    public static func decodeAll(_ json: String) -> [String: RunItem] {
        guard let values = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else { return [:] }
        return values.mapValues(RunItem.init(storageValue:))
    }

    public static func encodeAll(_ items: [String: RunItem]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(items.mapValues(\.storageValue)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What a workspace's Run button knows (TSK-01, TSK-02), from its last look: whether the repository has a
/// `tasks.json` and, once the menu opened or Run was clicked, the file and the Run script. Nothing reads it again until
/// the next open or click: it is never watched.
public struct RunMenuState: Equatable, Sendable {
    public enum Tasks: Equatable, Sendable {
        /// No `tasks.json` in the worktree or the main clone: Run is today's plain button.
        case missing
        /// The file is there, not read since the panel appeared.
        case unread
        case loaded(TaskFile)
        /// TSK-07: the menu's "tasks.json can't be read", with this ("Line 41: …") as its second line.
        case invalid(String)
    }

    public var tasks: Tasks
    /// The Run script (`rocky.json` or the repository settings) as last read; nil when there is none or before the
    /// first read, which `hasReadRunScript` tells apart.
    public var runScript: String?
    public var hasReadRunScript: Bool
    /// `rocky.json` does not parse: the menu's Run script row is disabled with it.
    public var runScriptFailure: String?

    public init(tasks: Tasks, runScript: String? = nil, hasReadRunScript: Bool = false, runScriptFailure: String? = nil) {
        self.tasks = tasks
        self.runScript = runScript
        self.hasReadRunScript = hasReadRunScript
        self.runScriptFailure = runScriptFailure
    }

    /// Whether Run is TSK-02's split button: the repository has a `tasks.json`, readable or not.
    public var hasTasksFile: Bool {
        tasks != .missing
    }

    public var file: TaskFile? {
        if case .loaded(let file) = tasks { return file }
        return nil
    }

    /// A Run script to run, or one that fails to read (whose Run shows the failure): both are "a Run script" to TSK-02.
    /// Before the first read, there may be one.
    private var mayHaveRunScript: Bool {
        !hasReadRunScript || runScript != nil || runScriptFailure != nil
    }

    /// TSK-02's default: the item last run from the menu in this repository; else the Run script; else the file's
    /// `{kind: "build", isDefault: true}` task; else nil, and the main part opens the menu. A label the file no longer
    /// has falls back, and so does a task while the file cannot be read. Before the first read, the last item and the
    /// Run script are taken on trust: the click that runs them reads first.
    public func defaultItem(last: RunItem?) -> RunItem? {
        switch last {
        case .runScript? where mayHaveRunScript:
            return .runScript
        case .task(let label)?:
            switch tasks {
            case .unread: return .task(label)
            case .loaded(let file) where file.task(label) != nil: return .task(label)
            default: break
            }
        default:
            break
        }
        if mayHaveRunScript { return .runScript }
        return file?.defaultBuildTask.map { .task($0.label) }
    }
}
