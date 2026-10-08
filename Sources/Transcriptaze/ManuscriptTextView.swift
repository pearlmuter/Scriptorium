import AppKit
import TranscriptazeCore

extension NSAttributedString.Key {
    /// Batch number of dictated text the guardian has not yet reviewed.
    static let freshBatch = NSAttributedString.Key("TZFreshBatch")
    /// Id of the highlight a character belongs to. Drawn, never written to the file.
    static let highlight = NSAttributedString.Key("TZHighlight")
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

    /// Colour, note and author of each highlight id in the text.
    var highlightInfo: [String: HighlightSpan] = [:] { didSet { needsDisplay = true } }
    /// Highlights just dismissed, fading out.
    private var fading: [(range: NSRange, color: HighlightColor, start: Date)] = []
    private var fadeTimer: Timer?
    /// Where the user's caret was when they went to the chat.
    var ghostRange: NSRange? { didSet { needsDisplay = true } }
    /// The sentence being read aloud, washed in lapis while it is heard.
    var readingRange: NSRange? { didSet { needsDisplay = true } }

    var onFormat: ((String) -> Void)?
    /// A plain click on a highlight.
    var onDismissHighlight: ((String) -> Void)?
    var onBecomeFirstResponder: (() -> Void)?

    let palette = HighlightPalette()
    private var paletteTask: DispatchWorkItem?
    private var pendingDismiss: DispatchWorkItem?

    /// The visible width, not our own frame: the inset feeds back into the frame.
    var viewportWidth: CGFloat { enclosingScrollView?.contentSize.width ?? bounds.width }
    var columnWidth: CGFloat { max(240, min(typesetting.measure, viewportWidth - 140)) }
    var horizontalMargin: CGFloat { max(70, floor((viewportWidth - columnWidth) / 2)) }

    override func setFrameSize(_ newSize: NSSize) {
        // Never wider than the page: the column is centred by the inset, not by scrolling sideways.
        var size = newSize
        if let width = enclosingScrollView?.contentSize.width, width > 0 { size.width = width }
        super.setFrameSize(size)
        updateContainer()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setFrameSize(self.frame.size)
                if clip.bounds.origin.x != 0 { clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y)) }
            }
        }
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
        drawHighlights()
        drawReading()
        drawGuardianWash()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // NSTextView leaves the clip on the text column; numbers live in the margin.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: dirtyRect).setClip()
        if typesetting.showNumbers { drawNumbers(in: dirtyRect) }
        drawGuardianCaret()
        drawGhost()
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

    private func drawReading() {
        guard let range = readingRange, range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }
        Palette.lapis.withAlphaComponent(0.11).setFill()
        for r in markerRects(for: range) { marker(r).fill() }
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

    // MARK: Highlights

    /// Each highlight run's rectangles, one per line it spans.
    private func markerRects(for range: NSRange) -> [NSRect] {
        guard let lm = layoutManager, let tc = textContainer, NSMaxRange(range) <= (string as NSString).length else { return [] }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSRect] = []
        lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
            let r = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            // Line spacing sits above the glyphs; the marker covers the letters, not the gap.
            let h = r.height
            rects.append(NSRect(x: r.minX - 2, y: r.minY + h * 0.2, width: r.width + 4, height: h * 0.78))
        }
        return rects
    }

    /// A felt-tip stroke: slightly rounded, never quite rectangular.
    private func marker(_ r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let k: CGFloat = 2.5
        p.move(to: NSPoint(x: r.minX + k, y: r.minY + 0.5))
        p.line(to: NSPoint(x: r.maxX - k, y: r.minY))
        p.curve(to: NSPoint(x: r.maxX, y: r.minY + k), controlPoint1: NSPoint(x: r.maxX - 0.5, y: r.minY), controlPoint2: NSPoint(x: r.maxX, y: r.minY + 0.5))
        p.line(to: NSPoint(x: r.maxX - 0.5, y: r.maxY - k))
        p.curve(to: NSPoint(x: r.maxX - k, y: r.maxY), controlPoint1: NSPoint(x: r.maxX - 0.5, y: r.maxY - 0.5), controlPoint2: NSPoint(x: r.maxX - 1, y: r.maxY))
        p.line(to: NSPoint(x: r.minX + k, y: r.maxY - 0.5))
        p.curve(to: NSPoint(x: r.minX, y: r.maxY - k), controlPoint1: NSPoint(x: r.minX + 0.5, y: r.maxY - 0.5), controlPoint2: NSPoint(x: r.minX, y: r.maxY - 1))
        p.line(to: NSPoint(x: r.minX + 0.5, y: r.minY + k))
        p.curve(to: NSPoint(x: r.minX + k, y: r.minY + 0.5), controlPoint1: NSPoint(x: r.minX + 0.5, y: r.minY + 1), controlPoint2: NSPoint(x: r.minX + 1, y: r.minY + 0.5))
        p.close()
        return p
    }

    private func drawHighlights() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let visible = visibleCharacterRange
        storage.enumerateAttribute(.highlight, in: visible) { value, range, _ in
            guard let id = value as? String, let info = highlightInfo[id] else { return }
            let rects = markerRects(for: range)
            Palette.highlighter(info.color).setFill()
            for r in rects { marker(r).fill() }
            // The guardian's highlights carry its lapis diamond; one with a note says so on hover.
            if info.author == .guardian, let last = rects.last, NSMaxRange(range) == highlightEnd(id, from: range) {
                let cx = last.maxX - 1, cy = last.minY + 1
                let d = NSBezierPath()
                d.move(to: NSPoint(x: cx, y: cy - 3)); d.line(to: NSPoint(x: cx + 2.4, y: cy))
                d.line(to: NSPoint(x: cx, y: cy + 3)); d.line(to: NSPoint(x: cx - 2.4, y: cy)); d.close()
                Palette.lapis.withAlphaComponent(info.note == nil ? 0.45 : 0.9).setFill()
                d.fill()
            }
        }
        let now = Date()
        for f in fading {
            let t = now.timeIntervalSince(f.start) / 0.35
            guard t < 1 else { continue }
            Palette.highlighter(f.color).withAlphaComponent(Palette.highlighter(f.color).alphaComponent * (1 - t)).setFill()
            for r in markerRects(for: f.range) { marker(r.insetBy(dx: CGFloat(t) * 3, dy: 0)).fill() }
        }
    }

    /// Where the run of highlight `id` that contains `range` ends.
    private func highlightEnd(_ id: String, from range: NSRange) -> Int {
        guard let storage = textStorage else { return NSMaxRange(range) }
        var end = NSMaxRange(range)
        while end < storage.length, storage.attribute(.highlight, at: end, effectiveRange: nil) as? String == id { end += 1 }
        return end
    }

    func fadeOut(_ range: NSRange, color: HighlightColor) {
        fading.append((range, color, Date()))
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.fading.removeAll { Date().timeIntervalSince($0.start) > 0.35 }
                self.needsDisplay = true
                if self.fading.isEmpty { timer.invalidate() }
            }
        }
    }

    /// The highlight under a point, if the point is on its letters.
    func highlightID(at point: NSPoint) -> String? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).insetBy(dx: -1, dy: 0).contains(p) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.highlight, at: index, effectiveRange: nil) as? String
    }

    override func mouseDown(with event: NSEvent) {
        pendingDismiss?.cancel()
        let hit = highlightID(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)   // tracks the click or drag to mouse-up
        // A plain click on a highlight wipes it away. Wait out a double-click,
        // which selects a word instead.
        guard let hit, event.clickCount == 1, selectedRange().length == 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.onDismissHighlight?(hit) }
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.userInfo?["highlights"] != nil }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["highlights": true]))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let id = highlightID(at: convert(event.locationInWindow, from: nil))
        let tip = id.flatMap { highlightInfo[$0] }.map { info -> String in
            let who = info.author == .guardian ? "Guardian" : "You"
            return [info.note, "\(who) · \(info.color.rawValue) · click to dismiss"].compactMap { $0 }.joined(separator: "\n")
        }
        if toolTip != tip { toolTip = tip }
    }

    // MARK: Palette

    /// Shows the three inks beside a fresh selection, once it has settled.
    func updatePalette() {
        paletteTask?.cancel()
        let sel = selectedRange()
        let text = string as NSString
        guard window?.firstResponder === self, sel.length > 0, NSMaxRange(sel) <= text.length,
              !text.substring(with: sel).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hidePalette()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.placePalette(for: sel) }
        paletteTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func placePalette(for sel: NSRange) {
        guard selectedRange() == sel, let lm = layoutManager, let tc = textContainer else { return }
        var overlaps = false
        textStorage?.enumerateAttribute(.highlight, in: sel) { v, _, stop in if v != nil { overlaps = true; stop.pointee = true } }
        palette.showsEraser = overlaps
        let glyphs = lm.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        var rects: [NSRect] = []
        lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, _ in
            rects.append(r.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
        }
        guard let first = rects.first, let last = rects.last else { return }
        // In the right margin, level with the selection's first line, where it hides no text.
        // If the margin is too narrow, flat above the selection instead.
        let columnRight = textContainerOrigin.x + columnWidth
        palette.vertical = bounds.width - columnRight >= 40
        let size = palette.intrinsicContentSize
        var origin: NSPoint
        if palette.vertical {
            let lineMid = first.minY + first.height * 0.6
            origin = NSPoint(x: columnRight + 12, y: lineMid - 7 - 7)
        } else {
            origin = NSPoint(x: first.minX, y: first.minY - size.height + 2)
            if origin.y < visibleRect.minY + 4 { origin = NSPoint(x: last.minX, y: last.maxY + 2) }
            origin.x = min(max(origin.x, textContainerOrigin.x - 8), columnRight - size.width + 8)
        }
        palette.frame = NSRect(origin: origin, size: size)
        if palette.superview !== self { addSubview(palette) }
        palette.isHidden = false
        palette.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            palette.animator().alphaValue = 1
        }
    }

    func hidePalette() {
        paletteTask?.cancel()
        palette.isHidden = true
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeFirstResponder?() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        hidePalette()
        return super.resignFirstResponder()
    }

    // MARK: Ghost cursor

    /// The user's caret left behind while they talk in the chat: a hollow ink
    /// bar with a ring on top, or a dotted underline beneath a selection.
    private func drawGhost() {
        guard let range = ghostRange, let lm = layoutManager, let tc = textContainer else { return }
        let length = (string as NSString).length
        guard NSMaxRange(range) <= length else { return }
        Palette.ink.withAlphaComponent(0.42).set()
        if range.length > 0 {
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
                let r = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                Palette.ink.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX - 1, y: r.minY + r.height * 0.2, width: r.width + 2, height: r.height * 0.78), xRadius: 2, yRadius: 2).fill()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: r.minX, y: r.maxY - 1.5))
                line.line(to: NSPoint(x: r.maxX, y: r.maxY - 1.5))
                line.lineWidth = 1.4
                line.setLineDash([2, 2.5], count: 2, phase: 0)
                Palette.ink.withAlphaComponent(0.5).setStroke()
                line.stroke()
            }
            return
        }
        var rect: NSRect
        if range.location < length {
            let glyph = lm.glyphIndexForCharacter(at: range.location)
            let line = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            rect = NSRect(x: line.minX + lm.location(forGlyphAt: glyph).x, y: line.minY, width: 1.5, height: line.height)
        } else if length > 0 {
            let line = lm.lineFragmentUsedRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil)
            rect = NSRect(x: line.maxX, y: line.minY, width: 1.5, height: line.height)
            if (string as NSString).character(at: length - 1) == 0x0A { rect.origin = NSPoint(x: 0, y: line.maxY) }
        } else {
            rect = NSRect(x: 0, y: 0, width: 1.5, height: typesetting.size * typesetting.lineHeight)
        }
        rect = rect.offsetBy(dx: textContainerOrigin.x - 0.75, dy: textContainerOrigin.y)
        rect = rect.insetBy(dx: 0, dy: rect.height * 0.14)
        Palette.ink.withAlphaComponent(0.4).setFill()
        NSBezierPath(rect: rect).fill()
        let ring = NSBezierPath(ovalIn: NSRect(x: rect.midX - 3, y: rect.minY - 6.5, width: 6, height: 6))
        ring.lineWidth = 1.2
        Palette.ink.withAlphaComponent(0.5).setStroke()
        ring.stroke()
    }

    // MARK: Keyboard formatting

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let map: [String: String] = flags == .command
            ? ["b": "bold", "i": "italic", "k": "link", "1": "h1", "2": "h2", "3": "h3", "0": "body"]
            : flags == [.command, .shift] ? ["8": "bullet", "7": "numbered", ".": "quote", "c": "code", "x": "strike"] : [:]
        if flags == [.command, .option], let i = ["1", "2", "3", "0"].firstIndex(of: key) {
            onFormat?(["highlight-yellow", "highlight-green", "highlight-pink", "highlight-clear"][i])
            return true
        }
        if let action = map[key] {
            onFormat?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
