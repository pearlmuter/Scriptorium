import Foundation

/// What streamed speech asks the editor to do.
public enum DictationAction: Equatable {
    case text(String)
    case paragraphBreak
}

/// Catches "new paragraph" / "new line" the instant they are spoken, so the
/// words never reach the page and the speaker is already on the next line.
///
/// Kyutai emits a word at a time, so a trailing "new" is held back until the
/// following word shows whether it began a command. Everything else passes
/// straight through. The guardian handles any command this misses.
public struct CommandReflex {
    private var held = ""
    public var isEnabled = true

    public init() {}

    static let commands: Set<String> = ["new paragraph", "new line", "next paragraph"]

    static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }

    /// Feeds a chunk of transcript (which may hold several words).
    public mutating func feed(_ chunk: String) -> [DictationAction] {
        guard isEnabled else { return chunk.isEmpty ? [] : [.text(chunk)] }
        var actions: [DictationAction] = []
        var pending = ""
        // Words keep their leading space, as the transcriber emits them.
        for word in Self.words(in: chunk) {
            if !held.isEmpty {
                let pair = Self.normalize(held) + " " + Self.normalize(word)
                if Self.commands.contains(pair) {
                    if !pending.isEmpty { actions.append(.text(pending)); pending = "" }
                    actions.append(.paragraphBreak)
                    held = ""
                    continue
                }
                pending += held
                held = ""
            }
            if Self.normalize(word) == "new" || Self.normalize(word) == "next" {
                held = word
            } else {
                pending += word
            }
        }
        if !pending.isEmpty { actions.append(.text(pending)) }
        return actions
    }

    /// Releases a held word — on a pause, or when dictation stops.
    public mutating func flush() -> [DictationAction] {
        defer { held = "" }
        return held.isEmpty ? [] : [.text(held)]
    }

    static func words(in chunk: String) -> [String] {
        var words: [String] = []
        var current = ""
        for ch in chunk {
            if ch.isWhitespace && !current.trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// Places dictated text at the caret with the spacing and capitalisation a
/// typist would have used.
public enum DictationComposer {
    /// The edit inserting `chunk` at `caret`, and where the caret ends up.
    public static func insert(_ chunk: String, at caret: Int, in text: String) -> (TextEdit, caret: Int) {
        let ns = text as NSString
        let caret = min(max(0, caret), ns.length)
        let prev: unichar? = caret > 0 ? ns.character(at: caret - 1) : nil
        let next: unichar? = caret < ns.length ? ns.character(at: caret) : nil
        var s = chunk
        let atLineStart = prev == nil || prev == 0x0A
        let afterContentPrefix = prev.map { isMarkdownPrefixEnd(ns, caret) && $0 == 0x20 } ?? false

        if atLineStart || afterContentPrefix || prev == 0x20 {
            s = String(s.drop { $0 == " " })
        } else if let first = s.first, !first.isWhitespace, !",.;:!?)'’".contains(first) {
            s = " " + s
        }
        if atLineStart || afterContentPrefix || endsSentence(ns, before: caret) {
            s = capitalizingFirstLetter(s)
        }
        var addedTrailingSpace = false
        if let next, next != 0x20, next != 0x0A, !",.;:!?)".utf16.contains(next), s.last != " " {
            s += " "
            addedTrailingSpace = true
        }
        let edit = TextEdit(range: NSRange(location: caret, length: 0), replacement: s)
        // The caret stays before a padding space, so the next word joins naturally.
        return (edit, caret + (s as NSString).length - (addedTrailingSpace ? 1 : 0))
    }

    /// A paragraph break at the caret, trimming the space a speaker leaves before it.
    public static func paragraphBreak(at caret: Int, in text: String) -> (TextEdit, caret: Int) {
        let ns = text as NSString
        var start = min(caret, ns.length)
        while start > 0, ns.character(at: start - 1) == 0x20 { start -= 1 }
        var end = min(caret, ns.length)
        while end < ns.length, ns.character(at: end) == 0x20 { end += 1 }
        // A speaker's pause before "new paragraph" often reaches the page as a comma; end the sentence instead.
        var replacement = "\n"
        if start > 0, ",;".utf16.contains(ns.character(at: start - 1)) {
            start -= 1
            replacement = ".\n"
        }
        return (TextEdit(range: NSRange(location: start, length: end - start), replacement: replacement), start + (replacement as NSString).length)
    }

    static func endsSentence(_ ns: NSString, before caret: Int) -> Bool {
        var i = caret - 1
        while i >= 0, ns.character(at: i) == 0x20 { i -= 1 }
        guard i >= 0 else { return true }
        return ".!?".utf16.contains(ns.character(at: i))
    }

    /// True when everything between line start and caret is a markdown prefix like "- " or "## ".
    static func isMarkdownPrefixEnd(_ ns: NSString, _ caret: Int) -> Bool {
        let lineStart = ns.lineRange(for: NSRange(location: max(0, caret - 1), length: 0)).location
        let head = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        let (kind, prefix) = Outline.classify(head + "x")
        return kind != .prose && prefix == (head as NSString).length
    }

    static func capitalizingFirstLetter(_ s: String) -> String {
        guard let i = s.firstIndex(where: { $0.isLetter }) else { return s }
        return s.replacingCharacters(in: i...i, with: String(s[i]).uppercased())
    }
}

/// Spoken sending for the chat: a message dictated into the chat field is sent
/// when it ends in "send it" (or "send message", "send that", or a lone "send")
/// and the speaker pauses.
public enum ChatVoice {
    static let commands = ["send it", "send message", "send the message", "send that", "send"]

    /// The draft without its closing send command, or nil if it has none.
    public static func strippingSend(_ draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = trimmed.lowercased()
        for command in commands where lower.hasSuffix(command) {
            let head = String(trimmed.dropLast(command.count))
            // A whole word, and (for a bare "send") its own sentence: "Then send" is prose, "…right? Send." is not.
            if let c = head.last, !(c.isWhitespace || c.isPunctuation) { continue }
            let rest = head.trimmingCharacters(in: .whitespaces)
            if command == "send", let last = rest.last, !".?!".contains(last) { continue }
            return rest.trimmingCharacters(in: CharacterSet(charactersIn: ",;: ")).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
