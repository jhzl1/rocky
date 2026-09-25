import AppKit
import RockyKit
import SwiftUI

/// Asks the editor to put its caret on a line and take the keyboard (`EDIT-01`'s ⌘L); a nil `line` only gives it the
/// keyboard back. `serial` grows with each request, so asking twice for the same line moves twice.
struct EditorLineRequest: Equatable {
    var line: Int?
    let serial: Int
}

/// `EDIT-01`'s code editor: an `NSTextView` in an `NSScrollView`, with a ruler (`CodeGutterView`) for the line numbers
/// and `EDIT-04`'s change bars. 12.5 mono on 20-point lines, the caret line on `currentLine`, the system find bar (⌘F),
/// ⌘L for go to line, Tab inserting the file's indentation (Return keeps the line's), undo and redo of its own, no
/// wrapping, and no substitutions or spell check. Colors come from Prism (`SyntaxHighlighter`) 150 ms after typing
/// stops, the visible lines first, and are applied only to what is on screen, so a long file costs what its viewport
/// costs.
///
/// Its undo history lives as long as the view: a tab that is hidden and shown again keeps its text (in `AppModel`) but
/// starts a new history.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: String?
    /// The file at the base, for the change bars; nil hides them.
    let baseText: String?
    var goToLine: EditorLineRequest?
    /// False for `FIL-06`'s large files: shown and searchable, never edited.
    var isEditable = true
    /// Take the keyboard when the editor appears.
    var takesFocus = true
    /// ⌘L while the editor has the keyboard: the view that holds it shows the go-to-line field.
    var onGoToLine: () -> Void = {}
    /// `Zoom.shared.scale`, read by the view that holds the editor, so a change of zoom reaches it.
    var zoom: Double = 1

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CodeEditorScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: CodeEditorScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: CodeEditorScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    /// Whether an editor, or its find bar, has the keyboard in `window`. `ChatView`'s key monitor then leaves Esc to it,
    /// the way it leaves it to a terminal: Esc closes the find bar rather than stopping the agent's turn.
    static func hasKeyboard(in window: NSWindow) -> Bool {
        guard var view = window.firstResponder as? NSView else { return false }
        // The find bar's field types through the window's field editor, whose delegate is the field.
        if let fieldEditor = view as? NSTextView, fieldEditor.isFieldEditor, let field = fieldEditor.delegate as? NSView {
            view = field
        }
        var current: NSView? = view
        while let candidate = current {
            if candidate is CodeEditorScrollView { return true }
            current = candidate.superview
        }
        return false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: CodeEditor
        private var metrics: EditorMetrics
        private let undo = UndoManager()
        private var scrollView: CodeEditorScrollView?
        private var textView: CodeTextView?
        private var gutter: CodeGutterView?
        /// The text the view holds, as last given to or taken from the binding: a binding value that is not this one
        /// came from outside (a reload).
        private var lastText = ""
        /// Grows with each change of the text, so results computed for an older text are dropped.
        private var version = 0
        private var lineStarts: [Int] = [0]
        /// The whole text's tokens, for `tokensVersion`, and the characters already colored from them.
        private var tokens: [SyntaxToken] = []
        private var tokensVersion = -1
        private var colored = IndexSet()
        /// No language: nothing is colored.
        private var isPlain = false
        private var highlightTask: Task<Void, Never>?
        private var barsTask: Task<Void, Never>?
        private var appliedLineRequest: Int?
        /// A reload is being applied: the text view's own change notification is not the user's typing.
        private var isReplacing = false
        private var boundsObserver: NSObjectProtocol?

        /// Past this length the visible lines are colored first, while Prism reads the whole text.
        private static let visibleFirstLength = 20_000
        private static let retokenizeDelay = Duration.milliseconds(150)

        init(_ parent: CodeEditor) {
            self.parent = parent
            self.metrics = EditorMetrics(zoom: parent.zoom)
            super.init()
        }

        // MARK: Building

        func makeScrollView() -> CodeEditorScrollView {
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            // Only what is on screen is laid out: a 5,000-line file opens and types like a short one.
            layoutManager.allowsNonContiguousLayout = true
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)

            let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
            // No wrapping: the view grows sideways with its longest line and scrolls.
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width, .height]
            textView.isRichText = false
            textView.importsGraphics = false
            textView.usesFontPanel = false
            textView.allowsUndo = true
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.isAutomaticTextCompletionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.smartInsertDeleteEnabled = false
            textView.drawsBackground = true
            textView.backgroundColor = Theme.background
            textView.insertionPointColor = EditorColors.text
            textView.selectedTextAttributes = [.backgroundColor: EditorColors.selection]
            textView.currentLineColor = EditorColors.currentLine
            textView.isEditable = parent.isEditable
            textView.wantsFocus = parent.takesFocus
            textView.delegate = self
            textView.onGoToLine = { [weak self] in self?.parent.onGoToLine() }

            let scrollView = CodeEditorScrollView()
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = true
            scrollView.backgroundColor = Theme.background
            scrollView.documentView = textView

            let gutter = CodeGutterView(scrollView: scrollView, orientation: .verticalRuler)
            gutter.clientView = textView
            scrollView.verticalRulerView = gutter
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true

            self.scrollView = scrollView
            self.textView = textView
            self.gutter = gutter
            applyMetrics()

            // Scrolling colors the lines that come into view, and moves the numbers.
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibleAreaChanged() }
            }

            load(parent.text)
            return scrollView
        }

        /// The first text: no undo, the caret at the start, the indentation detected, colors and bars at once.
        private func load(_ text: String) {
            guard let textView, let storage = textView.textStorage else { return }
            lastText = text
            storage.setAttributedString(NSAttributedString(string: text, attributes: metrics.attributes))
            textView.indentUnit = Indentation.detect(in: text) ?? CodeTextView.defaultIndent
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textChanged(immediately: true)
        }

        func update(_ newParent: CodeEditor) {
            let old = parent
            parent = newParent
            guard let textView else { return }
            if newParent.zoom != old.zoom {
                metrics = EditorMetrics(zoom: newParent.zoom)
                applyMetrics()
            }
            if textView.isEditable != newParent.isEditable { textView.isEditable = newParent.isEditable }
            if newParent.text != lastText { replace(with: newParent.text) }
            if newParent.language != old.language {
                tokensVersion = -1
                scheduleHighlight(immediately: true)
            }
            if newParent.baseText != old.baseText { scheduleBars(immediately: true) }
            if let request = newParent.goToLine, request.serial != appliedLineRequest {
                appliedLineRequest = request.serial
                go(to: request.line)
            }
        }

        func tearDown() {
            highlightTask?.cancel()
            barsTask?.cancel()
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
            textView?.delegate = nil
            textView?.onGoToLine = nil
            undo.removeAllActions()
        }

        /// Fonts, line height and gutter width at the zoom, over the whole text.
        private func applyMetrics() {
            guard let textView, let storage = textView.textStorage, let gutter else { return }
            let attributes = metrics.attributes
            textView.font = metrics.font
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            textView.typingAttributes = attributes
            textView.textContainerInset = NSSize(width: 12 * metrics.zoom, height: 8 * metrics.zoom)
            gutter.metrics = metrics
            gutter.ruleThickness = metrics.gutterWidth
            gutter.needsDisplay = true
        }

        // MARK: Text

        func textDidChange(_ notification: Notification) {
            guard !isReplacing, let textView else { return }
            let text = textView.string
            lastText = text
            parent.text = text
            textChanged(immediately: false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.caretMoved()
            gutter?.needsDisplay = true
        }

        /// Its own history, so an editor's undo never reaches the message box or another tab's editor.
        func undoManager(for view: NSTextView) -> UndoManager? {
            undo
        }

        private func textChanged(immediately: Bool) {
            version += 1
            lineStarts = LineStarts.of(utf16Units())
            colored = IndexSet()
            gutter?.lineStarts = lineStarts
            gutter?.needsDisplay = true
            textView?.caretMoved()
            scheduleHighlight(immediately: immediately)
            scheduleBars(immediately: immediately)
        }

        private func utf16Units() -> [UInt16] {
            guard let string = textView?.textStorage?.mutableString, string.length > 0 else { return [] }
            var units = [UInt16](repeating: 0, count: string.length)
            units.withUnsafeMutableBufferPointer { buffer in
                if let base = buffer.baseAddress { string.getCharacters(base, range: NSRange(location: 0, length: string.length)) }
            }
            return units
        }

        /// A text from outside (`EDIT-03`'s reload): only the part that differs is replaced, as one undoable change, so
        /// the caret keeps its line and the view its scroll position.
        private func replace(with newText: String) {
            guard let textView, let storage = textView.textStorage, let scrollView else { return }
            let old = utf16Units()
            let new = Array(newText.utf16)
            var prefix = 0
            while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
            // Never between the two halves of a surrogate pair.
            if prefix > 0, UTF16.isLeadSurrogate(new[prefix - 1]) { prefix -= 1 }
            var suffix = 0
            while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
                suffix += 1
            }
            if suffix > 0, UTF16.isTrailSurrogate(new[new.count - suffix]) { suffix -= 1 }
            let range = NSRange(location: prefix, length: old.count - prefix - suffix)
            let replacement = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
            let caret = caretPosition()
            let origin = scrollView.contentView.bounds.origin

            isReplacing = true
            let attributed = NSAttributedString(string: replacement, attributes: metrics.attributes)
            if textView.isEditable, textView.shouldChangeText(in: range, replacementString: replacement) {
                storage.replaceCharacters(in: range, with: attributed)
                textView.didChangeText()
            } else {
                storage.replaceCharacters(in: range, with: attributed)
            }
            isReplacing = false
            lastText = newText
            textChanged(immediately: true)
            restore(caret: caret, origin: origin)
        }

        private func caretPosition() -> (line: Int, column: Int) {
            let location = textView?.selectedRange().location ?? 0
            let line = LineStarts.line(containing: location, in: lineStarts)
            return (line, location - lineStarts[line])
        }

        private func restore(caret: (line: Int, column: Int), origin: NSPoint) {
            guard let textView, let string = textView.textStorage?.mutableString, let scrollView else { return }
            let line = min(caret.line, lineStarts.count - 1)
            let start = lineStarts[line]
            // The line's end, before its "\n" or "\r\n".
            var end = line + 1 < lineStarts.count ? lineStarts[line + 1] : string.length
            while end > start, [0x0A, 0x0D].contains(string.character(at: end - 1)) { end -= 1 }
            textView.setSelectedRange(NSRange(location: min(start + caret.column, end), length: 0))
            let clip = scrollView.contentView
            let bounds = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
            clip.scroll(to: bounds.origin)
            scrollView.reflectScrolledClipView(clip)
        }

        /// ⌘L's line (1-based, clamped to the file), centered, and the keyboard back to the editor.
        private func go(to line: Int?) {
            guard let textView else { return }
            if let line {
                let index = min(max(line - 1, 0), lineStarts.count - 1)
                textView.setSelectedRange(NSRange(location: lineStarts[index], length: 0))
                textView.centerSelectionInVisibleArea(nil)
            }
            textView.window?.makeFirstResponder(textView)
        }

        private func visibleAreaChanged() {
            colorVisible()
            gutter?.needsDisplay = true
        }

        // MARK: Colors (DIFF-04)

        /// Prism 150 ms after the last change (at once for a new text): the visible lines alone first when the text is
        /// long, then the whole text, whose tokens color what is on screen and, as it scrolls, what comes into view.
        private func scheduleHighlight(immediately: Bool) {
            highlightTask?.cancel()
            guard let language = parent.language else {
                clearColors()
                return
            }
            isPlain = false
            let version = self.version
            let text = lastText
            let length = textView?.textStorage?.length ?? 0
            highlightTask = Task { [weak self] in
                if !immediately { try? await Task.sleep(for: Self.retokenizeDelay) }
                guard !Task.isCancelled, let self else { return }
                if length > Self.visibleFirstLength, let visible = self.visibleText() {
                    let tokens = await SyntaxHighlighter.shared.tokens(for: visible.text, language: language)
                    guard !Task.isCancelled, self.version == version else { return }
                    self.paint(tokens, in: visible.range)
                }
                let tokens = await SyntaxHighlighter.shared.tokens(for: text, language: language)
                guard !Task.isCancelled, self.version == version else { return }
                self.tokens = tokens
                self.tokensVersion = version
                self.colored = IndexSet()
                self.colorVisible()
            }
        }

        /// Plain text (an unknown language, a large file): the colors go once, and typing costs nothing more.
        private func clearColors() {
            guard !isPlain, let layoutManager = textView?.layoutManager, let length = textView?.textStorage?.length else { return }
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
            tokens = []
            tokensVersion = -1
            isPlain = true
        }

        /// Temporary attributes of the layout manager, not the text's own: coloring touches neither the undo history
        /// nor the layout.
        private func paint(_ tokens: [SyntaxToken], in range: NSRange) {
            guard let layoutManager = textView?.layoutManager, let length = textView?.textStorage?.length else { return }
            let range = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard range.length > 0 else { return }
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for token in tokens {
                let tokenRange = NSRange(location: range.location + token.range.lowerBound, length: token.range.count)
                let clipped = NSIntersectionRange(tokenRange, range)
                guard clipped.length > 0, let color = EditorColors.syntax[token.kind] else { continue }
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: clipped)
            }
        }

        /// Colors, from the whole text's tokens, the lines on screen and a screen above and below that are not colored
        /// yet. Nothing while the tokens are older than the text: the colors already drawn stay until new ones arrive.
        private func colorVisible() {
            guard tokensVersion == version, let layoutManager = textView?.layoutManager,
                  let visible = visibleCharacterRange(margin: true), let visibleRange = Range(visible) else { return }
            var missing = IndexSet(integersIn: visibleRange)
            missing.subtract(colored)
            guard !missing.isEmpty else { return }
            for range in missing.rangeView {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(range))
                var index = firstToken(endingAfter: range.lowerBound)
                while index < tokens.count, tokens[index].range.lowerBound < range.upperBound {
                    let token = tokens[index]
                    let clipped = token.range.clamped(to: range)
                    if !clipped.isEmpty, let color = EditorColors.syntax[token.kind] {
                        layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: NSRange(clipped))
                    }
                    index += 1
                }
            }
            colored.formUnion(missing)
        }

        /// The first token that ends after `offset`; tokens come in order and do not overlap.
        private func firstToken(endingAfter offset: Int) -> Int {
            var low = 0
            var high = tokens.count
            while low < high {
                let middle = (low + high) / 2
                if tokens[middle].range.upperBound <= offset { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// The whole lines on screen, and with `margin` a screen above and below.
        private func visibleCharacterRange(margin: Bool) -> NSRange? {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  let string = textView.textStorage?.mutableString, string.length > 0 else { return nil }
            let visible = textView.visibleRect
            let extra = margin ? visible.height : 0
            let rect = NSRect(
                x: 0,
                y: visible.minY - extra - textView.textContainerOrigin.y,
                width: textView.bounds.width,
                height: visible.height + extra * 2
            )
            let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            return string.lineRange(for: characters)
        }

        private func visibleText() -> (text: String, range: NSRange)? {
            guard let string = textView?.textStorage?.mutableString, let range = visibleCharacterRange(margin: false),
                  range.length > 0 else { return nil }
            return (string.substring(with: range), range)
        }

        // MARK: Change bars (EDIT-04)

        /// The bars against the base, 150 ms after the last change (at once for a new text or base), computed off the
        /// main actor.
        private func scheduleBars(immediately: Bool) {
            barsTask?.cancel()
            guard let base = parent.baseText else {
                if gutter?.bars != nil {
                    gutter?.bars = nil
                    gutter?.needsDisplay = true
                }
                return
            }
            let version = self.version
            let text = lastText
            barsTask = Task { [weak self] in
                if !immediately { try? await Task.sleep(for: Self.retokenizeDelay) }
                guard !Task.isCancelled else { return }
                let bars = await Task.blocking { ChangeBars.compute(base: base, text: text) }.value
                guard !Task.isCancelled, let self, self.version == version else { return }
                self.gutter?.bars = bars
                self.gutter?.needsDisplay = true
            }
        }
    }
}

/// The editor's measures at a zoom (`EDIT-01`: 12.5 mono on 20-point lines, a 56-point gutter).
@MainActor
struct EditorMetrics {
    let zoom: Double
    let font: NSFont
    let lineHeight: CGFloat
    /// Lifts the glyphs to the middle of their line, which a fixed line height would leave at its bottom.
    let baselineOffset: CGFloat
    let characterWidth: CGFloat
    let gutterWidth: CGFloat

    init(zoom: Double) {
        self.zoom = zoom
        font = NSFont.monospacedSystemFont(ofSize: 12.5 * zoom, weight: .regular)
        lineHeight = 20 * zoom
        let natural = font.ascender - font.descender + font.leading
        baselineOffset = max(0, (lineHeight - natural) / 2)
        characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        gutterWidth = 56 * zoom
    }

    /// Every character's attributes: the font, the text color, the fixed line height, a tab as four columns (as the
    /// diff draws it, `HighlightedLine.tabWidth`) and no wrapping.
    var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.tabStops = []
        paragraph.defaultTabInterval = characterWidth * CGFloat(HighlightedLine.tabWidth)
        paragraph.lineBreakMode = .byClipping
        return [
            .font: font,
            .foregroundColor: EditorColors.text,
            .paragraphStyle: paragraph,
            .baselineOffset: baselineOffset,
        ]
    }
}

/// `Theme`'s colors as the AppKit colors the editor draws with, converted once.
@MainActor
enum EditorColors {
    static let text = NSColor(Theme.textPrimary)
    static let lineNumber = NSColor(Theme.textTertiary)
    static let selection = NSColor(Theme.editorSelection)
    static let currentLine = NSColor(Theme.currentLine)
    static let added = NSColor(Theme.success)
    static let modified = NSColor(Theme.attention)
    static let removed = NSColor(Theme.danger)
    static let syntax: [SyntaxKind: NSColor] = Dictionary(uniqueKeysWithValues: SyntaxKind.allCases.compactMap { kind in
        Theme.syntax(kind).map { (kind, NSColor($0)) }
    })
}

/// The editor's scroll view. `CodeEditor.hasKeyboard(in:)` knows the editor, and its find bar, by it.
final class CodeEditorScrollView: NSScrollView {}

/// The editor's text view: Tab inserts the file's indentation, Return keeps the line's, ⌘L asks for a line, and the caret
/// line is filled with `currentLine` under the text.
final class CodeTextView: NSTextView {
    static let defaultIndent = "    "
    var indentUnit = "    "
    var onGoToLine: (() -> Void)?
    var currentLineColor = NSColor.clear
    /// Take the keyboard once the view is in a window.
    var wantsFocus = true
    private var lastLineRect: NSRect?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus, window != nil else { return }
        wantsFocus = false
        // After SwiftUI has placed the view, or it takes the keyboard back.
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable else { return }
        insertText(indentUnit, replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, let text = textStorage?.mutableString else {
            super.insertNewline(sender)
            return
        }
        let caret = selectedRange().location
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        var end = line.location
        while end < caret, [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
        let indent = text.substring(with: NSRange(location: line.location, length: end - line.location))
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Every view of the window is asked, before the menus; only the editor with the keyboard answers. File ▸ Go to
        // Line… (⌘L, KBD-02) does the same for the editor on screen without the keyboard.
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "l", window?.firstResponder === self,
           let onGoToLine {
            onGoToLine()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let line = currentLineRect(), line.intersects(rect) else { return }
        currentLineColor.setFill()
        line.intersection(rect).fill(using: .sourceOver)
    }

    /// Redraws the caret line where it was and where it is now.
    func caretMoved() {
        let now = currentLineRect()
        if let lastLineRect { setNeedsDisplay(lastLineRect) }
        if let now { setNeedsDisplay(now) }
        lastLineRect = now
    }

    /// The caret's line across the whole view, or the empty line after a final newline.
    func currentLineRect() -> NSRect? {
        guard let layoutManager, let storage = textStorage else { return nil }
        let caret = selectedRange().location
        let fragment: NSRect
        if caret >= storage.length, layoutManager.extraLineFragmentTextContainer != nil {
            fragment = layoutManager.extraLineFragmentRect
        } else if storage.length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, storage.length - 1))
            fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            return nil
        }
        guard fragment.height > 0 else { return nil }
        return NSRect(x: 0, y: fragment.minY + textContainerOrigin.y, width: bounds.width, height: fragment.height)
    }
}

/// The editor's gutter (`EDIT-01`, `EDIT-04`): line numbers right-aligned 12 points from its edge in `textTertiary`
/// (the caret's line in `textPrimary`), and 3-point change bars 4 points from its left edge, added in `success` and
/// modified in `attention`, with a small `danger` triangle where lines were removed. A final newline's empty line has
/// no number, as in the diff.
final class CodeGutterView: NSRulerView {
    var lineStarts: [Int] = [0]
    var bars: ChangeBars?
    var metrics: EditorMetrics?

    override var isFlipped: Bool { true }

    override var requiredThickness: CGFloat {
        ruleThickness
    }

    /// Since macOS 14 a view does not clip its drawing to its bounds, and `dirtyRect` can be larger than them: filling it
    /// painted the gutter's background over the whole text, and past the editor over the window (user reports,
    /// 2026-09-24: no text, then no sidebar and no top bar, and numbers over the terminal bar).
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clipsToBounds = true
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.intersection(dirtyRect).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? CodeTextView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let storage = textView.textStorage, let metrics else { return }
        let length = storage.length
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(
            forBoundingRect: NSRect(x: 0, y: visible.minY - origin.y, width: textView.bounds.width, height: visible.height),
            in: container
        )
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = LineStarts.line(containing: textView.selectedRange().location, in: lineStarts)
        let lastNumbered = length > 0 && lineStarts.last == length ? lineStarts.count - 2 : lineStarts.count - 1
        var line = LineStarts.line(containing: characters.location, in: lineStarts)
        while line <= lastNumbered, lineStarts[line] <= NSMaxRange(characters) {
            let start = lineStarts[line]
            let fragment: NSRect
            if start < length {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            } else {
                // An empty text: its one line is the extra fragment.
                fragment = layoutManager.extraLineFragmentRect
            }
            let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            drawLine(line, top: top, height: fragment.height, isCurrent: line == caretLine, isLast: line == lastNumbered, metrics: metrics)
            line += 1
        }
    }

    private func drawLine(_ line: Int, top: CGFloat, height: CGFloat, isCurrent: Bool, isLast: Bool, metrics: EditorMetrics) {
        let zoom = CGFloat(metrics.zoom)
        if let bars {
            if let mark = bars.marks[line] {
                (mark == .added ? EditorColors.added : EditorColors.modified).setFill()
                NSBezierPath(roundedRect: NSRect(x: 4 * zoom, y: top, width: 3 * zoom, height: height), xRadius: zoom, yRadius: zoom).fill()
            }
            if bars.deletionsAbove.contains(line) { drawDeletion(at: top, zoom: zoom) }
            if isLast, bars.deletionAtEnd { drawDeletion(at: top + height, zoom: zoom) }
        }
        let number = String(line + 1) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metrics.font,
            .foregroundColor: isCurrent ? EditorColors.text : EditorColors.lineNumber,
        ]
        let size = number.size(withAttributes: attributes)
        number.draw(at: NSPoint(x: bounds.width - 12 * zoom - size.width, y: top + (height - size.height) / 2), withAttributes: attributes)
    }

    /// A 5 × 8 triangle pointing right, centered on the line edge at `y`.
    private func drawDeletion(at y: CGFloat, zoom: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3 * zoom, y: y - 4 * zoom))
        path.line(to: NSPoint(x: 8 * zoom, y: y))
        path.line(to: NSPoint(x: 3 * zoom, y: y + 4 * zoom))
        path.close()
        EditorColors.removed.setFill()
        path.fill()
    }
}
