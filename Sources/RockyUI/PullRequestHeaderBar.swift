import AppKit
import RockyKit
import SwiftUI

/// HDR-01: the panel's header, in the title bar row beside the conversation's top bar (LAY-01) and as tall as it
/// (`WindowMetrics.titleRowHeight`), tinted by the state's group, with no line under it: the tint marks it, and the
/// next line is the tab rows' (PNL-03). The pull request's pill (HDR-03), the state's label (HDR-02, ERR-01), which
/// truncates and carries its full text as its tooltip, one action that never shrinks, then the panel toggle (PNL-02),
/// 12 points from the window's edge like the top bar's. Its empty space drags the window (PNL-01). A new label slides in
/// from 2 points below as it fades in, and the tint cross-fades, both in 150 ms; neither moves with Reduce Motion.
struct PullRequestHeaderBar: View {
    let model: AppModel
    let workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let header = model.pullRequestHeader(workspaceId: workspace.id)
        let panel = model.pullRequests.panels[workspace.id] ?? PullRequestPanelState()
        HStack(spacing: 8) {
            if let pullRequest = panel.shownPullRequest {
                PullRequestPill(number: pullRequest.number, url: pullRequest.url, group: header.group) {
                    model.rightPanelTabs[workspace.id] = .checks
                }
            }
            ZStack(alignment: .leading) {
                HeaderLabel(header: header)
                    .id(header.label)
                    .transition(
                        reduceMotion
                            ? AnyTransition.identity
                            : AnyTransition.asymmetric(
                                insertion: AnyTransition.opacity.combined(with: AnyTransition.offset(y: 2)),
                                removal: AnyTransition.identity
                            )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .animation(reduceMotion ? nil : Theme.Motion.state, value: header.label)
            PullRequestHeaderAction(model: model, workspace: workspace, header: header, panel: panel)
                .fixedSize()
                .layoutPriority(1)
            RightPanelToggle()
                .layoutPriority(1)
        }
        // Without a pill, the label lines up with the section title and the text under it (18 from the edge).
        .padding(.leading, panel.shownPullRequest == nil ? 18 : 8)
        .padding(.trailing, 12)
        .frame(height: WindowMetrics.titleRowHeight)
        // The row is where the title bar was, as the top bar is.
        .windowDragBackground()
        // Only over the header's own bounds: the panel's column, never the conversation's top bar beside it.
        .background(header.group.tint, ignoresSafeAreaEdges: [])
        .animation(reduceMotion ? nil : Theme.Motion.state, value: header.group)
    }
}

/// HDR-02's label: 13 medium in the group's tone, after a spinner while the state moves; "No pull request" and "No
/// changes yet" in `textTertiary`, regular weight (HDR-04).
private struct HeaderLabel: View {
    let header: HeaderPresentation

    var body: some View {
        HStack(spacing: 6) {
            if header.spins {
                CircularProgress(size: 13, tint: header.group.tone)
            }
            Text(header.label)
                .font(.rocky(13, weight: header.isDim ? .regular : .medium))
                .foregroundStyle(header.isDim ? Theme.textTertiary : header.group.tone)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .optionalHelp(header.label.isEmpty ? nil : header.label)
    }
}

/// HDR-03: two segments in a 24-point outline, radius 5. "#4525" shows the Checks tab, Rocky's view of the pull
/// request, and ⌘-click opens it on GitHub; ↗ opens it on GitHub. Its text and border follow the header: `success` in
/// the in-sync group, `merged` once merged.
struct PullRequestPill: View {
    let number: Int
    let url: URL
    let group: HeaderGroup
    let showChecks: () -> Void

    private var color: Color {
        switch group {
        case .inSync: Theme.success
        case .merged: Theme.merged
        default: Theme.textPrimary
        }
    }

    private var border: Color {
        switch group {
        case .inSync: Theme.success.opacity(0.25)
        case .merged: Theme.merged.opacity(0.3)
        default: Color.white.opacity(0.14)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            PillSegment {
                if NSEvent.modifierFlags.contains(.command) {
                    _ = NSWorkspace.shared.open(url)
                } else {
                    showChecks()
                }
            } label: {
                Text(verbatim: "#\(number)")
                    .padding(.horizontal, 8)
            }
            .help("Show the pull request (⌘-click: open on GitHub)")
            .accessibilityLabel("Pull request \(number)")
            Rectangle().fill(border).frame(width: 1)
            PillSegment {
                _ = NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.rocky(10, weight: .semibold))
                    .padding(.horizontal, 5)
            }
            .help("Open on GitHub")
            .accessibilityLabel("Open on GitHub")
        }
        .font(.rocky(12, weight: .medium))
        .foregroundStyle(color)
        .frame(height: Zoom.shared(24))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border))
        .fixedSize()
    }
}

/// One half of the pill, lit white 6 % on hover.
private struct PillSegment<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxHeight: .infinity)
                .background(hovering ? Theme.fillIconHover : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// HDR-02's last column: the one action of the state. Agent actions are disabled with AGT-00's reason while the
/// conversation cannot take a prompt; Rocky's own (Pull, Push, Ready for review, merge, Archive) spin while they run.
/// Queued shows a static badge (OUT-30), and checks pending, review required and blocked have none.
private struct PullRequestHeaderAction: View {
    let model: AppModel
    let workspace: Workspace
    let header: HeaderPresentation
    let panel: PullRequestPanelState

    private var pullRequest: PullRequestInfo? {
        panel.snapshot?.pullRequest
    }

    var body: some View {
        let availability = model.agentActionAvailability(workspaceId: workspace.id)
        switch header.action {
        case .none:
            EmptyView()
        case .queuedBadge:
            QueuedBadge()
        case .createPR:
            CreatePullRequestButton(model: model, workspace: workspace, availability: availability)
        case .commitAndPush:
            agentButton("Commit and push", availability: availability) { await $0.commitAndPush(workspaceId: $1) }
        case .resolveIncompatible:
            agentButton("Resolve", availability: availability) { await $0.resolveIncompatibility(workspaceId: $1) }
        case .resolveConflicts:
            agentButton("Resolve", availability: availability) { await $0.resolveConflicts(workspaceId: $1) }
        case .fixErrors:
            agentButton("Fix errors", availability: availability, running: model.isRunning(.fixErrors, workspaceId: workspace.id)) {
                await $0.fixFailingChecks(workspaceId: $1)
            }
        case .pull:
            rockyButton("Pull", action: .pull) { await $0.pullBranch(workspaceId: $1) }
        case .push:
            rockyButton("Push", action: .push) { await $0.pushBranch(workspaceId: $1) }
        case .viewChecks:
            Button("View checks") {
                if let pullRequest { _ = NSWorkspace.shared.open(pullRequest.checksURL) }
            }
            .buttonStyle(HeaderButtonStyle())
            .help("Open the pull request's checks on GitHub")
        case .addAllComments:
            // AGT-05: every pending comment; none loaded yet (or all hidden) leaves nothing to send.
            agentButton(
                "Add all comments to chat",
                availability: availability,
                disabledReason: panel.comments.isEmpty ? "No pending comments" : nil
            ) {
                await $0.sendComments(workspaceId: $1, ids: nil)
            }
        case .readyForReview:
            rockyButton("Ready for review", action: .readyForReview, kind: .outline) { await $0.markReadyForReview(workspaceId: $1) }
                .help("Mark the pull request ready for review on GitHub")
        case .merge:
            if let pullRequest, let snapshot = panel.snapshot {
                MergeButton(model: model, workspace: workspace, pullRequest: pullRequest, repository: snapshot.repository)
            }
        case .archive:
            ArchiveButton(model: model, workspace: workspace)
        }
    }

    private func agentButton(
        _ title: String,
        availability: AgentActionAvailability,
        running: Bool = false,
        disabledReason: String? = nil,
        _ run: @escaping @MainActor @Sendable (AppModel, String) async -> Void
    ) -> some View {
        let model = self.model
        let workspaceId = workspace.id
        let reason = availability.reason ?? disabledReason
        return Button {
            Task { await run(model, workspaceId) }
        } label: {
            HeaderButtonLabel(title: title, spins: running, tint: HeaderButtonStyle.Kind.primary.text)
        }
        .buttonStyle(HeaderButtonStyle())
        .disabled(reason != nil || running)
        .optionalHelp(reason)
    }

    private func rockyButton(
        _ title: String,
        action: PullRequestAction,
        kind: HeaderButtonStyle.Kind = .primary,
        _ run: @escaping @MainActor @Sendable (AppModel, String) async -> Void
    ) -> some View {
        let model = self.model
        let workspaceId = workspace.id
        let running = model.isRunning(action, workspaceId: workspaceId)
        return Button {
            Task { await run(model, workspaceId) }
        } label: {
            HeaderButtonLabel(title: title, spins: running, tint: kind.text)
        }
        .buttonStyle(HeaderButtonStyle(kind: kind))
        .disabled(running)
    }
}

/// PR-05's merge button, in the header (HDR-01's merge fill) and in the Git status row "Ready to merge" (a ghost
/// button), which share the workspace's method and its confirmation. Its label is the method's ("Squash", "Merge",
/// "Rebase"); the first click turns it into "Confirm squash" in `attention` for 4 s, the second merges, and while
/// GitHub merges it says "Merging…" with a spinner. With two or three methods allowed, the header's is a split button
/// whose chevron opens Rocky's menu of them; the row's merges with the method picked there.
struct MergeButton: View {
    enum Style {
        case header, row
    }

    let model: AppModel
    let workspace: Workspace
    let pullRequest: PullRequestInfo
    let repository: RepositorySettings
    var style: Style = .header

    var body: some View {
        let model = self.model
        let workspaceId = workspace.id
        let allowed = MergeMethods.available(repository: repository)
        let method = model.mergeMethod(workspaceId: workspaceId) ?? MergeMethods.initial(available: allowed, viewerDefault: repository.viewerDefaultMergeMethod)
        let confirming = model.isConfirmingMerge(workspaceId: workspaceId)
        let merging = model.isRunning(.merge, workspaceId: workspaceId)
        let base = model.pullRequestBase(workspaceId: workspaceId) ?? pullRequest.baseRefName
        let title = merging ? "Merging…" : confirming ? method.confirmTitle : method.buttonTitle
        let press: () -> Void = { Task { await model.confirmOrMerge(workspaceId: workspaceId) } }
        switch style {
        case .header:
            let kind: HeaderButtonStyle.Kind = confirming ? .confirm : .merge
            HStack(spacing: 0) {
                Button {
                    press()
                } label: {
                    HeaderButtonLabel(title: title, spins: merging, tint: kind.text)
                }
                .buttonStyle(HeaderButtonStyle(kind: kind, corners: allowed.count > 1 ? .leading : .all))
                .help(method.tooltip(base: base))
                if allowed.count > 1 {
                    MenuButton(id: "merge-method-\(workspaceId)", placement: .belowTrailing, width: 340) { isOpen in
                        SplitChevron(kind: kind, isOpen: isOpen)
                    } content: {
                        MergeMethodMenu(model: model, workspaceId: workspaceId, methods: allowed, current: method, base: base, canBeRebased: pullRequest.canBeRebased)
                    }
                    .accessibilityLabel("Merge method")
                    .help("Choose how to merge")
                }
            }
            .disabled(merging)
        case .row:
            Button {
                press()
            } label: {
                HStack(spacing: 5) {
                    if merging { CircularProgress(size: 11, tint: Theme.textSecondary) }
                    if confirming {
                        Text(title).foregroundStyle(Theme.attention)
                    } else {
                        Text(title)
                    }
                }
            }
            .font(.rocky(12))
            .buttonStyle(RockyTextButtonStyle(height: 22))
            .disabled(merging)
            .help(method.tooltip(base: base))
        }
    }
}

/// PR-05's menu: one item per method the repository allows, in the order squash, rebase, merge, with its second line
/// and a check on the current one. Rebase is disabled while GitHub cannot rebase the branch cleanly. Picking one keeps
/// it for the workspace until Rocky quits and cancels a confirmation.
private struct MergeMethodMenu: View {
    let model: AppModel
    let workspaceId: String
    let methods: [MergeMethod]
    let current: MergeMethod
    let base: String
    let canBeRebased: Bool

    var body: some View {
        ForEach(methods, id: \.self) { method in
            MenuItem(
                title: method.menuTitle,
                detail: method.menuDetail(base: base),
                isChecked: method == current,
                detailSize: 11.5,
                disabledReason: method == .rebase && !canBeRebased ? "GitHub can't rebase this branch cleanly" : nil
            ) {
                model.setMergeMethod(workspaceId: workspaceId, method)
            }
        }
    }
}

/// PR-06's Archive, in the merged header: today's remove flow at once when the worktree is clean; with uncommitted
/// changes or untracked files, first "tokyo has 3 uncommitted changes. Archive anyway?" (Cancel / Archive), whose
/// Archive stashes them before removing the worktree. The branch, and the one on GitHub, stay.
private struct ArchiveButton: View {
    let model: AppModel
    let workspace: Workspace
    @State private var uncommitted: Int?
    @State private var isChecking = false

    var body: some View {
        let running = model.isRunning(.archive, workspaceId: workspace.id)
        Button {
            Task { await archive() }
        } label: {
            HeaderButtonLabel(title: "Archive", spins: running || isChecking, tint: HeaderButtonStyle.Kind.archive.text)
        }
        .buttonStyle(HeaderButtonStyle(kind: .archive))
        .disabled(running || isChecking)
        .help("Run the archive script and remove the worktree; the branch is kept")
        .rockyDialog(item: $uncommitted) { count in
            let model = self.model
            let workspaceId = workspace.id
            return Dialog(
                title: AppModel.archiveQuestion(workspaceName: workspace.name, uncommitted: count),
                message: "Rocky puts them in a git stash of the repository first, then removes the worktree. The branch \(workspace.branch) is kept.",
                buttons: [
                    .cancel(),
                    .destructive("Archive") {
                        Task { await model.archiveMergedWorkspace(workspaceId: workspaceId, stashingChanges: true) }
                    },
                ]
            )
        }
    }

    /// Asks git how many changes the worktree has now, not the panel's last status.
    private func archive() async {
        isChecking = true
        let count = await model.uncommittedChangeCount(workspaceId: workspace.id)
        isChecking = false
        if let count, count > 0 {
            uncommitted = count
        } else {
            await model.archiveMergedWorkspace(workspaceId: workspace.id)
        }
    }
}

/// AGT-01's split button: "Create PR" sends the agent AGT-01's prompt; the chevron opens Rocky's menu with "Create
/// draft PR" (the same prompt with `--draft`) and "Create PR manually ↗" (GitHub's compare page in the browser). The
/// menu has no icon column and is as wide as its longest label, at least 200 (HDR-04). Both halves are disabled while
/// the conversation cannot take a prompt (AGT-00).
private struct CreatePullRequestButton: View {
    let model: AppModel
    let workspace: Workspace
    let availability: AgentActionAvailability
    @Environment(ToastPresenter.self) private var toasts: ToastPresenter?

    var body: some View {
        let model = self.model
        let workspaceId = workspace.id
        let toasts = self.toasts
        HStack(spacing: 0) {
            Button("Create PR") {
                Task { await model.createPullRequest(workspaceId: workspaceId, draft: false) }
            }
            .buttonStyle(HeaderButtonStyle(corners: .leading))
            MenuButton(id: "create-pr-\(workspaceId)", placement: .belowTrailing, width: 200, growsToFit: true) { isOpen in
                SplitChevron(kind: .primary, isOpen: isOpen)
            } content: {
                MenuItem(title: "Create draft PR") {
                    Task { await model.createPullRequest(workspaceId: workspaceId, draft: true) }
                }
                MenuItem(title: "Create PR manually", trailingSymbol: "arrow.up.right") {
                    if let url = model.compareURL(workspaceId: workspaceId) {
                        _ = NSWorkspace.shared.open(url)
                    } else {
                        toasts?.show("Rocky has not found this repository on GitHub yet.")
                    }
                }
            }
            .accessibilityLabel("More ways to create a pull request")
        }
        .disabled(availability != .available)
        .optionalHelp(availability.reason)
    }
}

/// The menu half of a split header button (AGT-01, and PR-05's merge): 22 points wide, the same fill as the main
/// half, with a thin line between them (white 8 % on Rocky's filled style, HDR-04). Lit on hover and while its menu is
/// open.
struct SplitChevron: View {
    let kind: HeaderButtonStyle.Kind
    let isOpen: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let lit = isEnabled && (hovering || isOpen)
        Image(systemName: "chevron.down")
            .font(.rocky(9, weight: .bold))
            .foregroundStyle(kind.text)
            .frame(width: Zoom.shared(22), height: Zoom.shared(24))
            .background(lit ? kind.hoverFill ?? kind.fill : kind.fill, in: UnevenRoundedRectangle(bottomTrailingRadius: 5, topTrailingRadius: 5))
            .overlay(alignment: .leading) {
                Rectangle().fill(kind.divider).frame(width: 1)
            }
            .brightness(lit && kind.hoverFill == nil ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// A header button's title, after a spinner in the text's color while its action runs.
struct HeaderButtonLabel: View {
    let title: String
    var spins = false
    var tint: Color = HeaderButtonStyle.Kind.primary.text

    var body: some View {
        HStack(spacing: 5) {
            if spins {
                CircularProgress(size: 12, tint: tint)
            }
            Text(title)
        }
    }
}

/// HDR-01's action button: 24 points, 12 medium, radius 5. The actions (Create PR, Commit and push, Fix errors,
/// Resolve…) use Rocky's filled style: `fillButton` with `textPrimary`, `fillButtonHover` on hover, never a white
/// fill (HDR-04). Merge fills with `success`, Archive with `merged` and a confirmation with `attention`, all with dark
/// text, darker on hover; the outline kind is `panel` with a white 14 % border. 45 % when disabled.
struct HeaderButtonStyle: ButtonStyle {
    enum Kind {
        case primary, merge, archive, confirm, outline

        var fill: Color {
            switch self {
            case .primary: Theme.fillButton
            case .merge: Theme.success
            case .archive: Theme.merged
            case .confirm: Theme.attention
            case .outline: Theme.panel
            }
        }

        /// The filled style lights up on hover; nil for the colored fills, which darken instead.
        var hoverFill: Color? {
            self == .primary ? Theme.fillButtonHover : nil
        }

        /// The filled style while pressed; nil for the colored fills, which darken instead.
        var pressedFill: Color? {
            self == .primary ? Theme.fillButtonPressed : nil
        }

        /// Dark text on the colored fills: Rocky's lighter `success` needs it for contrast (HDR-01).
        var text: Color {
            switch self {
            case .primary: Theme.textPrimary
            case .merge: Color(red: 0x10 / 255, green: 0x25 / 255, blue: 0x1A / 255)
            case .archive: Color(red: 0x1E / 255, green: 0x15 / 255, blue: 0x30 / 255)
            case .confirm: Color(red: 0x2A / 255, green: 0x1C / 255, blue: 0x06 / 255)
            case .outline: Theme.textPrimary
            }
        }

        /// The line between a split button's halves.
        var divider: Color {
            switch self {
            case .primary: Color.white.opacity(0.08)
            case .merge: Color(red: 0x10 / 255, green: 0x25 / 255, blue: 0x1A / 255).opacity(0.3)
            case .outline: Color.white.opacity(0.14)
            default: Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1A / 255).opacity(0.25)
            }
        }
    }

    /// Which corners are rounded: all, or one side for the halves of a split button.
    enum Corners {
        case all, leading, trailing
    }

    var kind: Kind = .primary
    var corners: Corners = .all

    func makeBody(configuration: Configuration) -> some View {
        HeaderButton(configuration: configuration, kind: kind, corners: corners)
    }

    private struct HeaderButton: View {
        let configuration: Configuration
        let kind: Kind
        let corners: Corners
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        private var fill: Color {
            guard isEnabled else { return kind.fill }
            if configuration.isPressed, let pressed = kind.pressedFill { return pressed }
            if hovering, let hover = kind.hoverFill { return hover }
            return kind.fill
        }

        private var shape: UnevenRoundedRectangle {
            let leading: CGFloat = corners == .trailing ? 0 : 5
            let trailing: CGFloat = corners == .leading ? 0 : 5
            return UnevenRoundedRectangle(
                topLeadingRadius: leading,
                bottomLeadingRadius: leading,
                bottomTrailingRadius: trailing,
                topTrailingRadius: trailing
            )
        }

        var body: some View {
            configuration.label
                .font(.rocky(12, weight: .medium))
                .foregroundStyle(kind.text)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: Zoom.shared(24))
                .background(fill, in: shape)
                .overlay {
                    if kind == .outline { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.14)) }
                }
                .brightness(isEnabled && kind.hoverFill == nil ? (configuration.isPressed ? -0.14 : hovering ? -0.08 : 0) : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

/// HDR-02's queued state: a static "Queued" badge, since merge queue actions are OUT-30.
private struct QueuedBadge: View {
    var body: some View {
        Text("Queued")
            .font(.rocky(12, weight: .medium))
            .foregroundStyle(Theme.attention)
            .padding(.horizontal, 8)
            .frame(height: Zoom.shared(22))
            .background(Theme.attention.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
    }
}
