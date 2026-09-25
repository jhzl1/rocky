import AppKit
import SwiftUI

/// Gives a SwiftUI view its NSView, so AppKit can say where it is on screen. Clicks go through it.
struct ViewAnchor: NSViewRepresentable {
    @MainActor
    final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The preview that floats over a file badge while the pointer rests on it, like Conductor's: the image itself, the
/// first lines of a text file, or the file's icon and size. A borderless child window, so it shows over the message
/// box and over badges inside the text view alike, and never takes a click.
@MainActor
final class FilePreviewPanel {
    static let shared = FilePreviewPanel()

    private var panel: NSPanel?
    private var pending: Task<Void, Never>?
    private var shownPath: String?
    /// How long the pointer rests on a badge before its preview opens, so passing over badges opens nothing.
    private static let delay = Duration.milliseconds(350)
    private static let gap: CGFloat = 6

    func show(_ path: String, over view: NSView?) {
        show(path, in: view?.window) { [weak view] in
            guard let view, let window = view.window else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
    }

    /// For a badge that is not a view of its own (drawn inside the message box's text): `badge` gives its frame
    /// on screen when the preview opens.
    func show(_ path: String, in window: NSWindow?, badge: @escaping @MainActor () -> NSRect?) {
        pending?.cancel()
        pending = Task { [weak self, weak window] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self, let window, let frame = badge() else { return }
            self.present(path, near: frame, parent: window)
        }
    }

    /// Hides the preview of `path`; the preview of another badge that opened meanwhile stays.
    func hide(_ path: String) {
        pending?.cancel()
        guard shownPath == nil || shownPath == path else { return }
        panel?.orderOut(nil)
        shownPath = nil
    }

    private func present(_ path: String, near badge: NSRect, parent: NSWindow) {
        let hosting = NSHostingView(rootView: FilePreviewContent(path: path).environment(\.colorScheme, .dark))
        let size = hosting.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        // Above the badge, or below it when there is no room above.
        var origin = NSPoint(x: badge.minX, y: badge.maxY + Self.gap)
        if origin.y + size.height > screen.maxY { origin.y = badge.minY - Self.gap - size.height }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        shownPath = path
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// What the hover preview shows for a file.
struct FilePreviewContent: View {
    let path: String
    private static let maxImage = CGSize(width: 340, height: 240)

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted(image.size).width, height: fitted(image.size).height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let lines = textLines {
                Text(verbatim: lines)
                    .font(.rocky(11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(14)
                    .frame(width: 360, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    // FIL-09: the badge's Material icon, larger; a folder keeps the blue folder.
                    if FileKind(path: path) == .folder {
                        Image(systemName: FileKind.folder.symbol)
                            .font(.rocky(22))
                            .foregroundStyle(FileKind.folder.color)
                    } else {
                        FileIcon(path: path, size: 22)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                        Text(details).font(.rocky(10)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 300, alignment: .leading)
            }
        }
        .padding(8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }

    /// Images and PDFs (their first page): NSImage reads both.
    private var image: NSImage? {
        switch FileKind(path: path) {
        case .image, .pdf: NSImage(contentsOfFile: path).flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0 : nil }
        default: nil
        }
    }

    private var textLines: String? {
        switch FileKind(path: path) {
        case .code, .data, .text, .spreadsheet: break
        default: return nil
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(14).joined(separator: "\n")
    }

    private var details: String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let bytes = attributes?[.size] as? Int else { return "File not found" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func fitted(_ size: CGSize) -> CGSize {
        let scale = min(1, Self.maxImage.width / size.width, Self.maxImage.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
