import AppKit
import Quartz
import RockyKit
import SwiftUI
import Textual

/// A file opened in its own tab from a badge, in large: an image fitted to the tab, Markdown rendered like the
/// agent's replies, code and text in monospace, anything else in Quick Look. The view a later "see what the agent
/// changed" will open files in.
struct FileTabView: View {
    let path: String
    @State private var text: String?
    @State private var loaded = false

    private var url: URL { URL(fileURLWithPath: path) }
    private var kind: FileKind { FileKind(path: path) }
    /// Bigger text files open in Quick Look, which pages through them.
    private static let maxTextBytes = 2_000_000

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: path) {
            loaded = false
            text = await Self.readText(path: path, kind: kind)
            loaded = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
            Text(path)
                .font(.rocky(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer()
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
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if !FileManager.default.fileExists(atPath: path) {
            ContentUnavailableView("File not found", systemImage: "questionmark.folder", description: Text(path))
        } else if kind == .image, let image = NSImage(contentsOfFile: path) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(24)
            }
            .defaultScrollAnchor(.center)
        } else if !loaded {
            ProgressLabel(text: "Opening \(url.lastPathComponent)…")
        } else if let text, url.pathExtension.lowercased() == "md" || url.pathExtension.lowercased() == "markdown" {
            ScrollView {
                StructuredText(text, parser: RockyMarkdownParser(zoom: Zoom.shared.scale))
                    .textual.structuredTextStyle(RockyMarkdownStyle())
                    .textual.textSelection(.enabled)
                    .font(.rocky(14))
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        } else if let text {
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: text)
                    .font(.rocky(12.5, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            QuickLookView(url: url)
        }
    }

    /// The file's text when it is a text file of a readable size; nil sends it to Quick Look.
    private static func readText(path: String, kind: FileKind) async -> String? {
        switch kind {
        case .code, .data, .text, .spreadsheet: break
        default: return nil
        }
        let limit = maxTextBytes
        // Off the cooperative pool (`Task.blocking`): file reads block, and a starved pool stops terminal output.
        return await Task.blocking {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            guard size <= limit, let data = FileManager.default.contents(atPath: path) else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
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
