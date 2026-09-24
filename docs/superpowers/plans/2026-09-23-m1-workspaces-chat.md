# M1 Repos, Workspaces and Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app where you add a git repo, create workspaces (one git worktree each), and chat in each workspace with Claude Code or OpenCode over ACP, without the polling that drains Conductor's battery.

**Architecture:** One SwiftPM package at the repo root. `RockyKit` holds all logic (JSON-RPC/ACP client, login environment, git worktrees, SQLite store, chat model, app model) and is covered by swift-testing tests; `RockyUI` holds the SwiftUI views; `Rocky` is the executable, wrapped into `build/Rocky.app` by a script. Every child process is started on demand (agents only when you press Start, git only when you create or remove a workspace); nothing polls.

**Tech Stack:** Swift 6 (language mode 6), SwiftPM, SwiftUI + Observation (macOS 14+), swift-testing, GRDB.swift 7.11.1, Xcode 27.0 toolchain, `/usr/bin/git`, `opencode acp`, `@agentclientprotocol/claude-agent-acp@0.81.0` run with `node`.

**Spec:** `docs/superpowers/specs/2026-09-22-rocky-design.md` (M1 row of the milestones table). M0 evidence: `docs/superpowers/spikes/2026-09-22-m0-findings.md`.

**Status of the code in this plan:** the code in Tasks 1–8 was compiled and its tests passed (55 tests) in a scratch build with Xcode 27.0 on 2026-09-23. Tasks 9–11 were written but not compiled.

**Tests and builds run once, in Task 12.** Tasks 1–11 write code and tests and commit them without compiling or running anything. Task 12 builds the package, runs the whole suite, and fixes what breaks, right before the branch is merged into `development`. If a build error appears there, fix it in the smallest way that keeps the task's interfaces and tests, and note it in the task report.

## Changed after M1

M2 changed parts of this plan's code: the ACP reader (Task 3) no longer uses `FileHandle.bytes`, which stalled
every agent behind an idle one; chats became conversation tabs that start in the background; the protocol gained
session settings, attachments, tool kinds and agent questions; the store gained migrations v3 to v5; the minimum
is macOS 15. The full list, with the decisions behind it, is in
`docs/superpowers/plans/2026-09-23-m2-terminal-scripts-env.md`, section "Changes during implementation".

## Global Constraints

- macOS 14.0 minimum; Swift tools 6.0, Swift 6 language mode; Xcode 27.0 is the active developer dir (`xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`).
- One dependency: `https://github.com/groue/GRDB.swift`, `exact: "7.11.1"`. No other package.
- Agents in M1: Claude Code and OpenCode only. Codex is deferred (spec "Decisions").
- Claude adapter: `@agentclientprotocol/claude-agent-acp@0.81.0`, installed once into `~/Library/Application Support/Rocky/agents` and run as `node <prefix>/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js`. OpenCode: `opencode acp`.
- ACP protocol version 1: `initialize` → `session/new` or `session/load` → `session/prompt`; `session/request_permission` answered by the user; `session/cancel` notification.
- Worktrees at `<repo>/../<repo>-worktrees/<name>`, branch `rocky/<name>`, created from `origin`'s default branch (or the current branch without an origin).
- Energy rules (spec Section 1): capture the login-shell environment once per launch with `zsh -l -i -c`; no timers that poll; agents start only on user action; chat updates coalesced (100 ms) and buffered while hidden.
- `CLAUDE_CONFIG_DIR` is never inherited from the shell; it comes only from the repo setting (M0 finding).
- Bundle id `dev.jhzl.rocky` (the power log attributes energy by bundle id).
- All code, comments, identifiers and UI copy in English. URL-like paths English.
- Branch: `development` is the principal branch. Create `feat/m1-workspaces-chat` from `development`. Never commit on `development`. There is no remote: never add one, never push. With no remote there is no PR: the work lands by merging `feat/m1-workspaces-chat` into `development` at the end of Task 12, only with the user's approval.
- No `swift build` and no `swift test` before Task 12, not even to check a single task.
- Commits: Conventional Commits, lowercase imperative, no `Co-Authored-By` or any AI attribution line. Never `--no-verify`.
- Shell: this machine blocks `cat`, `ls`, `grep`, `find`, `sed` in agent shells; use `bat`, `eza`, `rg`, `fd`, `sd`.
- Manual tests use personal repos only (for example `~/Documents/dev/personal/rocky` itself). Never add, open or modify any repo under `~/Documents/dev/celes`.

## Review Focus

1. Quitting Rocky with agents running must leave no agent process behind (energy): `AppDelegate.applicationShouldTerminate` stops all chats; pinned by `AppModelTests.chatUsesTheRepoClaudeInstancePersistsAndResumes` (`stopAllAgents` → `.stopped("Stopped")`) and the `pgrep` check in Task 12.
2. Agent text containing U+2028 must not split a JSON-RPC line: pinned by `ACPConnectionTests.skipsNoiseDeliversNotificationsAndAnswersPermissionWithoutDeadlock` (fixture sends `a\u{2028}b`).
3. `git fetch` offline or asking for credentials must not hang or block workspace creation: `GIT_TERMINAL_PROMPT=0`, `ssh -o BatchMode=yes`; pinned by `WorktreeServiceTests.fetchFailureStillCreatesFromLastKnownRef`.
4. Removing a workspace with uncommitted changes must be refused and keep the folder: pinned by `WorktreeServiceTests.removeKeepsBranchAndRefusesDirtyWorktree`.
5. A login shell that prints banners or hangs must not break or freeze startup: pinned by `EnvironmentTests.parseIgnoresShellNoiseBeforeTheMarker` and `EnvironmentTests.captureTimesOutOnAHangingShell`.

## File Structure

```
Package.swift
.gitignore
Resources/Info.plist
scripts/make-app.sh                       build/Rocky.app
scripts/energy-report.sh                  power-log report, Rocky vs Conductor
Sources/RockyKit/ACP/JSONValue.swift      Sendable JSON
Sources/RockyKit/ACP/RPCCodec.swift       newline-delimited JSON-RPC 2.0
Sources/RockyKit/ACP/ACPConnection.swift  agent process + request/response over stdio
Sources/RockyKit/ACP/ACPProtocol.swift    ACP payload builders/readers (pure)
Sources/RockyKit/Environment/ProcessRunner.swift
Sources/RockyKit/Environment/LoginEnvironment.swift
Sources/RockyKit/Environment/WorkspaceEnvironment.swift   env per workspace + Claude instance detection
Sources/RockyKit/Git/WorktreeService.swift                worktrees + WorkspaceNamer
Sources/RockyKit/Store/Records.swift
Sources/RockyKit/Store/RockyStore.swift
Sources/RockyKit/Agents/AgentLauncher.swift
Sources/RockyKit/Chat/ChatSessionModel.swift
Sources/RockyKit/App/AppModel.swift
Sources/RockyUI/{RootView,SidebarView,RepoSettingsView,WorkspaceDetailView,ChatView}.swift
Sources/Rocky/RockyApp.swift
Tests/RockyKitTests/*.swift, Tests/RockyKitTests/Fixtures/*.sh
```

---

### Task 1: Package scaffold and JSON-RPC codec

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/RockyUI/RockyUI.swift`, `Sources/Rocky/main.swift`
- Create: `Sources/RockyKit/ACP/JSONValue.swift`, `Sources/RockyKit/ACP/RPCCodec.swift`
- Create: `Tests/RockyKitTests/Fixtures.swift`, `Tests/RockyKitTests/Fixtures/.gitkeep`
- Test: `Tests/RockyKitTests/RPCCodecTests.swift`

**Interfaces:**
- Produces: `enum JSONValue: Sendable, Equatable, Codable` (cases `null, bool, number(Double), string, array, object`; `subscript(key:) -> JSONValue?`, `stringValue`, `boolValue`, `intValue`, `arrayValue`; literal conformances). `enum RPCID { case int(Int), string(String) }`. `enum RPCMessage { request(id:method:params:), notification(method:params:), response(id:result:), errorResponse(id:code:message:) }`. `enum RPCCodec { static func encode(_:) throws -> Data; static func decode(_: String) throws -> RPCMessage }`. `enum RPCCodecError { notJSONRPC(String) }`. Test helpers `Fixtures.url(_:)`, `Fixtures.temporaryDirectory(_:)`, `Fixtures.stderrLog()`, `actor Recorder<Value>`.

- [ ] **Step 1: Create the branch and scaffold**

```bash
cd ~/Documents/dev/personal/rocky
git switch development
git switch -c feat/m1-workspaces-chat
mkdir -p Sources/RockyKit/ACP Sources/RockyUI Sources/Rocky Tests/RockyKitTests/Fixtures Resources scripts
touch Tests/RockyKitTests/Fixtures/.gitkeep
```

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rocky",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Rocky", targets: ["Rocky"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "RockyKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "RockyUI", dependencies: ["RockyKit"]),
        .executableTarget(name: "Rocky", dependencies: ["RockyKit", "RockyUI"]),
        .testTarget(name: "RockyKitTests", dependencies: ["RockyKit"], resources: [.copy("Fixtures")]),
    ]
)
```

`.gitignore`:

```
.build/
build/
.swiftpm/
```

`Sources/RockyUI/RockyUI.swift` (placeholder until Task 10):

```swift
// SwiftUI views for Rocky arrive in Task 10.
import RockyKit
```

`Sources/Rocky/main.swift` (placeholder until Task 10):

```swift
import RockyKit

print("Rocky: the app arrives in Task 10")
```

`Tests/RockyKitTests/Fixtures.swift`:

```swift
import Foundation

enum Fixtures {
    static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "sh", subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name).sh")
        }
        return url
    }

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocky-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    static func stderrLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rocky-agent-\(UUID().uuidString).log")
    }
}

/// Collects values produced on other tasks for assertions.
actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}
```

- [ ] **Step 2: Write the tests**

`Tests/RockyKitTests/RPCCodecTests.swift`:

```swift
import Foundation
import Testing
@testable import RockyKit

struct RPCCodecTests {
    @Test func encodesRequestAsOneSortedNewlineTerminatedLine() throws {
        let data = try RPCCodec.encode(.request(id: .int(1), method: "initialize", params: ["protocolVersion": 1]))
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":1}}"# + "\n")
    }

    @Test func encodesResponseKeepingStringID() throws {
        let data = try RPCCodec.encode(.response(id: .string("p1"), result: ["ok": true]))
        #expect(String(decoding: data, as: UTF8.self) == #"{"id":"p1","jsonrpc":"2.0","result":{"ok":true}}"# + "\n")
    }

    @Test func decodesResponse() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s1"}}"#)
        #expect(message == .response(id: .int(3), result: ["sessionId": "s1"]))
    }

    @Test func decodesErrorResponse() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"Authentication required"}}"#)
        #expect(message == .errorResponse(id: .int(4), code: -32000, message: "Authentication required"))
    }

    @Test func decodesNotification() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1"}}"#)
        #expect(message == .notification(method: "session/update", params: ["sessionId": "s1"]))
    }

    @Test func decodesAgentToClientRequestWithStringID() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{}}"#)
        #expect(message == .request(id: .string("perm-1"), method: "session/request_permission", params: [:]))
    }

    @Test func decodesNullResultAsNull() throws {
        #expect(try RPCCodec.decode(#"{"jsonrpc":"2.0","id":5,"result":null}"#) == .response(id: .int(5), result: .null))
    }

    @Test func keepsBooleansAsBooleans() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","id":6,"result":{"loadSession":true}}"#)
        #expect(message == .response(id: .int(6), result: ["loadSession": .bool(true)]))
    }

    @Test(arguments: ["Loading config...", "", #"{"jsonrpc":"2.0"}"#, "[1,2]"])
    func rejectsLinesThatAreNotJSONRPC(line: String) {
        #expect(throws: RPCCodecError.self) { try RPCCodec.decode(line) }
    }
}
```

- [ ] **Step 3: Implement**

`Sources/RockyKit/ACP/JSONValue.swift`:

```swift
import Foundation

/// A Sendable JSON value, so ACP messages can cross actor boundaries.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self, value == value.rounded() { return Int(value) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
```

`Sources/RockyKit/ACP/RPCCodec.swift`:

```swift
import Foundation

public enum RPCID: Sendable, Hashable {
    case int(Int)
    case string(String)

    var json: JSONValue {
        switch self {
        case .int(let value): .number(Double(value))
        case .string(let value): .string(value)
        }
    }

    init?(_ json: JSONValue?) {
        if let value = json?.intValue {
            self = .int(value)
        } else if let value = json?.stringValue {
            self = .string(value)
        } else {
            return nil
        }
    }
}

public enum RPCMessage: Sendable, Equatable {
    case request(id: RPCID, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: RPCID, result: JSONValue)
    case errorResponse(id: RPCID, code: Int, message: String)
}

public enum RPCCodecError: Error, Equatable {
    case notJSONRPC(String)
}

/// ACP frames are newline-delimited JSON-RPC 2.0 objects.
public enum RPCCodec {
    public static func encode(_ message: RPCMessage) throws -> Data {
        var object: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch message {
        case let .request(id, method, params):
            object["id"] = id.json
            object["method"] = .string(method)
            object["params"] = params
        case let .notification(method, params):
            object["method"] = .string(method)
            object["params"] = params
        case let .response(id, result):
            object["id"] = id.json
            object["result"] = result
        case let .errorResponse(id, code, message):
            object["id"] = id.json
            object["error"] = ["code": .number(Double(code)), "message": .string(message)]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: String) throws -> RPCMessage {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else {
            throw RPCCodecError.notJSONRPC(line)
        }
        let id = RPCID(object["id"])
        let params = object["params"] ?? .null
        if let method = object["method"]?.stringValue {
            if let id { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard let id else { throw RPCCodecError.notJSONRPC(line) }
        if let error = object["error"] {
            return .errorResponse(id: id, code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? "")
        }
        return .response(id: id, result: object["result"] ?? .null)
    }
}
```

- [ ] **Step 4: Resolve the dependency and commit**

`swift package resolve` fetches GRDB 7.11.1 and writes `Package.resolved` without compiling anything.

```bash
swift package resolve
git add Package.swift Package.resolved .gitignore Sources Tests
git commit -m "feat(kit): add package scaffold and json-rpc codec"
```

---

### Task 2: Process runner and login environment

**Files:**
- Create: `Sources/RockyKit/Environment/ProcessRunner.swift`, `Sources/RockyKit/Environment/LoginEnvironment.swift`, `Sources/RockyKit/Environment/WorkspaceEnvironment.swift`
- Test: `Tests/RockyKitTests/EnvironmentTests.swift`

**Interfaces:**
- Consumes: `Fixtures.temporaryDirectory(_:)` (Task 1).
- Produces: `ProcessRunner.run(_ executable: URL, _ arguments: [String], in: URL? = nil, environment: [String: String]? = nil) throws -> String` (trimmed stdout; throws `ProcessFailure(command:status:stderr:)`). `LoginEnvironment.parse(_ output: Data) -> [String: String]`, `LoginEnvironment.capture(shell:arguments:timeout:) throws -> [String: String]` (throws `LoginEnvironmentError.timedOut` / `.markerMissing`), `LoginEnvironment.marker`. `WorkspaceEnvironment.make(login:claudeConfigDir:) -> [String: String]`. `ClaudeInstances.detect(home: URL) -> [String]`.

- [ ] **Step 1: Write the tests**

`Tests/RockyKitTests/EnvironmentTests.swift`:

```swift
import Foundation
import Testing
@testable import RockyKit

struct EnvironmentTests {
    @Test func parseIgnoresShellNoiseBeforeTheMarker() {
        var output = Data("Last login: Tue\nwelcome to oh-my-zsh\n".utf8)
        output += Data([0]) + Data(LoginEnvironment.marker.utf8) + Data([0])
        output += Data("PATH=/opt/homebrew/bin:/usr/bin\0HOME=/Users/me\0EMPTY=\0".utf8)
        #expect(LoginEnvironment.parse(output) == ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/me", "EMPTY": ""])
    }

    @Test func parseKeepsEqualsSignsAndNewlinesInsideValues() {
        var output = Data([0]) + Data(LoginEnvironment.marker.utf8) + Data([0])
        output += Data("OPTS=a=b=c\0MULTI=line1\nline2\0".utf8)
        #expect(LoginEnvironment.parse(output) == ["OPTS": "a=b=c", "MULTI": "line1\nline2"])
    }

    @Test func parseReturnsEmptyWithoutMarker() {
        #expect(LoginEnvironment.parse(Data("PATH=/usr/bin\0".utf8)).isEmpty)
    }

    @Test func captureReadsARealShell() throws {
        let environment = try LoginEnvironment.capture(
            shell: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo noise; printf '\\0\(LoginEnvironment.marker)\\0'; env -0"]
        )
        #expect(environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
        #expect(environment["TERM"] == "dumb")
    }

    @Test func captureTimesOutOnAHangingShell() {
        #expect(throws: LoginEnvironmentError.timedOut) {
            try LoginEnvironment.capture(shell: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.5)
        }
    }

    @Test func workspaceEnvironmentNeverInheritsClaudeConfigDir() {
        let login = ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-celes", "SHLVL": "2"]
        #expect(WorkspaceEnvironment.make(login: login, claudeConfigDir: nil) == ["PATH": "/usr/bin"])
        #expect(WorkspaceEnvironment.make(login: login, claudeConfigDir: "/Users/me/.claude-rentek")
            == ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-rentek"])
    }

    @Test func detectsClaudeInstancesWithSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        for name in [".claude", ".claude-celes", ".claude-empty", ".config"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in [".claude", ".claude-celes"] {
            FileManager.default.createFile(atPath: home.appendingPathComponent("\(name)/settings.json").path, contents: Data("{}".utf8))
        }
        #expect(ClaudeInstances.detect(home: home) == [home.appendingPathComponent(".claude").path, home.appendingPathComponent(".claude-celes").path])
    }

    @Test func processRunnerReturnsTrimmedStdoutAndThrowsOnFailure() throws {
        #expect(try ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hello"]) == "hello")
        #expect(throws: ProcessFailure.self) {
            try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo boom >&2; exit 4"])
        }
    }

    @Test func processRunnerDoesNotDeadlockOnLargeStderr() throws {
        let output = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo done"])
        #expect(output == "done")
    }
}
```

- [ ] **Step 2: Implement**

`Sources/RockyKit/Environment/ProcessRunner.swift`:

```swift
import Foundation

public struct ProcessFailure: Error, Equatable, CustomStringConvertible {
    public let command: String
    public let status: Int32
    public let stderr: String

    public var description: String { "\(command) exited \(status): \(stderr)" }
}

private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

public enum ProcessRunner {
    /// Runs a command to completion and returns stdout without trailing whitespace.
    /// Blocking: call it off the main actor.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment { process.environment = environment }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain stderr concurrently: a full pipe would block the child forever.
        let errorOutput = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorOutput.data = stderr.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ProcessFailure(
                command: ([executable.lastPathComponent] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                stderr: String(decoding: errorOutput.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

`Sources/RockyKit/Environment/LoginEnvironment.swift`:

```swift
import Foundation

public enum LoginEnvironmentError: Error, Equatable {
    case timedOut
    case markerMissing
}

private final class CaptureBox: @unchecked Sendable {
    var data = Data()
}

/// Captures the user's login-shell environment once, so agents see the same PATH as a terminal.
/// Conductor spawned `zsh -l` repeatedly; Rocky runs it once per launch (spec Section 1).
public enum LoginEnvironment {
    public static let marker = "__ROCKY_ENV_BEGIN__"

    /// `-i` is required: PATH entries such as pnpm's live in `.zshrc`, which a non-interactive login shell skips.
    public static let zshArguments = ["-l", "-i", "-c", "printf '\\0\(marker)\\0'; env -0"]

    /// Parses `env -0` output that follows the NUL-wrapped marker; shell startup noise before it is ignored.
    public static func parse(_ output: Data) -> [String: String] {
        let separator = Data([0]) + Data(marker.utf8) + Data([0])
        guard let range = output.range(of: separator) else { return [:] }
        var environment: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }

    /// Blocking: call it off the main actor.
    public static func capture(
        shell: URL = URL(fileURLWithPath: "/bin/zsh"),
        arguments: [String] = zshArguments,
        timeout: TimeInterval = 15
    ) throws -> [String: String] {
        let process = Process()
        process.executableURL = shell
        process.arguments = arguments
        let current = ProcessInfo.processInfo.environment
        var environment = ["TERM": "dumb", "SHELL": shell.path]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] { environment[key] = current[key] }
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let output = CaptureBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.data = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw LoginEnvironmentError.timedOut
        }
        // A background job started by the profile can hold stdout open; do not wait for it forever.
        guard drained.wait(timeout: .now() + 2) == .success else { throw LoginEnvironmentError.markerMissing }
        let parsed = parse(output.data)
        guard !parsed.isEmpty else { throw LoginEnvironmentError.markerMissing }
        return parsed
    }
}
```

`Sources/RockyKit/Environment/WorkspaceEnvironment.swift`:

```swift
import Foundation

public enum WorkspaceEnvironment {
    /// Never inherited from the login shell. A stray CLAUDE_CONFIG_DIR made the Claude adapter
    /// load another Claude instance's hooks (M0 finding); the repo setting decides it instead.
    public static let strippedKeys: Set<String> = ["CLAUDE_CONFIG_DIR", "PWD", "OLDPWD", "SHLVL", "_"]

    public static func make(login: [String: String], claudeConfigDir: String?) -> [String: String] {
        var environment = login.filter { !strippedKeys.contains($0.key) }
        if let claudeConfigDir, !claudeConfigDir.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = claudeConfigDir
        }
        return environment
    }
}

public enum ClaudeInstances {
    /// Claude Code config directories in `home`: `.claude` plus any `.claude-<name>` holding a `settings.json`.
    public static func detect(home: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .map { home.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("settings.json").path) }
            .sorted()
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/RockyKit/Environment Tests/RockyKitTests/EnvironmentTests.swift
git commit -m "feat(kit): capture the login shell environment once"
```

---

### Task 3: ACP connection over stdio

**Files:**
- Create: `Sources/RockyKit/ACP/ACPConnection.swift`, `Tests/RockyKitTests/Fixtures/fake-agent.sh`
- Test: `Tests/RockyKitTests/ACPConnectionTests.swift`

**Interfaces:**
- Consumes: `RPCCodec`, `RPCMessage`, `JSONValue` (Task 1); `Fixtures.url`, `Fixtures.stderrLog`, `Recorder` (Task 1).
- Produces: `actor ACPConnection { init(executable: URL, arguments: [String], environment: [String: String], cwd: URL, stderrLog: URL) throws; func setHandlers(_: ACPHandlers); func start() throws; func call(_ method: String, _ params: JSONValue) async throws -> JSONValue; func notify(_ method: String, _ params: JSONValue) throws; func terminate(); var skippedLines: [String] }`. `struct ACPHandlers(onNotification:onRequest:onExit:)`. `struct ACPNotification(method:params:)`. `enum ACPConnectionError { agentExited(status: Int32, stderrTail: String), rpc(code: Int, message: String) }`.

- [ ] **Step 1: Write the fixture and the tests**

`Tests/RockyKitTests/Fixtures/fake-agent.sh`:

```bash
#!/bin/bash
# Scripted transport-level agent for ACPConnectionTests.
# ok: stdout noise, 200 KB stderr, notification with U+2028, permission request, echo reply.
# exit: reads one request and exits 3. env: responds with $ROCKY_PROBE. error: JSON-RPC error.
mode="${1:-ok}"
read -r _request
case "$mode" in
  exit)
    echo "missing credentials" >&2
    exit 3
    ;;
  env)
    echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"probe\":\"$ROCKY_PROBE\"}}"
    ;;
  error)
    echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Authentication required"}}'
    ;;
  ok)
    echo "fake-agent booting"
    head -c 200000 /dev/zero | tr '\0' 'x' >&2
    printf '{"jsonrpc":"2.0","method":"session/update","params":{"text":"a\xe2\x80\xa8b"}}\n'
    echo '{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"options":[{"optionId":"allow","kind":"allow_once"}]}}'
    read -r permission_reply
    echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"echo\":$permission_reply}}"
    ;;
esac
```

`Tests/RockyKitTests/ACPConnectionTests.swift`:

```swift
import Foundation
import Testing
@testable import RockyKit

struct ACPConnectionTests {
    private func connect(_ mode: String, environment: [String: String] = [:]) throws -> ACPConnection {
        let env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        return try ACPConnection(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [Fixtures.url("fake-agent").path, mode],
            environment: env,
            cwd: FileManager.default.temporaryDirectory,
            stderrLog: Fixtures.stderrLog()
        )
    }

    @Test func skipsNoiseDeliversNotificationsAndAnswersPermissionWithoutDeadlock() async throws {
        let connection = try connect("ok")
        let notifications = Recorder<ACPNotification>()
        let requests = Recorder<String>()
        await connection.setHandlers(ACPHandlers(
            onNotification: { await notifications.append($0) },
            onRequest: { method, _ in
                await requests.append(method)
                return ["outcome": ["outcome": "selected", "optionId": "allow"]]
            }
        ))
        try await connection.start()

        let result = try await connection.call("initialize", ["protocolVersion": 1])

        #expect(await requests.values == ["session/request_permission"])
        #expect(await notifications.values == [ACPNotification(method: "session/update", params: ["text": "a\u{2028}b"])])
        #expect(await connection.skippedLines == ["fake-agent booting"])
        #expect(result["echo"]?["id"] == "p1")
        #expect(result["echo"]?["result"]?["outcome"]?["optionId"] == "allow")
        await connection.terminate()
    }

    @Test func agentExitFailsPendingAndLaterCallsWithStderrTail() async throws {
        let connection = try connect("exit")
        let exits = Recorder<ACPConnectionError>()
        await connection.setHandlers(ACPHandlers(onExit: { await exits.append($0) }))
        try await connection.start()

        await #expect(throws: ACPConnectionError.self) { try await connection.call("initialize", [:]) }
        do {
            _ = try await connection.call("session/new", [:])
            Issue.record("expected the second call to throw")
        } catch let ACPConnectionError.agentExited(status, stderrTail) {
            #expect(status == 3)
            #expect(stderrTail.contains("missing credentials"))
        }
        #expect(await exits.values.count == 1)
    }

    @Test func rpcErrorIsThrownAsRpc() async throws {
        let connection = try connect("error")
        try await connection.start()
        await #expect(throws: ACPConnectionError.rpc(code: -32000, message: "Authentication required")) {
            try await connection.call("session/new", [:])
        }
        await connection.terminate()
    }

    @Test func environmentReachesTheAgentProcess() async throws {
        let connection = try connect("env", environment: ["ROCKY_PROBE": "probe-123"])
        try await connection.start()
        #expect(try await connection.call("initialize", [:])["probe"] == "probe-123")
        await connection.terminate()
    }
}
```

- [ ] **Step 2: Implement**

`Sources/RockyKit/ACP/ACPConnection.swift`:

```swift
import Foundation

public struct ACPNotification: Sendable, Equatable {
    public let method: String
    public let params: JSONValue
}

public enum ACPConnectionError: Error, Equatable {
    case agentExited(status: Int32, stderrTail: String)
    case rpc(code: Int, message: String)
}

public struct ACPHandlers: Sendable {
    /// Awaited in stream order before the next line is read, so a response is never
    /// processed ahead of the notifications that preceded it.
    public var onNotification: @Sendable (ACPNotification) async -> Void
    /// Runs on its own task: a permission prompt waiting on the user must not stall reading.
    public var onRequest: @Sendable (String, JSONValue) async -> JSONValue
    public var onExit: @Sendable (ACPConnectionError) async -> Void

    public init(
        onNotification: @escaping @Sendable (ACPNotification) async -> Void = { _ in },
        onRequest: @escaping @Sendable (String, JSONValue) async -> JSONValue = { _, _ in [:] },
        onExit: @escaping @Sendable (ACPConnectionError) async -> Void = { _ in }
    ) {
        self.onNotification = onNotification
        self.onRequest = onRequest
        self.onExit = onExit
    }
}

/// One agent process speaking ACP over stdio.
public actor ACPConnection {
    /// Writing to a pipe whose reader died raises SIGPIPE, which kills the app by default.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public private(set) var skippedLines: [String] = []

    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderrLog: URL
    private var handlers = ACPHandlers()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextID = 1
    private var exitError: ACPConnectionError?

    public init(executable: URL, arguments: [String], environment: [String: String], cwd: URL, stderrLog: URL) throws {
        _ = Self.ignoreSIGPIPE
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // stderr goes to a file: an unread pipe fills at 64 KB and blocks the agent.
        process.standardError = try FileHandle(forWritingTo: stderrLog)
        self.process = process
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderrLog = stderrLog
    }

    public func setHandlers(_ handlers: ACPHandlers) {
        self.handlers = handlers
    }

    public func start() throws {
        try process.run()
        let stdout = stdout
        Task { [weak self] in
            // Split on "\n" only: JSON text may contain U+2028, which `bytes.lines` would treat as a line break.
            var line: [UInt8] = []
            do {
                for try await byte in stdout.bytes {
                    if byte == 0x0A {
                        await self?.receive(String(decoding: line, as: UTF8.self))
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(byte)
                    }
                }
            } catch {}
            await self?.finish()
        }
    }

    public func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        if let exitError { throw exitError }
        let id = nextID
        nextID += 1
        let data = try RPCCodec.encode(.request(id: .int(id), method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdin.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: ACPConnectionError.agentExited(status: -1, stderrTail: "\(error)"))
            }
        }
    }

    public func notify(_ method: String, _ params: JSONValue) throws {
        if let exitError { throw exitError }
        try stdin.write(contentsOf: RPCCodec.encode(.notification(method: method, params: params)))
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func receive(_ line: String) async {
        guard let message = try? RPCCodec.decode(line) else {
            if !line.isEmpty { skippedLines.append(line) }
            return
        }
        switch message {
        case let .response(.int(id), result):
            pending.removeValue(forKey: id)?.resume(returning: result)
        case let .errorResponse(.int(id), code, message):
            pending.removeValue(forKey: id)?.resume(throwing: ACPConnectionError.rpc(code: code, message: message))
        case .response, .errorResponse:
            break
        case let .notification(method, params):
            await handlers.onNotification(ACPNotification(method: method, params: params))
        case let .request(id, method, params):
            let onRequest = handlers.onRequest
            Task { [weak self] in
                let result = await onRequest(method, params)
                await self?.reply(id: id, result: result)
            }
        }
    }

    private func reply(id: RPCID, result: JSONValue) {
        guard exitError == nil, let data = try? RPCCodec.encode(.response(id: id, result: result)) else { return }
        try? stdin.write(contentsOf: data)
    }

    private func finish() async {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let log = (try? String(contentsOf: stderrLog, encoding: .utf8)) ?? ""
        let error = ACPConnectionError.agentExited(status: process.terminationStatus, stderrTail: String(log.suffix(2000)))
        exitError = error
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        await handlers.onExit(error)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/RockyKit/ACP/ACPConnection.swift Tests/RockyKitTests/Fixtures/fake-agent.sh Tests/RockyKitTests/ACPConnectionTests.swift
git commit -m "feat(kit): add acp stdio connection"
```

---

### Task 4: ACP protocol payloads

**Files:**
- Create: `Sources/RockyKit/ACP/ACPProtocol.swift`
- Test: `Tests/RockyKitTests/ACPProtocolTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (Task 1).
- Produces: `struct AgentCapabilities(loadSession:)`, `enum SessionEvent { agentText, agentThought, toolCall(id:title:status:), toolCallUpdate(id:status:), ignored(String) }`, `struct PermissionOption(id:name:kind:)`, `struct PermissionRequest(title:options:)`, and `enum ACPProtocol` with `initializeParams()`, `capabilities(from:)`, `newSessionParams(cwd:)`, `loadSessionParams(sessionId:cwd:)`, `promptParams(sessionId:text:)`, `cancelParams(sessionId:)`, `sessionId(fromNewSession:)`, `event(fromUpdate:sessionId:) -> SessionEvent?`, `permissionRequest(from:)`, `permissionResponse(optionId: String?)`.

- [ ] **Step 1: Write the tests**

`Tests/RockyKitTests/ACPProtocolTests.swift`:

```swift
import Foundation
import Testing
@testable import RockyKit

struct ACPProtocolTests {
    private func update(_ body: JSONValue, session: String = "s1") -> JSONValue {
        ["sessionId": .string(session), "update": body]
    }

    @Test func readsLoadSessionCapability() {
        #expect(ACPProtocol.capabilities(from: ["agentCapabilities": ["loadSession": true]]).loadSession)
        #expect(!ACPProtocol.capabilities(from: [:]).loadSession)
    }

    @Test func buildsPromptParams() {
        #expect(ACPProtocol.promptParams(sessionId: "s1", text: "hi")
            == ["sessionId": "s1", "prompt": [["type": "text", "text": "hi"]]])
    }

    @Test func mapsMessageThoughtAndToolUpdates() {
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Hel"]]), sessionId: "s1")
            == .agentText("Hel"))
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "hmm"]]), sessionId: "s1")
            == .agentThought("hmm"))
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run ls", "status": "pending"]), sessionId: "s1")
            == .toolCall(id: "t1", title: "Run ls", status: "pending"))
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"]), sessionId: "s1")
            == .toolCallUpdate(id: "t1", status: "completed"))
    }

    @Test func ignoresUnknownKindsAndUpdatesWithoutStatus() {
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "available_commands_update"]), sessionId: "s1")
            == .ignored("available_commands_update"))
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "tool_call_update", "toolCallId": "t1"]), sessionId: "s1")
            == .ignored("tool_call_update"))
    }

    @Test func dropsUpdatesForAnotherSession() {
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "agent_message_chunk"], session: "other"), sessionId: "s1") == nil)
    }

    @Test func nonTextContentBecomesEmptyText() {
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "agent_message_chunk", "content": ["type": "image"]]), sessionId: "s1")
            == .agentText(""))
    }

    @Test func readsPermissionRequestAndBuildsResponses() {
        let request = ACPProtocol.permissionRequest(from: [
            "toolCall": ["toolCallId": "t1", "title": "Run printenv"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"], ["name": "no id"]],
        ])
        #expect(request == PermissionRequest(title: "Run printenv", options: [PermissionOption(id: "allow", name: "Allow", kind: "allow_once")]))
        #expect(ACPProtocol.permissionResponse(optionId: "allow") == ["outcome": ["outcome": "selected", "optionId": "allow"]])
        #expect(ACPProtocol.permissionResponse(optionId: nil) == ["outcome": ["outcome": "cancelled"]])
    }
}
```

- [ ] **Step 2: Implement**

`Sources/RockyKit/ACP/ACPProtocol.swift`:

```swift
import Foundation

public struct AgentCapabilities: Sendable, Equatable {
    public var loadSession: Bool

    public init(loadSession: Bool) {
        self.loadSession = loadSession
    }
}

public enum SessionEvent: Sendable, Equatable {
    case agentText(String)
    case agentThought(String)
    case toolCall(id: String, title: String, status: String)
    case toolCallUpdate(id: String, status: String)
    case ignored(String)
}

public struct PermissionOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
}

public struct PermissionRequest: Sendable, Equatable {
    public let title: String
    public let options: [PermissionOption]
}

/// Builds and reads ACP payloads (protocol version 1). Pure functions, no I/O.
public enum ACPProtocol {
    public static func initializeParams() -> JSONValue {
        [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
        ]
    }

    public static func capabilities(from result: JSONValue) -> AgentCapabilities {
        AgentCapabilities(loadSession: result["agentCapabilities"]?["loadSession"]?.boolValue ?? false)
    }

    public static func newSessionParams(cwd: URL) -> JSONValue {
        ["cwd": .string(cwd.path), "mcpServers": []]
    }

    public static func loadSessionParams(sessionId: String, cwd: URL) -> JSONValue {
        ["sessionId": .string(sessionId), "cwd": .string(cwd.path), "mcpServers": []]
    }

    public static func promptParams(sessionId: String, text: String) -> JSONValue {
        ["sessionId": .string(sessionId), "prompt": [["type": "text", "text": .string(text)]]]
    }

    public static func cancelParams(sessionId: String) -> JSONValue {
        ["sessionId": .string(sessionId)]
    }

    public static func sessionId(fromNewSession result: JSONValue) -> String? {
        result["sessionId"]?.stringValue
    }

    /// Maps a `session/update` payload to an event; nil when it belongs to another session.
    public static func event(fromUpdate params: JSONValue, sessionId: String) -> SessionEvent? {
        guard params["sessionId"]?.stringValue == sessionId,
              let update = params["update"],
              let kind = update["sessionUpdate"]?.stringValue else { return nil }
        switch kind {
        case "agent_message_chunk":
            return .agentText(update["content"]?["text"]?.stringValue ?? "")
        case "agent_thought_chunk":
            return .agentThought(update["content"]?["text"]?.stringValue ?? "")
        case "tool_call":
            return .toolCall(
                id: update["toolCallId"]?.stringValue ?? "",
                title: update["title"]?.stringValue ?? "Tool call",
                status: update["status"]?.stringValue ?? "pending"
            )
        case "tool_call_update":
            guard let status = update["status"]?.stringValue else { return .ignored(kind) }
            return .toolCallUpdate(id: update["toolCallId"]?.stringValue ?? "", status: status)
        default:
            return .ignored(kind)
        }
    }

    public static func permissionRequest(from params: JSONValue) -> PermissionRequest {
        let options = (params["options"]?.arrayValue ?? []).compactMap { option -> PermissionOption? in
            guard let id = option["optionId"]?.stringValue else { return nil }
            return PermissionOption(id: id, name: option["name"]?.stringValue ?? id, kind: option["kind"]?.stringValue ?? "")
        }
        return PermissionRequest(title: params["toolCall"]?["title"]?.stringValue ?? "The agent wants to run a tool", options: options)
    }

    /// `nil` answers "cancelled", which ACP requires when the prompt is cancelled or dismissed.
    public static func permissionResponse(optionId: String?) -> JSONValue {
        guard let optionId else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": .string(optionId)]]
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/RockyKit/ACP/ACPProtocol.swift Tests/RockyKitTests/ACPProtocolTests.swift
git commit -m "feat(kit): add acp protocol payload mapping"
```

---

### Task 5: Git worktrees and workspace names

**Files:**
- Create: `Sources/RockyKit/Git/WorktreeService.swift`
- Create: `Tests/RockyKitTests/GitFixture.swift`
- Test: `Tests/RockyKitTests/WorktreeServiceTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner`, `ProcessFailure` (Task 2); `Fixtures.temporaryDirectory` (Task 1).
- Produces: `struct WorktreeService: Sendable { init(environment:); static func worktreesRoot(for: URL) -> URL; static let branchPrefix = "rocky/"; func isRepositoryRoot(_: URL) -> Bool; func baseRef(repo:) throws -> (ref: String, fetchFailed: Bool); func isTaken(repo:name:) -> Bool; func create(repo:name:) throws -> CreatedWorktree; func remove(repo:worktree:) throws }`. `struct CreatedWorktree(name:path:branch:baseRef:fetchFailed:)`. `enum WorkspaceNamer { static let cities: [String]; static func pick(isTaken:order:) -> String }`. Test helper `GitFixture.environment`, `GitFixture.git(_:in:)`, `GitFixture.localRepo(in:name:)`, `GitFixture.clonedRepo(in:)`.

- [ ] **Step 1: Write the fixture helper and the tests**

`Tests/RockyKitTests/GitFixture.swift`:

```swift
import Foundation
@testable import RockyKit

/// Real git repositories in a temp directory; no network.
enum GitFixture {
    static let git = URL(fileURLWithPath: "/usr/bin/git")
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "Rocky Test"
        env["GIT_AUTHOR_EMAIL"] = "rocky@example.com"
        env["GIT_COMMITTER_NAME"] = "Rocky Test"
        env["GIT_COMMITTER_EMAIL"] = "rocky@example.com"
        return env
    }()

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) throws -> String {
        try ProcessRunner.run(git, arguments, in: directory, environment: environment)
    }

    /// A repo with one commit on `main` and no remote.
    static func localRepo(in parent: URL, name: String = "app") throws -> URL {
        let repo = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try Data("hello\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try git(["add", "README.md"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    /// A clone of a bare origin whose default branch is `trunk`, with the clone checked out on `feature`.
    static func clonedRepo(in parent: URL) throws -> URL {
        let seed = try localRepo(in: parent, name: "seed")
        try git(["branch", "-m", "main", "trunk"], in: seed)
        try git(["clone", "-q", "--bare", seed.path, parent.appendingPathComponent("origin.git").path], in: parent)
        try git(["clone", "-q", parent.appendingPathComponent("origin.git").path, "app"], in: parent)
        let repo = parent.appendingPathComponent("app", isDirectory: true)
        try git(["switch", "-q", "-c", "feature"], in: repo)
        return repo
    }
}
```

`Tests/RockyKitTests/WorktreeServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import RockyKit

struct WorktreeServiceTests {
    private let service = WorktreeService(environment: GitFixture.environment)

    @Test func worktreesLiveNextToTheRepo() {
        #expect(WorktreeService.worktreesRoot(for: URL(fileURLWithPath: "/Users/me/dev/app")).path == "/Users/me/dev/app-worktrees")
    }

    @Test func recognisesOnlyTheRepositoryRoot() throws {
        let parent = try Fixtures.temporaryDirectory("git")
        let repo = try GitFixture.localRepo(in: parent)
        let nested = repo.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(service.isRepositoryRoot(repo))
        #expect(!service.isRepositoryRoot(nested))
        #expect(!service.isRepositoryRoot(parent))
    }

    @Test func createsWorktreeFromCurrentBranchWhenThereIsNoOrigin() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let created = try service.create(repo: repo, name: "lisbon")
        #expect(created.baseRef == "main")
        #expect(created.branch == "rocky/lisbon")
        #expect(!created.fetchFailed)
        #expect(FileManager.default.fileExists(atPath: created.path.appendingPathComponent("README.md").path))
        #expect(try GitFixture.git(["rev-parse", "--abbrev-ref", "HEAD"], in: created.path) == "rocky/lisbon")
    }

    @Test func createsWorktreeFromOriginDefaultBranchNotTheCheckedOutOne() throws {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("git"))
        let created = try service.create(repo: repo, name: "kyoto")
        #expect(created.baseRef == "origin/trunk")
        #expect(!created.fetchFailed)
    }

    @Test func fetchFailureStillCreatesFromLastKnownRef() throws {
        let parent = try Fixtures.temporaryDirectory("git")
        let repo = try GitFixture.clonedRepo(in: parent)
        try FileManager.default.removeItem(at: parent.appendingPathComponent("origin.git"))
        let created = try service.create(repo: repo, name: "oslo")
        #expect(created.baseRef == "origin/trunk")
        #expect(created.fetchFailed)
    }

    @Test func repoWithoutCommitsThrowsInsteadOfCreating() throws {
        let repo = try Fixtures.temporaryDirectory("empty")
        try GitFixture.git(["init", "-q", "-b", "main"], in: repo)
        #expect(throws: ProcessFailure.self) { try service.create(repo: repo, name: "lima") }
    }

    @Test func nameIsTakenByDirectoryOrBranch() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        _ = try service.create(repo: repo, name: "quito")
        #expect(service.isTaken(repo: repo, name: "quito"))
        try GitFixture.git(["branch", "rocky/cusco"], in: repo)
        #expect(service.isTaken(repo: repo, name: "cusco"))
        #expect(!service.isTaken(repo: repo, name: "hanoi"))
    }

    @Test func removeKeepsBranchAndRefusesDirtyWorktree() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let clean = try service.create(repo: repo, name: "dakar")
        try service.remove(repo: repo, worktree: clean.path)
        #expect(!FileManager.default.fileExists(atPath: clean.path.path))
        #expect(try GitFixture.git(["branch", "--list", "rocky/dakar"], in: repo).contains("rocky/dakar"))

        let dirty = try service.create(repo: repo, name: "accra")
        try Data("wip\n".utf8).write(to: dirty.path.appendingPathComponent("README.md"))
        #expect(throws: ProcessFailure.self) { try service.remove(repo: repo, worktree: dirty.path) }
        #expect(FileManager.default.fileExists(atPath: dirty.path.path))
    }

    @Test func namerSkipsTakenNamesAndFallsBackToSuffix() {
        let identity: ([String]) -> [String] = { $0 }
        #expect(WorkspaceNamer.pick(isTaken: { $0 == "lisbon" }, order: identity) == "kyoto")
        #expect(WorkspaceNamer.pick(isTaken: { !$0.hasSuffix("-2") || $0 == "lisbon-2" }, order: identity) == "kyoto-2")
    }
}
```

- [ ] **Step 2: Implement**

`Sources/RockyKit/Git/WorktreeService.swift`:

```swift
import Foundation

public struct CreatedWorktree: Sendable, Equatable {
    public let name: String
    public let path: URL
    public let branch: String
    public let baseRef: String
    /// `git fetch` failed (offline, auth); the worktree was created from the last fetched ref.
    public let fetchFailed: Bool
}

/// Git worktree operations through `/usr/bin/git`. Blocking: call off the main actor.
public struct WorktreeService: Sendable {
    public static let branchPrefix = "rocky/"
    private static let git = URL(fileURLWithPath: "/usr/bin/git")

    public let environment: [String: String]

    public init(environment: [String: String]) {
        // Never block on a credential or host-key prompt: there is no terminal to answer it.
        self.environment = environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
        ]) { _, new in new }
    }

    /// Worktrees live next to the repo, so `~/.gitconfig` `includeIf "gitdir:..."` rules still match.
    public static func worktreesRoot(for repo: URL) -> URL {
        repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-worktrees", isDirectory: true)
    }

    public func isRepositoryRoot(_ url: URL) -> Bool {
        guard let top = try? run(["rev-parse", "--show-toplevel"], in: url) else { return false }
        return URL(fileURLWithPath: top).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
    }

    /// origin's default branch when the repo has an origin, else the current branch.
    public func baseRef(repo: URL) throws -> (ref: String, fetchFailed: Bool) {
        let remotes = try run(["remote"], in: repo).split(separator: "\n").map(String.init)
        guard remotes.contains("origin") else {
            return (try run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), false)
        }
        let fetchFailed = (try? run(["fetch", "--quiet", "origin"], in: repo)) == nil
        if let ref = try? run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo) {
            return (ref, fetchFailed)
        }
        return (try run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), fetchFailed)
    }

    public func isTaken(repo: URL, name: String) -> Bool {
        let path = Self.worktreesRoot(for: repo).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path.path) { return true }
        return (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/\(Self.branchPrefix)\(name)"], in: repo)) != nil
    }

    public func create(repo: URL, name: String) throws -> CreatedWorktree {
        let (base, fetchFailed) = try baseRef(repo: repo)
        let root = Self.worktreesRoot(for: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(name, isDirectory: true)
        let branch = Self.branchPrefix + name
        try run(["worktree", "add", "-b", branch, path.path, base], in: repo)
        return CreatedWorktree(name: name, path: path, branch: branch, baseRef: base, fetchFailed: fetchFailed)
    }

    /// Removes the worktree directory and keeps its branch, so no commit is lost.
    /// Fails while the worktree has uncommitted changes.
    public func remove(repo: URL, worktree: URL) throws {
        try run(["worktree", "remove", worktree.path], in: repo)
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) throws -> String {
        try ProcessRunner.run(Self.git, arguments, in: directory, environment: environment)
    }
}

public enum WorkspaceNamer {
    public static let cities = [
        "lisbon", "kyoto", "oslo", "lima", "quito", "cusco", "hanoi", "dakar", "accra", "porto",
        "nairobi", "havana", "bogota", "caracas", "merida", "sucre", "rosario", "valencia", "seville", "bergen",
        "tallinn", "riga", "vilnius", "krakow", "prague", "vienna", "zagreb", "split", "tbilisi", "yerevan",
        "baku", "almaty", "busan", "osaka", "taipei", "manila", "cebu", "perth", "hobart", "auckland",
    ]

    public static func pick(isTaken: (String) -> Bool, order: ([String]) -> [String] = { $0.shuffled() }) -> String {
        let candidates = order(cities)
        if let free = candidates.first(where: { !isTaken($0) }) { return free }
        var suffix = 2
        while true {
            if let free = candidates.map({ "\($0)-\(suffix)" }).first(where: { !isTaken($0) }) { return free }
            suffix += 1
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/RockyKit/Git Tests/RockyKitTests/GitFixture.swift Tests/RockyKitTests/WorktreeServiceTests.swift
git commit -m "feat(kit): create and remove workspace worktrees"
```

---

### Task 6: SQLite store

**Files:**
- Create: `Sources/RockyKit/Store/Records.swift`, `Sources/RockyKit/Store/RockyStore.swift`
- Test: `Tests/RockyKitTests/RockyStoreTests.swift`

**Interfaces:**
- Consumes: GRDB 7.11.1 (Task 1 `Package.swift`); `Fixtures.temporaryDirectory` (Task 1).
- Produces: records `Repo(id:name:path:claudeConfigDir:createdAt:)`, `Workspace(id:repoId:name:path:branch:createdAt:)`, `ChatSessionRecord(id:workspaceId:agent:acpSessionId:createdAt:)`, `ChatMessageRecord(id:sessionId:seq:kind:text:status:createdAt:)`. `final class RockyStore: Sendable { init(path:) throws; static func inMemory() throws -> RockyStore; add(_: Repo); update(_: Repo); repos(); deleteRepo(id:); add(_: Workspace); workspaces(repoId:); deleteWorkspace(id:); add(_: ChatSessionRecord); update(_: ChatSessionRecord); latestSession(workspaceId:agent:) -> ChatSessionRecord?; upsert(_: ChatMessageRecord); messages(sessionId:) }` (all `throws`). `enum RockyStoreError { duplicateRepo(String) }`.

- [ ] **Step 1: Write the tests**

`Tests/RockyKitTests/RockyStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import RockyKit

struct RockyStoreTests {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func storesAndUpdatesRepos() throws {
        let store = try RockyStore.inMemory()
        var repo = Repo(name: "app", path: "/dev/app", createdAt: day)
        try store.add(repo)
        repo.claudeConfigDir = "/Users/me/.claude-celes"
        try store.update(repo)
        #expect(try store.repos() == [repo])
    }

    @Test func rejectsTheSameRepoPathTwice() throws {
        let store = try RockyStore.inMemory()
        try store.add(Repo(name: "app", path: "/dev/app"))
        #expect(throws: RockyStoreError.duplicateRepo("/dev/app")) { try store.add(Repo(name: "app2", path: "/dev/app")) }
    }

    @Test func deletingARepoCascadesToWorkspacesAndTranscripts() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "lisbon", path: "/dev/app-worktrees/lisbon", branch: "rocky/lisbon")
        try store.add(workspace)
        let session = ChatSessionRecord(workspaceId: workspace.id, agent: "claude")
        try store.add(session)
        try store.upsert(ChatMessageRecord(id: "m1", sessionId: session.id, seq: 0, kind: "user", text: "hi", status: nil))

        try store.deleteRepo(id: repo.id)

        #expect(try store.workspaces(repoId: repo.id).isEmpty)
        #expect(try store.latestSession(workspaceId: workspace.id, agent: "claude") == nil)
        #expect(try store.messages(sessionId: session.id).isEmpty)
    }

    @Test func latestSessionIsPerAgent() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "rocky/lisbon")
        try store.add(workspace)
        let older = ChatSessionRecord(workspaceId: workspace.id, agent: "claude", createdAt: day)
        let newer = ChatSessionRecord(workspaceId: workspace.id, agent: "claude", createdAt: day.addingTimeInterval(60))
        let other = ChatSessionRecord(workspaceId: workspace.id, agent: "opencode", createdAt: day.addingTimeInterval(120))
        for session in [older, newer, other] { try store.add(session) }
        #expect(try store.latestSession(workspaceId: workspace.id, agent: "claude") == newer)
    }

    @Test func upsertAppendsInOrderAndReplacesInPlace() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "b")
        try store.add(workspace)
        let session = ChatSessionRecord(workspaceId: workspace.id, agent: "claude")
        try store.add(session)

        try store.upsert(ChatMessageRecord(id: "a", sessionId: session.id, seq: 0, kind: "user", text: "hi", status: nil))
        try store.upsert(ChatMessageRecord(id: "b", sessionId: session.id, seq: 0, kind: "tool", text: "Run ls", status: "pending"))
        try store.upsert(ChatMessageRecord(id: "b", sessionId: session.id, seq: 0, kind: "tool", text: "Run ls", status: "completed"))

        let messages = try store.messages(sessionId: session.id)
        #expect(messages.map(\.id) == ["a", "b"])
        #expect(messages.map(\.seq) == [1, 2])
        #expect(messages[1].status == "completed")
    }

    @Test func persistsAcrossReopen() throws {
        let path = try Fixtures.temporaryDirectory("db").appendingPathComponent("rocky.sqlite").path
        try RockyStore(path: path).add(Repo(name: "app", path: "/dev/app"))
        #expect(try RockyStore(path: path).repos().map(\.name) == ["app"])
    }
}
```

- [ ] **Step 2: Implement**

`Sources/RockyKit/Store/Records.swift`:

```swift
import Foundation
import GRDB

public struct Repo: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repo"

    public var id: String
    public var name: String
    public var path: String
    /// Claude Code instance for this repo's agents (for example `~/.claude-celes`); nil uses Claude's default.
    public var claudeConfigDir: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, path: String, claudeConfigDir: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.claudeConfigDir = claudeConfigDir
        self.createdAt = createdAt
    }
}

public struct Workspace: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspace"

    public var id: String
    public var repoId: String
    public var name: String
    public var path: String
    public var branch: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, repoId: String, name: String, path: String, branch: String, createdAt: Date = Date()) {
        self.id = id
        self.repoId = repoId
        self.name = name
        self.path = path
        self.branch = branch
        self.createdAt = createdAt
    }
}

public struct ChatSessionRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chatSession"

    public var id: String
    public var workspaceId: String
    public var agent: String
    /// ACP session id, used with `session/load` to resume; nil until the agent assigns one.
    public var acpSessionId: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, workspaceId: String, agent: String, acpSessionId: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.workspaceId = workspaceId
        self.agent = agent
        self.acpSessionId = acpSessionId
        self.createdAt = createdAt
    }
}

public struct ChatMessageRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chatMessage"

    public var id: String
    public var sessionId: String
    public var seq: Int
    public var kind: String
    public var text: String
    public var status: String?
    public var createdAt: Date

    public init(id: String, sessionId: String, seq: Int, kind: String, text: String, status: String?, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.seq = seq
        self.kind = kind
        self.text = text
        self.status = status
        self.createdAt = createdAt
    }
}
```

`Sources/RockyKit/Store/RockyStore.swift`:

```swift
import Foundation
import GRDB

public enum RockyStoreError: Error, Equatable {
    case duplicateRepo(String)
}

/// SQLite persistence for repos, workspaces and chat transcripts.
public final class RockyStore: Sendable {
    private let db: DatabaseQueue

    public convenience init(path: String) throws {
        try self.init(queue: DatabaseQueue(path: path))
    }

    public static func inMemory() throws -> RockyStore {
        try RockyStore(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        db = queue
        try Self.migrator.migrate(db)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "repo") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("claudeConfigDir", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text)
                t.column("repoId", .text).notNull().indexed().references("repo", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("branch", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "chatSession") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().indexed().references("workspace", onDelete: .cascade)
                t.column("agent", .text).notNull()
                t.column("acpSessionId", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "chatMessage") { t in
                t.primaryKey("id", .text)
                t.column("sessionId", .text).notNull().indexed().references("chatSession", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("status", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }
        return migrator
    }

    // MARK: Repos

    public func add(_ repo: Repo) throws {
        do {
            try db.write { try repo.insert($0) }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw RockyStoreError.duplicateRepo(repo.path)
        }
    }

    public func update(_ repo: Repo) throws {
        try db.write { try repo.update($0) }
    }

    public func repos() throws -> [Repo] {
        try db.read { try Repo.order(Column("createdAt"), Column("name")).fetchAll($0) }
    }

    /// Deletes the repo and, by cascade, its workspaces and transcripts. Files on disk are untouched.
    public func deleteRepo(id: String) throws {
        _ = try db.write { try Repo.deleteOne($0, key: id) }
    }

    // MARK: Workspaces

    public func add(_ workspace: Workspace) throws {
        try db.write { try workspace.insert($0) }
    }

    public func workspaces(repoId: String) throws -> [Workspace] {
        try db.read { try Workspace.filter(Column("repoId") == repoId).order(Column("createdAt"), Column("name")).fetchAll($0) }
    }

    public func deleteWorkspace(id: String) throws {
        _ = try db.write { try Workspace.deleteOne($0, key: id) }
    }

    // MARK: Chat

    public func add(_ session: ChatSessionRecord) throws {
        try db.write { try session.insert($0) }
    }

    public func update(_ session: ChatSessionRecord) throws {
        try db.write { try session.update($0) }
    }

    public func latestSession(workspaceId: String, agent: String) throws -> ChatSessionRecord? {
        try db.read {
            try ChatSessionRecord
                .filter(Column("workspaceId") == workspaceId && Column("agent") == agent)
                .order(Column("createdAt").desc)
                .fetchOne($0)
        }
    }

    /// Appends with the next `seq`, or replaces the record with the same id (a tool call whose status changed).
    public func upsert(_ message: ChatMessageRecord) throws {
        try db.write { db in
            var message = message
            if let existing = try ChatMessageRecord.fetchOne(db, key: message.id) {
                message.seq = existing.seq
            } else {
                let maxSeq = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM chatMessage WHERE sessionId = ?", arguments: [message.sessionId])
                message.seq = (maxSeq ?? 0) + 1
            }
            try message.save(db)
        }
    }

    public func messages(sessionId: String) throws -> [ChatMessageRecord] {
        try db.read { try ChatMessageRecord.filter(Column("sessionId") == sessionId).order(Column("seq")).fetchAll($0) }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/RockyKit/Store Tests/RockyKitTests/RockyStoreTests.swift
git commit -m "feat(kit): persist repos, workspaces and transcripts in sqlite"
```

---

### Task 7: Agent launcher

**Files:**
- Create: `Sources/RockyKit/Agents/AgentLauncher.swift`
- Test: `Tests/RockyKitTests/AgentLauncherTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner` (Task 2); `Fixtures.temporaryDirectory` (Task 1).
- Produces: `enum AgentKind: String { claude, opencode; displayName }`. `struct AgentLaunch(executable:arguments:environment:cwd:stderrLog:)`. `enum AgentLauncherError { executableNotFound(String), adapterNotInstalled }`. `enum AgentLauncher { claudeAdapterPackage; claudeAdapterVersion = "0.81.0"; claudeAdapterScript(prefix:) -> URL; resolve(_ name:, path: String?) -> URL?; launch(_ kind:, cwd:, environment:, adapterPrefix:, logsDirectory:) throws -> AgentLaunch; installClaudeAdapter(prefix:environment:) throws }`.

- [ ] **Step 1: Write the tests**

`Tests/RockyKitTests/AgentLauncherTests.swift`:

```swift
import Foundation
import Testing
@testable import RockyKit

struct AgentLauncherTests {
    private func makeExecutable(_ name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func resolveFindsFirstExecutableOnPath() throws {
        let first = try Fixtures.temporaryDirectory("bin1")
        let second = try Fixtures.temporaryDirectory("bin2")
        try makeExecutable("opencode", in: second)
        #expect(AgentLauncher.resolve("opencode", path: "\(first.path):\(second.path)") == second.appendingPathComponent("opencode"))
        #expect(AgentLauncher.resolve("opencode", path: first.path) == nil)
        #expect(AgentLauncher.resolve("opencode", path: nil) == nil)
    }

    @Test func opencodeLaunchesWithAcpSubcommand() throws {
        let bin = try Fixtures.temporaryDirectory("bin")
        try makeExecutable("opencode", in: bin)
        let cwd = URL(fileURLWithPath: "/tmp/ws")
        let launch = try AgentLauncher.launch(.opencode, cwd: cwd, environment: ["PATH": bin.path], adapterPrefix: bin, logsDirectory: bin)
        #expect(launch.executable == bin.appendingPathComponent("opencode"))
        #expect(launch.arguments == ["acp"])
        #expect(launch.cwd == cwd)
    }

    @Test func claudeNeedsNodeAndTheInstalledAdapter() throws {
        let bin = try Fixtures.temporaryDirectory("bin")
        let prefix = try Fixtures.temporaryDirectory("agents")
        #expect(throws: AgentLauncherError.executableNotFound("node")) {
            try AgentLauncher.launch(.claude, cwd: bin, environment: ["PATH": bin.path], adapterPrefix: prefix, logsDirectory: bin)
        }
        try makeExecutable("node", in: bin)
        #expect(throws: AgentLauncherError.adapterNotInstalled) {
            try AgentLauncher.launch(.claude, cwd: bin, environment: ["PATH": bin.path], adapterPrefix: prefix, logsDirectory: bin)
        }
        let script = AgentLauncher.claudeAdapterScript(prefix: prefix)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: script.path, contents: Data())
        let launch = try AgentLauncher.launch(.claude, cwd: bin, environment: ["PATH": bin.path], adapterPrefix: prefix, logsDirectory: bin)
        #expect(launch.executable == bin.appendingPathComponent("node"))
        #expect(launch.arguments == [script.path])
    }
}
```

- [ ] **Step 2: Implement**

`Sources/RockyKit/Agents/AgentLauncher.swift`:

```swift
import Foundation

public enum AgentKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case claude
    case opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        }
    }
}

public struct AgentLaunch: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let cwd: URL
    public let stderrLog: URL

    public init(executable: URL, arguments: [String], environment: [String: String], cwd: URL, stderrLog: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.stderrLog = stderrLog
    }
}

public enum AgentLauncherError: Error, Equatable {
    case executableNotFound(String)
    case adapterNotInstalled
}

public enum AgentLauncher {
    public static let claudeAdapterPackage = "@agentclientprotocol/claude-agent-acp"
    public static let claudeAdapterVersion = "0.81.0"

    public static func claudeAdapterScript(prefix: URL) -> URL {
        prefix.appendingPathComponent("node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js")
    }

    /// First executable named `name` in a PATH string.
    public static func resolve(_ name: String, path: String?) -> URL? {
        for directory in (path ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Resolves how to start `kind`. The Claude adapter runs from `adapterPrefix` with `node`
    /// instead of `npx`, so starting a session never hits the npm registry.
    public static func launch(
        _ kind: AgentKind,
        cwd: URL,
        environment: [String: String],
        adapterPrefix: URL,
        logsDirectory: URL
    ) throws -> AgentLaunch {
        let log = logsDirectory.appendingPathComponent("\(kind.rawValue)-\(UUID().uuidString.prefix(8)).log")
        switch kind {
        case .opencode:
            guard let opencode = resolve("opencode", path: environment["PATH"]) else {
                throw AgentLauncherError.executableNotFound("opencode")
            }
            return AgentLaunch(executable: opencode, arguments: ["acp"], environment: environment, cwd: cwd, stderrLog: log)
        case .claude:
            guard let node = resolve("node", path: environment["PATH"]) else {
                throw AgentLauncherError.executableNotFound("node")
            }
            let script = claudeAdapterScript(prefix: adapterPrefix)
            guard FileManager.default.fileExists(atPath: script.path) else { throw AgentLauncherError.adapterNotInstalled }
            return AgentLaunch(executable: node, arguments: [script.path], environment: environment, cwd: cwd, stderrLog: log)
        }
    }

    /// Installs the pinned Claude adapter into `prefix` with npm. Blocking; needs network once.
    public static func installClaudeAdapter(prefix: URL, environment: [String: String]) throws {
        guard let npm = resolve("npm", path: environment["PATH"]) else { throw AgentLauncherError.executableNotFound("npm") }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try ProcessRunner.run(
            npm,
            ["install", "--prefix", prefix.path, "--no-audit", "--no-fund", "\(claudeAdapterPackage)@\(claudeAdapterVersion)"],
            in: prefix,
            environment: environment
        )
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/RockyKit/Agents Tests/RockyKitTests/AgentLauncherTests.swift
git commit -m "feat(kit): resolve how to launch claude and opencode"
```

---

### Task 8: Chat session model

**Files:**
- Create: `Sources/RockyKit/Chat/ChatSessionModel.swift`
- Create: `Tests/RockyKitTests/Fixtures/fake-acp-agent.sh`, `Tests/RockyKitTests/FakeACP.swift`
- Test: `Tests/RockyKitTests/ChatSessionModelTests.swift`

**Interfaces:**
- Consumes: `ACPConnection`, `ACPHandlers`, `ACPConnectionError` (Task 3); `ACPProtocol`, `SessionEvent`, `PermissionRequest`, `AgentCapabilities` (Task 4); `AgentKind`, `AgentLaunch` (Task 7).
- Produces: `struct ChatItem(id: UUID, kind: Kind, text:, status:)` with `Kind { user, agent, thought, tool, error }`. `@MainActor @Observable final class ChatSessionModel { init(agent:launch:history:resumeSessionId:flushInterval:onPersist:); agent; items; state: State { idle, starting, ready, running, stopped(String) }; pendingPermission; sessionId; capabilities; isVisible; start() async; send(_:) async; cancel() async; answerPermission(optionId:); stop() async; flush() }`. Test helper `Fixtures.fakeACPLaunch(loadSession:)`.

- [ ] **Step 1: Write the fixtures and the tests**

`Tests/RockyKitTests/Fixtures/fake-acp-agent.sh`:

```bash
#!/bin/bash
# Scripted ACP agent for ChatSessionModel tests.
# Answers initialize, session/new, session/load (replaying one old message first) and session/prompt.
# A prompt streams "Hel" + "lo", announces tool t1, asks permission, then reports t1 completed or failed.
# FAKE_ACP_LOAD_SESSION=false makes initialize report loadSession=false.
load_session="${FAKE_ACP_LOAD_SESSION:-true}"
update() {
  echo "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"fake-1\",\"update\":$1}}"
}
while IFS= read -r line; do
  id=""
  if [[ $line =~ \"id\":([0-9]+) ]]; then id="${BASH_REMATCH[1]}"; fi
  case "$line" in
    *'"method":"initialize"'*)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":$load_session}}}"
      ;;
    *'"method":"session/new"'*)
      update '{"sessionUpdate":"available_commands_update","availableCommands":[]}'
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"fake-1\"}}"
      ;;
    *'"method":"session/load"'*)
      update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"replayed"}}'
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":null}"
      ;;
    *'"method":"session/prompt"'*)
      update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hel"}}'
      update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}'
      update '{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Run printenv","status":"pending"}'
      echo '{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"fake-1","toolCall":{"toolCallId":"t1","title":"Run printenv"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}'
      IFS= read -r reply
      if [[ $reply == *'"optionId":"allow"'* ]]; then status=completed; else status=failed; fi
      update "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"$status\"}"
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
      ;;
  esac
done
```

`Tests/RockyKitTests/FakeACP.swift`:

```swift
import Foundation
@testable import RockyKit

extension Fixtures {
    /// Launches `fake-acp-agent.sh`, a scripted ACP agent (see the script header).
    static func fakeACPLaunch(loadSession: Bool = true) -> AgentLaunch {
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_ACP_LOAD_SESSION"] = loadSession ? "true" : "false"
        return AgentLaunch(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [url("fake-acp-agent").path],
            environment: environment,
            cwd: FileManager.default.temporaryDirectory,
            stderrLog: stderrLog()
        )
    }
}
```

`Tests/RockyKitTests/ChatSessionModelTests.swift`:

```swift
import Foundation
import Testing
@testable import RockyKit

@MainActor
struct ChatSessionModelTests {
    private func waitForPermission(_ model: ChatSessionModel) async throws {
        for _ in 0..<500 where model.pendingPermission == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.pendingPermission != nil)
    }

    private func summary(_ items: [ChatItem]) -> [String] {
        items.map { "\($0.kind.rawValue):\($0.text)" + ($0.status.map { "[\($0)]" } ?? "") }
    }

    @Test func startsANewSessionAndIgnoresUpdatesBeforeIt() async {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        #expect(model.state == .ready)
        #expect(model.sessionId == "fake-1")
        #expect(model.capabilities.loadSession)
        #expect(model.items.isEmpty)
        await model.stop()
    }

    @Test func streamsTextAsksPermissionAndPersistsTheTurn() async throws {
        var persisted: [ChatItem] = []
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero) { persisted.append($0) }
        await model.start()

        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        #expect(model.state == .running)
        #expect(model.pendingPermission?.title == "Run printenv")
        #expect(model.pendingPermission?.options.map(\.id) == ["allow", "reject"])
        model.answerPermission(optionId: "allow")
        await sending

        #expect(model.state == .ready)
        #expect(summary(model.items) == ["user:hi", "agent:Hello", "tool:Run printenv[completed]"])
        #expect(summary(persisted) == ["user:hi", "agent:Hello", "tool:Run printenv[completed]"])
        await model.stop()
    }

    @Test func rejectedPermissionMarksTheToolFailed() async throws {
        let model = ChatSessionModel(agent: .opencode, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        model.answerPermission(optionId: "reject")
        await sending
        #expect(model.items.last?.status == "failed")
        await model.stop()
    }

    @Test func hiddenSessionBuffersUpdatesUntilShown() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        model.isVisible = false

        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        #expect(summary(model.items) == ["user:hi"])
        model.isVisible = true
        #expect(summary(model.items) == ["user:hi", "agent:Hello", "tool:Run printenv[pending]"])

        model.answerPermission(optionId: "allow")
        await sending
        await model.stop()
    }

    @Test func resumeUsesSessionLoadAndDoesNotDuplicateReplayedHistory() async {
        let history = [ChatItem(kind: .user, text: "earlier"), ChatItem(kind: .agent, text: "replayed")]
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), history: history, resumeSessionId: "fake-1", flushInterval: .zero)
        await model.start()
        #expect(model.state == .ready)
        #expect(model.sessionId == "fake-1")
        #expect(model.items == history)
        await model.stop()
    }

    @Test func resumeFallsBackToNewSessionWhenAgentCannotLoad() async {
        let history = [ChatItem(kind: .user, text: "earlier")]
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(loadSession: false), history: history, resumeSessionId: "old-9", flushInterval: .zero)
        await model.start()
        #expect(model.sessionId == "fake-1")
        #expect(model.items == history)
        await model.stop()
    }

    @Test func agentThatExitsDuringStartStopsWithReason() async {
        let launch = AgentLaunch(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "read -r line; echo 'Authentication required' >&2; exit 3"],
            environment: ProcessInfo.processInfo.environment,
            cwd: FileManager.default.temporaryDirectory,
            stderrLog: Fixtures.stderrLog()
        )
        let model = ChatSessionModel(agent: .claude, launch: launch, flushInterval: .zero)
        await model.start()
        #expect(model.state == .stopped("Agent exited (3). Authentication required"))
    }

    @Test func stopWhileWaitingForPermissionUnblocksTheTurn() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        await model.stop()
        await sending
        #expect(model.pendingPermission == nil)
        #expect(model.state == .stopped("Stopped"))
    }
}
```

- [ ] **Step 2: Implement**

`Sources/RockyKit/Chat/ChatSessionModel.swift`:

```swift
import Foundation
import Observation

public struct ChatItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user, agent, thought, tool, error
    }

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var status: String?

    public init(id: UUID = UUID(), kind: Kind, text: String, status: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.status = status
    }
}

/// One agent session in one workspace: starts the ACP process, streams its updates into `items`,
/// and surfaces permission prompts.
@MainActor
@Observable
public final class ChatSessionModel {
    public enum State: Equatable {
        case idle, starting, ready, running
        case stopped(String)
    }

    public let agent: AgentKind
    public private(set) var items: [ChatItem]
    public private(set) var state: State = .idle
    public private(set) var pendingPermission: PermissionRequest?
    public private(set) var sessionId: String?
    public private(set) var capabilities = AgentCapabilities(loadSession: false)
    /// While false, updates are buffered and applied on the next show (spec Section 1).
    public var isVisible = true {
        didSet { if isVisible { flush() } }
    }

    @ObservationIgnored private let launch: AgentLaunch
    @ObservationIgnored private let flushInterval: Duration
    @ObservationIgnored private let onPersist: @MainActor (ChatItem) -> Void
    @ObservationIgnored private var resumeSessionId: String?
    @ObservationIgnored private var connection: ACPConnection?
    @ObservationIgnored private var buffered: [SessionEvent] = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var openTextItem: UUID?
    @ObservationIgnored private var toolItems: [String: UUID] = [:]
    @ObservationIgnored private var turnItems: [UUID] = []
    @ObservationIgnored private var permissionContinuation: CheckedContinuation<String?, Never>?

    public init(
        agent: AgentKind,
        launch: AgentLaunch,
        history: [ChatItem] = [],
        resumeSessionId: String? = nil,
        flushInterval: Duration = .milliseconds(100),
        onPersist: @escaping @MainActor (ChatItem) -> Void = { _ in }
    ) {
        self.agent = agent
        self.launch = launch
        self.items = history
        self.resumeSessionId = resumeSessionId
        self.flushInterval = flushInterval
        self.onPersist = onPersist
    }

    public func start() async {
        switch state {
        case .idle, .stopped: break
        default: return
        }
        state = .starting
        resumeSessionId = sessionId ?? resumeSessionId
        sessionId = nil
        do {
            let connection = try ACPConnection(
                executable: launch.executable,
                arguments: launch.arguments,
                environment: launch.environment,
                cwd: launch.cwd,
                stderrLog: launch.stderrLog
            )
            self.connection = connection
            await connection.setHandlers(ACPHandlers(
                onNotification: { [weak self] notification in await self?.receive(notification) },
                onRequest: { [weak self] method, params in
                    guard method == "session/request_permission", let self else {
                        return ACPProtocol.permissionResponse(optionId: nil)
                    }
                    let optionId = await self.askPermission(ACPProtocol.permissionRequest(from: params))
                    return ACPProtocol.permissionResponse(optionId: optionId)
                },
                onExit: { [weak self] error in await self?.connectionEnded(error) }
            ))
            try await connection.start()
            capabilities = ACPProtocol.capabilities(from: try await connection.call("initialize", ACPProtocol.initializeParams()))
            // Updates are dropped while `sessionId` is nil. `session/load` replays the whole
            // conversation before it responds, and the transcript already comes from the store.
            if let resume = resumeSessionId, capabilities.loadSession {
                _ = try await connection.call("session/load", ACPProtocol.loadSessionParams(sessionId: resume, cwd: launch.cwd))
                sessionId = resume
            } else {
                let result = try await connection.call("session/new", ACPProtocol.newSessionParams(cwd: launch.cwd))
                guard let id = ACPProtocol.sessionId(fromNewSession: result) else {
                    throw ACPConnectionError.rpc(code: 0, message: "session/new returned no sessionId")
                }
                sessionId = id
            }
            state = .ready
        } catch {
            state = .stopped(Self.describe(error))
            await connection?.terminate()
        }
    }

    public func send(_ text: String) async {
        guard state == .ready, let connection, let sessionId else { return }
        let userItem = ChatItem(kind: .user, text: text)
        items.append(userItem)
        onPersist(userItem)
        state = .running
        openTextItem = nil
        turnItems = []
        do {
            _ = try await connection.call("session/prompt", ACPProtocol.promptParams(sessionId: sessionId, text: text))
            flush()
            if state == .running { state = .ready }
        } catch ACPConnectionError.rpc(_, let message) {
            flush()
            appendTurnItem(ChatItem(kind: .error, text: message))
            if state == .running { state = .ready }
        } catch {
            flush()
            // stop() or the exit handler may already have set a more precise reason.
            if state == .running { state = .stopped(Self.describe(error)) }
        }
        for id in turnItems {
            if let item = items.first(where: { $0.id == id }) { onPersist(item) }
        }
    }

    public func cancel() async {
        answerPermission(optionId: nil)
        guard let connection, let sessionId else { return }
        try? await connection.notify("session/cancel", ACPProtocol.cancelParams(sessionId: sessionId))
    }

    public func answerPermission(optionId: String?) {
        pendingPermission = nil
        permissionContinuation?.resume(returning: optionId)
        permissionContinuation = nil
    }

    public func stop() async {
        answerPermission(optionId: nil)
        state = .stopped("Stopped")
        await connection?.terminate()
    }

    public func flush() {
        let events = buffered
        buffered.removeAll()
        for event in events { apply(event) }
    }

    private func receive(_ notification: ACPNotification) {
        guard notification.method == "session/update", let sessionId,
              let event = ACPProtocol.event(fromUpdate: notification.params, sessionId: sessionId) else { return }
        buffered.append(event)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard isVisible else { return }
        guard flushInterval > .zero else { return flush() }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self, flushInterval] in
            try? await Task.sleep(for: flushInterval)
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case .agentText(let text):
            appendText(text, kind: .agent)
        case .agentThought(let text):
            appendText(text, kind: .thought)
        case let .toolCall(id, title, status):
            let item = ChatItem(kind: .tool, text: title, status: status)
            toolItems[id] = item.id
            appendTurnItem(item)
        case let .toolCallUpdate(id, status):
            guard let itemId = toolItems[id], let index = items.firstIndex(where: { $0.id == itemId }) else { return }
            items[index].status = status
        case .ignored:
            break
        }
    }

    private func appendText(_ text: String, kind: ChatItem.Kind) {
        if let openTextItem, let index = items.lastIndex(where: { $0.id == openTextItem }), items[index].kind == kind {
            items[index].text += text
            return
        }
        let item = ChatItem(kind: kind, text: text)
        appendTurnItem(item)
        openTextItem = item.id
    }

    private func appendTurnItem(_ item: ChatItem) {
        openTextItem = nil
        items.append(item)
        turnItems.append(item.id)
    }

    private func askPermission(_ request: PermissionRequest) async -> String? {
        await withCheckedContinuation { continuation in
            permissionContinuation?.resume(returning: nil)
            permissionContinuation = continuation
            pendingPermission = request
        }
    }

    private func connectionEnded(_ error: ACPConnectionError) {
        answerPermission(optionId: nil)
        connection = nil
        if case .stopped = state { return }
        state = .stopped(Self.describe(error))
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let ACPConnectionError.agentExited(status, stderrTail):
            let lastLine = stderrTail.split(separator: "\n").last.map(String.init) ?? ""
            return "Agent exited (\(status)). \(lastLine)".trimmingCharacters(in: .whitespaces)
        case let ACPConnectionError.rpc(_, message):
            return message
        default:
            return "\(error)"
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/RockyKit/Chat Tests/RockyKitTests/Fixtures/fake-acp-agent.sh Tests/RockyKitTests/FakeACP.swift Tests/RockyKitTests/ChatSessionModelTests.swift
git commit -m "feat(kit): add chat session model over acp"
```

---

### Task 9: App model

**Files:**
- Create: `Sources/RockyKit/App/AppModel.swift`
- Test: `Tests/RockyKitTests/AppModelTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–8.
- Produces: `struct RockyPaths(database:adapterPrefix:logs:)` with `static func standard() throws`. `@MainActor @Observable final class AppModel { init(store:paths:captureEnvironment:makeLaunch:installAdapter:); repos; workspaces: [String: [Workspace]]; selectedWorkspaceId; errorMessage; busyMessage; loginEnvironment; selectedWorkspace; repo(id:); existingChat(workspaceId:); bootstrap() async; refreshEnvironment() async; addRepo(at:) async; setClaudeConfigDir(repoId:_:); removeRepo(id:) async; createWorkspace(repoId:) async; removeWorkspace(id:) async; openChat(workspace:agent:) async -> ChatSessionModel?; stopAllAgents() async }`.

- [ ] **Step 1: Write the tests**

`Tests/RockyKitTests/AppModelTests.swift`:

```swift
import Foundation
import Testing
@testable import RockyKit

final class LaunchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var environments: [[String: String]] = []

    func record(_ environment: [String: String]) {
        lock.withLock { environments.append(environment) }
    }

    var last: [String: String]? {
        lock.withLock { environments.last }
    }
}

@MainActor
struct AppModelTests {
    private func makeModel(
        store: RockyStore? = nil,
        capture: @escaping @Sendable () throws -> [String: String] = { GitFixture.environment },
        launches: LaunchBox = LaunchBox()
    ) throws -> AppModel {
        let root = try Fixtures.temporaryDirectory("app")
        let paths = RockyPaths(database: root.appendingPathComponent("rocky.sqlite"), adapterPrefix: root.appendingPathComponent("agents"), logs: root)
        return AppModel(
            store: try store ?? RockyStore.inMemory(),
            paths: paths,
            captureEnvironment: capture,
            makeLaunch: { _, cwd, environment, _ in
                launches.record(environment)
                let fake = Fixtures.fakeACPLaunch()
                return AgentLaunch(executable: fake.executable, arguments: fake.arguments, environment: fake.environment, cwd: cwd, stderrLog: fake.stderrLog)
            },
            installAdapter: { _, _ in }
        )
    }

    private func answerNextPermission(_ chat: ChatSessionModel) async throws {
        for _ in 0..<500 where chat.pendingPermission == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.answerPermission(optionId: "allow")
    }

    @Test func addRepoAcceptsOnlyRepositoryRootsOnce() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let parent = try Fixtures.temporaryDirectory("repos")
        let repo = try GitFixture.localRepo(in: parent)

        await model.addRepo(at: parent)
        #expect(model.repos.isEmpty)
        #expect(model.errorMessage?.contains("not the root of a git repository") == true)

        await model.addRepo(at: repo)
        #expect(model.repos.map(\.name) == ["app"])

        await model.addRepo(at: repo)
        #expect(model.errorMessage == "app is already in Rocky.")
        #expect(model.repos.count == 1)
    }

    @Test func createsSelectsAndRemovesAWorkspace() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)

        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        #expect(model.selectedWorkspaceId == workspace.id)
        #expect(workspace.branch == "rocky/\(workspace.name)")
        #expect(workspace.path.hasPrefix(WorktreeService.worktreesRoot(for: repo).path))
        #expect(FileManager.default.fileExists(atPath: workspace.path))

        await model.removeWorkspace(id: workspace.id)
        #expect(model.workspaces[repoId]?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(model.selectedWorkspaceId == nil)
    }

    @Test func chatUsesTheRepoClaudeInstancePersistsAndResumes() async throws {
        let store = try RockyStore.inMemory()
        let launches = LaunchBox()
        let model = try makeModel(store: store, launches: launches)
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        model.setClaudeConfigDir(repoId: repoId, "/Users/me/.claude-celes")
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)

        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        #expect(launches.last?["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-celes")
        #expect(chat.state == .ready)
        async let sending: Void = chat.send("hi")
        try await answerNextPermission(chat)
        await sending
        await model.stopAllAgents()
        #expect(chat.state == .stopped("Stopped"))

        let reopened = try makeModel(store: store, launches: launches)
        await reopened.bootstrap()
        let resumed = try #require(await reopened.openChat(workspace: workspace, agent: .claude))
        #expect(resumed.sessionId == "fake-1")
        #expect(resumed.items.map(\.text) == ["hi", "Hello", "Run printenv"])
        #expect(resumed.items.last?.status == "completed")
        await reopened.stopAllAgents()
    }

    @Test func repoWithoutClaudeInstanceNeverInheritsOne() async throws {
        let launches = LaunchBox()
        let model = try makeModel(capture: {
            GitFixture.environment.merging(["CLAUDE_CONFIG_DIR": "/Users/me/.claude-celes"]) { _, new in new }
        }, launches: launches)
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)

        _ = await model.openChat(workspace: workspace, agent: .opencode)
        #expect(launches.last?["CLAUDE_CONFIG_DIR"] == nil)
        await model.stopAllAgents()
    }

    @Test func environmentCaptureFailureFallsBackAndReports() async throws {
        struct Boom: Error {}
        let model = try makeModel(capture: { throw Boom() })
        await model.bootstrap()
        #expect(model.loginEnvironment["PATH"] != nil)
        #expect(model.errorMessage?.hasPrefix("Could not read your login shell environment") == true)
    }
}
```

- [ ] **Step 2: Implement**

`Sources/RockyKit/App/AppModel.swift`:

```swift
import Foundation
import Observation

public struct RockyPaths: Sendable {
    public let database: URL
    public let adapterPrefix: URL
    public let logs: URL

    public init(database: URL, adapterPrefix: URL, logs: URL) {
        self.database = database
        self.adapterPrefix = adapterPrefix
        self.logs = logs
    }

    /// `~/Library/Application Support/Rocky` for data and the Claude adapter, `~/Library/Logs/Rocky` for agent stderr.
    public static func standard() throws -> RockyPaths {
        let fileManager = FileManager.default
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Rocky", isDirectory: true)
        let logs = try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Logs/Rocky", isDirectory: true)
        for directory in [support, logs] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return RockyPaths(
            database: support.appendingPathComponent("rocky.sqlite"),
            adapterPrefix: support.appendingPathComponent("agents", isDirectory: true),
            logs: logs
        )
    }
}

/// App state: repos, their workspaces, and one running chat per workspace.
@MainActor
@Observable
public final class AppModel {
    public private(set) var repos: [Repo] = []
    public private(set) var workspaces: [String: [Workspace]] = [:]
    public var selectedWorkspaceId: String?
    public var errorMessage: String?
    public private(set) var busyMessage: String?
    public private(set) var loginEnvironment: [String: String] = [:]

    @ObservationIgnored public let store: RockyStore
    @ObservationIgnored public let paths: RockyPaths
    @ObservationIgnored private let captureEnvironment: @Sendable () throws -> [String: String]
    @ObservationIgnored private let makeLaunch: @Sendable (AgentKind, URL, [String: String], RockyPaths) throws -> AgentLaunch
    @ObservationIgnored private let installAdapter: @Sendable (RockyPaths, [String: String]) throws -> Void
    @ObservationIgnored private var chats: [String: ChatSessionModel] = [:]

    public init(
        store: RockyStore,
        paths: RockyPaths,
        captureEnvironment: @escaping @Sendable () throws -> [String: String] = { try LoginEnvironment.capture() },
        makeLaunch: @escaping @Sendable (AgentKind, URL, [String: String], RockyPaths) throws -> AgentLaunch = { kind, cwd, environment, paths in
            try AgentLauncher.launch(kind, cwd: cwd, environment: environment, adapterPrefix: paths.adapterPrefix, logsDirectory: paths.logs)
        },
        installAdapter: @escaping @Sendable (RockyPaths, [String: String]) throws -> Void = { paths, environment in
            try AgentLauncher.installClaudeAdapter(prefix: paths.adapterPrefix, environment: environment)
        }
    ) {
        self.store = store
        self.paths = paths
        self.captureEnvironment = captureEnvironment
        self.makeLaunch = makeLaunch
        self.installAdapter = installAdapter
    }

    public var selectedWorkspace: Workspace? {
        workspaces.values.joined().first { $0.id == selectedWorkspaceId }
    }

    public func repo(id: String) -> Repo? {
        repos.first { $0.id == id }
    }

    public func existingChat(workspaceId: String) -> ChatSessionModel? {
        chats[workspaceId]
    }

    /// Loads persisted state and captures the login environment once (spec Section 1).
    public func bootstrap() async {
        reload()
        await refreshEnvironment()
    }

    public func refreshEnvironment() async {
        let capture = captureEnvironment
        do {
            loginEnvironment = try await Task.detached { try capture() }.value
        } catch {
            loginEnvironment = ProcessInfo.processInfo.environment
            errorMessage = "Could not read your login shell environment (\(error)). Agents use Rocky's own environment."
        }
    }

    public func addRepo(at url: URL) async {
        let service = WorktreeService(environment: loginEnvironment)
        let isRoot = await Task.detached { service.isRepositoryRoot(url) }.value
        guard isRoot else {
            errorMessage = "\(url.path) is not the root of a git repository."
            return
        }
        do {
            try store.add(Repo(name: url.lastPathComponent, path: url.path))
            reload()
        } catch RockyStoreError.duplicateRepo {
            errorMessage = "\(url.lastPathComponent) is already in Rocky."
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func setClaudeConfigDir(repoId: String, _ directory: String?) {
        guard var repo = repo(id: repoId) else { return }
        repo.claudeConfigDir = (directory?.isEmpty ?? true) ? nil : directory
        do {
            try store.update(repo)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Forgets the repo in Rocky. Its folder and worktrees stay on disk.
    public func removeRepo(id: String) async {
        for workspace in workspaces[id] ?? [] {
            await chats.removeValue(forKey: workspace.id)?.stop()
        }
        do {
            try store.deleteRepo(id: id)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func createWorkspace(repoId: String) async {
        guard let repo = repo(id: repoId) else { return }
        let repoURL = URL(fileURLWithPath: repo.path)
        let service = WorktreeService(environment: loginEnvironment)
        busyMessage = "Creating workspace…"
        defer { busyMessage = nil }
        do {
            let created = try await Task.detached {
                let name = WorkspaceNamer.pick(isTaken: { service.isTaken(repo: repoURL, name: $0) })
                return try service.create(repo: repoURL, name: name)
            }.value
            let workspace = Workspace(repoId: repo.id, name: created.name, path: created.path.path, branch: created.branch)
            try store.add(workspace)
            reload()
            selectedWorkspaceId = workspace.id
            if created.fetchFailed {
                errorMessage = "git fetch failed; \(created.name) was created from the last fetched \(created.baseRef)."
            }
        } catch {
            errorMessage = "Could not create a workspace: \(error)"
        }
    }

    /// Removes the worktree folder and keeps its branch. Git refuses while there are uncommitted changes.
    public func removeWorkspace(id: String) async {
        guard let workspace = workspaces.values.joined().first(where: { $0.id == id }),
              let repo = repo(id: workspace.repoId) else { return }
        await chats.removeValue(forKey: id)?.stop()
        let service = WorktreeService(environment: loginEnvironment)
        let repoURL = URL(fileURLWithPath: repo.path)
        let worktreeURL = URL(fileURLWithPath: workspace.path)
        do {
            try await Task.detached { try service.remove(repo: repoURL, worktree: worktreeURL) }.value
            try store.deleteWorkspace(id: id)
            if selectedWorkspaceId == id { selectedWorkspaceId = nil }
            reload()
        } catch {
            errorMessage = "Could not remove \(workspace.name): \(error)"
        }
    }

    /// Returns the workspace's chat for `agent`, starting it and resuming that agent's last session.
    public func openChat(workspace: Workspace, agent: AgentKind) async -> ChatSessionModel? {
        if let chat = chats[workspace.id], chat.agent == agent { return chat }
        await chats.removeValue(forKey: workspace.id)?.stop()
        guard let repo = repo(id: workspace.repoId) else { return nil }
        let environment = WorkspaceEnvironment.make(login: loginEnvironment, claudeConfigDir: repo.claudeConfigDir)
        do {
            let launch = try await resolveLaunch(agent, cwd: URL(fileURLWithPath: workspace.path), environment: environment)
            let existing = try store.latestSession(workspaceId: workspace.id, agent: agent.rawValue)
            var record = existing ?? ChatSessionRecord(workspaceId: workspace.id, agent: agent.rawValue)
            if existing == nil { try store.add(record) }
            let history = try store.messages(sessionId: record.id).map(ChatItem.init(record:))
            let store = self.store
            let recordId = record.id
            let chat = ChatSessionModel(agent: agent, launch: launch, history: history, resumeSessionId: record.acpSessionId) { item in
                try? store.upsert(ChatMessageRecord(item: item, sessionId: recordId))
            }
            chats[workspace.id] = chat
            await chat.start()
            if let sessionId = chat.sessionId, sessionId != record.acpSessionId {
                record.acpSessionId = sessionId
                try store.update(record)
            }
            return chat
        } catch {
            errorMessage = "Could not start \(agent.displayName): \(error)"
            return nil
        }
    }

    /// Called before quitting, so no agent process outlives Rocky.
    public func stopAllAgents() async {
        for chat in chats.values { await chat.stop() }
        chats.removeAll()
    }

    private func resolveLaunch(_ agent: AgentKind, cwd: URL, environment: [String: String]) async throws -> AgentLaunch {
        let makeLaunch = self.makeLaunch
        let paths = self.paths
        do {
            return try makeLaunch(agent, cwd, environment, paths)
        } catch AgentLauncherError.adapterNotInstalled {
            busyMessage = "Installing the Claude adapter (one time)…"
            defer { busyMessage = nil }
            let install = installAdapter
            try await Task.detached { try install(paths, environment) }.value
            return try makeLaunch(agent, cwd, environment, paths)
        }
    }

    private func reload() {
        do {
            repos = try store.repos()
            var byRepo: [String: [Workspace]] = [:]
            for repo in repos { byRepo[repo.id] = try store.workspaces(repoId: repo.id) }
            workspaces = byRepo
        } catch {
            errorMessage = "\(error)"
        }
    }
}

extension ChatItem {
    init(record: ChatMessageRecord) {
        self.init(
            id: UUID(uuidString: record.id) ?? UUID(),
            kind: Kind(rawValue: record.kind) ?? .agent,
            text: record.text,
            status: record.status
        )
    }
}

extension ChatMessageRecord {
    init(item: ChatItem, sessionId: String) {
        self.init(id: item.id.uuidString, sessionId: sessionId, seq: 0, kind: item.kind.rawValue, text: item.text, status: item.status)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/RockyKit/App Tests/RockyKitTests/AppModelTests.swift
git commit -m "feat(kit): add app model for repos, workspaces and chats"
```

---

### Task 10: SwiftUI app and bundle

**Files:**
- Delete: `Sources/RockyUI/RockyUI.swift`, `Sources/Rocky/main.swift`
- Create: `Sources/RockyUI/RootView.swift`, `Sources/RockyUI/SidebarView.swift`, `Sources/RockyUI/RepoSettingsView.swift`, `Sources/RockyUI/WorkspaceDetailView.swift`, `Sources/RockyUI/ChatView.swift`
- Create: `Sources/Rocky/RockyApp.swift`, `Resources/Info.plist`, `scripts/make-app.sh`

**Interfaces:**
- Consumes: `AppModel`, `ChatSessionModel`, `ChatItem`, `PermissionRequest`, `AgentKind`, `ClaudeInstances`, `Repo`, `Workspace`, `RockyPaths`, `RockyStore` (Tasks 2–9).
- Produces: `public struct RootView(model:)`; the `Rocky` executable; `scripts/make-app.sh` → `build/Rocky.app`.

This task has no automated UI tests: the logic under the views is covered by Tasks 1–9. It is verified by building and by the manual checklist in Task 12.

- [ ] **Step 1: Remove the placeholders**

```bash
git rm Sources/RockyUI/RockyUI.swift Sources/Rocky/main.swift
```

- [ ] **Step 2: Write the views**

`Sources/RockyUI/RootView.swift`:

```swift
import RockyKit
import SwiftUI

public struct RootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let workspace = model.selectedWorkspace {
                WorkspaceDetailView(model: model, workspace: workspace)
                    .id(workspace.id)
            } else {
                ContentUnavailableView(
                    "No workspace selected",
                    systemImage: "square.stack.3d.up",
                    description: Text("Add a repository, then create a workspace from its menu.")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let busy = model.busyMessage {
                ProgressView(busy)
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
        }
        .alert(
            "Rocky",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
```

`Sources/RockyUI/SidebarView.swift`:

```swift
import AppKit
import RockyKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var settingsRepo: Repo?
    @State private var workspaceToRemove: Workspace?

    var body: some View {
        List(selection: $model.selectedWorkspaceId) {
            ForEach(model.repos) { repo in
                Section {
                    ForEach(model.workspaces[repo.id] ?? []) { workspace in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name)
                            Text(workspace.branch)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(workspace.id)
                        .contextMenu {
                            Button("Remove Workspace…", role: .destructive) { workspaceToRemove = workspace }
                        }
                    }
                } header: {
                    header(for: repo)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .toolbar {
            ToolbarItem {
                Button("Add Repository", systemImage: "plus", action: addRepository)
            }
        }
        .sheet(item: $settingsRepo) { repo in
            RepoSettingsView(model: model, repo: repo)
        }
        .confirmationDialog(
            "Remove \(workspaceToRemove?.name ?? "")?",
            isPresented: Binding(get: { workspaceToRemove != nil }, set: { if !$0 { workspaceToRemove = nil } }),
            presenting: workspaceToRemove
        ) { workspace in
            Button("Remove Worktree", role: .destructive) {
                Task { await model.removeWorkspace(id: workspace.id) }
            }
        } message: { workspace in
            Text("Deletes the folder \(workspace.path). The branch \(workspace.branch) is kept. Git refuses while there are uncommitted changes.")
        }
    }

    private func header(for repo: Repo) -> some View {
        HStack {
            Text(repo.name)
            Spacer()
            Menu {
                Button("New Workspace") { Task { await model.createWorkspace(repoId: repo.id) } }
                Button("Settings…") { settingsRepo = repo }
                Divider()
                Button("Remove from Rocky", role: .destructive) { Task { await model.removeRepo(id: repo.id) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addRepo(at: url) }
    }
}
```

`Sources/RockyUI/RepoSettingsView.swift`:

```swift
import RockyKit
import SwiftUI

struct RepoSettingsView: View {
    let model: AppModel
    let repo: Repo
    @Environment(\.dismiss) private var dismiss
    @State private var claudeConfigDir: String
    private let instances = ClaudeInstances.detect(home: FileManager.default.homeDirectoryForCurrentUser)

    init(model: AppModel, repo: Repo) {
        self.model = model
        self.repo = repo
        _claudeConfigDir = State(initialValue: repo.claudeConfigDir ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(repo.name) {
                    Picker("Claude instance", selection: $claudeConfigDir) {
                        Text("Claude default").tag("")
                        ForEach(instances, id: \.self) { Text($0).tag($0) }
                        if !claudeConfigDir.isEmpty && !instances.contains(claudeConfigDir) {
                            Text(claudeConfigDir).tag(claudeConfigDir)
                        }
                    }
                    Text("Sets CLAUDE_CONFIG_DIR for Claude Code sessions in this repo. Rocky never inherits it from your shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.setClaudeConfigDir(repoId: repo.id, claudeConfigDir)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480)
    }
}
```

`Sources/RockyUI/WorkspaceDetailView.swift`:

```swift
import RockyKit
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace
    @State private var agent: AgentKind = .claude
    @State private var chat: ChatSessionModel?
    @State private var starting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name).font(.headline)
                    Text(workspace.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Picker("Agent", selection: $agent) {
                    ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding()
            Divider()
            if let chat, chat.agent == agent {
                ChatView(chat: chat)
            } else {
                // Agents start only on request: an idle workspace spawns no process (spec Section 1).
                ContentUnavailableView {
                    Label("\(agent.displayName) is not running", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("Start \(agent.displayName)") { Task { await start() } }
                        .disabled(starting)
                }
            }
        }
        .onAppear {
            if let existing = model.existingChat(workspaceId: workspace.id) {
                chat = existing
                agent = existing.agent
            }
        }
    }

    private func start() async {
        starting = true
        chat = await model.openChat(workspace: workspace, agent: agent)
        starting = false
    }
}
```

`Sources/RockyUI/ChatView.swift`:

```swift
import RockyKit
import SwiftUI

struct ChatView: View {
    let chat: ChatSessionModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.items) { item in
                            ChatItemRow(item: item).id(item.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: chat.items.last?.text) {
                    if let id = chat.items.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            footer
        }
        .onAppear { chat.isVisible = true }
        .onDisappear { chat.isVisible = false }
        .sheet(isPresented: Binding(
            get: { chat.pendingPermission != nil },
            set: { if !$0 { chat.answerPermission(optionId: nil) } }
        )) {
            if let request = chat.pendingPermission {
                PermissionSheet(request: request) { chat.answerPermission(optionId: $0) }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch chat.state {
        case .stopped(let reason):
            HStack {
                Text(reason).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Restart") { Task { await chat.start() } }
            }
            .padding()
        case .idle, .starting:
            ProgressView("Starting \(chat.agent.displayName)…").padding()
        case .ready, .running:
            HStack(alignment: .bottom) {
                TextField("Message \(chat.agent.displayName)", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                if chat.state == .running {
                    Button("Stop") { Task { await chat.cancel() } }
                } else {
                    Button("Send", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, chat.state == .ready else { return }
        draft = ""
        Task { await chat.send(text) }
    }
}

struct ChatItemRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            Text(item.text)
                .textSelection(.enabled)
                .padding(10)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            Text(Self.markdown(item.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            Text(item.text)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label {
                Text(item.text) + Text(item.status.map { "  \($0)" } ?? "").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: toolIcon)
            }
            .font(.callout)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var toolIcon: String {
        switch item.status {
        case "completed": "checkmark.circle"
        case "failed": "xmark.circle"
        default: "hammer"
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct PermissionSheet: View {
    let request: PermissionRequest
    let answer: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permission needed").font(.headline)
            Text(request.title).textSelection(.enabled)
            HStack {
                Button("Cancel") { answer(nil) }
                Spacer()
                ForEach(request.options) { option in
                    if option.kind.hasPrefix("allow") {
                        Button(option.name) { answer(option.id) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(option.name) { answer(option.id) }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
```

- [ ] **Step 3: Write the app entry point**

`Sources/Rocky/RockyApp.swift`:

```swift
import AppKit
import RockyKit
import RockyUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed under `swift run` (no bundle); harmless inside Rocky.app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Stops every agent before quitting, so no agent process keeps running (and using energy) after Rocky.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.stopAllAgents()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct RockyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = RockyApp.makeModel()

    var body: some Scene {
        WindowGroup("Rocky") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
        }
    }

    @MainActor
    private static func makeModel() -> AppModel {
        do {
            let paths = try RockyPaths.standard()
            return AppModel(store: try RockyStore(path: paths.database.path), paths: paths)
        } catch {
            fatalError("Rocky could not open its database: \(error)")
        }
    }
}
```

- [ ] **Step 4: Write the bundle files**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Rocky</string>
    <key>CFBundleIdentifier</key>
    <string>dev.jhzl.rocky</string>
    <key>CFBundleName</key>
    <string>Rocky</string>
    <key>CFBundleDisplayName</key>
    <string>Rocky</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
```

`scripts/make-app.sh`:

```bash
#!/bin/bash
# Builds build/Rocky.app from the SwiftPM product and signs it ad hoc.
# The bundle id (dev.jhzl.rocky) is what the macOS power log attributes energy to.
# Usage: scripts/make-app.sh [release|debug]
set -euo pipefail
config="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
swift build -c "$config" --product Rocky --package-path "$root"
bin_dir="$(swift build -c "$config" --product Rocky --package-path "$root" --show-bin-path)"
app="$root/build/Rocky.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Rocky" "$app/Contents/MacOS/Rocky"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "$app"
```

```bash
chmod +x scripts/make-app.sh
```

- [ ] **Step 5: Commit**

```bash
git add Sources Resources scripts/make-app.sh
git commit -m "feat(app): add swiftui app for workspaces and chat"
```

---

### Task 11: Energy report and README

**Files:**
- Create: `scripts/energy-report.sh`, `README.md`

**Interfaces:**
- Consumes: the bundle id `dev.jhzl.rocky` (Task 10).
- Produces: `scripts/energy-report.sh [minutes] [bundle-id]`, used by Task 12.

- [ ] **Step 1: Write the energy report script**

`scripts/energy-report.sh`:

```bash
#!/bin/bash
# Energy and processes started over the last N minutes, per app, from the macOS power log. Read-only.
# Compares Rocky with Conductor. The log flushes lazily: the last few minutes may be missing.
# Usage: scripts/energy-report.sh [minutes=30] [bundle-id=dev.jhzl.rocky]
set -euo pipefail
minutes="${1:-30}"
bundle="${2:-dev.jhzl.rocky}"
db="file:/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL?mode=ro"
end=$(date +%s)
start=$((end - minutes * 60))
# energy and cpu_time are per interval (summed); tasks_started is cumulative (max - min).
sqlite3 -readonly -column -header "$db" "
SELECT BundleId AS app,
       ROUND(SUM(energy) / 1e9, 1) AS energy,
       ROUND(SUM(cpu_time), 1) AS cpu_s,
       MAX(tasks_started) - MIN(tasks_started) AS processes_started,
       ROUND((MAX(tasks_started) - MIN(tasks_started)) * 1.0 / $minutes, 1) AS processes_per_min
FROM PLCoalitionAgent_EventInterval_CoalitionInterval
WHERE BundleId IN ('$bundle', 'com.conductor.app') AND timestamp BETWEEN $start AND $end
GROUP BY BundleId;"
```

```bash
chmod +x scripts/energy-report.sh
```

- [ ] **Step 2: Write the README**

`README.md`:

````markdown
# Rocky

Personal macOS app for running coding agents (Claude Code, OpenCode) in parallel, one git worktree per workspace.
Design: `docs/superpowers/specs/2026-09-22-rocky-design.md`.

## Build and run

    swift test                     # logic tests
    scripts/make-app.sh            # builds build/Rocky.app (release)
    open build/Rocky.app

Requirements: Xcode 27, `git`, `node` + `npm` (Claude adapter), `opencode` on your login-shell PATH.
The Claude adapter (`@agentclientprotocol/claude-agent-acp@0.81.0`) installs itself on first use into
`~/Library/Application Support/Rocky/agents`. Agent logs: `~/Library/Logs/Rocky`.

## Energy

    scripts/energy-report.sh 30    # Rocky vs Conductor over the last 30 minutes, from the macOS power log
````

- [ ] **Step 3: Commit**

```bash
git add scripts/energy-report.sh README.md
git commit -m "docs(m1): add readme and energy report"
```

---

### Task 12: Build, tests and M1 verification

This is the only task that compiles or runs tests. It runs once all the code of Tasks 1–11 is committed, right before the merge into `development`.

**Files:**
- Modify: whatever the build or the tests show broken in Tasks 1–11, in the smallest way that keeps each task's interfaces and tests.
- Create: `docs/superpowers/m1-verification.md`

**Interfaces:**
- Consumes: everything from Tasks 1–11.
- Produces: a passing `swift test`, `build/Rocky.app`, and the verification record for M1.

- [ ] **Step 1: Build and run the whole suite**

Run: `swift build && swift test`
Expected: `Build complete!`, then every suite passes, 0 failures. Tasks 9–11 never compiled, so build errors there are expected. Fix each one in the smallest way that keeps the task's interfaces and tests, commit the fix with the scope of the task it belongs to (for example `fix(kit): ...`), and run this step again until it passes.

- [ ] **Step 2: Run the chat model tests three times**

Run: `for i in 1 2 3; do swift test --filter ChatSessionModelTests 2>&1 | rg "✘|Suite ChatSessionModelTests"; done`
Expected: three `Suite ChatSessionModelTests passed` lines and no `✘`. Three runs catch ordering flakiness between notifications and responses.

- [ ] **Step 3: Build the app bundle and open it**

Run: `scripts/make-app.sh && open build/Rocky.app`
Expected: the script prints `.../build/Rocky.app`; a "Rocky" window opens with the empty state "No workspace selected" and a `+` (Add Repository) toolbar button. Quit with ⌘Q.

- [ ] **Step 4: Run the manual checklist with real agents**

The user runs this step. Use a personal repo only: `~/Documents/dev/personal/rocky` itself. Never a repo under `~/Documents/dev/celes`.

1. `open build/Rocky.app`, press `+`, choose `~/Documents/dev/personal/rocky`. Expected: a "rocky" section appears in the sidebar.
2. From the "rocky" section menu choose "New Workspace". Expected: a city-named workspace appears and is selected; `eza ~/Documents/dev/personal/rocky-worktrees` lists it; `git -C ~/Documents/dev/personal/rocky branch --list 'rocky/*'` shows its branch.
3. Pick "OpenCode", press "Start OpenCode", send `Run printenv HOME and reply with only its output`. Expected: a permission sheet (or none if OpenCode auto-allows), then the agent's reply with your home path.
4. Switch to "Claude Code", press Start. Expected on first use: "Installing the Claude adapter (one time)…", then a ready chat. Send the same prompt and allow the permission. Expected: reply with your home path.
5. In the repo menu choose "Settings…", pick `~/.claude-rentek` (or any instance listed), Save; select the workspace, switch agent away and back, Start Claude again, send `Run printenv CLAUDE_CONFIG_DIR and reply with only its output`. Expected: the chosen instance path.
6. Quit Rocky with ⌘Q while Claude is idle, then run `pgrep -fl "claude-agent-acp|opencode acp"`. Expected: no output (Review Focus 1).
7. Reopen Rocky, select the workspace, pick Claude, Start. Expected: the earlier transcript is shown and the agent continues the same conversation (ask `What did I ask you before?`).
8. Right-click the workspace → "Remove Workspace…" → "Remove Worktree". Expected: the folder is gone and the `rocky/<name>` branch still exists. Then delete the branch yourself if you do not need it: `git -C ~/Documents/dev/personal/rocky branch -D rocky/<name>`.

- [ ] **Step 5: Measure energy at rest**

The user runs this step. Leave Rocky open with one workspace and no agent running for 30 minutes (on battery if possible), then run `scripts/energy-report.sh 30`.
Expected: the `dev.jhzl.rocky` row shows `processes_per_min` below 5 (spec Section 1 success criterion). If the row is missing, the power log has not flushed yet: wait 10 minutes and run it again.

- [ ] **Step 6: Record the results**

Write `docs/superpowers/m1-verification.md` with: the date, the `swift test` summary line from Step 1, the result of each checklist item (pass/fail plus the literal output for items 2, 5 and 6), and the literal `scripts/energy-report.sh 30` output. Any failure goes in a "Known issues" list with the exact error text.

If Steps 3–5 led to a code fix, run Steps 1 and 2 again before this step and record the new summary line.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/m1-verification.md
git commit -m "docs(m1): add verification record"
```

- [ ] **Step 8: Merge into development**

Only after the user approves it. With no remote this merge takes the place of the PR.

```bash
git switch development
git merge --ff-only feat/m1-workspaces-chat
```
