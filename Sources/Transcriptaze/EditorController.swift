import AppKit
import TranscriptazeCore

/// Owns the open note's text view. Three hands write into it: the user's
/// keyboard, the transcriber (at the user's caret) and the guardian (anywhere).
/// All three go through `NSTextStorage` on the main thread, one edit at a time,
/// so they interleave between words rather than colliding.
@MainActor
final class EditorController: NSObject, @preconcurrency NSTextViewDelegate, @preconcurrency NSTextStorageDelegate, DocumentHost {
    let textView: ManuscriptTextView
    let scrollView: NSScrollView
    private let storage = NSTextStorage()
    private var styler: Styler

    var typesetting: Typesetting {
        didSet {
            guard typesetting != oldValue else { return }
            styler = Styler(typesetting: typesetting)
            textView.typesetting = typesetting
            styler.styleAll(storage)
            textView.typingAttributes = styler.baseAttributes
        }
    }

    private(set) var revision = 0
    private var nextBatch = 0
    var isDictating = false
    /// Mark dictation as unreviewed (wet ink). Off while no guardian may read it.
    var marksFresh = true
    var noteTitle = "Untitled"

    /// Called after any change to the text (for saving and the sidebar).
    var onTextChange: (() -> Void)?
    /// Called when the guardian edits, with a human summary.
    var onGuardianEdit: ((String) -> Void)?
    /// Called when new dictated text lands.
    var onFreshText: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    private var glowTimer: Timer?

    init(typesetting: Typesetting) {
        self.typesetting = typesetting
        self.styler = Styler(typesetting: typesetting)

        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: typesetting.measure, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        textView = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), textContainer: container)
        scrollView = NSScrollView()
        super.init()

        textView.typesetting = typesetting
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = true
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.drawsBackground = true
        textView.backgroundColor = Palette.paper
        textView.insertionPointColor = Palette.ink
        textView.selectedTextAttributes = [.backgroundColor: Palette.selection]
        textView.typingAttributes = styler.baseAttributes
        textView.delegate = self
        textView.onFormat = { [weak self] in self?.format($0) }
        textView.setAccessibilityIdentifier("manuscript")
        storage.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.paper
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
    }

    // MARK: Loading

    func load(text: String, title: String) {
        noteTitle = title
        textView.guardianRange = nil
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: styler.baseAttributes))
        storage.endEditing()
        styler.styleAll(storage)
        textView.outline = Outline(text: text)
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        revision += 1
    }

    var text: String { storage.string }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Keep the guardian's cursor attached to the text it was on.
        if let g = textView.guardianRange {
            let edit = TextEdit(range: NSRange(location: editedRange.location, length: editedRange.length - delta), replacement: String(repeating: " ", count: editedRange.length))
            let start = edit.transform(g.location)
            let end = max(start, edit.transform(NSMaxRange(g)))
            textView.guardianRange = NSRange(location: start, length: end - start)
        }
        // A fence opening or closing restyles everything after it.
        let ns = textStorage.string as NSString
        let lines = ns.lineRange(for: editedRange)
        let touchesFence = ns.substring(with: lines).contains("```") || ns.substring(with: lines).contains("~~~") || delta < 0
        styler.style(textStorage, lines: touchesFence ? NSRange(location: lines.location, length: ns.length - lines.location) : lines)
    }

    func textDidChange(_ notification: Notification) {
        revision += 1
        textView.outline = Outline(text: storage.string)
        onTextChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Typing next to dictated text must not inherit its "unreviewed" mark.
        var attrs = textView.typingAttributes
        if attrs[.freshBatch] != nil {
            attrs[.freshBatch] = nil
            attrs[.foregroundColor] = Palette.ink
            textView.typingAttributes = attrs
        }
        onSelectionChange?()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { return continueList() }
        return false
    }

    /// Return in a list item starts the next item; on an empty item it ends the list.
    private func continueList() -> Bool {
        let ns = storage.string as NSString
        let caret = textView.selectedRange().location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        var content = ns.substring(with: line)
        if content.hasSuffix("\n") { content.removeLast() }
        let (kind, prefixLength) = Outline.classify(content)
        guard kind == .listItem || kind == .quote else { return false }
        let prefix = (content as NSString).substring(to: prefixLength)
        if (content as NSString).length == prefixLength {
            replace(NSRange(location: line.location, length: prefixLength), with: "", action: "End List")
            return true
        }
        var next = prefix
        if let n = Int(prefix.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) {
            next = prefix.replacingOccurrences(of: "\(n)", with: "\(n + 1)")
        }
        next = next.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        textView.insertText("\n" + next, replacementRange: textView.selectedRange())
        return true
    }

    // MARK: Editing primitives

    /// One undoable edit through the text view, so undo, spelling and the
    /// layout all see it like typing.
    @discardableResult
    private func replace(_ range: NSRange, with string: String, action: String, fresh: Int? = nil) -> Bool {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return false }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: string)
        let inserted = NSRange(location: range.location, length: (string as NSString).length)
        if let fresh, inserted.length > 0 {
            storage.addAttribute(.freshBatch, value: fresh, range: inserted)
            storage.addAttribute(.foregroundColor, value: Palette.wetInk, range: inserted)
        }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(action)
        return true
    }

    // MARK: Dictation

    func insertDictation(_ actions: [DictationAction]) {
        for action in actions {
            let selection = textView.selectedRange()
            let caret = NSMaxRange(selection)
            switch action {
            case .text(let chunk):
                guard !chunk.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                nextBatch += 1
                let (edit, newCaret) = DictationComposer.insert(chunk, at: caret, in: storage.string)
                if replace(edit.range, with: edit.replacement, action: "Dictation", fresh: marksFresh ? nextBatch : nil) {
                    textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                }
            case .paragraphBreak:
                let (edit, newCaret) = DictationComposer.paragraphBreak(at: caret, in: storage.string)
                if replace(edit.range, with: edit.replacement, action: "New Paragraph") {
                    textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                }
            }
        }
        textView.scrollRangeToVisible(textView.selectedRange())
        onFreshText?()
    }

    // MARK: DocumentHost

    var userCursor: Int { NSMaxRange(textView.selectedRange()) }

    var freshRanges: [(range: NSRange, batch: Int)] {
        var out: [(NSRange, Int)] = []
        storage.enumerateAttribute(.freshBatch, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let b = value as? Int { out.append((range, b)) }
        }
        return out
    }

    func applyGuardianEdit(_ edit: TextEdit, summary: String) {
        let selection = textView.selectedRange()
        textView.breakUndoCoalescing()
        guard replace(edit.range, with: edit.replacement, action: "Guardian Edit") else { return }
        textView.breakUndoCoalescing()
        // The user's caret stays with their text, whatever moved around it.
        let start = edit.transform(selection.location)
        let end = edit.transform(NSMaxRange(selection))
        textView.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
        textView.guardianRange = NSRange(location: edit.range.location, length: (edit.replacement as NSString).length)
        flashGuardian()
        onGuardianEdit?(summary)
    }

    /// Dries all wet ink and hides the guardian's cursor.
    func releaseGuardian() {
        markReviewed(through: Int.max)
        textView.guardianRange = nil
        guardianActive = false
    }

    func setUserCursor(_ offset: Int) {
        let o = min(max(0, offset), storage.length)
        textView.setSelectedRange(NSRange(location: o, length: 0))
        textView.scrollRangeToVisible(NSRange(location: o, length: 0))
    }

    func setGuardianFocus(_ range: NSRange?, label: String?) {
        guard let range else { return }   // the cursor stays parked where it last worked
        textView.guardianRange = range
        flashGuardian()
    }

    var guardianActive: Bool {
        get { textView.guardianActive }
        set { textView.guardianActive = newValue }
    }

    func markReviewed(through batch: Int) {
        var dried: [NSRange] = []
        storage.enumerateAttribute(.freshBatch, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let b = value as? Int, b <= batch { dried.append(range) }
        }
        guard !dried.isEmpty else { return }
        storage.beginEditing()
        for r in dried {
            storage.removeAttribute(.freshBatch, range: r)
            styler.style(storage, lines: r)
        }
        storage.endEditing()
        // Park the guardian's cursor at the end of what it has read.
        if textView.guardianRange == nil, let last = dried.max(by: { NSMaxRange($0) < NSMaxRange($1) }) {
            textView.guardianRange = NSRange(location: NSMaxRange(last), length: 0)
        }
    }

    private func flashGuardian() {
        textView.guardianGlow = 1
        glowTimer?.invalidate()
        let started = Date()
        glowTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let t = Date().timeIntervalSince(started)
                let glow = max(0, 1 - t / 2.4)
                self?.textView.guardianGlow = CGFloat(glow * glow)
                if glow <= 0 { timer.invalidate() }
            }
        }
    }

    // MARK: Formatting

    func format(_ action: String) {
        let ns = storage.string as NSString
        let selection = textView.selectedRange()
        let inline: [String: String] = ["bold": "**", "italic": "*", "code": "`", "strike": "~~"]
        if let marker = inline[action] {
            let m = (marker as NSString).length
            let selected = ns.substring(with: selection)
            // Toggle off when the selection is already wrapped.
            if selection.location >= m, NSMaxRange(selection) + m <= ns.length,
               ns.substring(with: NSRange(location: selection.location - m, length: m)) == marker,
               ns.substring(with: NSRange(location: NSMaxRange(selection), length: m)) == marker {
                replace(NSRange(location: selection.location - m, length: selection.length + 2 * m), with: selected, action: "Format")
                textView.setSelectedRange(NSRange(location: selection.location - m, length: selection.length))
                return
            }
            replace(selection, with: marker + selected + marker, action: "Format")
            textView.setSelectedRange(NSRange(location: selection.location + m, length: selection.length))
            return
        }
        if action == "link" {
            let selected = ns.substring(with: selection)
            replace(selection, with: "[\(selected)]()", action: "Link")
            textView.setSelectedRange(NSRange(location: selection.location + (selected as NSString).length + 3, length: 0))
            return
        }
        let prefixes: [String: String] = ["h1": "# ", "h2": "## ", "h3": "### ", "quote": "> ", "bullet": "- ", "numbered": "1. ", "body": ""]
        guard let prefix = prefixes[action] else { return }
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        var content = ns.substring(with: line)
        if content.hasSuffix("\n") { content.removeLast() }
        let (_, existing) = Outline.classify(content)
        let current = (content as NSString).substring(to: existing)
        let new = current == prefix ? "" : prefix   // pressing the same style again removes it
        let delta = (new as NSString).length - existing
        replace(NSRange(location: line.location, length: existing), with: new, action: "Format")
        textView.setSelectedRange(NSRange(location: max(line.location, selection.location + delta), length: selection.length))
    }

    // MARK: Status

    var wordCount: Int {
        storage.string.split { $0.isWhitespace || $0.isNewline }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    var caretAddress: String {
        let outline = textView.outline
        guard let a = outline.address(of: userCursor) else { return "" }
        return "¶\(a.paragraph)" + (a.sentence.map { " · \($0)" } ?? "")
    }
}
