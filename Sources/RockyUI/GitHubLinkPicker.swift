import AppKit
import RockyKit
import SwiftUI

/// The picker's tabs (`GHL-02`), in their order: Tab and ⇧Tab go through them.
enum GitHubLinkTab: CaseIterable, Hashable {
    case issues, pullRequests, branches

    var title: String {
        switch self {
        case .issues: "Issues"
        case .pullRequests: "Pull requests"
        case .branches: "Branches"
        }
    }

    /// "Couldn't load issues: …" (`GHL-02`'s error state).
    var failureNoun: String {
        switch self {
        case .issues: "issues"
        case .pullRequests: "pull requests"
        case .branches: "branches"
        }
    }
}

/// A list as it loads (`GHL-02`'s states).
enum LinkLoad<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }

    var isLoaded: Bool { value != nil }
}

/// A search's results and the text they are for: a newer text's may still be on their way.
struct LinkSearch<Value: Equatable>: Equatable {
    let query: String
    let load: LinkLoad<Value>
}

/// One row of the picker (`GHL-02`).
struct GitHubLinkRow: Identifiable, Equatable {
    enum Item: Equatable {
        case issue(IssueSummary)
        case pullRequest(PullRequestSummary)
        case branch(BranchRef)
    }

    let item: Item
    /// At the row's end and as its tooltip: "Checked out in …", "From a fork", "Current branch".
    let reason: String?
    /// Nothing happens on it: it has a reason, or `GHL-05`'s notice covers its tab.
    let isDisabled: Bool

    var id: String {
        switch item {
        case .issue(let issue): "issue-\(issue.number)"
        case .pullRequest(let pullRequest): "pull-\(pullRequest.number)"
        case .branch(let branch): "branch-\(branch.id)"
        }
    }
}

/// What the picker's list shows in place of rows, or its rows.
enum LinkListState: Equatable {
    case loading
    case rows([GitHubLinkRow])
    case empty(String)
    case failed(String)
}

/// Opens and closes the "+" menu's GitHub picker (`GHL-01`…`GHL-05`, M2.9 Decision 1) and holds what it shows: the
/// query, the tab, each tab's first page and search, the branches and the notice. A panel like Quick Open's, not a
/// menu: it has a search field, tabs and rows with states and keys. While it shows, a local key monitor takes Esc, ↑/↓,
/// Return and Tab/⇧Tab before the field and before `ChatView`'s monitor, which lets every key through meanwhile; an
/// open Rocky menu or a mini-modal keeps its keys. A reference, so the monitor reads the state at the key's time.
///
/// Energy (`GHL-03`): a tab's first page loads when the tab first shows in an opening, a search 250 ms after typing
/// stops, and newer typing or closing cancels what is in flight. The branches come from git, with one `git fetch
/// --prune` when the Branches tab first shows. Nothing is kept after it closes.
@MainActor
@Observable
final class GitHubLinkPresenter {
    static let shared = GitHubLinkPresenter()

    /// One opening of the picker: its workspace and the conversation whose message box gets the files. A new id each
    /// time, so the panel enters once per opening and a load of an earlier opening lands nowhere.
    struct Opening: Equatable {
        let id = UUID()
        let workspaceId: String
        let conversationId: String
    }

    private(set) var opening: Opening?
    /// The search field's text, shared by the tabs (`GHL-02`: Tab keeps it).
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var tab: GitHubLinkTab = .issues
    /// The message box's frame in the window (`.global`): the panel sits above it, on its left edge.
    private(set) var anchor: CGRect = .zero
    /// The highlighted row, which Return picks; nil is the first one that can be picked.
    private(set) var highlightedId: String?
    private(set) var issuePage: LinkLoad<[IssueSummary]>?
    private(set) var pullRequestPage: LinkLoad<[PullRequestSummary]>?
    private(set) var issueSearch: LinkSearch<[IssueSummary]>?
    private(set) var pullRequestSearch: LinkSearch<[PullRequestSummary]>?
    private(set) var branches: LinkLoad<LinkBranches>?
    /// `GHL-05`: why the workspace cannot switch, read when the Pull requests or Branches tab first shows, and again
    /// by a pick it refuses. The notice covers those tabs while it is set.
    private(set) var switchRefusal: GitHubLinkError?
    /// The row being picked, whose state glyph spins (`GHL-04`).
    private(set) var pickingId: String?
    /// Why the last pick did nothing, over the list until the next pick or tab.
    private(set) var pickRefusal: String?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var pageLoads: [GitHubLinkTab: Task<Void, Never>] = [:]
    @ObservationIgnored private var searchLoad: Task<Void, Never>?
    @ObservationIgnored private var pick: Task<Void, Never>?
    @ObservationIgnored private var didReadRefusal = false
    @ObservationIgnored private var didFetchBranches = false

    /// `GHL-03`'s debounce.
    static let searchDelay = Duration.milliseconds(250)

    var isShown: Bool { opening != nil }

    /// `GHL-01`'s item: the picker over the conversation's message box, on Issues, its field focused.
    func show(workspaceId: String, conversationId: String, model: AppModel, anchor: CGRect) {
        close(restoringFocus: false)
        self.model = model
        self.anchor = anchor
        window = NSApp.keyWindow ?? NSApp.mainWindow
        opening = Opening(workspaceId: workspaceId, conversationId: conversationId)
        showTab(.issues)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Esc, a click outside, another workspace or a settings panel: the keyboard goes back to the message box.
    func dismiss() {
        close(restoringFocus: true)
    }

    /// The conversation's view went away (another tab, a file tab over it): its picker goes with it.
    func dismiss(conversationId: String) {
        guard opening?.conversationId == conversationId else { return }
        close(restoringFocus: false)
    }

    /// Keeps the panel on its message box when the layout moves.
    func move(conversationId: String, to anchor: CGRect) {
        guard opening?.conversationId == conversationId, anchor != self.anchor else { return }
        self.anchor = anchor
    }

    func select(_ tab: GitHubLinkTab) {
        guard tab != self.tab else { return }
        showTab(tab)
    }

    private func close(restoringFocus: Bool) {
        guard let opening else { return }
        self.opening = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for load in pageLoads.values { load.cancel() }
        pageLoads = [:]
        searchLoad?.cancel()
        searchLoad = nil
        // A pick of a branch or a pull request that already switched the worktree still attaches its file.
        pick?.cancel()
        pick = nil
        // GHL-03: no cache after the picker closes.
        query = ""
        tab = .issues
        highlightedId = nil
        issuePage = nil
        pullRequestPage = nil
        issueSearch = nil
        pullRequestSearch = nil
        branches = nil
        switchRefusal = nil
        pickingId = nil
        pickRefusal = nil
        didReadRefusal = false
        didFetchBranches = false
        guard restoringFocus else { return }
        let conversationId = opening.conversationId
        // On the next turn, once SwiftUI has removed the field, whose field editor hands the keyboard to the window.
        Task { @MainActor in ConversationComposers.controller(conversationId: conversationId)?.focus() }
    }

    // MARK: Loading (GHL-03)

    private func showTab(_ tab: GitHubLinkTab) {
        self.tab = tab
        highlightedId = nil
        pickRefusal = nil
        if tab != .branches { loadPageIfNeeded(tab) }
        if tab != .issues { prepareSwitching(fetching: tab == .branches) }
        search()
    }

    /// The tab's first page, once per opening; a failed one again, since typing or reopening retries (`GHL-02`).
    private func loadPageIfNeeded(_ tab: GitHubLinkTab) {
        guard let model, let opening, pageLoads[tab] == nil else { return }
        let workspaceId = opening.workspaceId
        switch tab {
        case .issues:
            guard issuePage?.isLoaded != true else { return }
            issuePage = .loading
            pageLoads[tab] = Task { [weak self] in
                let result = await Self.fetch { try await model.githubIssues(workspaceId: workspaceId, query: "") }
                guard let self, self.opening?.id == opening.id else { return }
                self.pageLoads[tab] = nil
                self.issuePage = result
            }
        case .pullRequests:
            guard pullRequestPage?.isLoaded != true else { return }
            pullRequestPage = .loading
            pageLoads[tab] = Task { [weak self] in
                let result = await Self.fetch { try await model.githubPullRequests(workspaceId: workspaceId, query: "") }
                guard let self, self.opening?.id == opening.id else { return }
                self.pageLoads[tab] = nil
                self.pullRequestPage = result
            }
        case .branches:
            return
        }
    }

    /// What the Pull requests and Branches tabs need, once per opening: `GHL-05`'s notice, and the branches with the
    /// worktrees holding them, which name the rows' reasons. The Branches tab also fetches once, then reads the list
    /// again.
    private func prepareSwitching(fetching: Bool) {
        guard let model, let opening else { return }
        let workspaceId = opening.workspaceId
        if !didReadRefusal {
            didReadRefusal = true
            Task { [weak self] in
                let refusal = await model.linkSwitchRefusal(workspaceId: workspaceId)
                guard let self, self.opening?.id == opening.id else { return }
                self.switchRefusal = refusal
            }
        }
        if branches == nil || branches?.value == nil && branches != .loading { loadBranches() }
        if fetching, !didFetchBranches {
            didFetchBranches = true
            Task { [weak self] in
                await model.fetchLinkBranches(workspaceId: workspaceId)
                guard let self, self.opening?.id == opening.id else { return }
                self.loadBranches()
            }
        }
    }

    /// Reads the branches from git; a list already on screen stays until the new one is read.
    private func loadBranches() {
        guard let model, let opening else { return }
        let workspaceId = opening.workspaceId
        if branches?.value == nil { branches = .loading }
        Task { [weak self] in
            let result = await Self.fetch { try await model.linkBranches(workspaceId: workspaceId) }
            guard let self, let result, self.opening?.id == opening.id else { return }
            // A later read's failure does not take away a list that was read.
            if case .failed = result, self.branches?.value != nil { return }
            self.branches = result
        }
    }

    private func queryChanged() {
        guard isShown else { return }
        highlightedId = nil
        search()
    }

    /// `GHL-03`'s search of the tab, 250 ms after the last keystroke; the one before is cancelled. Branches filter in
    /// memory and search nothing. An empty query shows the first page, loading it again after a failure.
    private func search() {
        searchLoad?.cancel()
        searchLoad = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, let opening, tab != .branches else { return }
        guard !text.isEmpty else {
            loadPageIfNeeded(tab)
            return
        }
        let workspaceId = opening.workspaceId
        let tab = self.tab
        switch tab {
        case .issues:
            guard issueSearch?.query != text || issueSearch?.load.isLoaded != true else { return }
            issueSearch = LinkSearch(query: text, load: .loading)
        case .pullRequests:
            guard pullRequestSearch?.query != text || pullRequestSearch?.load.isLoaded != true else { return }
            pullRequestSearch = LinkSearch(query: text, load: .loading)
        case .branches:
            return
        }
        searchLoad = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.searchDelay)) != nil else { return }
            switch tab {
            case .issues:
                let result = await Self.fetch { try await model.githubIssues(workspaceId: workspaceId, query: text) }
                guard let self, let result, self.opening?.id == opening.id else { return }
                self.issueSearch = LinkSearch(query: text, load: result)
            case .pullRequests:
                let result = await Self.fetch { try await model.githubPullRequests(workspaceId: workspaceId, query: text) }
                guard let self, let result, self.opening?.id == opening.id else { return }
                self.pullRequestSearch = LinkSearch(query: text, load: result)
            case .branches:
                return
            }
        }
    }

    /// A load's outcome; nil when it was cancelled (Decision 2: dropped, never shown).
    private static func fetch<Value: Equatable>(_ body: () async throws -> Value) async -> LinkLoad<Value>? {
        do {
            let value = try await body()
            return Task.isCancelled ? nil : .loaded(value)
        } catch {
            if Task.isCancelled || GitHubLinkError.isCancellation(error) { return nil }
            return .failed(GitHubLinkError.text(for: error))
        }
    }

    // MARK: What it shows (GHL-02)

    /// The tab's list for the query, or the state in its place.
    var listState: LinkListState {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tab {
        case .issues:
            let search: LinkLoad<[IssueSummary]> = issueSearch.flatMap { $0.query == text ? $0.load : nil } ?? .loading
            let load = text.isEmpty ? issuePage : search
            return state(of: load, empty: text.isEmpty ? "No open issues" : "No matches") { issues in
                issues.map { GitHubLinkRow(item: .issue($0), reason: nil, isDisabled: false) }
            }
        case .pullRequests:
            let search: LinkLoad<[PullRequestSummary]> = pullRequestSearch.flatMap { $0.query == text ? $0.load : nil } ?? .loading
            let load = text.isEmpty ? pullRequestPage : search
            let list = branches?.value
            let blocked = switchRefusal != nil
            return state(of: load, empty: text.isEmpty ? "No open pull requests" : "No matches") { pulls in
                pulls.map { pull in
                    // OUT-50: a fork's head is in another repository.
                    let reason = pull.isCrossRepository ? "From a fork" : list?.reason(forBranchNamed: pull.headRefName)
                    return GitHubLinkRow(item: .pullRequest(pull), reason: blocked ? nil : reason, isDisabled: blocked || reason != nil)
                }
            }
        case .branches:
            let blocked = switchRefusal != nil
            return state(of: branches, empty: "No matches") { list in
                list.matching(text).map { branch in
                    let reason = list.reason(for: branch)
                    // Under the notice only the current branch keeps its reason, which the notice does not explain.
                    let shown = blocked && reason != "Current branch" ? nil : reason
                    return GitHubLinkRow(item: .branch(branch), reason: shown, isDisabled: blocked || reason != nil)
                }
            }
        }
    }

    private func state<Value: Equatable>(of load: LinkLoad<Value>?, empty: String, rows: (Value) -> [GitHubLinkRow]) -> LinkListState {
        switch load {
        case nil, .loading: return .loading
        case .failed(let reason): return .failed("Couldn’t load \(tab.failureNoun): \(reason)")
        case .loaded(let value):
            let made = rows(value)
            return made.isEmpty ? .empty(empty) : .rows(made)
        }
    }

    /// The box over the list: the last pick's refusal, else `GHL-05`'s notice on the Pull requests and Branches tabs.
    var notice: String? {
        if let pickRefusal { return pickRefusal }
        guard tab != .issues, switchRefusal != nil else { return nil }
        return GitHubLinkError.changesNotice
    }

    /// The row Return picks: the highlighted one, else the first that can be picked.
    var highlighted: GitHubLinkRow? {
        guard case .rows(let rows) = listState else { return nil }
        let pickable = rows.filter { !$0.isDisabled }
        return pickable.first { $0.id == highlightedId } ?? pickable.first
    }

    /// ↓ and ↑ over the rows that can be picked, wrapping at both ends.
    private func moveHighlight(_ step: Int) {
        guard case .rows(let rows) = listState else { return }
        let pickable = rows.filter { !$0.isDisabled }
        guard !pickable.isEmpty else { return }
        let current = pickable.firstIndex { $0.id == highlighted?.id } ?? 0
        highlightedId = pickable[((current + step) % pickable.count + pickable.count) % pickable.count].id
    }

    /// The row under the pointer.
    func highlight(_ row: GitHubLinkRow) {
        guard !row.isDisabled, row.id != highlightedId else { return }
        highlightedId = row.id
    }

    // MARK: Keys

    /// The keys the picker takes, in its window: whether the event was used. A composition in progress (an input
    /// method's marked text) keeps Return and Esc.
    private func handle(_ event: NSEvent) -> Bool {
        guard isShown, event.window === window, !MenuPresenter.isAnyMenuOpen, !DialogPresenter.shared.isShowing else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isComposing = (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
        switch event.keyCode {
        case 53:   // Esc
            guard modifiers.isEmpty, !isComposing else { return false }
            dismiss()
            return true
        case 125, 126:   // ↓, ↑
            guard modifiers.isEmpty else { return false }
            moveHighlight(event.keyCode == 125 ? 1 : -1)
            return true
        case 36, 76:   // Return, and Enter on the keypad
            guard modifiers.isEmpty, !isComposing else { return false }
            if let highlighted { pick(highlighted) }
            return true
        case 48:   // Tab, ⇧Tab
            guard modifiers.isEmpty || modifiers == .shift else { return false }
            let tabs = GitHubLinkTab.allCases
            let index = tabs.firstIndex(of: tab) ?? 0
            let step = modifiers == .shift ? tabs.count - 1 : 1
            showTab(tabs[(index + step) % tabs.count])
            return true
        default:
            return false
        }
    }

    // MARK: Picking (GHL-04, GHL-05)

    /// An issue: its file at the caret, and one already in the box only closes the picker. A pull request or a branch:
    /// the worktree switched first, then its file, one per message. A refusal says why over the list and attaches
    /// nothing; git's failure is a toast, and the picker closes (`GHL-05`).
    func pick(_ row: GitHubLinkRow) {
        guard let model, let opening, pickingId == nil, !row.isDisabled else { return }
        let files = ConversationComposers.controller(conversationId: opening.conversationId)?.draft?.files ?? []
        let links = files.compactMap(LinkAttachments.kind(ofPath:))
        switch row.item {
        case .issue(let issue):
            guard !links.contains(.issue(issue.number)) else {
                dismiss()
                return
            }
        case .pullRequest, .branch:
            guard !links.contains(where: \.switchesWorktree) else {
                pickRefusal = "One pull request or branch per message."
                return
            }
        }
        pickRefusal = nil
        pickingId = row.id
        let workspaceId = opening.workspaceId
        let item = row.item
        pick = Task { [weak self] in
            do {
                let file: URL
                let title: String
                switch item {
                case .issue(let issue):
                    file = try await model.linkIssue(workspaceId: workspaceId, number: issue.number)
                    title = "#\(issue.number) \(issue.title)"
                case .pullRequest(let pullRequest):
                    file = try await model.linkPullRequest(workspaceId: workspaceId, number: pullRequest.number)
                    title = "#\(pullRequest.number) \(pullRequest.title)"
                case .branch(let branch):
                    file = try await model.linkBranch(workspaceId: workspaceId, branch: branch)
                    title = branch.name
                }
                LinkBadgeTitles.remember(title, for: file.path)
                self?.attach(file, opening: opening)
            } catch {
                self?.pickFailed(error, opening: opening, model: model)
            }
        }
    }

    /// The file goes into the message box of the conversation the picker opened from, at the caret, even when the
    /// picker was closed meanwhile: a switched worktree keeps its chip.
    private func attach(_ file: URL, opening: Opening) {
        let composer = ConversationComposers.controller(conversationId: opening.conversationId)
        if self.opening?.id == opening.id { close(restoringFocus: false) }
        composer?.insert(files: [file])
        Task { @MainActor in composer?.focus() }
    }

    private func pickFailed(_ error: Error, opening: Opening, model: AppModel) {
        let isCurrent = self.opening?.id == opening.id
        if isCurrent { pickingId = nil }
        guard !GitHubLinkError.isCancellation(error) else { return }
        let text = GitHubLinkError.text(for: error)
        if case GitHubLinkError.git = error {
            model.onToast?(text)
            if isCurrent { close(restoringFocus: true) }
            return
        }
        guard isCurrent else {
            model.onToast?(text)
            return
        }
        pickRefusal = text
        if let refusal = error as? GitHubLinkError, refusal.isChangesOfItsOwn { switchRefusal = refusal }
    }
}

extension LinkAttachments.Kind {
    /// A pull request's or a branch's file: its pick switched the worktree, so a message has one at most (`GHL-04`).
    var switchesWorktree: Bool {
        switch self {
        case .issue, .reviewComments: false
        case .pullRequest, .branch: true
        }
    }
}

/// The badges' tooltips (Decision 4): the first line of the file Rocky wrote for a link, "#154 Refresh the button
/// styles" or a branch's name. The picker gives the title it knows when it attaches the file; any other is read
/// once, off the main actor, and kept until Rocky quits.
@MainActor
enum LinkBadgeTitles {
    private static var titles: [String: String] = [:]

    static func remember(_ title: String, for path: String) {
        titles[path] = title
    }

    static func cached(_ path: String) -> String? {
        titles[path] ?? fromName(path)
    }

    /// `RVW-01`'s "Review comments on #131", from the name alone, so the transcript and ↑'s history draw it too.
    private static func fromName(_ path: String) -> String? {
        guard case .reviewComments(let number) = LinkAttachments.kind(ofPath: path) else { return nil }
        return "Review comments on #\(number)"
    }

    /// nil for a file that is no link, or whose file is gone.
    static func title(for path: String) async -> String? {
        guard LinkAttachments.kind(ofPath: path) != nil else { return nil }
        if let known = cached(path) { return known }
        let url = URL(fileURLWithPath: path)
        let title = await Task.blocking { LinkAttachments.title(ofFileAt: url) }.value
        if let title { titles[path] = title }
        return title
    }
}

// MARK: Views

/// GitHub's mark (`Resources/Icons/github.svg`, Simple Icons, CC0) as a template, in `textPrimary` unless told.
struct GitHubMark: View {
    var size: CGFloat = 14
    var color: Color = Theme.textPrimary

    static let image: NSImage = {
        let url = Bundle.module.url(forResource: "github", withExtension: "svg", subdirectory: "Icons")
        let image = url.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color)
            .frame(width: Zoom.shared(size), height: Zoom.shared(size))
            .accessibilityHidden(true)
    }
}

/// A link's badge mark in place of the file's icon (Decision 4): GitHub's for an issue, the pull request and branch
/// glyphs for the others.
struct LinkMark: View {
    let kind: LinkAttachments.Kind
    var size: CGFloat = 12

    var body: some View {
        switch kind {
        case .issue: GitHubMark(size: size)
        case .pullRequest: GitGlyph(kind: .pullRequest, size: size, color: Theme.textPrimary)
        case .branch: GitGlyph(kind: .branch, size: size, color: Theme.textPrimary)
        case .reviewComments:
            Image(systemName: "text.bubble")
                .font(.rocky(size - 1))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: Zoom.shared(size), height: Zoom.shared(size))
                .accessibilityHidden(true)
        }
    }
}

/// `GHL-01`'s "+" item. Its own view, so the item follows the link state as it resolves while the menu shows; the
/// resolution runs when the menu first shows it, once per repository and launch (Decision 3). Until it answers, the
/// item can be chosen, and the picker's requests say what is wrong.
struct LinkGitHubMenuItem: View {
    let model: AppModel
    let workspaceId: String
    let action: () -> Void

    var body: some View {
        MenuItem(title: "Link GitHub issue", icon: .template(GitHubMark.image), disabledReason: disabledReason, action: action)
            .task { await model.resolveGitHubLinks(workspaceId: workspaceId) }
    }

    private var disabledReason: String? {
        // WSC-03: a branch or a pull request switches a worktree that does not exist yet.
        if let hint = model.creatingHint(workspaceId: workspaceId) { return hint }
        guard case .unavailable(let reason) = model.githubLinkState(workspaceId: workspaceId) else { return nil }
        return reason
    }
}

/// The picker over the whole window, from `RootView`, under the mini-modals and the menus: a transparent layer that
/// closes it on a click outside (no dimming), and the panel, its bottom 8 points above the message box and its left
/// edge on the box's (`GHL-02`). It enters with the menus' 120 ms fade, keyed on the opening, so typing and the tabs
/// never replay it, and closes at once.
struct GitHubLinkPickerHost: View {
    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 8

    private var presenter: GitHubLinkPresenter { .shared }

    var body: some View {
        GeometryReader { proxy in
            if let opening = presenter.opening {
                // Anchors are window coordinates (`.global`), as the menus' are.
                let origin = proxy.frame(in: .global).origin
                let anchor = presenter.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.dismiss() }
                    AboveAnchorLayout(anchor: anchor, gap: Self.gap, margin: Self.margin) {
                        GitHubLinkPanel()
                            .id(opening.id)
                    }
                }
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .ignoresSafeArea()
        // With the picker closed, clicks reach the window under it.
        .allowsHitTesting(presenter.isShown)
        // Only opening animates. Under an animation, the `.identity` removal kept the panel on screen for 120 ms after
        // its state was cleared, and it showed its loading spinner before it went (user report, 2026-09-28).
        .animation(presenter.opening == nil ? nil : .easeOut(duration: 0.12), value: presenter.opening?.id)
        // Closing the window (⌘W) closes the picker, whose key monitor listens to that window alone.
        .onDisappear { presenter.dismiss() }
    }
}

/// Puts its one subview above `anchor`, `gap` over its top edge, on its left edge, and at least `margin` inside.
private struct AboveAnchorLayout: Layout {
    let anchor: CGRect
    let gap: CGFloat
    let margin: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let size = panel.sizeThatFits(.unspecified)
        let x = min(max(anchor.minX, margin), bounds.width - size.width - margin)
        let y = max(anchor.minY - gap - size.height, margin)
        panel.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// `GHL-02`'s panel, 520 wide in Quick Open's look (radius 12, a 1-point `hairline` ring, black 45 % shadow of radius
/// 18 at y 10): the 40-point search, the tabs, and the list.
private struct GitHubLinkPanel: View {
    @FocusState private var fieldHasKeyboard: Bool

    private var presenter: GitHubLinkPresenter { .shared }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(Theme.hairline).frame(height: 1)
            tabs
            Rectangle().fill(Theme.hairline).frame(height: 1)
            GitHubLinkList()
        }
        .frame(width: Zoom.shared(520))
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        .onAppear {
            // On the next turn, once the field is in the window (GHL-01: focused on open).
            Task { @MainActor in fieldHasKeyboard = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link GitHub")
        .accessibilityAddTraits(.isModal)
    }

    /// 40 points: `magnifyingglass` 13 in `textTertiary` and the 13.5 field, with a placeholder that does not move on
    /// focus.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.rocky(13))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            TextField("Search GitHub", text: Bindable(presenter).query, prompt: Text(verbatim: ""))
                .textFieldStyle(.plain)
                .font(.rocky(13.5))
                .stablePlaceholder("Search by number, title or description", isVisible: presenter.query.isEmpty)
                .foregroundStyle(Theme.textPrimary)
                .focused($fieldHasKeyboard)
        }
        .padding(.horizontal, 14)
        .frame(height: Zoom.shared(40))
    }

    /// Issues · Pull requests · Branches, 24-point pills, the chosen one on `fillSelected`.
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(GitHubLinkTab.allCases, id: \.self) { tab in
                LinkTabPill(title: tab.title, isSelected: presenter.tab == tab) { presenter.select(tab) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

private struct LinkTabPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.rocky(12.5))
                .foregroundStyle(isSelected || hovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: Zoom.shared(24))
                .background(isSelected ? Theme.fillSelected : (hovering ? Theme.fillHover : Color.clear), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The list, up to 300 tall and at least 120: the notice, then the rows; or in their place one spinner, the empty
/// line or the error, centred (`GHL-02`'s states). The highlighted row scrolls into view.
private struct GitHubLinkList: View {
    @State private var contentHeight: CGFloat = 0
    /// Where the pointer last was: rows sliding under a pointer that did not move do not take the highlight.
    @State private var pointer: CGPoint?

    private var presenter: GitHubLinkPresenter { .shared }
    private static let inset: CGFloat = 5

    var body: some View {
        let state = presenter.listState
        let minHeight = Zoom.shared(120)
        switch state {
        case .loading:
            CircularProgress(size: 14)
                .frame(maxWidth: .infinity, minHeight: minHeight)
        case .empty(let text), .failed(let text):
            VStack(spacing: 0) {
                if let notice = presenter.notice { LinkNotice(text: notice).padding(Self.inset) }
                Text(verbatim: text)
                    .font(.rocky(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
        case .rows(let rows):
            rowList(rows, minHeight: minHeight)
        }
    }

    private func rowList(_ rows: [GitHubLinkRow], minHeight: CGFloat) -> some View {
        let highlighted = presenter.highlighted?.id
        let height = min(max(contentHeight, minHeight), Zoom.shared(300))
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if let notice = presenter.notice { LinkNotice(text: notice) }
                    ForEach(rows) { row in
                        LinkRowView(row: row, isHighlighted: row.id == highlighted, isPicking: presenter.pickingId == row.id)
                            .id(row.id)
                            .onContinuousHover(coordinateSpace: .global) { hover($0, row: row) }
                            .onTapGesture { presenter.pick(row) }
                    }
                }
                .padding(Self.inset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: height, alignment: .top)
            .onChange(of: highlighted) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presenter.tab.title)
    }

    private func hover(_ phase: HoverPhase, row: GitHubLinkRow) {
        guard case .active(let location) = phase else { return }
        defer { pointer = location }
        guard let pointer, pointer != location else { return }
        presenter.highlight(row)
    }
}

/// `GHL-05`'s notice, and a pick's refusal: `attention` at 8 %, radius 7, a warning glyph in `attention`.
private struct LinkNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.rocky(12))
                .foregroundStyle(Theme.attention)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.rocky(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

/// One row, 32 points, radius 7, padding 0 10, gap 8 (`GHL-02`). An issue or a pull request: GitHub's mark, its state
/// glyph (a spinner while it is picked), "#212" in 12.5 mono tabular `textTertiary` in 52 points, the title. A branch:
/// the branch glyph, its name in 12.5 mono, "origin" for one only on the remote. A reason at the end, in 11
/// `textTertiary`, which is also the tooltip.
private struct LinkRowView: View {
    let row: GitHubLinkRow
    let isHighlighted: Bool
    let isPicking: Bool

    var body: some View {
        HStack(spacing: 8) {
            switch row.item {
            case .issue(let issue):
                GitHubMark(size: 14)
                glyph { IssueStateGlyph(state: issue.state) }
                number(issue.number)
                title(issue.title)
            case .pullRequest(let pullRequest):
                GitHubMark(size: 14)
                glyph { PullRequestStateGlyph(pullRequest: pullRequest) }
                number(pullRequest.number)
                title(pullRequest.title)
            case .branch(let branch):
                glyph { GitGlyph(kind: .branch, size: 14, color: Theme.textSecondary) }
                Text(verbatim: branch.name)
                    .font(.rocky(12.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if branch.isRemoteOnly {
                    Text(verbatim: "origin")
                        .font(.rocky(11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if let reason = row.reason {
                Text(verbatim: reason)
                    .font(.rocky(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Zoom.shared(200), alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: Zoom.shared(32), maxHeight: Zoom.shared(32), alignment: .leading)
        .background(isHighlighted ? Theme.fillSelected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .opacity(row.isDisabled ? 0.45 : 1)
        .contentShape(Rectangle())
        .modifier(ClickableUnless(disabled: row.isDisabled))
        .optionalHelp(row.reason)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    /// The state glyph's 14-point slot, or the spinner while the row is picked.
    @ViewBuilder
    private func glyph<Glyph: View>(@ViewBuilder _ content: () -> Glyph) -> some View {
        Group {
            if isPicking {
                CircularProgress(size: 14)
            } else {
                content()
            }
        }
        .frame(width: Zoom.shared(14), height: Zoom.shared(14))
    }

    private func number(_ number: Int) -> some View {
        Text(verbatim: "#\(number)")
            .font(.rocky(12.5, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .frame(width: Zoom.shared(52), alignment: .leading)
    }

    private func title(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.rocky(13))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityText: String {
        let base = switch row.item {
        case .issue(let issue): "Issue #\(issue.number), \(issue.title), \(issue.state.rawValue)"
        case .pullRequest(let pull): "Pull request #\(pull.number), \(pull.title), \(pull.isDraft ? "draft" : pull.state.rawValue)"
        case .branch(let branch): "Branch \(branch.name)\(branch.isRemoteOnly ? ", on origin" : "")"
        }
        return [base, row.reason].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The pointing hand only on a row that does something.
private struct ClickableUnless: ViewModifier {
    let disabled: Bool

    func body(content: Content) -> some View {
        if disabled { content } else { content.clickable() }
    }
}

/// An issue's state (`GHL-02`): open in `success`; closed, found by number, in `merged`.
private struct IssueStateGlyph: View {
    let state: GitHubItemState

    var body: some View {
        Image(systemName: state == .open ? "smallcircle.filled.circle" : "checkmark.circle")
            .font(.rocky(12.5))
            .foregroundStyle(state == .open ? Theme.success : Theme.merged)
            .accessibilityHidden(true)
    }
}

/// A pull request's state (`GHL-02`): open in `success`, a draft in `textTertiary`, a closed or merged one found by
/// number in `merged`, the merge glyph for a merged one.
private struct PullRequestStateGlyph: View {
    let pullRequest: PullRequestSummary

    var body: some View {
        switch pullRequest.state {
        case .open: GitGlyph(kind: .pullRequest, size: 14, color: pullRequest.isDraft ? Theme.textTertiary : Theme.success)
        case .merged: GitGlyph(kind: .merge, size: 14, color: Theme.merged)
        case .closed: GitGlyph(kind: .pullRequest, size: 14, color: Theme.merged)
        }
    }
}
