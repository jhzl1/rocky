import AppKit
import RockyKit
import SwiftUI

/// A file's Material Icon Theme icon (`FIL-09`): the SVG of `FileIcons.iconId`, drawn as a vector at `size` points
/// (14 in rows and headers, 12 in tabs, badges and the line chip), whatever its viewBox. If the SVG fails to load, it
/// is `FileKind`'s symbol and color, as files were drawn before. Decorative: the name next to it carries the meaning.
/// Folders never come here; they keep `FileKind.folder`.
struct FileIcon: View {
    /// Relative or absolute; only its name and folders are read, never the disk.
    let path: String
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = FileIconImages.image(forPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                let kind = FileKind(path: path, isDirectory: false)
                Image(systemName: kind.symbol)
                    .font(.rocky(size * 0.8))
                    .foregroundStyle(kind.color)
            }
        }
        .frame(width: Zoom.shared(size), height: Zoom.shared(size))
        .accessibilityHidden(true)
    }
}

/// The bundled icons (`Resources/FileIcons`, written by `scripts/vendor-file-icons.py`): the manifest decoded once,
/// on the first icon drawn, and each SVG read once per icon id, so a tree of thousands of rows reads the disk once per
/// kind of file and redrawing a row reads nothing. A failed load is kept too, so it is not retried on every redraw.
@MainActor
enum FileIconImages {
    private static let manifest: FileIconManifest? = {
        guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "FileIcons"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FileIconManifest.self, from: data)
    }()

    private static var images: [String: NSImage?] = [:]

    /// The image of the file at `path`, or nil when the manifest or its SVG could not be read.
    static func image(forPath path: String) -> NSImage? {
        guard let manifest else { return nil }
        let id = FileIcons.iconId(forPath: path, manifest: manifest)
        if let cached = images[id] { return cached }
        let image = Bundle.module.url(forResource: id, withExtension: "svg", subdirectory: "FileIcons")
            .flatMap(NSImage.init(contentsOf:))
            .flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0 : nil }
        images[id] = .some(image)
        return image
    }
}
