import Foundation
import NaturalLanguage

/// The chapter-and-verse structure of a note.
///
/// In the editor every line is a paragraph (Return starts a new one), so the
/// outline is a function of the text alone. All ranges are UTF-16 `NSRange`s,
/// because that is what `NSTextView` speaks. Headings, code and rules are not
/// counted; prose, list items and quotes are.
public struct Outline: Equatable {
    public enum Kind: Equatable {
        case prose
        case heading(level: Int)
        case listItem
        case quote
        case code
        case rule
        case blank
    }

    public struct Sentence: Equatable {
        public let number: Int
        /// Excludes trailing whitespace.
        public let range: NSRange
    }

    public struct Block: Equatable {
        public let kind: Kind
        /// Paragraph number, when this block is counted.
        public let number: Int?
        /// The whole line, excluding its newline.
        public let range: NSRange
        /// The line minus its markdown prefix (`- `, `> `, `## `).
        public let contentRange: NSRange
        public let sentences: [Sentence]
    }

    public let blocks: [Block]

    public var paragraphs: [Block] { blocks.filter { $0.number != nil } }

    public func paragraph(_ number: Int) -> Block? {
        blocks.first { $0.number == number }
    }

    /// The block containing `offset`; an offset at a newline belongs to the line before it.
    public func block(at offset: Int) -> Block? {
        blocks.first { offset >= $0.range.location && offset <= NSMaxRange($0.range) }
    }

    /// (paragraph, sentence) for an offset, where determinable.
    public func address(of offset: Int) -> (paragraph: Int, sentence: Int?)? {
        guard let block = block(at: offset), let p = block.number else { return nil }
        let s = block.sentences.last { $0.range.location <= offset }?.number ?? block.sentences.first?.number
        return (p, s)
    }

    public init(text: String) {
        let ns = text as NSString
        var blocks: [Block] = []
        var number = 0
        var inFence = false
        var location = 0
        let length = ns.length
        while location <= length {
            let lineEnd = ns.range(of: "\n", options: [], range: NSRange(location: location, length: length - location))
            let end = lineEnd.location == NSNotFound ? length : lineEnd.location
            let range = NSRange(location: location, length: end - location)
            let line = ns.substring(with: range)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            var kind: Kind
            var prefix = 0
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                kind = .code
                inFence.toggle()
            } else if inFence {
                kind = .code
            } else {
                (kind, prefix) = Outline.classify(line)
            }

            let content = NSRange(location: location + prefix, length: max(0, range.length - prefix))
            var paragraphNumber: Int?
            var sentences: [Sentence] = []
            switch kind {
            case .prose, .listItem, .quote:
                number += 1
                paragraphNumber = number
                sentences = Outline.sentences(in: ns, content: content)
            default:
                break
            }
            blocks.append(Block(kind: kind, number: paragraphNumber, range: range, contentRange: content, sentences: sentences))
            if lineEnd.location == NSNotFound { break }
            location = end + 1
        }
        self.blocks = blocks
    }

    /// Kind and markdown prefix length (UTF-16) of a single non-code line.
    public static func classify(_ line: String) -> (Kind, Int) {
        let ns = line as NSString
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return (.blank, 0) }
        if let m = headingRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            return (.heading(level: m.range(at: 1).length), m.range.length)
        }
        if ruleRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
            return (.rule, ns.length)
        }
        if let m = listRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            return (.listItem, m.range.length)
        }
        if let m = quoteRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            return (.quote, m.range.length)
        }
        return (.prose, 0)
    }

    static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+")
    static let ruleRegex = try! NSRegularExpression(pattern: "^\\s{0,3}([-*_])(\\s*\\1){2,}\\s*$")
    static let listRegex = try! NSRegularExpression(pattern: "^\\s*(?:[-*+]|\\d{1,3}[.)])(?:[ \\t]+\\[[ xX]\\])?[ \\t]+")
    static let quoteRegex = try! NSRegularExpression(pattern: "^\\s*>[ \\t]?")

    private static let cache = SentenceCache()

    /// Sentence ranges within a piece of text, exactly as the outline segments them.
    public static func sentenceRanges(in text: String) -> [NSRange] {
        cache.ranges(for: text)
    }

    static func sentences(in ns: NSString, content: NSRange) -> [Sentence] {
        guard content.length > 0 else { return [] }
        let text = ns.substring(with: content)
        let relative = cache.ranges(for: text)
        return relative.enumerated().map { index, r in
            Sentence(number: index + 1, range: NSRange(location: content.location + r.location, length: r.length))
        }
    }
}

/// NLTokenizer is fast, but a paragraph is re-segmented on every keystroke
/// elsewhere in the note; memoising by content makes that free.
final class SentenceCache: @unchecked Sendable {
    private var store: [String: [NSRange]] = [:]
    private let lock = NSLock()

    func ranges(for text: String) -> [NSRange] {
        lock.lock(); defer { lock.unlock() }
        if let hit = store[text] { return hit }
        let result = Self.segment(text)
        if store.count > 4000 { store.removeAll() }
        store[text] = result
        return result
    }

    static func segment(_ text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var r = NSRange(range, in: text)
            // Trim surrounding whitespace so a sentence's range is its words.
            let ns = text as NSString
            while r.length > 0, let c = Unicode.Scalar(ns.character(at: NSMaxRange(r) - 1)), CharacterSet.whitespacesAndNewlines.contains(c) { r.length -= 1 }
            while r.length > 0, let c = Unicode.Scalar(ns.character(at: r.location)), CharacterSet.whitespacesAndNewlines.contains(c) { r.location += 1; r.length -= 1 }
            if r.length > 0 { ranges.append(r) }
            return true
        }
        return ranges
    }
}
