import AppKit
import RockyKit
import SwiftUI

/// The slash command popup's state (CMD-03, CMD-04), owned by `ComposerController` and updated on every text or
/// selection change of the message box. The text view keeps the keyboard: it hands ↑, ↓, Return, Tab and Esc here
/// while the popup is open.
@MainActor
@Observable
final class SlashCommandPopupModel {
    enum Choice: Equatable {
        /// Run it now: the first token becomes "/name" and the message is sent.
        case send(String)
        /// The first token becomes "/name ", with the caret after the space and the hint as ghost text.
        case complete(String, hint: String?)
    }

    private(set) var isOpen = false
    /// The text between the "/" and the caret (KIT-02).
    private(set) var query = ""
    private(set) var matches: [SlashCommandFilter.Match] = []
    private(set) var selection = 0
    /// Every command the popup filters, and whether they are the conversation's own list or the last list of its
    /// repository and agent (CMD-05).
    private(set) var commands: [SlashCommand] = []
    private(set) var confirmed = false
    /// The first token Esc closed the popup on: it stays closed until the token changes.
    @ObservationIgnored private(set) var dismissedToken: String?
    /// The command VoiceOver last heard about, so the same selection is not announced twice (A11Y-02).
    @ObservationIgnored private var announcedName: String?

    var selectedCommand: SlashCommand? {
        matches.indices.contains(selection) ? matches[selection].command : nil
    }

    func update(text: String, caret: Int, firstIsAttachment: Bool, commands: [SlashCommand], confirmed: Bool) {
        let token = Self.firstToken(of: text)
        if dismissedToken != nil, dismissedToken != token { dismissedToken = nil }
        guard dismissedToken == nil,
              let query = SlashQuery.parse(text: text, caret: caret, firstIsAttachment: firstIsAttachment) else {
            return close()
        }
        // A new query selects the first row (CMD-01); a new list for the same query keeps the selected command when
        // it is still there (CMD-05).
        let isNewQuery = !isOpen || query != self.query
        let previous = selectedCommand?.name
        let ranked = SlashCommandFilter.matches(commands, query: query)
        assign(\.commands, commands)
        assign(\.confirmed, confirmed)
        assign(\.query, query)
        assign(\.matches, ranked)
        assign(\.selection, isNewQuery ? 0 : ranked.firstIndex { $0.command.name == previous } ?? 0)
        assign(\.isOpen, true)
        announceSelection()
    }

    /// ↑ and ↓, wrapping at both ends.
    func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selection = ((selection + delta) % matches.count + matches.count) % matches.count
        announceSelection()
    }

    /// The row under the pointer.
    func select(_ index: Int) {
        guard matches.indices.contains(index), index != selection else { return }
        selection = index
        announceSelection()
    }

    /// Return runs a command that takes no input and completes one that does; Tab always completes (CMD-04). nil
    /// when nothing is selected: Return then sends the text as typed.
    func choose(isReturn: Bool) -> Choice? {
        guard isOpen, let command = selectedCommand else { return nil }
        if isReturn, command.inputHint == nil { return .send(command.name) }
        return .complete(command.name, hint: command.inputHint)
    }

    /// Esc: closed until the first token changes.
    func dismiss(text: String) {
        dismissedToken = Self.firstToken(of: text)
        close()
    }

    /// The "+" menu's Commands opens the popup even on a token Esc closed it on (CMD-07).
    func allowReopening() {
        dismissedToken = nil
    }

    private func close() {
        assign(\.isOpen, false)
        announcedName = nil
    }

    /// The text's first token when it starts with "/", else nil.
    private static func firstToken(of text: String) -> String? {
        SlashQuery.tokenRange(in: text).map { String(decoding: text.utf16.prefix($0.upperBound), as: UTF16.self) }
    }

    /// Writes only a changed value: `update` runs on every keystroke and caret move, and each write redraws the
    /// views that read it.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SlashCommandPopupModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// A11Y-02: VoiceOver reads the selected command as "/name, description" while the focus stays in the text view.
    private func announceSelection() {
        guard isOpen, let command = selectedCommand, command.name != announcedName else { return }
        announcedName = command.name
        guard NSWorkspace.shared.isVoiceOverEnabled, let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        let announcement = command.description.isEmpty ? "/\(command.name)" : "/\(command.name), \(command.description)"
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: announcement,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// The popup over the message box (CMD-01): as wide as the box, 8 points above its top edge, growing upward. An
/// overlay, not a window, so the text view keeps the keyboard. It appears in 120 ms, fading in as it rises 4 points;
/// with Reduce Motion it only fades.
struct SlashCommandPopup: View {
    let popup: SlashCommandPopupModel
    let agent: AgentKind
    /// A click on a row: Return on it.
    let onChoose: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if popup.isOpen {
                panel.transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.12), value: popup.isOpen)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .frame(maxWidth: .infinity)
        // Like Rocky's menus (`MenuPanel`): the panel color, a hairline ring and their shadow.
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    /// CMD-05's states, then the list.
    @ViewBuilder
    private var content: some View {
        if popup.commands.isEmpty && !popup.confirmed {
            stateRow {
                CircularProgress(size: Zoom.shared(13))
                Text(verbatim: "Starting \(agent.displayName)…")
            }
        } else if popup.commands.isEmpty {
            stateRow { Text(verbatim: "\(agent.displayName) has no commands here.") }
        } else if popup.matches.isEmpty {
            stateRow { Text(verbatim: "No commands match “\(popup.query)”. Return sends it as a message.") }
        } else {
            SlashCommandList(popup: popup, onChoose: onChoose)
        }
    }

    private func stateRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10, content: content)
            .font(.rocky(12.5))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: Zoom.shared(44), alignment: .leading)
    }

    /// The keys, and on the right the agent and how many commands it announced.
    private var footer: some View {
        HStack(spacing: 12) {
            Text(verbatim: "↑↓ navigate · Return run · Tab complete · Esc close")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(verbatim: count)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .font(.rocky(11))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 12)
        .frame(height: Zoom.shared(28))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .accessibilityHidden(true)
    }

    private var count: String {
        let name = agent.displayName
        if popup.confirmed { return "\(name) · \(popup.commands.count)" }
        return popup.commands.isEmpty ? name : "\(name) · \(popup.commands.count) · from the last session"
    }
}

/// The popup's rows: 32 points each in a 4-point inset, at most 8 visible, then it scrolls, keeping the selected
/// row in view (CMD-01). Lazy: the rows have a fixed height, so nothing is estimated, and a user with hundreds of
/// skills does not build hundreds of rows per keystroke.
private struct SlashCommandList: View {
    let popup: SlashCommandPopupModel
    let onChoose: (Int) -> Void
    /// Where the pointer last was: rows sliding under a pointer that did not move (the list scrolled to the
    /// selection, or opened under it) do not take the selection.
    @State private var pointer: CGPoint?

    private static let visibleRows = 8
    private static let inset: CGFloat = 4

    var body: some View {
        let rowHeight = Zoom.shared(32)
        let height = CGFloat(min(popup.matches.count, Self.visibleRows)) * rowHeight + Self.inset * 2
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(popup.matches.enumerated()), id: \.element.command.id) { index, match in
                        SlashCommandRow(match: match, isSelected: index == popup.selection, height: rowHeight)
                            .id(match.command.id)
                            .onContinuousHover(coordinateSpace: .global) { hover($0, index: index) }
                            .onTapGesture { onChoose(index) }
                    }
                }
                .padding(Self.inset)
            }
            .scrollIndicators(popup.matches.count > Self.visibleRows ? .automatic : .never)
            // The conversation's scroll view anchors at the bottom, and the popup, floating in its inset, inherits
            // that: it opened on the end of the list. The best match is at the top.
            .defaultScrollAnchor(.top)
            .frame(height: height)
            .onChange(of: popup.selection) { reveal(in: proxy) }
            .onChange(of: popup.query) { reveal(in: proxy) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    /// Scrolls the least that shows the selected row.
    private func reveal(in proxy: ScrollViewProxy) {
        guard let id = popup.selectedCommand?.id else { return }
        proxy.scrollTo(id)
    }

    private func hover(_ phase: HoverPhase, index: Int) {
        guard case .active(let location) = phase else { return }
        defer { pointer = location }
        guard let pointer, pointer != location else { return }
        popup.select(index)
    }
}

/// One command (CMD-02): "/name" with the matched part in accent, the hint, the description on the right, and an
/// "MCP" tag for an MCP prompt, whose name shows without its "mcp:" prefix. The whole row is the click target, with
/// the pointing hand; the tooltip holds the full description.
private struct SlashCommandRow: View {
    let match: SlashCommandFilter.Match
    let isSelected: Bool
    let height: CGFloat

    private var command: SlashCommand { match.command }

    var body: some View {
        HStack(spacing: 10) {
            name
                .font(.rocky(13, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(2)
            if let hint = command.inputHint {
                CappedWidth(width: Zoom.shared(200)) {
                    Text(verbatim: hint)
                        .font(.rocky(12, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
            }
            Text(verbatim: command.description)
                .font(.rocky(12.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if command.isMCP {
                Text(verbatim: "MCP")
                    .font(.rocky(9.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 5)
                    .frame(height: Zoom.shared(16))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(isSelected ? Theme.fillSelected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .clickable()
        .help(command.description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.description.isEmpty ? "/\(command.name)" : "/\(command.name), \(command.description)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The shown name, with the part that matched the query in accent (tiers 1 to 3 of KIT-03).
    private var name: Text {
        let shown = Array(command.isMCP ? String(command.name.dropFirst(SlashCommand.mcpPrefix.count)) : command.name)
        let dropped = command.name.count - shown.count
        guard let range = match.nameRange else { return Text(verbatim: "/" + String(shown)) }
        let lower = min(max(range.lowerBound - dropped, 0), shown.count)
        let upper = min(max(range.upperBound - dropped, lower), shown.count)
        return Text(verbatim: "/" + String(shown[..<lower]))
            + Text(verbatim: String(shown[lower..<upper])).foregroundStyle(Theme.accent)
            + Text(verbatim: String(shown[upper...]))
    }
}

/// Offers its content at most `width` and takes the content's own size: a short hint stays short, a long one
/// truncates at `width`. A `frame(maxWidth:)` would take the whole `width` whatever the hint's length.
private struct CappedWidth: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let offered = ProposedViewSize(width: min(proposal.width ?? width, width), height: proposal.height)
        return subviews.first?.sizeThatFits(offered) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
