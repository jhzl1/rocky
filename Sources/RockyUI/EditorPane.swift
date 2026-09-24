import AppKit
import RockyKit
import SwiftUI

extension FileKind {
    /// Code, data and text files, and files of no known kind (a Makefile, a dotfile), open in the editor when their
    /// bytes are text; images, PDFs, audio, video and archives show as file tabs showed them before M3 (`EDIT-01`).
    var opensInEditor: Bool {
        switch self {
        case .code, .data, .text, .spreadsheet, .other: true
        case .image, .pdf, .archive, .audio, .video, .folder: false
        }
    }
}

/// A file in the code editor, inside its tab (`EDIT-01`…`EDIT-04`): the file read into the model once (its buffer
/// outlives the view, so hiding the tab keeps unsaved edits), then `CodeEditor` on that buffer, read-only and plain past
/// 2 MB, with the go-to-line field over it on ⌘L. A file the editor cannot show says "File not found", or shows
/// `FIL-06`'s card: too large to open past 20 MB, else binary (a NUL in its first 8 KB, or text that is not UTF-8).
struct EditorPane: View {
    let model: AppModel
    let workspaceId: String
    /// Absolute: the file's key in `AppModel.editors`.
    let path: String
    /// The file at the base, for `EDIT-04`'s change bars; nil hides them.
    var baseText: String?
    /// A Markdown file tab on Preview: the buffer rendered instead of the editor (`EDIT-01`).
    var showsMarkdownPreview = false
    /// Whether the editor takes the keyboard when it appears.
    var takesFocus = true
    @State private var asksForLine = false
    @State private var lineRequest: EditorLineRequest?

    var body: some View {
        content
            .task(id: path) { await model.openEditor(workspaceId: workspaceId, path: path) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.editor(workspaceId: workspaceId, path: path) {
        case nil, .loading?:
            ProgressLabel(text: "Opening \((path as NSString).lastPathComponent)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing?:
            ContentUnavailableView("File not found", systemImage: "questionmark.folder", description: Text(path))
        case .unavailable(let size)?:
            UnopenedFileView(url: URL(fileURLWithPath: path), size: size)
        case .document(let document)?:
            if showsMarkdownPreview {
                MarkdownFilePreview(text: document.buffer.text)
            } else {
                editor(isReadOnly: document.isReadOnly)
            }
        }
    }

    private func editor(isReadOnly: Bool) -> some View {
        let model = self.model
        let workspaceId = self.workspaceId
        let path = self.path
        // Read from the model at the time it is read, never a copy from this body: the editor compares it with what it
        // holds, and an older value would look like a reload and undo the last keystrokes.
        let text = Binding(
            get: { model.editor(workspaceId: workspaceId, path: path)?.document?.buffer.text ?? "" },
            set: { model.setEditorText($0, workspaceId: workspaceId, path: path) }
        )
        return CodeEditor(
            text: text,
            // FIL-06's large files stay plain text: Prism over megabytes would stall the tab.
            language: isReadOnly ? nil : SyntaxHighlighter.language(forPath: path),
            baseText: isReadOnly ? nil : baseText,
            goToLine: lineRequest,
            isEditable: !isReadOnly,
            takesFocus: takesFocus,
            onGoToLine: { asksForLine = true },
            zoom: Zoom.shared.scale
        )
        .overlay(alignment: .top) {
            if asksForLine {
                GoToLineField(
                    go: { line in
                        asksForLine = false
                        lineRequest = EditorLineRequest(line: line, serial: (lineRequest?.serial ?? 0) + 1)
                    },
                    dismiss: { asksForLine = false }
                )
                .padding(.top, 10)
            }
        }
        // File ▸ Go to Line… (⌘L, KBD-02) while this editor is on screen, whether or not it has the keyboard: a preview
        // tab leaves the keyboard in the tree (FIL-05).
        .focusedSceneValue(\.editorGoToLine, EditorGoToLineAction { asksForLine = true })
    }
}

/// What File ▸ Go to Line… does: opens the go-to-line field of the editor on screen. `EditorPane` publishes it while
/// its editor shows, so the command is off everywhere else (a diff, a conversation, a Markdown preview).
public struct EditorGoToLineAction {
    let open: @MainActor () -> Void

    @MainActor
    public func run() {
        open()
    }
}

private struct EditorGoToLineKey: FocusedValueKey {
    typealias Value = EditorGoToLineAction
}

extension FocusedValues {
    public var editorGoToLine: EditorGoToLineAction? {
        get { self[EditorGoToLineKey.self] }
        set { self[EditorGoToLineKey.self] = newValue }
    }
}

/// `EDIT-01`'s go to line (⌘L): a small field over the editor. Return goes to the line typed, Esc gives the keyboard
/// back to the editor where it was, and clicking elsewhere only closes it.
private struct GoToLineField: View {
    let go: (Int?) -> Void
    let dismiss: () -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Go to line")
                .font(.rocky(12))
                .foregroundStyle(Theme.textSecondary)
            TextField("Line", text: $text)
                .textFieldStyle(.plain)
                .font(.rocky(12.5, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: Zoom.shared(72))
                .focused($isFocused)
                .onSubmit { go(Int(text.trimmingCharacters(in: .whitespaces))) }
                .onExitCommand { go(nil) }
        }
        .padding(.horizontal, 10)
        .frame(height: Zoom.shared(30))
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .onAppear { isFocused = true }
        .onChange(of: isFocused) { _, focused in
            if !focused { dismiss() }
        }
    }
}

/// `EDIT-02` and `EDIT-03`'s part of a file tab's header: "Edited" (11.5 `textSecondary`) and Save while the file has
/// unsaved edits, else "Reloaded" for the 2 s after a change on disk reloaded it (the model clears it). Nothing for a
/// file that is not in the editor. ⌘S is File ▸ Save, which saves the file on screen (`AppModel.saveVisibleEditor`).
struct EditorStatusControls: View {
    let model: AppModel
    let workspaceId: String
    /// Absolute.
    let path: String

    var body: some View {
        let document = model.editor(workspaceId: workspaceId, path: path)?.document
        if let document, document.buffer.isDirty || document.buffer.keepsMine {
            HStack(spacing: 10) {
                Text("Edited")
                    .font(.rocky(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                EditorSaveButton(model: model, workspaceId: workspaceId, path: path)
            }
        } else if document?.reloadedAt != nil {
            Text("Reloaded")
                .font(.rocky(11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
        }
    }
}

/// `EDIT-02`'s Save: a filled button. Its ⌘S is the File menu's Save (KBD-02), one owner for the key, which the
/// menu leaves to the settings panels while they are open (`SettingsPresenter.isAnySettingsPanelOpen`).
private struct EditorSaveButton: View {
    let model: AppModel
    let workspaceId: String
    let path: String

    var body: some View {
        Button("Save") {
            let model = self.model
            let workspaceId = self.workspaceId
            let path = self.path
            Task { await model.saveEditor(workspaceId: workspaceId, path: path) }
        }
        .font(.rocky(12.5, weight: .medium))
        .buttonStyle(RockyFilledButtonStyle())
        .help("Save (⌘S)")
    }
}

/// The banners between a file tab's header and its content (`EDIT-02`, `EDIT-03`, `FIL-06`), 12.5 with a hairline under
/// each: the file changed on disk under unsaved edits (Reload, Keep Mine), in both modes; the agent working in the
/// workspace, while the editor shows, until closed in this tab; a large file read-only in Rocky, while the editor
/// shows; and, in Diff mode, the unsaved edits the diff does not show yet.
struct EditorBanners: View {
    let model: AppModel
    let workspaceId: String
    /// Absolute.
    let path: String
    /// The editor is on screen: Edit mode, or a file tab's editor.
    let isEditing: Bool

    var body: some View {
        let document = model.editor(workspaceId: workspaceId, path: path)?.document
        VStack(spacing: 0) {
            if let document {
                if document.buffer.conflict {
                    EditorBanner(style: .warning, text: "This file changed on disk.") {
                        Button("Reload") { model.reloadEditor(workspaceId: workspaceId, path: path) }
                            .font(.rocky(12.5))
                            .buttonStyle(RockyTextButtonStyle(height: 26))
                            .help("Drop your edits for the file on disk")
                        Button("Keep Mine") { model.keepMine(workspaceId: workspaceId, path: path) }
                            .font(.rocky(12.5, weight: .medium))
                            .buttonStyle(RockyFilledButtonStyle())
                            .help("Your next save overwrites the file on disk")
                    }
                }
                if isEditing, !document.hidesAgentBanner, let agent = model.workingAgent(workspaceId: workspaceId) {
                    EditorBanner(style: .info, text: "\(agent.displayName) is working in this workspace and may change this file.") {
                        Button("Close", systemImage: "xmark") { model.hideAgentBanner(workspaceId: workspaceId, path: path) }
                            .font(.rocky(10))
                            .buttonStyle(RockyIconButtonStyle(size: 18))
                            .help("Close")
                    }
                }
                // FIL-06: text of 2–20 MB, shown whole but plain and never edited.
                if isEditing, document.isReadOnly {
                    EditorBanner(style: .info, text: "Large file · \(FileSizeText.format(document.size)) · read-only in Rocky") {
                        EmptyView()
                    }
                }
                if !isEditing, document.buffer.isDirty {
                    EditorBanner(style: .info, text: "Unsaved edits · Save to see them here.") {
                        EditorSaveButton(model: model, workspaceId: workspaceId, path: path)
                    }
                }
            }
        }
    }
}

/// One banner: a warning (`bannerWarning`, with the error glyph) or a note (`bannerInfo`), its text, then its buttons;
/// 7 × 14 padding.
private struct EditorBanner<Actions: View>: View {
    enum Style {
        case warning, info
    }

    let style: Style
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            if style == .warning {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.rocky(13))
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .font(.rocky(12.5))
        .foregroundStyle(style == .warning ? Theme.bannerWarningText : Theme.bannerInfoText)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(style == .warning ? Theme.bannerWarning : Theme.bannerInfo)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
