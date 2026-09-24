import SwiftUI

// The pieces of Rocky's settings panels, shared by the app's Settings (`SettingsModal`) and a repository's
// (`RepoSettingsModal`) so both look the same (user request, 2026-09-23). A panel is `SettingsModalOverlay` holding a
// `SettingsPanel`; its content is `SettingsSection` cards of `SettingsRow`s split by `SettingsDivider`s, with
// `SettingsButton`, `SettingsMenuLabel` and `SettingsTextField` as their controls.

/// The dimmed window under a settings panel, and the panel, while `isPresented`. A click on the dimmed part calls
/// `onClose`; the presenter's own Esc monitor closes it too.
struct SettingsModalOverlay<Panel: View>: View {
    let isPresented: Bool
    let onClose: () -> Void
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                    .transition(.opacity)
                panel()
                    .padding(40)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .ignoresSafeArea()
        .animation(Theme.Motion.state, value: isPresented)
    }
}

/// A settings panel: its title and × over a hairline, the scrolling `content`, then an optional `footer` (a
/// repository's Cancel and Save).
struct SettingsPanel<Content: View, Footer: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.rocky(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button("Close", systemImage: "xmark") { onClose() }
                    .buttonStyle(RockyIconButtonStyle())
                    .help("Close (Esc)")
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            SettingsDivider()
            ScrollView {
                content()
                    .padding(24)
            }
            footer()
        }
        .font(.rocky(13))
        // As large as Settings was as a window, smaller when the window is.
        .frame(maxWidth: Zoom.shared(620), maxHeight: Zoom.shared(600))
        .background(Color.rockyBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.composerBorder))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .accessibilityAddTraits(.isModal)
    }
}

extension SettingsPanel where Footer == EmptyView {
    init(title: String, onClose: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, onClose: onClose, content: content, footer: { EmptyView() })
    }
}

/// A titled card of rows. Rows inside it are split by `SettingsDivider`s.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.rocky(12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 14)
                .background(Theme.composer, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.composerBorder))
        }
    }
}

/// A row of a section: its title with an optional detail under it, and its control at the trailing edge.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: Text?
    @ViewBuilder let control: () -> Control

    /// `detail` is markdown, so backticks set a path in code (`~/.local/share/opencode`) and `*` is emphasis.
    init(_ title: String, detail: String?, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail.map { Text(LocalizedStringKey($0)) }
        self.control = control
    }

    /// `verbatimDetail` shows as written, so the `*` of a glob such as `.vscode/*` stays a character.
    init(_ title: String, verbatimDetail: String?, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = verbatimDetail.map { Text(verbatim: $0) }
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    detail
                        .font(.rocky(11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 10)
    }
}

/// The line between two rows of a section, and under a panel's header.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

/// A small button of the settings, drawn like Rocky's other controls.
struct SettingsButton: View {
    var title: String?
    var systemImage: String?
    let help: String
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    init(title: String, help: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.isEnabled = isEnabled
        self.action = action
    }

    init(systemImage: String, help: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: Zoom.shared(14), height: Zoom.shared(14))
                } else if let title {
                    Text(title)
                }
            }
            .font(.rocky(12))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(Color.white.opacity(hovering && isEnabled ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The label of a `MenuButton` in the settings: the current choice and an up-down chevron on a small fill, lit while
/// its menu is open, with a spinner while its choices load.
struct SettingsMenuLabel: View {
    let title: String
    let isOpen: Bool
    var isLoading = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if isLoading {
                CircularProgress(size: 10)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.rocky(9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.rocky(12))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(isOpen ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// A text field of the settings, drawn like the sidebar's search field: `fillControl` with a hairline, an `accent`
/// ring while focused. The prompt shows verbatim. `isMultiline` grows it to six lines (a script); `isSecure` hides
/// what is typed (a secret).
struct SettingsTextField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    let isMonospaced: Bool
    let isSecure: Bool
    let isMultiline: Bool
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    init(
        _ label: String,
        text: Binding<String>,
        prompt: String = "",
        isMonospaced: Bool = false,
        isSecure: Bool = false,
        isMultiline: Bool = false,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.isMonospaced = isMonospaced
        self.isSecure = isSecure
        self.isMultiline = isMultiline
        self.onSubmit = onSubmit
    }

    var body: some View {
        field
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(.rocky(12, design: isMonospaced ? .monospaced : .default))
            .foregroundStyle(Theme.textPrimary)
            .focused($isFocused)
            .onSubmit { onSubmit() }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.fillControl, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Theme.accent.opacity(0.55) : Theme.hairline)
            )
            .accessibilityLabel(Text(verbatim: label))
    }

    @ViewBuilder
    private var field: some View {
        let promptText = Text(verbatim: prompt).foregroundStyle(Theme.textTertiary)
        if isSecure {
            SecureField(label, text: $text, prompt: promptText)
        } else if isMultiline {
            TextField(label, text: $text, prompt: promptText, axis: .vertical)
                .lineLimit(1...6)
        } else {
            TextField(label, text: $text, prompt: promptText)
        }
    }
}
