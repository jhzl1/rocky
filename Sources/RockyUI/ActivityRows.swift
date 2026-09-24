import RockyKit
import SwiftUI

/// How a tool call reads in the conversation, like Conductor's activity rows: an icon for its kind, a short label
/// ("Read image", "Run", "Load skill") and its detail as a badge. The files it touches get badges of their own.
struct ToolSummary {
    let symbol: String
    let label: String
    let detail: String?
    let isCommand: Bool

    init(item: ChatItem) {
        let title = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = item.toolKind
        symbol = Self.symbol(kind: kind, title: title)
        if kind == ACPProtocol.questionToolKind {
            // Claude's AskUserQuestion: the question itself was answered in its card.
            label = "User input"
            detail = nil
            isCommand = false
            return
        }
        if kind == "execute" {
            // Claude's adapter titles a command with the command itself.
            label = "Run"
            detail = title.isEmpty || title == "Terminal" ? nil : Self.firstLine(title)
            isCommand = true
            return
        }
        isCommand = false
        if !item.attachments.isEmpty, let stripped = Self.labelWithoutPaths(title, paths: item.attachments, kind: kind) {
            let readsImage = kind == "read" && item.attachments.contains { FileKind(path: $0) == .image }
            label = stripped == "Read" && readsImage ? "Read image" : stripped
            detail = nil
            return
        }
        if let colon = title.range(of: ": ") {
            label = String(title[..<colon.lowerBound])
            detail = Self.firstLine(String(title[colon.upperBound...]))
            return
        }
        if kind == "fetch", let space = title.firstIndex(of: " ") {
            label = String(title[..<space])
            detail = String(title[title.index(after: space)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return
        }
        label = title.isEmpty ? "Tool call" : Self.firstLine(title)
        detail = nil
    }

    /// "Read Sources/App.swift (1 - 20)" becomes "Read" when App.swift has its own badge.
    static func labelWithoutPaths(_ title: String, paths: [String], kind: String?) -> String? {
        for path in paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard !name.isEmpty, let nameRange = title.range(of: name, options: .backwards) else { continue }
            // The path starts after the last space or backtick before the file name.
            let head = title[..<nameRange.lowerBound]
            let start = head.lastIndex { $0 == " " || $0 == "`" }.map { title.index(after: $0) } ?? title.startIndex
            let label = title[..<start].trimmingCharacters(in: CharacterSet(charactersIn: " `"))
            if !label.isEmpty { return label }
            return switch kind {
            case "read": "Read"
            case "edit": "Edit"
            case "delete": "Delete"
            case "search": "Search"
            default: nil
            }
        }
        return nil
    }

    static func symbol(kind: String?, title: String) -> String {
        switch kind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.left.arrow.right"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        case "switch_mode": "map"
        case ACPProtocol.questionToolKind: "text.bubble"
        default: title.hasPrefix("Load skill") ? "sparkles" : "wrench.and.screwdriver"
        }
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }
}

/// The icon column every activity row starts with.
struct ActivityIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.rocky(13))
            .foregroundStyle(.secondary)
            .frame(width: Zoom.shared(18))
    }
}

struct ToolCallRow: View {
    let item: ChatItem
    /// The call belongs to the turn in progress, so a pending status means it is still running.
    let isLive: Bool

    /// Running now: the label shimmers (MOT-03) instead of a spinner next to it.
    private var isRunning: Bool {
        isLive && (item.status == "pending" || item.status == "in_progress")
    }

    var body: some View {
        let summary = ToolSummary(item: item)
        HStack(spacing: 8) {
            ActivityIcon(systemImage: summary.symbol)
            ShimmerText(summary.label, isLive: isRunning)
                .lineLimit(1)
                .layoutPriority(1)
            ForEach(item.attachments.prefix(3), id: \.self) { FileBadge(path: $0) }
            if item.attachments.count > 3 {
                DetailBadge(text: "+\(item.attachments.count - 3)")
            }
            if let detail = summary.detail {
                DetailBadge(text: detail, monospaced: summary.isCommand)
            }
            status
        }
        .font(.rocky(13.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        // The full title for a cut command; a row with files has their previews instead.
        .help(item.attachments.isEmpty ? item.text : "")
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case "completed" where item.toolKind == ACPProtocol.questionToolKind:
            DetailBadge(text: "ANSWERED", monospaced: true, systemImage: "checkmark.circle")
        case "failed":
            DetailBadge(text: "FAILED", monospaced: true, tint: Theme.danger, systemImage: "xmark.circle")
        default:
            EmptyView()
        }
    }
}

/// Consecutive tool calls folded into one row, like Conductor's "2 tool calls"; click to see each one.
struct ToolGroupRow: View {
    let tools: [ChatItem]
    let isLive: Bool
    @State private var expanded = false

    private var title: String {
        let failed = tools.filter { $0.status == "failed" }.count
        return "\(tools.count) tool calls" + (failed > 0 ? " · \(failed) failed" : "")
    }

    /// The distinct labels of the calls, in order: "Read, Edit, Run".
    private var overview: String {
        var labels: [String] = []
        for label in tools.map({ ToolSummary(item: $0).label }) where !labels.contains(label) {
            labels.append(label)
        }
        return labels.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    ActivityIcon(systemImage: "square.stack.3d.up")
                    // Its title shimmers while one of its calls runs (MOT-03).
                    ShimmerText(title, isLive: isLive && tools.contains { $0.status == "pending" || $0.status == "in_progress" })
                        .layoutPriority(1)
                    if !expanded { DetailBadge(text: overview) }
                    Image(systemName: "chevron.right")
                        .font(.rocky(10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tools) { ToolCallRow(item: $0, isLive: isLive) }
                }
                .padding(.leading, 26)
            }
        }
        .font(.rocky(13.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The agent's thinking: "Thinking" and its first line as a badge, like Conductor's; click to read all of it.
struct ThoughtRow: View {
    let item: ChatItem
    @State private var expanded = false

    private var preview: String? {
        let line = item.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*_#")) }
        return line?.isEmpty == false ? line : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    ActivityIcon(systemImage: "brain")
                    Text("Thinking").layoutPriority(1)
                    if !expanded, let preview { DetailBadge(text: preview) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
            .help(expanded ? "Hide the thinking" : "Show the thinking")
            if expanded {
                Text(item.text)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 26)
            }
        }
        .font(.rocky(13.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sent command (CMD-06): "/name" as a chip, accent text on accent at 14 %, then its arguments as ordinary text,
/// with their files as badges.
struct CommandMessageText: View {
    let item: ChatItem
    let command: String

    /// What follows "/name", without the space between them.
    private var arguments: String {
        String(item.text.dropFirst(command.count + 1).drop(while: \.isWhitespace))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "/" + command)
                .font(.rocky(12.5, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 7)
                .frame(height: Zoom.shared(22))
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
            if item.attachments.isEmpty {
                if !arguments.isEmpty { Text(arguments).textSelection(.enabled) }
            } else {
                InlineFilesText(text: arguments, files: item.attachments)
            }
        }
    }
}

/// The user's message on the right. Its files sit inside the text as badges, where they were written, as in
/// Conductor. A message that runs one of the agent's commands starts with its chip.
struct UserMessageRow: View {
    let item: ChatItem
    var command: String?

    var body: some View {
        Group {
            if let command {
                CommandMessageText(item: item, command: command)
            } else if item.attachments.isEmpty {
                Text(item.text).textSelection(.enabled)
            } else {
                InlineFilesText(text: item.text, files: item.attachments)
            }
        }
        .lineSpacing(3)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: Zoom.shared(620), alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// At the end of the conversation while the agent works (MOT-03): "Working", shimmering, and how long the turn has
/// run. Not "Thinking", which is the label of the agent's thoughts (`ThoughtRow`).
struct WorkingRow: View {
    let startedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            ShimmerText("Working")
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    // In the code font, so the time reads apart from the label (user decision, 2026-09-23).
                    Text(verbatim: Self.elapsed(from: startedAt, to: context.date))
                        .font(.rocky(12, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "8s", then "1m 5s".
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
