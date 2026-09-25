import Foundation

/// One button of Rocky's mini-modals (DLG-02, DLG-06), as its row lays it out. Pure, so the order and the keys are
/// tested here; the view (`DialogHost`) pairs each button with its action by `id`, the button's index in the list the
/// call site gave.
public struct DialogButton: Sendable, Equatable, Identifiable {
    public enum Role: Sendable, Equatable {
        /// White fill, the send button's colors: Save, Save All, Commit, Allow, OK.
        case primary
        /// `danger` tint: Discard, Remove Worktree, Archive, Don't Save.
        case destructive
        /// What Esc and a click outside press: Cancel, Keep Editing.
        case cancel
        /// Every other choice, drawn as Cancel is: Always Allow, Reject.
        case secondary
    }

    public let id: Int
    public let role: Role
    /// At the left end of the row, apart from the others: "Don't Save" (DLG-02), and Cancel and the reject options of
    /// a permission request (DLG-06).
    public let isLeading: Bool
    /// ⌘D presses it, as in the native prompt: "Don't Save" (DLG-03).
    public let isDontSave: Bool
    /// A disabled button is drawn dimmed, skipped by Tab and pressed by no key: Commit with an empty subject.
    public let isEnabled: Bool

    public init(id: Int, role: Role, isLeading: Bool = false, isDontSave: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.role = role
        self.isLeading = isLeading
        self.isDontSave = isDontSave
        self.isEnabled = isEnabled
    }
}

/// A mini-modal's buttons laid out as the native dialogs had them, whatever order the call site lists them in, as
/// `.confirmationDialog` did: the leading ones at the left end in their order; then at the right Cancel, the other
/// choices, and last the one that acts, primary or destructive, which is the default (DLG-02). "Don't Save · Cancel ·
/// Save", "Cancel · Discard Changes".
public struct DialogButtonRow: Sendable, Equatable {
    public let leading: [DialogButton]
    public let trailing: [DialogButton]

    public init(_ buttons: [DialogButton]) {
        leading = buttons.filter(\.isLeading)
        // A stable sort by rank: the call site's order holds within each group.
        trailing = buttons.filter { !$0.isLeading }
            .enumerated()
            .sorted { (Self.rank($0.element.role), $0.offset) < (Self.rank($1.element.role), $1.offset) }
            .map(\.element)
    }

    private static func rank(_ role: DialogButton.Role) -> Int {
        switch role {
        case .cancel: 0
        case .secondary: 1
        case .primary, .destructive: 2
        }
    }

    /// Left to right: the order Tab walks.
    public var buttons: [DialogButton] {
        leading + trailing
    }

    /// Return presses it: the rightmost button when it is primary or destructive (DLG-02). A row ending in a secondary
    /// button (a permission request with no "Allow") has none, so Return never grants more than the user picked.
    public var defaultButton: DialogButton? {
        guard let rightmost = buttons.last, rightmost.role == .primary || rightmost.role == .destructive else { return nil }
        return rightmost
    }

    /// Esc and a click outside press it: the cancel button, else the default, the error modal's OK (DLG-03).
    public var cancelButton: DialogButton? {
        buttons.first { $0.role == .cancel } ?? defaultButton
    }

    /// ⌘D presses it (DLG-03).
    public var dontSaveButton: DialogButton? {
        buttons.first(where: \.isDontSave)
    }

    /// The button Tab (`forward`) or ⇧Tab moves the focus to from `focused`, wrapping at both ends and skipping the
    /// disabled ones (DLG-03). Before any move, the focus is on the default, so the first Tab goes from the rightmost
    /// button around to the leftmost, and the first ⇧Tab to the default's left. nil when no button can take it.
    public func focus(after focused: Int?, forward: Bool) -> Int? {
        let order = buttons.filter(\.isEnabled).map(\.id)
        guard !order.isEmpty else { return nil }
        guard let start = (focused ?? defaultButton?.id).flatMap(order.firstIndex(of:)) else {
            return forward ? order.first : order.last
        }
        let step = forward ? 1 : -1
        return order[(start + step + order.count) % order.count]
    }
}

/// A permission request's button (DLG-06): an option of the agent's, or Cancel, which answers none.
public struct PermissionButton: Sendable, Equatable {
    /// nil for Cancel.
    public let option: PermissionOption?
    public let role: DialogButton.Role
    public let isLeading: Bool
}

extension PermissionRequest {
    /// DLG-06's row, left to right: Cancel at the left end, as the sheet had it, and the `reject_*` options next to it;
    /// at the right the options of any other kind, then `allow_always`, then `allow_once`, the one primary button and
    /// the default, as Return accepts once in Claude Code's own prompt. Every option but `allow_once` is secondary, and
    /// each group keeps the agent's order.
    public var buttons: [PermissionButton] {
        let cancel = PermissionButton(option: nil, role: .cancel, isLeading: true)
        let rejects = options.filter { $0.kind.hasPrefix("reject") }
        let others = options.filter { !$0.kind.hasPrefix("reject") && $0.kind != "allow_always" && $0.kind != "allow_once" }
        return [cancel]
            + rejects.map { PermissionButton(option: $0, role: .secondary, isLeading: true) }
            + others.map { PermissionButton(option: $0, role: .secondary, isLeading: false) }
            + options.filter { $0.kind == "allow_always" }.map { PermissionButton(option: $0, role: .secondary, isLeading: false) }
            + options.filter { $0.kind == "allow_once" }.map { PermissionButton(option: $0, role: .primary, isLeading: false) }
    }
}
