import AppKit
import RockyKit
import SwiftUI

/// The Checks tab (PNL-03), in the design's order: the pull request's title and body (PRB-01), Git status (GST-01),
/// Deployments (DEP-01), Checks (CHK-01) and Comments (REV-01). It shows nothing until the workspace's first refresh
/// of the launch, while the header says "Loading PR info…".
struct ChecksTab: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        let panel = model.pullRequests.panels[workspace.id] ?? PullRequestPanelState()
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = panel.snapshot {
                if let pullRequest = snapshot.pullRequest {
                    PullRequestTextSection(pullRequest: pullRequest)
                } else {
                    NoPullRequestNote(agentName: model.existingChat(workspaceId: workspace.id)?.agent.displayName ?? AgentKind.claude.displayName)
                }
                GitStatusSection(model: model, workspace: workspace, snapshot: snapshot, panel: panel)
                if let pullRequest = snapshot.pullRequest {
                    if !pullRequest.latestDeployments.isEmpty {
                        DeploymentsSection(deployments: pullRequest.latestDeployments)
                    }
                    if !pullRequest.checks.isEmpty {
                        ChecksSection(model: model, workspace: workspace, pullRequest: pullRequest)
                    }
                    // REV-01: only pending comments, hidden when there are none. A merged pull request has none.
                    if !pullRequest.isMerged, !panel.comments.isEmpty {
                        CommentsSection(model: model, workspace: workspace, comments: panel.comments, added: panel.addedCommentIds)
                    }
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Title and body (PRB-01)

/// PRB-01: the title and the body as GitHub has them, read-only (user decision, 2026-09-24). They change when GitHub's
/// do, on the next refresh. Both are selectable, so they can be copied.
private struct PullRequestTextSection: View {
    let pullRequest: PullRequestInfo

    var body: some View {
        // Trimmed, so a body of blank lines shows nothing, and trailing newlines add no empty line.
        let description = pullRequest.body.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: pullRequest.title)
                .font(.rocky(13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 3)
            if !description.isEmpty {
                PullRequestBodyText(text: description)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// PRB-01's body: plain text, not rendered markdown, 12 `textSecondary`. It grows with its text to 180 points, then
/// scrolls. A hidden copy of the text gives the height, since a scroll view takes whatever it is offered.
private struct PullRequestBodyText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.rocky(12))
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: Zoom.shared(180), alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .overlay {
                ScrollView {
                    Text(verbatim: text)
                        .font(.rocky(12))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A body that fits does not bounce.
                .scrollBounceBehavior(.basedOnSize)
            }
    }
}

/// PRB-01 without a pull request, in place of the title and body.
private struct NoPullRequestNote: View {
    let agentName: String

    var body: some View {
        let lead = Text("No pull request yet.").foregroundStyle(Theme.textPrimary).fontWeight(.medium)
        let command = Text(verbatim: "gh pr create").font(.rocky(12, design: .monospaced))
        Text("\(lead) Create PR asks \(agentName) to commit, push and open it with \(command).")
            .font(.rocky(12.5))
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(Zoom.shared(3))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

// MARK: Git status (GST-01)

/// GST-01: the rows in the table's order with their dots and ghost actions; "Up to date with <base>" with none.
private struct GitStatusSection: View {
    let model: AppModel
    let workspace: Workspace
    let snapshot: PullRequestSnapshot
    let panel: PullRequestPanelState

    var body: some View {
        let base = model.pullRequestBase(workspaceId: workspace.id) ?? "the base"
        let rows = GitStatusRow.rows(pr: snapshot.pullRequest, local: panel.local, baseBehindBy: snapshot.baseBehindBy, base: base)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Git status")
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GitStatusRowView(row: row) {
                    GitStatusAction(model: model, workspace: workspace, action: row.action, snapshot: snapshot, panel: panel)
                }
            }
        }
    }
}

/// GST-01's row: 30 points, inset 8, 12 on the left, radius 7, lit on hover; an 8-point dot in a 12-point circle,
/// the text in 13, the action on the right.
private struct GitStatusRowView<Action: View>: View {
    let row: GitStatusRow
    @ViewBuilder let action: () -> Action
    @State private var hovering = false

    private var dot: Color {
        switch row.tone {
        case .danger: Theme.danger
        case .attention: Theme.attention
        case .muted: Theme.textTertiary
        case .success: Theme.success
        case .merged: Theme.merged
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: Zoom.shared(8), height: Zoom.shared(8))
                .frame(width: Zoom.shared(12), height: Zoom.shared(12))
            Text(row.text)
                .font(.rocky(13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.text)
            action()
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: Zoom.shared(30))
        .background(hovering ? Theme.fillHover : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .padding(.horizontal, 8)
    }
}

/// The ghost button of a Git status row. Agent actions follow AGT-00; Pull waits for a clean worktree (GST-03). "Ready
/// to merge" carries PR-05's merge button, sharing the header's method and confirmation.
private struct GitStatusAction: View {
    let model: AppModel
    let workspace: Workspace
    let action: GitStatusRow.Action
    let snapshot: PullRequestSnapshot
    let panel: PullRequestPanelState

    private var local: LocalGitStatus? {
        panel.local
    }

    var body: some View {
        let reason = model.agentActionAvailability(workspaceId: workspace.id).reason
        switch action {
        case .resolveConflicts:
            ghost("Resolve", disabledReason: reason) { await $0.resolveConflicts(workspaceId: $1) }
        case .resolveIncompatible:
            ghost("Resolve", disabledReason: reason) { await $0.resolveIncompatibility(workspaceId: $1) }
        case .commitAndPush:
            ghost("Commit and push", disabledReason: reason) { await $0.commitAndPush(workspaceId: $1) }
        case .createPR:
            ghost("Create PR", disabledReason: reason) { await $0.createPullRequest(workspaceId: $1, draft: false) }
        case .pull:
            let dirty = (local?.uncommitted ?? 0) > 0
            ghost("Pull", running: .pull, disabledReason: dirty ? "Commit or discard the changes first" : nil) {
                await $0.pullBranch(workspaceId: $1)
            }
        case .push:
            ghost("Push", running: .push) { await $0.pushBranch(workspaceId: $1) }
        case .pullFromBase:
            ghost("Pull", running: .pullFromBase, disabledReason: reason) { await $0.pullFromBase(workspaceId: $1) }
        case .readyForReview:
            ghost("Ready for review", running: .readyForReview) { await $0.markReadyForReview(workspaceId: $1) }
        case .addAllComments:
            ghost("Add all comments to chat", disabledReason: reason ?? (panel.comments.isEmpty ? "No pending comments" : nil)) {
                await $0.sendComments(workspaceId: $1, ids: nil)
            }
        case .merge:
            if let pullRequest = snapshot.pullRequest {
                MergeButton(model: model, workspace: workspace, pullRequest: pullRequest, repository: snapshot.repository, style: .row)
            }
        case .none:
            EmptyView()
        }
    }

    private func ghost(
        _ title: String,
        running action: PullRequestAction? = nil,
        disabledReason: String? = nil,
        _ run: @escaping @MainActor @Sendable (AppModel, String) async -> Void
    ) -> some View {
        let model = self.model
        let workspaceId = workspace.id
        let spins = action.map { model.isRunning($0, workspaceId: workspaceId) } ?? false
        return GhostButton(title: title, spins: spins, disabledReason: disabledReason) {
            Task { await run(model, workspaceId) }
        }
    }
}

/// GST-01's and CHK-01's ghost action: 22 points, 12 `textSecondary`, lit on hover, with a spinner while its action
/// runs. `disabledReason` disables it and becomes its tooltip.
private struct GhostButton: View {
    let title: String
    var spins = false
    var disabledReason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if spins { CircularProgress(size: 11, tint: Theme.textSecondary) }
                Text(title)
            }
        }
        .font(.rocky(12))
        .buttonStyle(RockyTextButtonStyle(height: 22))
        .disabled(disabledReason != nil || spins)
        .optionalHelp(disabledReason)
    }
}

// MARK: Deployments (DEP-01)

/// DEP-01: the latest deployment of each environment of the pull request's last commit.
private struct DeploymentsSection: View {
    let deployments: [PullRequestDeployment]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Deployments")
            ForEach(Array(deployments.enumerated()), id: \.offset) { _, deployment in
                DeploymentRow(deployment: deployment)
            }
        }
    }
}

/// DEP-01's row: the status icon (its word in the tooltip), the provider's mark, the name and ↗. The row and ↗ open
/// the environment's URL.
private struct DeploymentRow: View {
    let deployment: PullRequestDeployment

    private var icon: StatusIcon.Kind {
        switch deployment.status {
        case .deployed: .passed
        case .failed: .failed
        case .deploying: .dot(Theme.attention)
        case .queued: .dot(Theme.textTertiary)
        case .inactive: .hollow
        }
    }

    var body: some View {
        let url = deployment.url
        let open: (() -> Void)? = url.map { url in { _ = NSWorkspace.shared.open(url) } }
        ListRow(action: open) {
            StatusIcon(kind: icon)
                .help(deployment.status.word)
            ProviderMark(provider: deployment.isVercel ? .vercel : .github)
            Text(deployment.displayName)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            ExternalLinkButton(title: "Open \(deployment.displayName)", url: url)
        }
        .optionalHelp(url?.absoluteString)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(deployment.displayName), \(deployment.status.word)")
    }
}

// MARK: Checks (CHK-01)

/// CHK-01: the last commit's checks, failed first, then running, then GitHub's order. With a failed one, the header
/// offers Re-run (CHK-02) and Fix errors (AGT-03). Running durations tick every 10 s, only while the window can be
/// seen and something runs.
private struct ChecksSection: View {
    let model: AppModel
    let workspace: Workspace
    let pullRequest: PullRequestInfo
    @Environment(\.windowIsVisible) private var windowIsVisible

    var body: some View {
        let model = self.model
        let workspaceId = workspace.id
        let checks = pullRequest.orderedChecks
        let anyFailed = checks.contains { $0.state == .failed }
        let anyRunning = checks.contains { $0.state == .running }
        let reason = model.agentActionAvailability(workspaceId: workspaceId).reason
        let canRerun = !pullRequest.failedWorkflowRunIds.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Checks") {
                if anyFailed {
                    GhostButton(
                        title: "Re-run",
                        spins: model.isRunning(.rerun, workspaceId: workspaceId),
                        disabledReason: canRerun ? nil : "Only GitHub Actions jobs can be re-run from Rocky"
                    ) {
                        Task { await model.rerunFailedChecks(workspaceId: workspaceId) }
                    }
                    GhostButton(
                        title: "Fix errors",
                        spins: model.isRunning(.fixErrors, workspaceId: workspaceId),
                        disabledReason: reason
                    ) {
                        Task { await model.fixFailingChecks(workspaceId: workspaceId) }
                    }
                }
            }
            TimelineView(.animation(minimumInterval: 10, paused: !windowIsVisible || !anyRunning)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                        CheckRow(check: check, now: context.date)
                    }
                }
            }
        }
    }
}

/// CHK-01's row: the status icon, the provider's mark, the name (truncated), the duration in 11 mono and ↗. No other
/// buttons.
private struct CheckRow: View {
    let check: PullRequestCheck
    let now: Date

    private var icon: StatusIcon.Kind {
        switch check.state {
        case .running: .running
        case .failed: .failed
        case .passed: .passed
        case .pending, .other: .dot(Theme.textTertiary)
        }
    }

    var body: some View {
        ListRow {
            StatusIcon(kind: icon)
            ProviderMark(provider: check.isVercel ? .vercel : .github)
            Text(check.name)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(check.name)
            if let duration = CheckDuration.text(start: check.startedAt, end: check.completedAt, now: now) {
                Text(duration)
                    .font(.rocky(11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            ExternalLinkButton(title: "Open \(check.name)", url: check.url)
        }
    }
}

// MARK: Comments (REV-01)

/// REV-01: the pull request's pending comments, "Add all to chat" (AGT-05) on the right. One row per unresolved,
/// current review thread, conversation comment and changes-requested review body, in AGT-05's order.
private struct CommentsSection: View {
    let model: AppModel
    let workspace: Workspace
    let comments: [PendingComment]
    let added: Set<String>

    var body: some View {
        let model = self.model
        let workspaceId = workspace.id
        let reason = model.agentActionAvailability(workspaceId: workspaceId).reason
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Comments") {
                GhostButton(title: "Add all to chat", disabledReason: reason) {
                    Task { await model.sendComments(workspaceId: workspaceId, ids: nil) }
                }
            }
            ForEach(comments) { comment in
                CommentRow(comment: comment, isAdded: added.contains(comment.id), disabledReason: reason) {
                    model.hideComment(workspaceId: workspaceId, id: comment.id)
                } addToChat: {
                    Task { await model.sendComments(workspaceId: workspaceId, ids: [comment.id]) }
                }
            }
        }
    }
}

/// REV-01's 28-point row: a `success` check once added to the chat (else empty), a 16-point avatar with the author's
/// initials (no remote image), the author in medium, then where the comment is (11 mono `textSecondary`). On hover,
/// Hide (ghost) and Add to chat (outline) take the place's room. The tooltip is the whole comment.
private struct CommentRow: View {
    let comment: PendingComment
    let isAdded: Bool
    let disabledReason: String?
    let hide: () -> Void
    let addToChat: () -> Void
    @State private var hovering = false

    /// The comment and its replies, as the chat gets them.
    private var fullText: String {
        ([comment.body] + comment.replies.map { "\($0.author): \($0.body)" }).joined(separator: "\n\n")
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isAdded {
                    StatusIcon(kind: .passed)
                } else {
                    Color.clear
                }
            }
            .frame(width: Zoom.shared(12), height: Zoom.shared(12))
            CommentAvatar(initials: comment.initials)
            Text(comment.author)
                .fontWeight(.medium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            if hovering {
                Spacer(minLength: 0)
                Button("Hide", action: hide)
                    .font(.rocky(12))
                    .buttonStyle(RockyTextButtonStyle(height: 22))
                    .help("Hide this comment for this pull request")
                Button("Add to chat", action: addToChat)
                    .font(.rocky(12))
                    .buttonStyle(RockyOutlineButtonStyle())
                    .disabled(disabledReason != nil)
                    .optionalHelp(disabledReason)
            } else {
                Text(comment.rowLocation)
                    .font(.rocky(11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.rocky(12.5))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: Zoom.shared(28))
        .background(hovering ? Theme.fillHover : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .help(fullText)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(comment.author), \(comment.rowLocation)\(isAdded ? ", added to chat" : "")")
    }
}

/// REV-01's 16-point avatar: the author's initials, 8 bold white on the design's blue.
private struct CommentAvatar: View {
    let initials: String

    var body: some View {
        Text(initials)
            .font(.rocky(8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Zoom.shared(16), height: Zoom.shared(16))
            .background(Theme.repoPalette[0], in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: Shared pieces

/// A section's title row: 30 points, 12 medium `textTertiary`, 18 from the left, with room on the right for its
/// ghost buttons.
private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.rocky(12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: Zoom.shared(30))
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// DEP-01's and CHK-01's 28-point row: inset 8, 12 on the left, radius 7, 12.5 text, lit on hover. With an action,
/// the whole row is clickable.
private struct ListRow<Content: View>: View {
    var action: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        let row = HStack(spacing: 6, content: content)
            .font(.rocky(12.5))
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: Zoom.shared(28))
            .background(hovering ? Theme.fillHover : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        Group {
            if let action {
                row.onTapGesture(perform: action).clickable()
            } else {
                row
            }
        }
        .padding(.horizontal, 8)
    }
}

/// ↗ at a row's end: 14 points in an 18-point box, `textTertiary`, lit on hover. Opens `url` in the browser.
private struct ExternalLinkButton: View {
    let title: String
    let url: URL?
    @State private var hovering = false

    var body: some View {
        Button {
            if let url { _ = NSWorkspace.shared.open(url) }
        } label: {
            Image(systemName: "arrow.up.right")
                .font(.rocky(10, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: Zoom.shared(18), height: Zoom.shared(18))
                .background(hovering ? Theme.fillIconHover : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .opacity(url == nil ? 0 : 1)
        .disabled(url == nil)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// CHK-01's and DEP-01's 12-point status icons: an `attention` spinner, a `danger` cross, a `success` check, an
/// 8-point dot, or a hollow one.
struct StatusIcon: View {
    enum Kind {
        case running, failed, passed, hollow
        case dot(Color)
    }

    let kind: Kind
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch kind {
            case .running:
                CircularProgress(size: size, tint: Theme.attention)
            case .failed:
                Image(systemName: "xmark")
                    .font(.rocky(size * 0.72, weight: .bold))
                    .foregroundStyle(Theme.danger)
            case .passed:
                Image(systemName: "checkmark")
                    .font(.rocky(size * 0.75, weight: .bold))
                    .foregroundStyle(Theme.success)
            case .dot(let color):
                Circle()
                    .fill(color)
                    .frame(width: Zoom.shared(8), height: Zoom.shared(8))
            case .hollow:
                Circle()
                    .strokeBorder(Theme.textTertiary, lineWidth: 1.5)
                    .frame(width: Zoom.shared(8), height: Zoom.shared(8))
            }
        }
        .frame(width: Zoom.shared(size), height: Zoom.shared(size))
    }
}

/// A provider's mark in a row (DEP-01, CHK-01): GitHub's or Vercel's, from Simple Icons (CC0) in Resources/Icons,
/// drawn as a template in `textTertiary`, like the agents' logos.
private struct ProviderMark: View {
    enum Provider: String {
        case github, vercel

        var name: String {
            switch self {
            case .github: "GitHub"
            case .vercel: "Vercel"
            }
        }
    }

    let provider: Provider
    var size: CGFloat = 12

    var body: some View {
        Image(nsImage: Self.image(for: provider))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: Zoom.shared(size), height: Zoom.shared(size))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityLabel(provider.name)
    }

    private static var images: [Provider: NSImage] = [:]

    private static func image(for provider: Provider) -> NSImage {
        if let image = images[provider] { return image }
        let url = Bundle.module.url(forResource: provider.rawValue, withExtension: "svg", subdirectory: "Icons")
        let image = url.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: provider.name)
            ?? NSImage()
        image.isTemplate = true
        images[provider] = image
        return image
    }
}
