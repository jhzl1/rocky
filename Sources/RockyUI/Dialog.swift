import AppKit
import RockyKit
import SwiftUI

// Rocky's mini-modals (DLG-01…DLG-06), which replace every native confirmation, alert and sheet (user decision,
// 2026-09-25: "quiero que creemos minimodales para dejar de depender de los menús nativos que no me gustan"). A call
// site describes one with `.rockyDialog(isPresented:)` or `.rockyDialog(item:)`, as it did with `.confirmationDialog`;
// `DialogPresenter` queues them, one on screen at a time, and `DialogHost` draws it over the dimmed window.

/// What a mini-modal shows (DLG-02): its title, an optional message and its buttons. The large variant (DLG-06, Commit
/// and a permission request) adds a body between them, an agent's mark before the title and a wider panel.
struct Dialog {
    let title: String
    var message: String?
    /// The error modal's message can be selected and copied (DLG-02).
    var isMessageSelectable = false
    /// A permission request's header: the agent's mark before "Permission needed" (DLG-06).
    var agent: AgentKind?
    /// 360 (DLG-02); the large variant's own width, Commit 500 and a permission request 460 (DLG-06).
    var width: CGFloat = 360
    /// The large variant's body, between the title and the buttons.
    var content: (@MainActor () -> AnyView)?
    /// A hint at the left of the buttons: Commit's "git add -A, then git commit".
    var footnote: String?
    /// The body's text fields take the typing keys, Space, Tab and Return while one has the keyboard, and ⌘Return
    /// presses the default (DLG-03, Commit). Without them, every key but the dialog's own waits.
    var hasTextFields = false
    let buttons: [DialogAction]

    /// The large variant: 15-point title, as `SettingsPanel`'s (DLG-06).
    var isLarge: Bool {
        content != nil
    }

    /// The buttons as the row lays them out, each with the state it has now (`DialogAction.isEnabled`).
    @MainActor
    var row: DialogButtonRow {
        DialogButtonRow(buttons.enumerated().map { index, button in
            DialogButton(
                id: index,
                role: button.role,
                isLeading: button.isLeading,
                isDontSave: button.isDontSave,
                isEnabled: button.isEnabled()
            )
        })
    }
}

/// The answer to the quit prompt with unsaved edits (DLG-05), from the mini-modal or, with no window, the native alert.
public enum UnsavedEditsAnswer: Sendable {
    case saveAll, dontSave, cancel
}

/// One button of a mini-modal: its words, its role (`DialogButton.Role`) and what it does. The call site lists them in
/// any order, as `.confirmationDialog`'s buttons were; the row puts them in DLG-02's.
struct DialogAction {
    let title: String
    let role: DialogButton.Role
    /// At the left end: "Don't Save", a permission request's Cancel and rejects.
    var isLeading = false
    /// ⌘D presses it (DLG-03).
    var isDontSave = false
    var help: String?
    /// Read live, so a button follows its dialog's state: Commit is off with an empty subject and while git runs.
    var isEnabled: @MainActor () -> Bool = { true }
    /// False: the dialog stays after the press and goes when its call site's binding does. Commit waits for git.
    var dismisses = true
    let action: @MainActor () -> Void

    /// Cancel, or its own words ("Keep Editing"), which Esc and a click outside press too.
    static func cancel(
        _ title: String = "Cancel",
        isEnabled: @escaping @MainActor () -> Bool = { true },
        action: @escaping @MainActor () -> Void = {}
    ) -> DialogAction {
        DialogAction(title: title, role: .cancel, isEnabled: isEnabled, action: action)
    }

    static func destructive(_ title: String, action: @escaping @MainActor () -> Void) -> DialogAction {
        DialogAction(title: title, role: .destructive, action: action)
    }

    static func primary(_ title: String, action: @escaping @MainActor () -> Void = {}) -> DialogAction {
        DialogAction(title: title, role: .primary, action: action)
    }

    /// "Don't Save": destructive, alone at the left end, and ⌘D (DLG-02, DLG-03).
    static func dontSave(action: @escaping @MainActor () -> Void) -> DialogAction {
        DialogAction(title: "Don’t Save", role: .destructive, isLeading: true, isDontSave: true, action: action)
    }
}

/// Holds the mini-modals, first in, first out: the first one shows, and a second waits until it closes (DLG-04). One
/// for the app, like `SettingsPresenter`, so the app delegate reaches it to ask before quitting (DLG-05). While one
/// shows, a local key monitor takes Return, Esc, Tab, ⇧Tab, Space and ⌘D, and lets no other key reach the window
/// behind: the message box, the terminal and the shortcuts wait (DLG-03). The monitor reads the dialog on screen here,
/// a reference, at the key's time (`CLAUDE.md`, key monitors). `ChatView`'s, the settings' and Quick Open's monitors
/// yield to it; an open Rocky menu keeps Esc.
@MainActor
@Observable
public final class DialogPresenter {
    public static let shared = DialogPresenter()

    struct Entry: Identifiable {
        let id: UUID
        var dialog: Dialog
        /// The call site's binding goes back to nil or false: the user answered.
        let onDismiss: @MainActor () -> Void
    }

    private(set) var queue: [Entry] = []
    /// The button Tab or ⇧Tab moved the keyboard focus to, by its index in the dialog's buttons; nil until then, when
    /// Return presses the default.
    private(set) var focusedButton: Int?
    /// The window `DialogHost` draws in; nil once it went (⌘W).
    @ObservationIgnored weak var window: NSWindow?
    /// What had the keyboard before the first dialog, given back after the last.
    @ObservationIgnored private weak var previousResponder: NSResponder?
    @ObservationIgnored private var keyMonitor: Any?
    /// The quit prompt's id while it waits for its answer (DLG-05).
    @ObservationIgnored private var quitPromptId: UUID?

    var current: Entry? {
        queue.first
    }

    /// A mini-modal is on screen.
    public var isShowing: Bool {
        !queue.isEmpty
    }

    /// Shows `dialog` when the ones before it have closed. `id` is the call site's: the same id again changes that
    /// dialog in place, where it waits or shows.
    func present(_ dialog: Dialog, id: UUID = UUID(), onDismiss: @escaping @MainActor () -> Void = {}) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue[index].dialog = dialog
            return
        }
        queue.append(Entry(id: id, dialog: dialog, onDismiss: onDismiss))
        if queue.count == 1 { firstDidShow() }
    }

    /// The call site's binding went back, or its view went away: the dialog goes without an answer.
    func withdraw(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index)
        if index == 0 { headDidChange() }
    }

    /// A click on a button, Return, Space or ⌘D. A disabled button does nothing. The dialog goes first, so the next one
    /// in the queue shows, then its action runs, then its binding goes back.
    func press(_ index: Int) {
        guard let entry = current, entry.dialog.buttons.indices.contains(index) else { return }
        let button = entry.dialog.buttons[index]
        guard button.isEnabled() else { return }
        if button.dismisses { withdraw(id: entry.id) }
        button.action()
        if button.dismisses { entry.onDismiss() }
    }

    /// Esc and a click on the dimmed window: the cancel button, or the error modal's OK. Nothing while it is disabled
    /// (Commit while git runs).
    func cancel() {
        guard let button = current?.dialog.row.cancelButton else { return }
        press(button.id)
    }

    /// `DialogHost` left its window (⌘W closed it). The dialogs of views keep their place until those views go too,
    /// which withdraws them, and the monitor lets every key through meanwhile. The quit prompt belongs to no view: it
    /// answers Cancel, so the quit it holds does not wait forever.
    func hostDidDisappear() {
        if isAskingToQuit { cancel() }
        window = nil
    }

    // MARK: Quitting (DLG-05)

    /// The quit prompt is waiting for its answer.
    public var isAskingToQuit: Bool {
        quitPromptId != nil
    }

    /// DLG-05: asks before quitting with unsaved edits, on the window, in the words of a tab's (`UnsavedChangesPrompt`):
    /// Don't Save alone at the left (⌘D), Cancel, and Save All, the default. A minimized, hidden or covered window comes
    /// forward first. A dialog on screen is cancelled as Esc would, and the prompt shows before the ones waiting
    /// (DLG-04). `answer` gets the choice. False, asking nothing, when there is no window (⌘W closed it): an in-app
    /// modal needs one, and the caller keeps the native alert.
    public func askToQuit(unsaved: [UnsavedEditor], answer: @escaping @MainActor (UnsavedEditsAnswer) -> Void) -> Bool {
        guard let window else { return false }
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let id = UUID()
        let dialog = Dialog(
            title: UnsavedChangesPrompt.title(for: unsaved, quitting: true),
            message: UnsavedChangesPrompt.message(for: unsaved),
            buttons: [
                .dontSave { answer(.dontSave) },
                .cancel(action: { answer(.cancel) }),
                .primary(UnsavedChangesPrompt.saveTitle(count: unsaved.count)) { answer(.saveAll) },
            ]
        )
        // One that cannot be cancelled (Commit while git runs) waits behind the prompt.
        cancel()
        quitPromptId = id
        queue.insert(Entry(id: id, dialog: dialog) { [weak self] in self?.quitPromptId = nil }, at: 0)
        if queue.count == 1 { firstDidShow() } else { headDidChange() }
        return true
    }

    private func pressDefault() {
        guard let button = current?.dialog.row.defaultButton else { return }
        press(button.id)
    }

    private func moveFocus(forward: Bool) {
        guard let row = current?.dialog.row else { return }
        focusedButton = row.focus(after: focusedButton, forward: forward)
    }

    // MARK: The keyboard

    private func firstDidShow() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return used ? nil : event
            }
        }
        guard let window else { return }
        // A restore still pending (a dialog closed and another opened on the same turn, as ⌘Q does) keeps its
        // responder. A field editor is not kept: its text field is, which takes the keyboard back.
        if previousResponder == nil {
            let responder = window.firstResponder
            if let editor = responder as? NSTextView, editor.isFieldEditor {
                previousResponder = editor.delegate as? NSResponder
            } else if responder !== window {
                previousResponder = responder
            }
        }
        // Nothing behind the dim keeps the keyboard: no caret blinks in the message box, and no key reaches the
        // terminal (DLG-03). The dialog's own fields take it (Commit).
        window.makeFirstResponder(nil)
    }

    private func headDidChange() {
        focusedButton = nil
        if queue.isEmpty {
            lastDidClose()
        } else {
            // The next dialog in the queue: a field of the one before, whose view is going, gives the keyboard up.
            window?.makeFirstResponder(nil)
        }
    }

    private func lastDidClose() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let window else {
            previousResponder = nil
            return
        }
        window.makeFirstResponder(nil)
        // On the next turn, once the dialog's views are gone, and only if nothing took the keyboard meanwhile and no
        // other dialog opened.
        Task { @MainActor [weak self] in
            guard let self, self.queue.isEmpty else { return }
            let responder = self.previousResponder
            self.previousResponder = nil
            guard let responder, window.firstResponder === window else { return }
            if let view = responder as? NSView, view.window !== window { return }
            window.makeFirstResponder(responder)
        }
    }

    /// DLG-03's keys, in the host's window: whether the event was used, or kept from the window behind.
    private func handle(_ event: NSEvent) -> Bool {
        guard let entry = current, let window, event.window === window else { return false }
        let dialog = entry.dialog
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()
        let textView = window.firstResponder as? NSTextView
        // Only a dialog with fields gives them its keys: whatever else holds a text view (nothing should, see
        // `firstDidShow`) waits with the rest of the window.
        let isTyping = dialog.hasTextFields && textView?.isEditable == true
        // An input method's composition keeps Return and Esc.
        let isComposing = isTyping && textView?.hasMarkedText() == true
        switch event.keyCode {
        case 53:   // Esc
            // DLG-03's order: an open Rocky menu takes Esc first, with its own monitor.
            if MenuPresenter.isAnyMenuOpen || isComposing { return false }
            if modifiers.isEmpty { cancel() }
            return true
        case 36, 76:   // Return, and Enter on the keypad
            if isComposing { return false }
            if modifiers == .command {
                pressDefault()
                return true
            }
            if isTyping { return false }
            if modifiers.isEmpty {
                // Once Tab moved the focus, Return presses the focused button, as Space does.
                if let focusedButton { press(focusedButton) } else { pressDefault() }
            }
            return true
        case 48:   // Tab
            if isTyping { return false }
            if modifiers.isEmpty || modifiers == .shift { moveFocus(forward: modifiers.isEmpty) }
            return true
        case 49:   // Space
            if isTyping { return false }
            if modifiers.isEmpty, let focusedButton { press(focusedButton) }
            return true
        default:
            if modifiers == .command, characters == "d" {
                if let dontSave = dialog.row.dontSaveButton { press(dontSave.id) }
                return true
            }
            if modifiers.contains(.command) { return !Self.passesThrough(characters, modifiers: modifiers) }
            // ⌃` is View ▸ Toggle Terminal's key equivalent, which would fire even from a field.
            if modifiers.contains(.control), characters == "`" { return true }
            return !isTyping
        }
    }

    /// The ⌘ keys a mini-modal leaves to the app: quitting (DLG-05), hiding and minimizing, the text keys its fields and
    /// its selectable message need, and the zoom, which the dialog follows. Every other shortcut waits (DLG-03).
    private static func passesThrough(_ characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let withoutShift = modifiers.subtracting(.shift)
        switch characters {
        case "q", "m", "c", "x", "v", "a": return modifiers == .command
        case "h": return modifiers == .command || modifiers == [.command, .option]
        case "z": return withoutShift == .command
        case "=", "+", "-", "0": return withoutShift == .command
        default: return false
        }
    }
}

/// Draws the mini-modal on screen over the whole window (DLG-02, DLG-04), from `RootView`, above the settings panels
/// and Quick Open and under the menus: the settings' dim (`SettingsModalOverlay`) and the panel, centered on the window.
/// The dim fades in over 150 ms and the panel fades in growing from 0.98; closing takes 120 ms; with Reduce Motion both
/// only fade. The next dialog in the queue replaces the panel on the same dim.
struct DialogHost: View {
    private var presenter: DialogPresenter { .shared }

    var body: some View {
        GeometryReader { proxy in
            SettingsModalOverlay(isPresented: presenter.current != nil, isDialog: true, onClose: { presenter.cancel() }) {
                if let entry = presenter.current {
                    DialogPanel(dialog: entry.dialog, focusedButton: presenter.focusedButton, maxHeight: proxy.size.height * 0.8)
                        .id(entry.id)
                }
            }
            .animation(Theme.Motion.state, value: presenter.current?.id)
        }
        .ignoresSafeArea()
        // With no dialog, clicks reach the window under it.
        .allowsHitTesting(presenter.isShowing)
        .background { DialogWindowReader { presenter.window = $0 } }
        .onDisappear { presenter.hostDidDisappear() }
    }
}

/// DLG-02's panel: 360 wide (the large variant's own width), its height from its content and at most 80 % of the
/// window's, where the message and the body scroll; padding 20, 16 at the bottom; `SettingsPanel`'s look
/// (`modalPanel`). The title at 14 semibold (15 in the large variant) and the message at 12.5 `textSecondary`, both
/// left-aligned and wrapping, then the buttons, 28 points high, 8 apart, at the right, with a "Don't Save" alone at the
/// left end. VoiceOver starts on the title.
private struct DialogPanel: View {
    let dialog: Dialog
    let focusedButton: Int?
    let maxHeight: CGFloat
    @AccessibilityFocusState private var titleHasVoiceOver: Bool

    private var presenter: DialogPresenter { .shared }

    var body: some View {
        let row = dialog.row
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let agent = dialog.agent {
                    AgentIcon(agent: agent, size: 16)
                }
                Text(dialog.title)
                    .font(.rocky(dialog.isLarge ? 15 : 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleHasVoiceOver)
            }
            if dialog.message != nil || dialog.content != nil {
                FittingScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let message = dialog.message {
                            messageText(message)
                                .padding(.top, 6)
                        }
                        if let content = dialog.content {
                            content()
                                .padding(.top, 12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            buttons(row)
                .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: Zoom.shared(dialog.width), alignment: .leading)
        // Its content's height, at most `maxHeight`: a `.frame(maxHeight:)` here grew a two-line dialog to 80 % of the
        // window (user report, 2026-09-25).
        .cappedHeight(maxHeight)
        .modalPanel()
        .onAppear { titleHasVoiceOver = true }
    }

    @ViewBuilder
    private func messageText(_ message: String) -> some View {
        let text = Text(message)
            .font(.rocky(12.5))
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        if dialog.isMessageSelectable {
            text.textSelection(.enabled)
        } else {
            text
        }
    }

    private func buttons(_ row: DialogButtonRow) -> some View {
        HStack(spacing: 8) {
            ForEach(row.leading) { button($0) }
            if let footnote = dialog.footnote {
                Text(footnote)
                    .font(.rocky(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ForEach(row.trailing) { button($0) }
        }
    }

    private func button(_ button: DialogButton) -> some View {
        let action = dialog.buttons[button.id]
        return DialogButtonView(title: action.title, role: button.role, isFocused: focusedButton == button.id, help: action.help) {
            presenter.press(button.id)
        }
        .disabled(!button.isEnabled)
    }
}

/// A mini-modal's button in its role's style (DLG-02), 12.5 medium: primary white (`RockyPrimaryButtonStyle`),
/// destructive on `danger` (`RockyDestructiveButtonStyle`), cancel and secondary filled (`RockyFilledButtonStyle`); 28
/// high, padding 14, radius 7. The button Tab moved to wears KBD-01's 2-point `accent` ring, 1 point outside it.
private struct DialogButtonView: View {
    let title: String
    let role: DialogButton.Role
    let isFocused: Bool
    let help: String?
    let action: () -> Void

    var body: some View {
        styled
            .font(.rocky(12.5, weight: .medium))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .optionalHelp(help)
    }

    @ViewBuilder
    private var styled: some View {
        let button = Button(title, action: action)
        switch role {
        case .primary:
            button.buttonStyle(RockyPrimaryButtonStyle(height: 28, horizontalPadding: 14, cornerRadius: 7))
        case .destructive:
            button.buttonStyle(RockyDestructiveButtonStyle())
        case .cancel, .secondary:
            button.buttonStyle(RockyFilledButtonStyle(height: 28, horizontalPadding: 14, cornerRadius: 7))
        }
    }
}

/// A vertical scroll view as tall as its content, up to `maxHeight` and to the height it is offered, then scrolling:
/// a mini-modal's message and body within 80 % of the window (DLG-06), a permission request's ten lines. The height is
/// the content's own, measured inside the scroll view, since a `ScrollView` takes every point it is offered.
struct FittingScrollView<Content: View>: View {
    var maxHeight: CGFloat = .infinity
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let height = min(contentHeight, maxHeight)
        ScrollView {
            content()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Never taller than its content; shorter, and scrolling, when the panel has less room.
        .frame(minHeight: 0, idealHeight: height, maxHeight: height)
    }
}

/// Its one subview at its own height when that fits in `maxHeight` and the proposal, else at that limit, where a
/// `FittingScrollView` inside it scrolls.
private struct HeightCap: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let limit = min(maxHeight, proposal.height ?? .infinity)
        guard natural.height > limit else { return natural }
        return child.sizeThatFits(ProposedViewSize(width: proposal.width, height: limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension View {
    /// At most `maxHeight` tall, and no taller than its content (`HeightCap`).
    fileprivate func cappedHeight(_ maxHeight: CGFloat) -> some View {
        HeightCap(maxHeight: maxHeight) { self }
    }

    /// DLG-01: a mini-modal while `isPresented`, as SwiftUI's `confirmationDialog(isPresented:…)` was. Its answer sets
    /// `isPresented` back to false; setting it to false elsewhere, or this view going, takes the dialog away.
    func rockyDialog(isPresented: Binding<Bool>, dialog: @escaping @MainActor () -> Dialog) -> some View {
        let item = Binding<Bool?>(
            get: { isPresented.wrappedValue ? true : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        )
        return modifier(RockyDialogModifier(item: item) { _ in dialog() })
    }

    /// DLG-01: a mini-modal while `item` is set, as `confirmationDialog(…, presenting:)` was. Its answer sets `item` back
    /// to nil; another item changes the dialog in place.
    func rockyDialog<Item: Equatable>(item: Binding<Item?>, dialog: @escaping @MainActor (Item) -> Dialog) -> some View {
        modifier(RockyDialogModifier(item: item, dialog: dialog))
    }
}

/// Keeps a call site's binding and its dialog in `DialogPresenter` in step, under one id per view.
private struct RockyDialogModifier<Item: Equatable>: ViewModifier {
    @Binding var item: Item?
    let dialog: @MainActor (Item) -> Dialog
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { sync(item) }
            .onChange(of: item) { _, newItem in sync(newItem) }
            .onDisappear { DialogPresenter.shared.withdraw(id: id) }
    }

    private func sync(_ item: Item?) {
        guard let item else {
            DialogPresenter.shared.withdraw(id: id)
            return
        }
        let binding = $item
        DialogPresenter.shared.present(dialog(item), id: id) { binding.wrappedValue = nil }
    }
}

/// Reports the window it is in, and nil when it leaves it.
private struct DialogWindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (NSWindow?) -> Void = { _ in }

        /// Never takes a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange(window)
        }
    }
}
