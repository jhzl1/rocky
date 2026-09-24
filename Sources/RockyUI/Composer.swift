import AppKit
import RockyKit
import SwiftUI

/// The message box's text, with the attached files inside it as badges between the words, like Conductor's. A
/// SwiftUI text field cannot hold views, so this is an NSTextView whose files are text attachments showing a
/// `FileBadge`. ChatView reads and clears the message through this controller.
@MainActor
@Observable
final class ComposerController {
    private(set) var isEmpty = true
    /// There is something to send: text other than spaces, or a file.
    private(set) var hasContent = false
    /// The editor's height: from two lines up to ten, then it scrolls.
    private(set) var height = ComposerController.minHeight
    @ObservationIgnored fileprivate weak var textView: ComposerTextView?

    /// A line of 14-point text, at Rocky's zoom.
    static var lineHeight: CGFloat { Zoom.shared(18) }
    static var minHeight: CGFloat { lineHeight * 2 }
    static var maxHeight: CGFloat { lineHeight * 10 }

    /// Puts files at the insertion point, as badges.
    func insert(files: [URL]) {
        textView?.insertFiles(files)
    }

    func focus() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }

    func resignFocus() {
        guard let textView, let window = textView.window, window.firstResponder === textView else { return }
        window.makeFirstResponder(nil)
    }

    /// A queued message back in the box to edit it: its text, with its files as badges where they were.
    func load(text: String, files: [String]) {
        textView?.load(MessageHistory.Entry(text: text, files: files))
    }

    /// The message to send and its files, then an empty box. Each file's place in the text is a
    /// `PromptAttachment.marker`.
    func takeMessage() -> (text: String, files: [URL]) {
        guard let textView else { return ("", []) }
        let message = textView.message()
        textView.clear()
        return message
    }

    fileprivate func textChanged() {
        guard let textView else { return }
        let string = textView.string
        isEmpty = string.isEmpty
        hasContent = string.contains(PromptAttachment.marker)
            || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        height = min(max(textView.contentHeight, Self.minHeight), Self.maxHeight)
    }
}

struct ComposerEditor: NSViewRepresentable {
    let controller: ComposerController
    /// `Zoom.scale`: the text and its badges are redrawn at it when it changes.
    var zoom: Double = 1
    /// The conversation's messages, oldest first, for ↑ and ↓ (`MessageHistory`).
    var history: [MessageHistory.Entry] = []
    let onSubmit: () -> Void
    /// Shift-Tab: plan mode on or off.
    let onBacktab: () -> Void
    let openFile: OpenFileAction?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView(usingTextLayoutManager: true)
        textView.zoom = zoom
        textView.configure()
        textView.delegate = context.coordinator
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        controller.textView = textView
        update(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        controller.textView = textView
        update(textView)
    }

    private func update(_ textView: ComposerTextView) {
        if textView.zoom != zoom { textView.apply(zoom: zoom) }
        textView.history.setEntries(history)
        textView.onSubmit = onSubmit
        textView.onBacktab = onBacktab
        textView.openFile = openFile
        textView.onChange = { [weak controller] in controller?.textChanged() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        func textDidChange(_ notification: Notification) {
            (notification.object as? ComposerTextView)?.onChange()
        }
    }
}

/// Return sends, Shift-Return starts a new line, Shift-Tab switches plan mode, ↑ and ↓ browse the conversation's
/// messages from an empty box. Pasted or dropped files become badges where the text is; pasted text comes in plain.
final class ComposerTextView: NSTextView {
    var history = MessageHistory()
    var onSubmit: () -> Void = {}
    var onBacktab: () -> Void = {}
    var onChange: () -> Void = {}
    var openFile: OpenFileAction?
    fileprivate(set) var zoom: Double = 1

    private var textFont: NSFont { .systemFont(ofSize: 14 * zoom) }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: textFont, .foregroundColor: NSColor.labelColor]
    }

    func configure() {
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        font = textFont
        textColor = .labelColor
        insertionPointColor = .labelColor
        typingAttributes = textAttributes
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    }

    /// The height the text needs at the current width.
    var contentHeight: CGFloat {
        guard let layoutManager = textLayoutManager else { return 0 }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return ceil(layoutManager.usageBoundsForTextContainer.height)
    }

    override func keyDown(with event: NSEvent) {
        if browseHistory(event) { return }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, !hasMarkedText() else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift) || modifiers.contains(.option) {
            insertNewlineIgnoringFieldEditor(nil)
        } else {
            onSubmit()
        }
    }

    /// ↑ on the first line and ↓ on the last one, with no modifier, browse the history when the box is empty or
    /// shows an untouched message; anywhere else they move the cursor.
    private func browseHistory(_ event: NSEvent) -> Bool {
        let isUp = event.keyCode == 126
        let isDown = event.keyCode == 125
        guard isUp || isDown, !hasMarkedText(),
              event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return false }
        let caret = selectedRange()
        guard caret.length == 0 else { return false }
        let length = (string as NSString).length
        let step: MessageHistory.Step?
        if isUp {
            guard isOnSameLine(caret.location, 0) else { return false }
            step = history.older(from: string)
        } else {
            guard isOnSameLine(caret.location, length) else { return false }
            step = history.newer(from: string)
        }
        switch step {
        case nil:
            return false
        case .stay:
            NSSound.beep()
        case .clear:
            replaceAll(with: NSAttributedString(string: ""))
        case .show(let entry):
            show(entry)
        }
        return true
    }

    /// Two text positions on the same visual line (a wrapped line counts as several). Their caret rectangles overlap
    /// vertically: they are not the same height on a line with a badge.
    private func isOnSameLine(_ first: Int, _ second: Int) -> Bool {
        guard first != second else { return true }
        let a = firstRect(forCharacterRange: NSRange(location: first, length: 0), actualRange: nil)
        let b = firstRect(forCharacterRange: NSRange(location: second, length: 0), actualRange: nil)
        return a.maxY > b.minY + 1 && b.maxY > a.minY + 1
    }

    /// A sent message back in the box: its text, with its files as badges where they were.
    private func show(_ entry: MessageHistory.Entry) {
        replaceAll(with: attributedMessage(entry))
        history.didShow(string)
    }

    /// A queued message back in the box. Not a history entry: ↑ and ↓ treat it as typed text, so they cannot
    /// replace it before it is sent again.
    fileprivate func load(_ entry: MessageHistory.Entry) {
        replaceAll(with: attributedMessage(entry))
    }

    private func attributedMessage(_ entry: MessageHistory.Entry) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let marker = PromptAttachment.marker
        // Messages sent before files sat inside the text: their files go first.
        let missing = max(0, entry.files.count - (entry.text.components(separatedBy: marker).count - 1))
        var files = entry.files[...]
        let parts = (String(repeating: marker + " ", count: missing) + entry.text).components(separatedBy: marker)
        for (index, part) in parts.enumerated() {
            if index > 0, let path = files.popFirst() {
                result.append(NSAttributedString(attachment: FileAttachment(path: path, owner: self)))
            }
            result.append(NSAttributedString(string: part))
        }
        result.addAttributes(textAttributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func replaceAll(with text: NSAttributedString) {
        let all = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: all, replacementString: text.string), let storage = textStorage else { return }
        storage.replaceCharacters(in: all, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        onBacktab()
    }

    override func paste(_ sender: Any?) {
        let files = PastedAttachments.read(from: .general)
        if files.isEmpty { pasteAsPlainText(sender) } else { insertFiles(files) }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .string]
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        insertFiles(urls)
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: Badges

    /// The badge under the pointer: it shows an X in place of its icon and its file's preview.
    private weak var hoveredBadge: FileAttachment?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["badges"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["badges": true]
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let hit = badgeFrames().first { $0.frame.contains(point) }
        setHovered(hit?.attachment)
        if hit != nil { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    /// On a badge: its X removes it, the rest opens its file in a tab. Anywhere else, the text as usual.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = badgeFrames().first(where: { $0.frame.contains(point) }) else {
            return super.mouseDown(with: event)
        }
        FilePreviewPanel.shared.hide(hit.attachment.path)
        if point.x < hit.frame.minX + FileBadgeLook.iconWidth {
            setHovered(nil)
            remove(hit.attachment)
        } else if let openFile {
            openFile(hit.attachment.path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: hit.attachment.path))
        }
    }

    private func setHovered(_ attachment: FileAttachment?) {
        guard attachment !== hoveredBadge else { return }
        if let previous = hoveredBadge {
            previous.isHovered = false
            redraw(previous)
            FilePreviewPanel.shared.hide(previous.path)
        }
        hoveredBadge = attachment
        guard let attachment else { return }
        attachment.isHovered = true
        redraw(attachment)
        FilePreviewPanel.shared.show(attachment.path, in: window) { [weak self, weak attachment] in
            guard let self, let attachment, let window = self.window,
                  let frame = self.badgeFrames().first(where: { $0.attachment === attachment })?.frame else { return nil }
            return window.convertToScreen(self.convert(frame, to: nil))
        }
    }

    /// Where each badge is drawn, in this view's coordinates.
    func badgeFrames() -> [(attachment: FileAttachment, frame: CGRect)] {
        guard let storage = textStorage, let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager else { return [] }
        // A badge whose hover changed was just invalidated; unlaid fragments report an empty frame.
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var frames: [(attachment: FileAttachment, frame: CGRect)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? FileAttachment,
                  let location = content.location(content.documentRange.location, offsetBy: range.location),
                  let fragment = layoutManager.textLayoutFragment(for: location) else { return }
            let frame = fragment.frameForTextAttachment(at: location)
            guard !frame.isEmpty else { return }
            let origin = fragment.layoutFragmentFrame.origin
            frames.append((attachment, frame.offsetBy(dx: origin.x + textContainerOrigin.x, dy: origin.y + textContainerOrigin.y)))
        }
        return frames
    }

    /// Draws a badge again, after its hover state changed.
    private func redraw(_ attachment: FileAttachment) {
        guard let storage = textStorage, let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard (value as AnyObject) === attachment,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            layoutManager.invalidateLayout(for: textRange)
            stop.pointee = true
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // The text wraps again at a new width; its height is read after this layout pass.
        if widthChanged { DispatchQueue.main.async { [weak self] in self?.onChange() } }
    }

    func insertFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let inserted = NSMutableAttributedString()
        for url in urls {
            inserted.append(NSAttributedString(attachment: FileAttachment(path: url.path, owner: self)))
            inserted.append(NSAttributedString(string: " "))
        }
        inserted.addAttributes(typingAttributes, range: NSRange(location: 0, length: inserted.length))
        insertText(inserted, replacementRange: selectedRange())
    }

    /// Takes a badge out of the text, with the space inserted after it.
    func remove(_ attachment: FileAttachment) {
        guard let storage = textStorage else { return }
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as AnyObject) === attachment {
                found = range
                stop.pointee = true
            }
        }
        guard var range = found else { return }
        if range.upperBound < storage.length, (storage.string as NSString).character(at: range.upperBound) == 0x20 {
            range.length += 1
        }
        guard shouldChangeText(in: range, replacementString: "") else { return }
        storage.replaceCharacters(in: range, with: "")
        didChangeText()
    }

    func message() -> (text: String, files: [URL]) {
        guard let storage = textStorage else { return ("", []) }
        var files: [URL] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let file = value as? FileAttachment { files.append(URL(fileURLWithPath: file.path)) }
        }
        return (storage.string.trimmingCharacters(in: .whitespacesAndNewlines), files)
    }

    /// Redraws the text and its badges at a new zoom.
    func apply(zoom newZoom: Double) {
        zoom = newZoom
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        var badges: [(range: NSRange, path: String)] = []
        storage.enumerateAttribute(.attachment, in: full) { value, range, _ in
            if let file = value as? FileAttachment { badges.append((range, file.path)) }
        }
        storage.beginEditing()
        storage.addAttributes(textAttributes, range: full)
        // From the end, so earlier ranges stay valid; a new attachment is drawn at the new size.
        for badge in badges.reversed() {
            let replacement = NSMutableAttributedString(attachment: FileAttachment(path: badge.path, owner: self))
            replacement.addAttributes(textAttributes, range: NSRange(location: 0, length: replacement.length))
            storage.replaceCharacters(in: badge.range, with: replacement)
        }
        storage.endEditing()
        font = textFont
        typingAttributes = textAttributes
        onChange()
    }

    func clear() {
        string = ""
        typingAttributes = textAttributes
        undoManager?.removeAllActions()
        onChange()
    }
}

/// A file inside the message box's text. TextKit draws it as an image of `FileBadgeLook`; the text view handles its
/// hover, X and click (`ComposerTextView`). Not a view of its own: TextKit made attachment views late, and until
/// then drew its generic attachment image, a white box, where the badge goes.
final class FileAttachment: NSTextAttachment {
    let path: String
    fileprivate weak var owner: ComposerTextView?
    /// Swaps the drawn image: the hovered badge has an X in place of its icon.
    fileprivate var isHovered = false {
        didSet { image = isHovered ? hoveredImage : plainImage }
    }
    /// Drawn when the badge is inserted, on the main thread, where SwiftUI can render.
    private let plainImage: NSImage?
    private let hoveredImage: NSImage?

    @MainActor
    fileprivate init(path: String, owner: ComposerTextView) {
        self.path = path
        self.owner = owner
        let scale = owner.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        plainImage = Self.render(path: path, hovered: false, scale: scale)
        hoveredImage = Self.render(path: path, hovered: true, scale: scale)
        super.init(data: nil, ofType: nil)
        // An image, not a view: TextKit draws it right away.
        allowsTextAttachmentView = false
        image = plainImage
        let size = FileBadgeLook.size(for: path)
        bounds = CGRect(x: 0, y: FileBadgeLook.baselineOffset, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) {
        path = coder.decodeObject(of: NSString.self, forKey: "path") as String? ?? ""
        plainImage = nil
        hoveredImage = nil
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(path as NSString, forKey: "path")
    }

    @MainActor
    private static func render(path: String, hovered: Bool, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: FileBadgeLook(path: path, isHovered: hovered, showsRemove: hovered)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.nsImage
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        bounds
    }
}
