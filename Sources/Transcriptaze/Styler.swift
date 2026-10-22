import AppKit
import TranscriptazeCore

/// Sets markdown as type. Markup stays in the text but recedes; only display
/// attributes are touched, never the text or the fresh-dictation marks.
struct Styler {
    var typesetting: Typesetting

    static let managedKeys: [NSAttributedString.Key] = [.font, .foregroundColor, .paragraphStyle, .kern, .backgroundColor, .strikethroughStyle, .underlineStyle, .baselineOffset]

    var isBook: Bool { typesetting.pageStyle == .book }

    /// Body paragraphs. A book sets them justified and hyphenated, marks each
    /// new paragraph with an indent rather than a gap, and leaves the first
    /// paragraph after a heading flush, as printers do.
    func paragraphStyle(lineHeight: CGFloat? = nil, before: CGFloat = 0, after: CGFloat? = nil, headIndent: CGFloat = 0, indentFirstLine: Bool = false, body: Bool = false) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeight ?? typesetting.lineHeight
        p.paragraphSpacing = after ?? (isBook ? 0 : typesetting.size * 0.72)
        p.paragraphSpacingBefore = before
        p.headIndent = headIndent
        p.firstLineHeadIndent = headIndent
        p.lineBreakStrategy = .standard
        p.hyphenationFactor = 0
        if body && isBook {
            p.alignment = .justified
            p.hyphenationFactor = 1.0
            p.usesDefaultHyphenation = true
            if indentFirstLine { p.firstLineHeadIndent = typesetting.size * 1.35 }
        }
        return p
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: typesetting.body, .foregroundColor: Palette.ink, .paragraphStyle: paragraphStyle()]
    }

    /// Restyles every line touching `range`.
    func style(_ storage: NSTextStorage, lines range: NSRange) {
        let ns = storage.string as NSString
        var lineRange = ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length))))
        // The next line's indent depends on this one.
        if NSMaxRange(lineRange) < ns.length {
            lineRange = NSUnionRange(lineRange, ns.lineRange(for: NSRange(location: NSMaxRange(lineRange), length: 0)))
        }
        let fenceState = Self.inFence(before: lineRange.location, in: ns)
        var inFence = fenceState
        var location = lineRange.location
        while location < NSMaxRange(lineRange) || (location == ns.length && location == lineRange.location) {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            styleLine(storage, line: line, inFence: &inFence)
            if NSMaxRange(line) <= location { break }
            location = NSMaxRange(line)
            if location >= ns.length { break }
        }
        applyFreshInk(storage, in: lineRange)
    }

    func styleAll(_ storage: NSTextStorage) {
        storage.beginEditing()
        style(storage, lines: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// Whether the line before this one is running prose (so this one is indented).
    static func followsProse(_ location: Int, in ns: NSString) -> Bool {
        guard location > 0 else { return false }
        let previous = ns.lineRange(for: NSRange(location: location - 1, length: 0))
        var text = ns.substring(with: previous)
        if text.hasSuffix("\n") { text.removeLast() }
        return Outline.classify(text).0 == .prose
    }

    static func inFence(before location: Int, in ns: NSString) -> Bool {
        guard location > 0 else { return false }
        var count = 0
        ns.substring(to: location).enumerateLines { line, _ in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { count += 1 }
        }
        return count % 2 == 1
    }

    private func styleLine(_ storage: NSTextStorage, line: NSRange, inFence: inout Bool) {
        let ns = storage.string as NSString
        var content = line
        if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
        for key in Self.managedKeys { storage.removeAttribute(key, range: line) }
        storage.addAttributes(baseAttributes, range: line)
        let text = ns.substring(with: content)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let ts = typesetting

        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || inFence {
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            storage.addAttributes([
                .font: ts.mono,
                .foregroundColor: isFence ? Palette.faintInk : Palette.ink,
                .backgroundColor: Palette.codeWash,
                .paragraphStyle: paragraphStyle(lineHeight: 1.3, after: 0),
            ], range: line)
            if isFence { inFence.toggle() }
            return
        }

        let (kind, prefix) = Outline.classify(text)
        let prefixRange = NSRange(location: content.location, length: min(prefix, content.length))
        switch kind {
        case .heading(let level):
            storage.addAttributes([
                .font: ts.heading(level),
                .paragraphStyle: paragraphStyle(lineHeight: 1.2, before: ts.size * (level == 1 ? 1.1 : 0.8), after: ts.size * (isBook ? 0.9 : 0.45)),
            ], range: line)
            // The hashes are markup, not type: kept in the text, never seen.
            storage.addAttributes([.foregroundColor: NSColor.clear, .font: NSFont.systemFont(ofSize: 0.01)], range: prefixRange)
        case .listItem:
            let indent = (ns.substring(with: prefixRange) as NSString).size(withAttributes: [.font: ts.body]).width
            storage.addAttribute(.paragraphStyle, value: paragraphStyle(after: ts.size * 0.3, headIndent: indent), range: line)
            storage.addAttribute(.foregroundColor, value: Palette.rubric.withAlphaComponent(0.8), range: prefixRange)
        case .quote:
            let quote = paragraphStyle(before: isBook ? ts.size * 0.5 : 0, after: isBook ? ts.size * 0.5 : nil, headIndent: isBook ? ts.size * 1.35 : 0, body: true)
            storage.addAttributes([.font: ts.italic, .foregroundColor: Palette.secondaryInk, .paragraphStyle: quote], range: line)
            storage.addAttribute(.foregroundColor, value: Palette.faintInk, range: prefixRange)
        case .rule:
            storage.addAttributes([.foregroundColor: Palette.faintInk, .kern: 6], range: line)
            return
        case .blank, .code:
            return
        case .prose:
            storage.addAttribute(.paragraphStyle, value: paragraphStyle(indentFirstLine: Self.followsProse(content.location, in: ns), body: true), range: line)
        }

        // Inline markup.
        let body = NSRange(location: content.location + prefixRange.length, length: content.length - prefixRange.length)
        let bodyText = ns.substring(with: body)
        let isHeading: Bool = { if case .heading = kind { return true }; return false }()
        for span in InlineMarkdown.spans(in: bodyText) {
            let r = NSRange(location: body.location + span.range.location, length: span.range.length)
            switch span.kind {
            case .strong:
                storage.addAttribute(.font, value: isHeading ? storage.attribute(.font, at: r.location, effectiveRange: nil)! : (kind == .quote ? ts.boldItalic : ts.bold), range: r)
            case .emphasis:
                storage.addAttribute(.font, value: kind == .quote ? ts.body : ts.italic, range: r)
            case .code:
                storage.addAttributes([.font: ts.mono, .backgroundColor: Palette.codeWash], range: r)
            case .strike:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Palette.secondaryInk], range: r)
            case .link:
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Palette.faintInk], range: r)
            }
            for m in span.markers where m.length > 0 {
                storage.addAttribute(.foregroundColor, value: Palette.faintInk, range: NSRange(location: body.location + m.location, length: m.length))
            }
            if span.kind == .link, let last = span.markers.last {
                storage.removeAttribute(.underlineStyle, range: NSRange(location: body.location + last.location, length: last.length))
            }
        }

        // Room for the raised verse numbers: widen the space before each sentence.
        guard ts.showNumbers, kind != .rule, !isHeading else { return }
        let sentences = Outline.sentenceRanges(in: bodyText)
        let verse = ts.verseNumeral
        for (i, s) in sentences.enumerated() where i > 0 {
            let at = body.location + s.location - 1
            guard at >= body.location, ns.character(at: at) == 0x20 else { continue }
            let w = ("\(i + 1)" as NSString).size(withAttributes: [.font: verse]).width
            storage.addAttribute(.kern, value: w + 3, range: NSRange(location: at, length: 1))
        }
    }

    /// Unreviewed dictation is set in wet ink until the guardian has read it.
    func applyFreshInk(_ storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(.freshBatch, in: range) { value, r, _ in
            guard value != nil else { return }
            storage.addAttribute(.foregroundColor, value: Palette.wetInk, range: r)
        }
    }
}

