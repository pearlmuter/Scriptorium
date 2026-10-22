import Foundation

/// One contiguous replacement. Every guardian operation reduces to exactly one,
/// so it can be applied atomically between two dictated words.
public struct TextEdit: Equatable {
    public var range: NSRange
    public var replacement: String
    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }

    /// Where an offset ends up after this edit. Offsets inside the replaced
    /// range move to its end, so a caret never lands mid-replacement.
    public func transform(_ offset: Int) -> Int {
        if offset <= range.location { return offset }
        let delta = (replacement as NSString).length - range.length
        if offset >= NSMaxRange(range) { return offset + delta }
        return range.location + (replacement as NSString).length
    }
}

public struct OperationError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Address-and-quote text operations: resolve a paragraph (and optionally a
/// sentence), find the quoted text there, produce one `TextEdit`.
public enum TextOperations {
    public enum Style: String, CaseIterable {
        case bold, italic, code, strike
        case heading1, heading2, heading3, quote, bullet, numbered, plain
    }

    // MARK: Resolution

    static func paragraph(_ number: Int, in outline: Outline) throws -> Outline.Block {
        guard let block = outline.paragraph(number) else {
            let count = outline.paragraphs.count
            throw OperationError("There is no ¶\(number); the note has \(count) paragraph\(count == 1 ? "" : "s"). Call read_document to see current numbering.")
        }
        return block
    }

    static func scope(paragraph number: Int, sentence: Int?, in outline: Outline) throws -> (block: Outline.Block, range: NSRange) {
        let block = try paragraph(number, in: outline)
        guard let sentence else { return (block, block.contentRange) }
        guard let s = block.sentences.first(where: { $0.number == sentence }) else {
            throw OperationError("¶\(number) has \(block.sentences.count) sentence(s); there is no sentence \(sentence).")
        }
        return (block, s.range)
    }

    /// Text the model may have copied out of `read_document` along with the quote.
    static func cleanQuote(_ quote: String) -> String {
        var q = quote.replacingOccurrences(of: "‸", with: "").replacingOccurrences(of: "•", with: "")
        q = q.replacingOccurrences(of: "^\\s*\\[\\d+\\]\\s*", with: "", options: .regularExpression)
        return q
    }

    static func normalizeQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "[’‘]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[“”]", with: "\"", options: .regularExpression)
    }

    /// Finds `quote` inside `range`. Exact first, then case/quote-insensitive.
    /// Falls back from the sentence to its paragraph, since sentence numbers
    /// are the thing a speaker is likeliest to get wrong.
    static func locate(_ rawQuote: String, paragraph number: Int, sentence: Int?, occurrence: Int?, in text: String) throws -> NSRange {
        let quote = cleanQuote(rawQuote)
        guard !quote.isEmpty else { throw OperationError("The text to find is empty.") }
        let outline = Outline(text: text)
        let (block, range) = try scope(paragraph: number, sentence: sentence, in: outline)
        let ns = text as NSString

        func matches(in scope: NSRange) -> [NSRange] {
            for options: NSString.CompareOptions in [[], [.caseInsensitive]] {
                var found: [NSRange] = []
                let haystack = normalizeQuotes(ns.substring(with: scope)) as NSString
                let needle = normalizeQuotes(quote)
                var search = NSRange(location: 0, length: haystack.length)
                while search.length > 0 {
                    let r = haystack.range(of: needle, options: options, range: search)
                    if r.location == NSNotFound { break }
                    found.append(NSRange(location: scope.location + r.location, length: r.length))
                    search = NSRange(location: NSMaxRange(r), length: haystack.length - NSMaxRange(r))
                }
                if !found.isEmpty { return found }
            }
            return []
        }

        var found = matches(in: range)
        if found.isEmpty, sentence != nil { found = matches(in: block.contentRange) }
        guard !found.isEmpty else {
            let where_ = sentence.map { "¶\(number) sentence \($0)" } ?? "¶\(number)"
            throw OperationError("\"\(quote)\" was not found in \(where_). It currently reads: \"\(ns.substring(with: range))\"")
        }
        if let occurrence {
            guard occurrence >= 1, occurrence <= found.count else {
                throw OperationError("\"\(quote)\" occurs \(found.count) time(s); occurrence \(occurrence) does not exist.")
            }
            return found[occurrence - 1]
        }
        guard found.count == 1 else {
            throw OperationError("\"\(quote)\" occurs \(found.count) times there. Quote more surrounding words, or pass occurrence.")
        }
        return found[0]
    }

    // MARK: Operations

    public static func replace(_ find: String, with replacement: String, paragraph: Int, sentence: Int?, occurrence: Int? = nil, in text: String) throws -> TextEdit {
        let range = try locate(find, paragraph: paragraph, sentence: sentence, occurrence: occurrence, in: text)
        return TextEdit(range: range, replacement: replacement)
    }

    public static func rewriteSentence(paragraph: Int, sentence: Int, text newText: String, in text: String) throws -> TextEdit {
        let (_, range) = try scope(paragraph: paragraph, sentence: sentence, in: Outline(text: text))
        return TextEdit(range: range, replacement: newText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Deletes quoted text, taking one neighbouring space with it so no
    /// double space or space-before-punctuation is left behind.
    public static func delete(_ find: String, paragraph: Int, sentence: Int?, occurrence: Int? = nil, in text: String) throws -> TextEdit {
        var range = try locate(find, paragraph: paragraph, sentence: sentence, occurrence: occurrence, in: text)
        range = absorbSpace(around: range, in: text as NSString)
        return TextEdit(range: range, replacement: "")
    }

    static func absorbSpace(around range: NSRange, in ns: NSString) -> NSRange {
        var r = range
        let before: unichar? = r.location > 0 ? ns.character(at: r.location - 1) : nil
        let after: unichar? = NSMaxRange(r) < ns.length ? ns.character(at: NSMaxRange(r)) : nil
        let isSpace: (unichar?) -> Bool = { $0 == 0x20 }
        let isBoundary: (unichar?) -> Bool = { c in
            guard let c else { return true }
            return c == 0x0A || ",.;:!?)".utf16.contains(c)
        }
        if isSpace(before) && (isSpace(after) || isBoundary(after)) {
            r.location -= 1; r.length += 1
        } else if isSpace(after) && (before == nil || before == 0x0A) {
            r.length += 1
        }
        return r
    }

    /// Starts a new paragraph at `at`. With `removeMatched`, the matched words
    /// themselves are deleted — how a spoken "new paragraph" is carried out.
    /// The first letter of the new paragraph is capitalised.
    public static func splitParagraph(paragraph: Int, at quote: String, removeMatched: Bool, occurrence: Int? = nil, in text: String) throws -> TextEdit {
        let ns = text as NSString
        let found = try locate(quote, paragraph: paragraph, sentence: nil, occurrence: occurrence, in: text)
        let block = try self.paragraph(paragraph, in: Outline(text: text))

        // Left side: drop trailing spaces (and dangling commas a dictated command leaves).
        var start = removeMatched ? found.location : found.location
        while start > block.contentRange.location, " ,".utf16.contains(ns.character(at: start - 1)) { start -= 1 }
        // Right side: skip the command, its punctuation and spaces, then capitalise.
        var end = removeMatched ? NSMaxRange(found) : found.location
        if removeMatched {
            while end < NSMaxRange(block.range), ".,;:!? ".utf16.contains(ns.character(at: end)) { end += 1 }
        } else {
            while end < NSMaxRange(block.range), ns.character(at: end) == 0x20 { end += 1 }
        }
        var replacement = "\n"
        if end < NSMaxRange(block.range) {
            let first = ns.substring(with: NSRange(location: end, length: 1))
            replacement += first.uppercased()
            end += 1
        }
        return TextEdit(range: NSRange(location: start, length: end - start), replacement: replacement)
    }

    /// Joins ¶n and ¶n+1 with a space.
    public static func mergeParagraphs(_ paragraph: Int, in text: String) throws -> TextEdit {
        let outline = Outline(text: text)
        let first = try self.paragraph(paragraph, in: outline)
        let second = try self.paragraph(paragraph + 1, in: outline)
        let ns = text as NSString
        var leftEnd = NSMaxRange(first.range)
        while leftEnd > first.range.location, ns.character(at: leftEnd - 1) == 0x20 { leftEnd -= 1 }
        return TextEdit(range: NSRange(location: leftEnd, length: second.contentRange.location - leftEnd), replacement: " ")
    }

    /// Inserts text after (or before) a quoted anchor, or at the end of the paragraph.
    public static func insert(_ newText: String, paragraph: Int, after: String?, before: String?, in text: String) throws -> TextEdit {
        let ns = text as NSString
        let block = try self.paragraph(paragraph, in: Outline(text: text))
        let location: Int
        if let after, !after.isEmpty {
            location = NSMaxRange(try locate(after, paragraph: paragraph, sentence: nil, occurrence: nil, in: text))
        } else if let before, !before.isEmpty {
            location = try locate(before, paragraph: paragraph, sentence: nil, occurrence: nil, in: text).location
        } else {
            location = NSMaxRange(block.range)
        }
        var insertion = newText
        let prev: unichar? = location > block.contentRange.location ? ns.character(at: location - 1) : nil
        let next: unichar? = location < NSMaxRange(block.range) ? ns.character(at: location) : nil
        let startsTight = insertion.first.map { ",.;:!?)".contains($0) || $0 == " " } ?? true
        if let prev, prev != 0x20, !startsTight { insertion = " " + insertion }
        if let next, next != 0x20, !",.;:!?)".utf16.contains(next), insertion.last != " " { insertion += " " }
        return TextEdit(range: NSRange(location: location, length: 0), replacement: insertion)
    }

    /// A new paragraph after ¶n (0 = top of the note).
    public static func insertParagraph(after paragraph: Int, text newText: String, in text: String) throws -> TextEdit {
        let line = newText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if paragraph == 0 {
            return TextEdit(range: NSRange(location: 0, length: 0), replacement: text.isEmpty ? line : line + "\n")
        }
        let block = try self.paragraph(paragraph, in: Outline(text: text))
        return TextEdit(range: NSRange(location: NSMaxRange(block.range), length: 0), replacement: "\n" + line)
    }

    public static func deleteParagraph(_ paragraph: Int, in text: String) throws -> TextEdit {
        let ns = text as NSString
        let block = try self.paragraph(paragraph, in: Outline(text: text))
        var r = block.range
        if NSMaxRange(r) < ns.length { r.length += 1 }           // its own newline
        else if r.location > 0 { r.location -= 1; r.length += 1 } // or the one before, at the end
        return TextEdit(range: r, replacement: "")
    }

    public static func format(_ style: Style, paragraph: Int, find: String?, occurrence: Int? = nil, in text: String) throws -> TextEdit {
        let ns = text as NSString
        switch style {
        case .bold, .italic, .code, .strike:
            let marker = ["bold": "**", "italic": "*", "code": "`", "strike": "~~"][style.rawValue]!
            let range: NSRange
            if let find, !find.isEmpty {
                range = try locate(find, paragraph: paragraph, sentence: nil, occurrence: occurrence, in: text)
            } else {
                range = try self.paragraph(paragraph, in: Outline(text: text)).contentRange
            }
            return TextEdit(range: range, replacement: marker + ns.substring(with: range) + marker)
        default:
            let block = try self.paragraph(paragraph, in: Outline(text: text))
            let prefix: String
            switch style {
            case .heading1: prefix = "# "
            case .heading2: prefix = "## "
            case .heading3: prefix = "### "
            case .quote: prefix = "> "
            case .bullet: prefix = "- "
            case .numbered: prefix = "1. "
            default: prefix = ""
            }
            return TextEdit(range: NSRange(location: block.range.location, length: block.contentRange.location - block.range.location), replacement: prefix)
        }
    }

    /// Caret offset at the start or end of a paragraph or sentence.
    public static func offset(paragraph: Int, sentence: Int?, atEnd: Bool, in text: String) throws -> Int {
        let (block, range) = try scope(paragraph: paragraph, sentence: sentence, in: Outline(text: text))
        if sentence == nil { return atEnd ? NSMaxRange(block.range) : block.contentRange.location }
        return atEnd ? NSMaxRange(range) : range.location
    }
}
