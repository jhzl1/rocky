import AppKit
import Quartz
import RockyKit
import SwiftUI
import Textual

/// A file opened in its own tab from a badge (one outside the worktree; a worktree file opens its worktree tab): an
/// image fitted to the tab, code, data and text in the code editor (`EDIT-01`; Markdown with Preview | Edit, Preview
/// first), a PDF or an image AppKit cannot draw in Quick Look, and any other file (an archive, audio, video) as
/// `FIL-06`'s binary card. A worktree tab shows images and other media through it too, without its header.
struct FileTabView: View {
    let model: AppModel
    let workspaceId: String
    /// Absolute.
    let path: String
    /// A diff tab draws its own header over the file (DIFF-01), so it leaves this one out.
    var showsHeader = true
    /// Markdown's Preview | Edit, while the tab is on screen.
    @State private var markdownMode: MarkdownTabMode = .preview

    private var url: URL { URL(fileURLWithPath: path) }
    private var kind: FileKind { FileKind(path: path) }

    private var isMarkdown: Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    /// The editor is on screen: an editor file, and not a Markdown file on Preview.
    private var isEditing: Bool {
        kind.opensInEditor && (!isMarkdown || markdownMode == .edit)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if kind.opensInEditor {
                    EditorBanners(model: model, workspaceId: workspaceId, path: path, isEditing: isEditing)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // DIFF-01's path chip, which opens the file in the default app (OPN-02); the full path, with "~".
            PathChip(path: (path as NSString).abbreviatingWithTildeInPath, url: url, isFolder: kind == .folder)
                .layoutPriority(1)
            Spacer()
            if kind.opensInEditor {
                EditorStatusControls(model: model, workspaceId: workspaceId, path: path)
            }
            if isMarkdown {
                ModePicker<MarkdownTabMode>(
                    options: [.init(mode: .preview, title: "Preview"), .init(mode: .edit, title: "Edit")],
                    selection: markdownMode,
                    select: { markdownMode = $0 }
                )
            }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .clickable()
            .help("Show in Finder")
            Button("Open", systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.open(url)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .clickable()
            .help("Open in its app")
        }
        .padding(.horizontal, 16)
        // A diff tab's header height (DIFF-01), so the chip sits the same in both kinds of tab.
        .frame(height: Zoom.shared(34))
    }

    @ViewBuilder
    private var content: some View {
        if kind == .image, let image = NSImage(contentsOfFile: path) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(24)
            }
            .defaultScrollAnchor(.center)
        } else if kind.opensInEditor {
            EditorPane(model: model, workspaceId: workspaceId, path: path, showsMarkdownPreview: isMarkdown && markdownMode == .preview)
        } else if !FileManager.default.fileExists(atPath: path) {
            ContentUnavailableView("File not found", systemImage: "questionmark.folder", description: Text(path))
        } else if kind == .image || kind == .pdf {
            // FIL-06: images and PDFs keep today's preview.
            QuickLookView(url: url)
        } else {
            UnopenedFileView(url: url, size: nil)
        }
    }
}

/// `FIL-06`'s card for a file Rocky does not open, centered, 13 `textSecondary`, with filled buttons under it: past
/// 20 MB, "Too large to open in Rocky · 48 MB" with Open in Finder and one button per installed editor (OPN-01), which
/// opens the file itself; any other binary file, "Binary file · 112 KB" with Open in Finder. A nil `size` is read from
/// the file's attributes, off the main actor. The editors are looked up once, when the card appears.
struct UnopenedFileView: View {
    let url: URL
    let size: Int?
    @State private var readSize: Int?
    @State private var editors: [(editor: ExternalEditor, app: URL)] = []
    @Environment(ToastPresenter.self) private var toasts: ToastPresenter?

    private var shownSize: Int? { size ?? readSize }

    private var isTooLarge: Bool { (shownSize ?? 0) > FileContent.readableLimit }

    private var title: String {
        let label = isTooLarge ? "Too large to open in Rocky" : "Binary file"
        return shownSize.map { "\(label) · \(FileSizeText.format($0))" } ?? label
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(verbatim: title)
                .font(.rocky(13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if isTooLarge {
                    ForEach(Array(editors.enumerated()), id: \.offset) { _, entry in
                        Button("Open in \(entry.editor.displayName)") {
                            ExternalEditorOpener.open(url, in: entry.editor, app: entry.app, toasts: toasts)
                        }
                    }
                }
            }
            .font(.rocky(12.5, weight: .medium))
            .buttonStyle(RockyFilledButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            guard size == nil else { return }
            let url = self.url
            readSize = await Task.blocking {
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
            }.value
        }
        .task(id: isTooLarge) {
            guard isTooLarge, editors.isEmpty else { return }
            editors = ExternalEditor.installed { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        }
    }
}

/// A file's size as `FIL-06` writes it: "3.4 MB", "112 KB" (decimal units, as Finder shows them).
enum FileSizeText {
    static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A Markdown file tab's two modes (`EDIT-01`).
enum MarkdownTabMode: Hashable {
    case preview, edit
}

/// Markdown rendered like the agent's replies, in a reading column: a Markdown file tab's Preview.
struct MarkdownFilePreview: View {
    let text: String

    var body: some View {
        ScrollView {
            StructuredText(text, parser: RockyMarkdownParser(zoom: Zoom.shared.scale))
                .textual.structuredTextStyle(RockyMarkdownStyle())
                .textual.textSelection(.enabled)
                .font(.rocky(14))
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Quick Look's own preview of a file (PDFs, movies, documents…).
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}
