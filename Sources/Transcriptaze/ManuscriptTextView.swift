import AppKit
import TranscriptazeCore

extension NSAttributedString.Key {
    /// Batch number of dictated text the guardian has not yet reviewed.
    static let freshBatch = NSAttributedString.Key("TZFreshBatch")
}

/// The writing surface: a centred column of type with chapter-and-verse
/// numbering drawn around it, and the guardian's cursor drawn into it.
/// Numbers are drawn, never inserted, so the text stays pure markdown.
final class ManuscriptTextView: NSTextView {
    var typesetting = Typesetting() { didSet { updateContainer(); needsDisplay = true } }
    var outline = Outline(text: "") { didSet { needsDisplay = true } }

    /// Where the guardian is looking or last worked.
    var guardianRange: NSRange? { didSet { needsDisplay = true } }
    var guardianActive = false { didSet { needsDisplay = true } }
    /// 0…1, how strongly the guardian's latest edit is washed in lapis.
    var guardianGlow: CGFloat = 0 { didSet { needsDisplay = true } }
    var verticalInset: CGFloat = 96

    var onFormat: ((String) -> Void)?

    /// The visible width, not our own frame: the inset feeds back into the frame.
    var viewportWidth: CGFloat { enclosingScrollView?.contentSize.width ?? bounds.width }
    var columnWidth: CGFloat { max(240, min(typesetting.measure, viewportWidth - 140)) }
    var horizontalMargin: CGFloat { max(70, floor((viewportWidth - columnWidth) / 2)) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContainer()
    }

    func updateContainer() {
        guard let container = textContainer else { return }
        let width = columnWidth
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        let inset = NSSize(width: horizontalMargin, height: verticalInset)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawGuardianWash()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // NSTextView leaves the clip on the text column; numbers live in the margin.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: dirtyRect).setClip()
        if typesetting.showNumbers { drawNumbers(in: dirtyRect) }
        drawGuardianCaret()
        NSGraphicsContext.restoreGraphicsState()
    }

    private var visibleCharacterRange: NSRange {
        guard let lm = layoutManager, let tc = textContainer else { return NSRange(location: 0, length: 0) }
        var r = visibleRect
        r.origin.x -= textContainerOrigin.x
        r.origin.y -= textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: r.insetBy(dx: 0, dy: -200), in: tc)
        return lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// Baseline position of the glyph for a character, in view coordinates.
    private func baselinePoint(forCharacter index: Int) -> (NSPoint, NSRect)? {
        guard let lm = layoutManager, index < (string as NSString).length else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: index)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let loc = lm.location(forGlyphAt: glyph)
        let o = textContainerOrigin
        return (NSPoint(x: o.x + line.minX + loc.x, y: o.y + line.minY + loc.y), line.offsetBy(dx: o.x, dy: o.y))
    }

    private func drawNumbers(in dirtyRect: NSRect) {
        let visible = visibleCharacterRange
        let margin = typesetting.marginNumeral
        let verse = typesetting.verseNumeral
        let body = typesetting.body
        let marginAttrs: [NSAttributedString.Key: Any] = [.font: margin, .foregroundColor: Palette.faintInk, .kern: 0.6]
        let verseAttrs: [NSAttributedString.Key: Any] = [.font: verse, .foregroundColor: Palette.rubric.withAlphaComponent(0.85)]

        for block in outline.paragraphs where NSIntersectionRange(block.range, visible).length > 0 || block.range.location == visible.location {
            guard let number = block.number, block.range.length > 0,
                  let (base, line) = baselinePoint(forCharacter: block.range.location) else { continue }
            guard line.intersects(dirtyRect.insetBy(dx: -200, dy: -40)) else { continue }
            let label = NSAttributedString(string: "\(number)", attributes: marginAttrs)
            let size = label.size()
            label.draw(at: NSPoint(x: textContainerOrigin.x - 26 - size.width, y: base.y - margin.ascender))

            for sentence in block.sentences where sentence.number > 1 {
                guard let (start, _) = baselinePoint(forCharacter: sentence.range.location) else { continue }
                let numeral = NSAttributedString(string: "\(sentence.number)", attributes: verseAttrs)
                let w = numeral.size().width
                let raisedBaseline = start.y - body.xHeight * 0.95
                numeral.draw(at: NSPoint(x: start.x - w - 2.5, y: raisedBaseline - verse.ascender))
            }
        }
    }

    private func drawGuardianWash() {
        guard let range = guardianRange, range.length > 0, guardianGlow > 0.01,
              let lm = layoutManager, let tc = textContainer, NSMaxRange(range) <= (string as NSString).length else { return }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        Palette.lapisWash.withAlphaComponent(0.16 * guardianGlow).setFill()
        lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
            let r = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).insetBy(dx: -2, dy: 1)
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        }
    }

    /// A slim lapis bar with a small cap, distinct from the user's ink caret.
    private func drawGuardianCaret() {
        guard let range = guardianRange, let lm = layoutManager else { return }
        let length = (string as NSString).length
        let index = min(NSMaxRange(range), length)
        var rect: NSRect
        if index < length || length == 0 {
            guard length > 0 else { return }
            let glyph = lm.glyphIndexForCharacter(at: index)
            let line = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let loc = lm.location(forGlyphAt: glyph)
            rect = NSRect(x: line.minX + loc.x, y: line.minY, width: 2, height: line.height)
        } else {
            let glyph = max(0, lm.numberOfGlyphs - 1)
            let line = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            rect = NSRect(x: line.maxX, y: line.minY, width: 2, height: line.height)
        }
        rect = rect.offsetBy(dx: textContainerOrigin.x - 1, dy: textContainerOrigin.y)
        let inset = rect.height * 0.14
        rect = rect.insetBy(dx: 0, dy: inset)
        let alpha: CGFloat = guardianActive ? 1 : 0.4
        Palette.lapis.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        // A small diamond above the bar marks it as the guardian's.
        let d = NSBezierPath()
        let cx = rect.midX, top = rect.minY - 2
        d.move(to: NSPoint(x: cx, y: top - 3.5))
        d.line(to: NSPoint(x: cx + 3, y: top))
        d.line(to: NSPoint(x: cx, y: top + 3.5))
        d.line(to: NSPoint(x: cx - 3, y: top))
        d.close()
        d.fill()
    }

    // MARK: Keyboard formatting

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let map: [String: String] = flags == .command
            ? ["b": "bold", "i": "italic", "k": "link", "1": "h1", "2": "h2", "3": "h3", "0": "body"]
            : flags == [.command, .shift] ? ["8": "bullet", "7": "numbered", ".": "quote", "c": "code", "x": "strike"] : [:]
        if let action = map[key] {
            onFormat?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
