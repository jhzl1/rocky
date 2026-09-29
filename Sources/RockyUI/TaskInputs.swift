import AppKit
import RockyKit
import SwiftUI

/// TSK-04: asks a run's inputs one at a time, each before anything of the run starts (`AppModel.runTask`). A
/// pickString is a Rocky menu above the Run button: the input's description as its caption, one row per option, the
/// default checked and highlighted so Return takes it, ↑/↓ to move (Decision 11 of M2.9). A promptString is a DLG-02
/// mini-modal holding one field. Esc, a click outside the menu, or Cancel answers nil, which cancels the whole run.
@MainActor
struct TaskInputPrompter {
    let menus: MenuPresenter?
    /// The Run button's frame in window coordinates, read when each input is asked.
    let anchor: () -> CGRect

    func ask(_ input: TaskInput) async -> String? {
        switch input.kind {
        case .pickString(let options): await pick(input, options: options)
        case .promptString(let password): await prompt(input, isSecure: password)
        // `VSCodeTasks.plan` refuses a task that reads one (TSK-07).
        case .unsupported: nil
        }
    }

    private func pick(_ input: TaskInput, options: [TaskInput.Option]) async -> String? {
        guard let menus, !options.isEmpty else { return nil }
        let frame = anchor()
        return await withCheckedContinuation { continuation in
            let answer = InputAnswer(continuation)
            let defaultIndex = options.firstIndex { $0.value == input.defaultValue }
            let actions: [@MainActor () -> Void] = options.map { option in { answer.give(option.value) } }
            menus.show(.init(
                id: "task-input-\(input.id)",
                anchor: frame,
                placement: .aboveLeading,
                width: Zoom.shared(260),
                keyActions: actions,
                // Without a default, the first row, as VS Code's picker lights it.
                initialHighlight: defaultIndex ?? 0,
                onCancel: { answer.give(nil) },
                content: AnyView(TaskPickMenu(input: input, options: options, defaultIndex: defaultIndex, actions: actions))
            ))
        }
    }

    /// The mini-modal's title is the input's description; the field is 300 wide, 28 high, with the default in it and
    /// selected, and a secure field for `password: true`. Cancel · Run, Run the default: Return in the field runs, Esc
    /// cancels.
    private func prompt(_ input: TaskInput, isSecure: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            let answer = InputAnswer(continuation)
            let field = PromptText(input.defaultValue ?? "")
            let id = UUID()
            let submit: @MainActor () -> Void = {
                answer.give(field.text)
                DialogPresenter.shared.withdraw(id: id)
            }
            DialogPresenter.shared.present(Dialog(
                title: input.description ?? input.id,
                width: 340,
                content: { AnyView(TaskPromptField(text: field, isSecure: isSecure, label: input.description ?? input.id, onSubmit: submit)) },
                keepsSmallTitle: true,
                hasTextFields: true,
                buttons: [
                    .cancel(action: { answer.give(nil) }),
                    .primary("Run") { answer.give(field.text) },
                ]
            ), id: id)
        }
    }
}

/// Resumes its run's wait once, with the first answer: a pick, Run, or a cancel that comes after them does nothing.
@MainActor
private final class InputAnswer {
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func give(_ value: String?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The promptString field's text, shared by the field and the dialog's Run button.
@MainActor
@Observable
private final class PromptText {
    var text: String

    init(_ text: String) {
        self.text = text
    }
}

/// A pickString's rows (TSK-04): the caption, 10.5 `textTertiary`, then each option's label, the default checked.
private struct TaskPickMenu: View {
    let input: TaskInput
    let options: [TaskInput.Option]
    let defaultIndex: Int?
    let actions: [@MainActor () -> Void]

    var body: some View {
        if let description = input.description {
            MenuSectionTitle(title: description, size: 10.5)
        }
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            MenuItem(title: option.label, isChecked: index == defaultIndex, keyIndex: index) {
                actions[index]()
            }
        }
    }
}

/// TSK-04's field: 28 high, `fillControl` under a `hairline`, radius 6, padding 8, 13-point text; the ring turns
/// `accent` at 55 % while it has the keyboard, which it takes when the dialog shows.
private struct TaskPromptField: View {
    @Bindable var text: PromptText
    let isSecure: Bool
    let label: String
    let onSubmit: @MainActor () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        field
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.rocky(13))
            .foregroundStyle(Theme.textPrimary)
            .focused($isFocused)
            .onSubmit { onSubmit() }
            .padding(.horizontal, 8)
            .frame(height: Zoom.shared(28))
            .background(Theme.fillControl, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Theme.accent.opacity(0.55) : Theme.hairline)
            }
            .accessibilityLabel(Text(verbatim: label))
            // After the dialog is in its window, or the focus does not take. The field selects its text as it takes
            // the keyboard, so typing replaces the default.
            .task { isFocused = true }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(label, text: $text.text, prompt: Text(verbatim: ""))
        } else {
            TextField(label, text: $text.text, prompt: Text(verbatim: ""))
        }
    }
}
