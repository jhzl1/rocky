import AppKit
import RockyKit

/// What ⌘V in the message box attaches instead of pasting as text.
enum PastedAttachments {
    /// Files copied in Finder, an image on the clipboard (saved as a PNG so the agent can read it), or a path to an
    /// existing file (clipboard managers such as Raycast paste an image as its file's path). Empty for plain text.
    static func read(from pasteboard: NSPasteboard) -> [URL] {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !fileURLs.isEmpty { return fileURLs }
        if let image = NSImage(pasteboard: pasteboard), let saved = save(image) {
            return [saved]
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix("/"), !text.contains("\n") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: text, isDirectory: &isDirectory), !isDirectory.boolValue {
                return [URL(fileURLWithPath: text)]
            }
        }
        return []
    }

    /// Writes the image as `image.png`, the name its badge shows (as Conductor's does), in a folder of its own under
    /// ~/Library/Caches/Rocky/Pasted so pastes never overwrite each other, as linked issues are (`PastedFiles`, M2.9
    /// Decision 4).
    private static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let folder = PastedFiles.standardFolder() else { return nil }
        return try? PastedFiles.write(png, named: "image.png", in: folder)
    }
}
