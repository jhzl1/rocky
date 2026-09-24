import AppKit
import RockyKit
import SwiftUI
import UniformTypeIdentifiers

/// What a file is, for its badge's icon and color (green images, red PDFs, blue code… like Conductor's).
enum FileKind {
    case image, pdf, code, data, text, spreadsheet, archive, audio, video, folder, other

    private static let codeExtensions: Set = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp",
        "m", "mm", "cs", "php", "sh", "zsh", "bash", "fish", "sql", "html", "css", "scss", "vue", "svelte", "lua",
        "dart", "ex", "exs",
    ]
    private static let dataExtensions: Set = ["json", "jsonc", "yaml", "yml", "toml", "plist", "xml", "ini", "env", "lock"]
    private static let textExtensions: Set = ["md", "markdown", "mdx", "txt", "rtf", "log"]
    private static let spreadsheetExtensions: Set = ["csv", "tsv", "xls", "xlsx", "numbers"]

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        // By extension first: UTType maps some code extensions elsewhere (".ts" is an MPEG stream to it).
        if Self.codeExtensions.contains(ext) { self = .code; return }
        if Self.dataExtensions.contains(ext) { self = .data; return }
        if Self.textExtensions.contains(ext) { self = .text; return }
        if Self.spreadsheetExtensions.contains(ext) { self = .spreadsheet; return }
        if ext.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                self = .folder
                return
            }
        }
        guard let type = UTType(filenameExtension: ext) else { self = .other; return }
        if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .archive) { self = .archive }
        else if type.conforms(to: .audio) { self = .audio }
        else if type.conforms(to: .movie) { self = .video }
        else if type.conforms(to: .sourceCode) { self = .code }
        else if type.conforms(to: .text) { self = .text }
        else { self = .other }
    }

    var symbol: String {
        switch self {
        case .image: "photo.fill"
        case .pdf: "doc.richtext.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .data: "curlybraces"
        case .text: "doc.text.fill"
        case .spreadsheet: "tablecells.fill"
        case .archive: "doc.zipper"
        case .audio: "waveform"
        case .video: "film.fill"
        case .folder: "folder.fill"
        case .other: "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .image: Color(red: 0.30, green: 0.78, blue: 0.40)
        case .pdf: Color(red: 0.94, green: 0.38, blue: 0.35)
        case .code: Color(red: 0.42, green: 0.64, blue: 0.98)
        case .data: Color(red: 0.95, green: 0.77, blue: 0.32)
        case .text: Color(white: 0.78)
        case .spreadsheet: Color(red: 0.25, green: 0.75, blue: 0.62)
        case .archive: Color(red: 0.96, green: 0.60, blue: 0.28)
        case .audio: Color(red: 0.93, green: 0.46, blue: 0.70)
        case .video: Color(red: 0.66, green: 0.53, blue: 0.97)
        case .folder: Color(red: 0.46, green: 0.70, blue: 0.98)
        case .other: Color(white: 0.6)
        }
    }
}

/// Opens a file in a tab of the workspace, next to its conversations. Set by `WorkspaceDetailView`.
struct OpenFileAction {
    let open: @MainActor (String) -> Void

    @MainActor
    func callAsFunction(_ path: String) {
        open(path)
    }
}

extension EnvironmentValues {
    @Entry var openFile: OpenFileAction?
}

/// How a file badge looks, like Conductor's: a bordered badge in two parts, the icon colored by the file's type and
/// the name. `showsRemove` puts an X in place of the icon. Only drawing, so the message box can also draw it as an
/// image (`FileAttachment`). Its size is fixed by `size(for:)`, so text can leave exactly its room in a line.
struct FileBadgeLook: View {
    let path: String
    var isHovered = false
    var showsRemove = false

    // Sizes at 100%; each one follows the zoom.
    static var height: CGFloat { Zoom.shared(22) }
    static var iconWidth: CGFloat { Zoom.shared(24) }
    private static var maxNameWidth: CGFloat { Zoom.shared(240) }
    private static let fontSize: CGFloat = 12.5
    private static var namePadding: (leading: CGFloat, trailing: CGFloat) { (Zoom.shared(7), Zoom.shared(8)) }
    /// Where a badge inside a line sits against the text's baseline: centered on 14-point text.
    static var baselineOffset: CGFloat { Zoom.shared(-6) }

    static func size(for path: String) -> CGSize {
        let name = URL(fileURLWithPath: path).lastPathComponent as NSString
        let nameWidth = ceil(name.size(withAttributes: [.font: NSFont.systemFont(ofSize: Zoom.shared(fontSize))]).width)
        return CGSize(width: iconWidth + 1 + namePadding.leading + min(nameWidth, maxNameWidth) + namePadding.trailing, height: height)
    }

    var body: some View {
        let kind = FileKind(path: path)
        let size = Self.size(for: path)
        HStack(spacing: 0) {
            Group {
                if showsRemove {
                    Image(systemName: "xmark")
                        .font(.rocky(9, weight: .bold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: kind.symbol)
                        .font(.rocky(11))
                        .foregroundStyle(kind.color)
                }
            }
            .frame(width: Self.iconWidth, height: Self.height)
            .background(Color.black.opacity(0.28))
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, Self.namePadding.leading)
                .padding(.trailing, Self.namePadding.trailing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.rocky(Self.fontSize))
        .frame(width: size.width, height: size.height)
        .background(Color.white.opacity(isHovered ? 0.08 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// A file badge in the conversation. Hovering shows a preview (`FilePreviewPanel`); clicking opens the file in a tab
/// of the workspace. With `onRemove`, hovering shows an X in place of the icon, and clicking it removes the file.
struct FileBadge: View {
    let path: String
    var onRemove: (() -> Void)?
    @Environment(\.openFile) private var openFile
    @State private var hovering = false
    @State private var anchor = ViewAnchor.Box()

    static var height: CGFloat { FileBadgeLook.height }
    static var baselineOffset: CGFloat { FileBadgeLook.baselineOffset }

    static func size(for path: String) -> CGSize {
        FileBadgeLook.size(for: path)
    }

    var body: some View {
        FileBadgeLook(path: path, isHovered: hovering, showsRemove: hovering && onRemove != nil)
            .overlay(alignment: .leading) {
                if hovering, let onRemove {
                    Button(action: onRemove) {
                        Color.clear
                            .frame(width: FileBadgeLook.iconWidth, height: FileBadgeLook.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .help("Remove")
                }
            }
            .contentShape(Rectangle())
            .background(ViewAnchor(box: anchor))
            .onHover { inside in
                hovering = inside
                if inside {
                    FilePreviewPanel.shared.show(path, over: anchor.view)
                } else {
                    FilePreviewPanel.shared.hide(path)
                }
            }
            .onTapGesture {
                FilePreviewPanel.shared.hide(path)
                if let openFile { openFile(path) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            .onDisappear { FilePreviewPanel.shared.hide(path) }
            .clickable()
    }
}

/// Text with files inside its lines, like a message in Conductor: each `PromptAttachment.marker` in `text` is the
/// next file of `files`. The text leaves a gap of the badge's size there, and the real badges, which can be hovered
/// and clicked, are laid over the gaps where the text layout put them.
struct InlineFilesText: View {
    let text: String
    let files: [String]

    /// Marks where a badge goes in the text layout.
    struct FileSlot: TextAttribute {
        let index: Int
    }

    private struct Slot: Identifiable {
        let index: Int
        let rect: CGRect
        var id: Int { index }
    }

    var body: some View {
        composed
            .fixedSize(horizontal: false, vertical: true)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { geometry in
                    if let anchored = layouts.first {
                        let origin = geometry[anchored.origin]
                        ForEach(slots(in: anchored.layout)) { slot in
                            FileBadge(path: files[slot.index])
                                .position(x: origin.x + slot.rect.midX, y: origin.y + slot.rect.midY)
                        }
                    }
                }
            }
    }

    /// Files without a marker (messages saved before files sat inside the text) go first.
    private var parts: [String] {
        let markers = text.components(separatedBy: PromptAttachment.marker).count - 1
        let missing = String(repeating: PromptAttachment.marker + " ", count: max(0, files.count - markers))
        return (missing + text).components(separatedBy: PromptAttachment.marker)
    }

    private var composed: Text {
        var result = Text(verbatim: "")
        for (index, part) in parts.enumerated() {
            if index > 0, index - 1 < files.count {
                let size = FileBadge.size(for: files[index - 1])
                result = result + Text(Image(size: size) { _ in })
                    .baselineOffset(FileBadge.baselineOffset)
                    .customAttribute(FileSlot(index: index - 1))
            }
            result = result + Text(verbatim: part)
        }
        return result
    }

    private func slots(in layout: Text.Layout) -> [Slot] {
        var slots: [Slot] = []
        for line in layout {
            for run in line {
                if let slot = run[FileSlot.self], slot.index < files.count {
                    slots.append(Slot(index: slot.index, rect: run.typographicBounds.rect))
                }
            }
        }
        return slots
    }
}

/// A short detail next to an activity row's label: a thought's first line, a command, a status.
struct DetailBadge: View {
    let text: String
    var monospaced = false
    var tint: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(monospaced ? .rocky(12, design: .monospaced) : .rocky(12.5))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.07)))
    }
}

/// Lays its views out in rows, starting a new row when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if added > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
