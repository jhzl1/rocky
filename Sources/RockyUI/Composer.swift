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
    /// There is something to send: text other than spaces, or a file. With a line chip, words: a comment needs them,
    /// as the comment box's Send does (CMT-02).
    private(set) var hasContent = false
    /// A line comment's chip starts the message (CMT-05 History): the message goes as that comment again.
    private(set) var hasLineChip = false
    /// The editor's height: from two lines up to ten, then it scrolls.
    private(set) var height = ComposerController.minHeight
    /// The slash command popup over the box (CMD-01…CMD-05), driven by this text view.
    let popup = SlashCommandPopupModel()
    @ObservationIgnored fileprivate weak var textView: ComposerTextView?
    /// What the popup offers: `AppModel.commands(for:)` of the conversation, set by ChatView.
    @ObservationIgnored private var commands: [SlashCommand] = []
    @ObservationIgnored private var commandsConfirmed = false

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

    /// A queued message back in the box to edit it: its text, with its files as badges where they were, and a line
    /// comment's chip before it (CMT-05 Running).
    func load(text: String, files: [String], lineRange: LineRangeAttachment? = nil) {
        textView?.load(MessageHistory.Entry(text: text, files: files, lineRange: lineRange))
    }

    /// The message to send, its files and its line chip's range, then an empty box. Each file's place in the text is a
    /// `PromptAttachment.marker`; the chip has none.
    func takeMessage() -> ComposerMessage {
        guard let textView else { return ComposerMessage(text: "", files: [], lineRange: nil) }
        let message = textView.message()
        textView.clear()
        return message
    }

    /// The conversation's commands changed, or its first list arrived: an open popup shows them in place.
    func setCommands(_ commands: [SlashCommand], confirmed: Bool) {
        self.commands = commands
        commandsConfirmed = confirmed
        refreshPopup()
    }

    /// The "+" menu's Commands (CMD-07): a "/" at the start of the message, and the popup open on it.
    func startCommand() {
        popup.allowReopening()
        textView?.beginCommand()
        focus()
        refreshPopup()
    }

    fileprivate func textChanged() {
        guard let textView else { return }
        let string = textView.string
        let chip = textView.lineChip != nil
        isEmpty = string.isEmpty
        if hasLineChip != chip { hasLineChip = chip }
        if chip {
            hasContent = !string.replacingOccurrences(of: PromptAttachment.marker, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            hasContent = string.contains(PromptAttachment.marker)
                || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        height = min(max(textView.contentHeight, Self.minHeight), Self.maxHeight)
        refreshPopup()
    }

    /// KIT-02 and KIT-03 again, after every edit and caret move.
    fileprivate func refreshPopup() {
        guard let textView else { return }
        let string = textView.string
        popup.update(
            text: string,
            caret: textView.selectedRange().location,
            // A line chip is an attachment too: with it first, a "/" is not a command (CMT-05 History, CMD-01).
            firstIsAttachment: string.hasPrefix(PromptAttachment.marker),
            commands: commands,
            confirmed: commandsConfirmed
        )
    }

    /// The keys the text view hands over while the popup is open (CMD-03). False lets the key do what it does
    /// without the popup: Return with no match sends the text as typed, and ↑ and ↓ over an empty list move the
    /// caret or browse the history.
    fileprivate func handlePopupKey(_ key: PopupKey) -> Bool {
        guard popup.isOpen, let textView else { return false }
        switch key {
        case .up, .down:
            guard !popup.matches.isEmpty else { return false }
            popup.moveSelection(key == .up ? -1 : 1)
        case .escape:
            popup.dismiss(text: textView.string)
        case .tab:
            // Nothing to complete is not a reason to put a tab in a command's name.
            if let choice = popup.choose(isReturn: false) { textView.apply(choice) }
        case .returnKey:
            guard let choice = popup.choose(isReturn: true) else { return false }
            textView.apply(choice)
        }
        return true
    }

    /// A sent "/compact" shown again with ↑ does not open the popup, or the next ↑ would move its selection instead
    /// of going on through the history. Editing the token opens it.
    fileprivate func historyShown() {
        guard let textView else { return }
        popup.dismiss(text: textView.string)
    }

    /// A click on a row: Return on it (CMD-03).
    func chooseRow(_ index: Int) {
        popup.select(index)
        guard let choice = popup.choose(isReturn: true) else { return }
        focus()
        textView?.apply(choice)
    }
}

/// What the message box sends: the text, its files, and the range of the line chip it starts with, which makes it a
/// line comment (CMT-05 Resend).
struct ComposerMessage {
    let text: String
    let files: [URL]
    let lineRange: LineRangeAttachment?
}

/// The keys the message box hands to the slash command popup while it is open.
enum PopupKey {
    case up, down, returnKey, tab, escape

    init?(_ event: NSEvent) {
        guard event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return nil }
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 36, 76: self = .returnKey
        case 48: self = .tab
        case 53: self = .escape
        default: return nil
        }
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
        // A new text view (the box comes back after Restart) starts empty: the controller's state follows it. After
        // this update, which must not change observed state.
        DispatchQueue.main.async { [weak controller] in controller?.textChanged() }
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
        textView.onSelectionChange = { [weak controller] in controller?.refreshPopup() }
        textView.onPopupKey = { [weak controller] key in controller?.handlePopupKey(key) ?? false }
        textView.onHistoryShown = { [weak controller] in controller?.historyShown() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        func textDidChange(_ notification: Notification) {
            (notification.object as? ComposerTextView)?.onChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? ComposerTextView)?.onSelectionChange()
        }
    }
}

/// Return sends, Shift-Return starts a new line, Shift-Tab switches plan mode, ↑ and ↓ browse the conversation's
/// messages from an empty box. Pasted or dropped files become badges where the text is; pasted text comes in plain.
/// While the slash command popup is open, ↑, ↓, Return, Tab and Esc go to it first.
///
/// A line comment brought back (CMT-05 History) starts with its chip (CMT-06 In the box), one at most: only ↑, ↓ and a
/// queued comment's Edit put one there, at the start. The caret and the selection never go before it, so nothing is
/// typed, dropped or selected there, and copying leaves it out; Backspace at the start of the text removes it.
final class ComposerTextView: NSTextView {
    var history = MessageHistory()
    var onSubmit: () -> Void = {}
    var onBacktab: () -> Void = {}
    var onChange: () -> Void = {}
    var onSelectionChange: () -> Void = {}
    fileprivate var onPopupKey: (PopupKey) -> Bool = { _ in false }
    fileprivate var onHistoryShown: () -> Void = {}
    var openFile: OpenFileAction?
    fileprivate(set) var zoom: Double = 1
    /// A completed command's input hint, drawn in `textTertiary` after the "/name " at `location` until the next
    /// edit (CMD-04). Drawn, not typed: it is never sent, and VoiceOver does not read it (A11Y-02).
    private var ghostHint: (text: String, location: Int)? {
        didSet { needsDisplay = true }
    }

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
        // An input method composing text keeps every key.
        if !hasMarkedText(), let key = PopupKey(event), onPopupKey(key) { return }
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

    /// A sent message back in the box: its text, with its files as badges where they were, and a line comment's chip
    /// first.
    private func show(_ entry: MessageHistory.Entry) {
        replaceAll(with: attributedMessage(entry))
        history.didShow(string)
        onHistoryShown()
    }

    /// A queued message back in the box. Not a history entry: ↑ and ↓ treat it as typed text, so they cannot
    /// replace it before it is sent again.
    fileprivate func load(_ entry: MessageHistory.Entry) {
        replaceAll(with: attributedMessage(entry))
    }

    private func attributedMessage(_ entry: MessageHistory.Entry) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let range = entry.lineRange {
            result.append(NSAttributedString(attachment: LineChipAttachment(range: range, owner: self)))
        }
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

    // MARK: Slash commands

    /// A chosen command replaces the message's first token, keeping the text and the files after it (CMD-04).
    fileprivate func apply(_ choice: SlashCommandPopupModel.Choice) {
        guard let token = SlashQuery.tokenRange(in: string) else { return }
        let range = NSRange(location: token.lowerBound, length: token.count)
        switch choice {
        case .send(let name):
            let replacement = "/" + name
            replaceCharacters(in: range, withPlain: replacement)
            setSelectedRange(NSRange(location: range.location + replacement.utf16.count, length: 0))
            // Today's send: while the agent works it goes into the queue.
            onSubmit()
        case let .complete(name, hint):
            let text = string as NSString
            let hasSpace = range.upperBound < text.length && text.character(at: range.upperBound) == 0x20
            let completed = "/" + name + " "
            replaceCharacters(in: range, withPlain: hasSpace ? "/" + name : completed)
            let caret = range.location + completed.utf16.count
            setSelectedRange(NSRange(location: caret, length: 0))
            let rest = (string as NSString).substring(from: caret)
            // Only over nothing: arguments already typed after the name are the input.
            if let hint, rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ghostHint = (hint, caret)
            }
            scrollRangeToVisible(selectedRange())
        }
    }

    /// CMD-07: "/" at the start of an empty message. A message with text gets "/ " before it, so its first word
    /// stays out of the token a chosen command replaces. A message that already starts with "/" gets the caret
    /// after it. A line comment's message gets nothing: with its chip first, a "/" is not a command (CMT-05 History).
    fileprivate func beginCommand() {
        guard lineChip == nil else { return }
        if string.isEmpty {
            replaceCharacters(in: NSRange(location: 0, length: 0), withPlain: "/")
        } else if !string.hasPrefix("/") {
            replaceCharacters(in: NSRange(location: 0, length: 0), withPlain: "/ ")
        }
        setSelectedRange(NSRange(location: 1, length: 0))
    }

    /// An edit the user can undo, in the box's font.
    private func replaceCharacters(in range: NSRange, withPlain text: String) {
        guard shouldChangeText(in: range, replacementString: text), let storage = textStorage else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: textAttributes))
        didChangeText()
    }

    override func didChangeText() {
        // The hint goes with the first character typed after it.
        ghostHint = nil
        super.didChangeText()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ghostHint, let window, ghostHint.location <= (string as NSString).length else { return }
        let caret = firstRect(forCharacterRange: NSRange(location: ghostHint.location, length: 0), actualRange: nil)
        guard caret != .zero else { return }
        let rect = convert(window.convertFromScreen(caret), from: nil)
        (ghostHint.text as NSString).draw(
            at: NSPoint(x: rect.minX, y: rect.minY),
            withAttributes: [.font: textFont, .foregroundColor: NSColor(Theme.textTertiary)]
        )
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

    // MARK: The line chip (CMT-05 History, CMT-06)

    /// The line chip the message starts with, if any. It is always the first character: see `setSelectedRanges`.
    var lineChip: LineChipAttachment? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        return storage.attribute(.attachment, at: 0, effectiveRange: nil) as? LineChipAttachment
    }

    /// The caret and every selection start after the chip, so nothing is typed before it, and a selection, which is
    /// what copying and dragging write, never holds it: it cannot be pasted twice or into the middle of the text.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        guard lineChip != nil else { return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag) }
        let clamped = ranges.map { value -> NSValue in
            let range = value.rangeValue
            guard range.location < 1 else { return value }
            return NSValue(range: NSRange(location: 1, length: max(0, range.upperBound - 1)))
        }
        super.setSelectedRanges(clamped, affinity: affinity, stillSelecting: stillSelectingFlag)
    }

    /// A drop of text before the chip is refused: it would put the chip in the middle of the message.
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        if lineChip != nil {
            for (index, value) in affectedRanges.enumerated() {
                let range = value.rangeValue
                let replacement = replacementStrings.flatMap { index < $0.count ? $0[index] : nil } ?? ""
                if range.location == 0, range.length == 0, !replacement.isEmpty { return false }
            }
        }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    /// Backspace at the start of the text removes the chip, and the message then goes as a normal one.
    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText(), lineChip != nil, selectedRanges.count == 1,
              selectedRange() == NSRange(location: 1, length: 0) else { return super.deleteBackward(sender) }
        let chip = NSRange(location: 0, length: 1)
        guard shouldChangeText(in: chip, replacementString: ""), let storage = textStorage else { return }
        storage.replaceCharacters(in: chip, with: "")
        didChangeText()
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

    func message() -> ComposerMessage {
        guard let storage = textStorage else { return ComposerMessage(text: "", files: [], lineRange: nil) }
        var files: [URL] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let file = value as? FileAttachment { files.append(URL(fileURLWithPath: file.path)) }
        }
        let chip = lineChip
        // The chip's character is not the text's: the markers left are its files'.
        let text = chip == nil ? storage.string : (storage.string as NSString).substring(from: 1)
        return ComposerMessage(text: text.trimmingCharacters(in: .whitespacesAndNewlines), files: files, lineRange: chip?.range)
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
        let chip = lineChip?.range
        storage.beginEditing()
        storage.addAttributes(textAttributes, range: full)
        // From the end, so earlier ranges stay valid; a new attachment is drawn at the new size. The chip, first, goes
        // last.
        for badge in badges.reversed() {
            let replacement = NSMutableAttributedString(attachment: FileAttachment(path: badge.path, owner: self))
            replacement.addAttributes(textAttributes, range: NSRange(location: 0, length: replacement.length))
            storage.replaceCharacters(in: badge.range, with: replacement)
        }
        if let chip {
            let replacement = NSMutableAttributedString(attachment: LineChipAttachment(range: chip, owner: self))
            replacement.addAttributes(textAttributes, range: NSRange(location: 0, length: replacement.length))
            storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: replacement)
        }
        storage.endEditing()
        font = textFont
        typingAttributes = textAttributes
        onChange()
    }

    func clear() {
        string = ""
        ghostHint = nil
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

/// CMT-06's line chip at the start of the message box (CMT-05 History). TextKit draws it as an image of
/// `FileBadgeLook(range:)` with a gap after it, so the text starts clear of it, like the comment box's. Not a badge: it
/// has no hover, X or click, and Backspace removes it (`ComposerTextView`).
final class LineChipAttachment: NSTextAttachment {
    let range: LineRangeAttachment

    /// Between the chip and the text after it.
    @MainActor private static var gap: CGFloat { Zoom.shared(6) }

    @MainActor
    fileprivate init(range: LineRangeAttachment, owner: ComposerTextView) {
        self.range = range
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
        let scale = owner.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let label = range.rangeLabel
        let renderer = ImageRenderer(content: FileBadgeLook(path: range.path, range: label)
            .padding(.trailing, Self.gap)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        image = renderer.nsImage
        let size = FileBadgeLook.size(for: range.path, range: label)
        bounds = CGRect(x: 0, y: FileBadgeLook.baselineOffset, width: size.width + Self.gap, height: size.height)
    }

    required init?(coder: NSCoder) {
        guard let entry = coder.decodeObject(of: NSString.self, forKey: "entry") as String?,
              let range = LineRangeAttachment(entry: entry) else { return nil }
        self.range = range
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(range.entry as NSString, forKey: "entry")
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        bounds
    }
}
