import Foundation

/// The message box's history, like a shell's: with the box empty, ↑ brings back the conversation's last message,
/// ↑ again the one before, and ↓ goes forward until the box is empty again. It only browses while the box shows an
/// entry untouched: after an edit the arrows move the cursor again.
public struct MessageHistory: Equatable, Sendable {
    /// A sent message: its text (a `PromptAttachment.marker` where each file sat) and its files.
    public struct Entry: Equatable, Sendable {
        public let text: String
        public let files: [String]

        public init(text: String, files: [String]) {
            self.text = text
            self.files = files
        }
    }

    public enum Step: Equatable, Sendable {
        case show(Entry)
        /// Past the newest entry: back to an empty box.
        case clear
        /// Already at the oldest entry.
        case stay
    }

    /// Oldest first.
    public private(set) var entries: [Entry] = []
    private var index: Int?
    /// The box's text as it showed the current entry, to tell an untouched entry from an edited one.
    private var shown: String?

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// A new message sent (or another conversation) starts browsing over from the newest one.
    public mutating func setEntries(_ entries: [Entry]) {
        guard entries != self.entries else { return }
        self.entries = entries
        index = nil
        shown = nil
    }

    /// The arrows browse the history: the box is empty, or shows an entry as it was brought back.
    public func browses(_ current: String) -> Bool {
        current.isEmpty || (index != nil && current == shown)
    }

    /// ↑: the entry before the one shown, or the newest from an empty box. nil when the arrow should move the cursor.
    public mutating func older(from current: String) -> Step? {
        guard browses(current), !entries.isEmpty else { return nil }
        if current.isEmpty { index = nil }
        let next = index.map { $0 - 1 } ?? entries.count - 1
        guard next >= 0 else { return .stay }
        index = next
        return .show(entries[next])
    }

    /// ↓: the entry after the one shown, then an empty box. nil when the arrow should move the cursor.
    public mutating func newer(from current: String) -> Step? {
        guard let index, !current.isEmpty, current == shown else { return nil }
        if index + 1 < entries.count {
            self.index = index + 1
            return .show(entries[index + 1])
        }
        self.index = nil
        shown = nil
        return .clear
    }

    /// The box now shows the entry as `displayed`.
    public mutating func didShow(_ displayed: String) {
        shown = displayed
    }
}
