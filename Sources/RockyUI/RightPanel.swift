import AppKit
import RockyKit
import SwiftUI

/// Where the right panel's state is kept (PNL-01): its open state, global and shared by the panel toggle (PNL-02) and
/// View ▸ Show Pull Request Panel (⌥⌘B, KBD-03), and its width. Neither follows the zoom.
public enum RightPanelStorage {
    public static let openKey = "rightPanelOpen"
    static let widthKey = "rightPanelWidth"
    /// PNL-01: 350 wide, dragged between 280 and 480.
    static let defaultWidth = 350.0
    static let widthRange: ClosedRange<Double> = 280...480
}

/// PNL-01: the workspace's pull request, in a full-height column at the window's right beside the conversation column
/// (LAY-01), on the sidebar's color. From the top: the header in the title bar row (HDR-01), the tab row (PNL-03) in
/// line with the conversation's, ERR-01's and PR-05's lines, the tab, which scrolls, and the footer (PR-07), in line
/// with the terminal bar and the sidebar footer. One right panel only: M3's Changes becomes one of its tabs.
struct RightPanel: View {
    let model: AppModel
    let workspace: Workspace

    private var panel: PullRequestPanelState {
        model.pullRequests.panels[workspace.id] ?? PullRequestPanelState()
    }

    private var tab: RightPanelTab {
        model.rightPanelTabs[workspace.id] ?? .checks
    }

    var body: some View {
        let panel = self.panel
        VStack(spacing: 0) {
            PullRequestHeaderBar(model: model, workspace: workspace)
            RightPanelTabRow(selection: tab) { model.rightPanelTabs[workspace.id] = $0 }
            // Under the tab row, not the header, so the tab row stays in line with the conversation's (LAY-01).
            if let error = panel.error {
                PanelErrorLine(error: error, isLoading: panel.isLoading) {
                    Task { await model.pullRequests.refresh(workspaceId: workspace.id, reason: .button) }
                }
            }
            if let failure = model.mergeErrors[workspace.id] {
                MergeErrorLine(text: failure) { model.dismissMergeError(workspaceId: workspace.id) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if panel.error == .accessRequired {
                        GitHubLoginNote()
                    }
                    switch tab {
                    case .checks:
                        ChecksTab(model: model, workspace: workspace)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            RightPanelFooter(model: model, workspace: workspace)
        }
        // Only the panel's own bounds, which start at the window's top (LAY-01): a color background reaches into the
        // safe area by default, and in the first build it painted over the top bar's controls.
        .background(Color.rockySidebar, ignoresSafeAreaEdges: [])
        // REV-01: comments are read with the pull request only while the panel shows them, and Checks, where they
        // are, is its only tab. The panel of the workspace left behind goes away with it.
        .onAppear { model.pullRequests.setCommentsVisible(true, workspaceId: workspace.id) }
        .onDisappear { model.pullRequests.setCommentsVisible(false, workspaceId: workspace.id) }
    }
}

/// ERR-01: what went wrong, under the header (12, `danger`), with Retry. GitHub's own detail when there is one;
/// offline keeps polling, so its line only offers Retry.
private struct PanelErrorLine: View {
    let error: PanelError
    let isLoading: Bool
    let retry: () -> Void

    private var text: String? {
        switch error {
        case .couldNotLoad(let detail): detail
        case .accessRequired: "Rocky has no GitHub token for this repository's account."
        case .unavailable: "origin is not on github.com, or this account cannot see the repository."
        case .offline: nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let text {
                Text(text)
                    .font(.rocky(12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button("Retry", action: retry)
                .font(.rocky(12))
                .buttonStyle(RockyTextButtonStyle(height: 22))
                .disabled(isLoading)
                .help("Ask GitHub again")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// PR-05: why GitHub refused the merge, under the header like ERR-01's line (12, `danger`), with × to hide it. The
/// next merge or another method hides it too.
private struct MergeErrorLine: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.rocky(12))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .font(.rocky(10, weight: .semibold))
                .buttonStyle(RockyIconButtonStyle(size: 22))
                .help("Dismiss")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ERR-01, ACC-01: without access, the tab says how to give Rocky an account, with the command to copy.
private struct GitHubLoginNote: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rocky reads GitHub with gh's account for this repository. Log in from a terminal, then Retry:")
                .font(.rocky(12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(verbatim: GitHubAccountError.loginCommand)
                    .font(.rocky(12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(GitHubAccountError.loginCommand, forType: .string)
                    copied = true
                }
                .font(.rocky(11))
                .buttonStyle(RockyIconButtonStyle(size: 22))
                .help("Copy the command")
            }
            .padding(.leading, 8)
            .padding(.trailing, 2)
            .padding(.vertical, 2)
            .background(Theme.fillControl, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// PNL-03: Conductor's pill tabs, 4 apart, drawn from `RightPanelTab.allCases` (Checks alone in M2.7), in a 34-point
/// row with 8 points at its sides and the hairline at its bottom, like the conversation's tab row (`ConversationTabs`),
/// so their lines are one line across the window (LAY-01).
private struct RightPanelTabRow: View {
    let selection: RightPanelTab
    let select: (RightPanelTab) -> Void

    var body: some View {
        let tabs = RightPanelTab.allCases
        HStack(spacing: 4) {
            if tabs.count == 1, let only = tabs.first {
                // One tab has nothing to switch to, and a lone pill read as a button that did nothing (user
                // feedback, 2026-09-24): it is the section's title until M3 adds Changes. Aligned with the content.
                Text(only.title)
                    .font(.rocky(12.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 10)
                    .accessibilityAddTraits(.isHeader)
            } else {
                ForEach(tabs, id: \.self) { tab in
                    RightPanelTabButton(title: tab.title, isSelected: tab == selection) { select(tab) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Zoom.shared(34))
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

/// One pill of PNL-03: 26 points, radius 6, 12.5 `textSecondary`; `fillHover` on hover; `fillSelected` and
/// `textPrimary` when selected.
private struct RightPanelTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.rocky(12.5))
                .foregroundStyle(isSelected || hovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: Zoom.shared(26))
                .background(
                    isSelected ? Theme.fillSelected : hovering ? Theme.fillHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// PR-07's footer: the repository's account (ACC-01) and when the panel last heard from GitHub. No refresh button: the
/// panel refreshes every 30 s while the window can be seen, and ERR-01's line keeps Retry (user decision,
/// 2026-09-24). Drawn like the sidebar's footer: the terminal panel bar's height plus the 1 point of the line above
/// that bar (`PanelDivider`), with the line on top, so the three lines are one line across the window (user report,
/// 2026-09-23: with the line inside the bar's height it sat 1 point lower). The time ticks every 10 s, and only while
/// the window can be seen.
private struct RightPanelFooter: View {
    let model: AppModel
    let workspace: Workspace
    @Environment(\.windowIsVisible) private var windowIsVisible

    var body: some View {
        let panel = model.pullRequests.panels[workspace.id] ?? PullRequestPanelState()
        HStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: 10, paused: !windowIsVisible || panel.updatedAt == nil)) { context in
                Text(panel.footerText(now: context.date))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // The footer spans the panel, so its line on top does too.
            Spacer(minLength: 0)
        }
        .font(.rocky(11.5))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 18)
        .frame(height: Zoom.shared(WindowMetrics.bottomBarHeight) + 1)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

/// PNL-02: the panel toggle, a 28-point `sidebar.right` icon button lit with `fillSelected` while the panel is open. It
/// is always the title bar row's last control, at the window's top-right corner: the panel header's while the panel is
/// open, the top bar's once it is closed (LAY-01). It shares the open state with View ▸ Show / Hide Pull Request Panel
/// (⌥⌘B, KBD-03) through `RightPanelStorage.openKey`.
struct RightPanelToggle: View {
    @AppStorage(RightPanelStorage.openKey) private var isOpen = true

    var body: some View {
        Button(PanelToggleText.pullRequestPanelAccessibilityLabel(isOpen: isOpen), systemImage: "sidebar.right") {
            isOpen.toggle()
        }
        .buttonStyle(RockyIconButtonStyle(isOn: isOpen))
        .font(.rocky(15))
        .help(PanelToggleText.pullRequestPanelTooltip(isOpen: isOpen))
    }
}

extension HeaderGroup {
    /// HDR-01: the label's color.
    var tone: Color {
        switch self {
        case .inSync: Theme.success
        case .outOfSync, .noPR: Theme.textPrimary
        case .queued: Theme.attention
        case .merged: Theme.merged
        case .loading: Theme.textTertiary
        }
    }

    /// HDR-01: the header's tint over the panel's color. Problems stay neutral, as in Conductor; the red lives in the
    /// check and dot icons.
    var tint: Color {
        switch self {
        case .inSync: Theme.success.opacity(0.13)
        case .outOfSync: Color.white.opacity(0.05)
        case .queued: Theme.attention.opacity(0.12)
        case .merged: Theme.merged.opacity(0.13)
        case .noPR, .loading: Color.clear
        }
    }
}

extension View {
    /// A tooltip only when there is something to say, such as why a button is disabled (AGT-00).
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
