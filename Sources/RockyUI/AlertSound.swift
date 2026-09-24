import AppKit

/// The sound Rocky plays when an agent finishes, fails or waits for you in a workspace you are not watching (user
/// decision, 2026-09-23). One of macOS's alert sounds, chosen in Settings; "None" turns it off.
enum AlertSound {
    static let defaultsKey = "alertSound"
    static let none = "None"
    static let defaultName = "Glass"

    /// The system's alert sounds by name, from `/System/Library/Sounds`, where `NSSound(named:)` finds them.
    static let available: [String] = {
        let folder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "aiff" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()

    static func play() {
        play(UserDefaults.standard.string(forKey: defaultsKey) ?? defaultName)
    }

    static func play(_ name: String) {
        guard name != none else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
