import Foundation

/// One stretch of the note read aloud: a sentence, addressed so the editor can
/// show it while it is heard.
public struct Passage: Equatable, Sendable {
    public let paragraph: Int
    public let sentence: Int
    public let text: String
}

/// The reading voice. The app implements it with Kokoro; the guardian drives it.
@MainActor
public protocol Narrator: AnyObject {
    /// Reads the passages in order, replacing anything being read.
    func read(_ passages: [Passage])
    func stopReading()
    /// Why reading is impossible, if it is.
    var unavailableReason: String? { get }
}

public enum Narration {
    /// The sentences of ¶from…¶to as plain text to speak. Markdown is dropped,
    /// and very short sentences ride with the next one so the voice keeps its flow.
    public static func passages(from: Int, to: Int, sentence: Int? = nil, in text: String) -> [Passage] {
        let outline = Outline(text: text)
        let ns = text as NSString
        var out: [Passage] = []
        var carry: (paragraph: Int, sentence: Int, text: String)?
        for block in outline.paragraphs {
            guard let p = block.number, p >= from, p <= to else { continue }
            for s in block.sentences where p != from || sentence == nil || s.number >= sentence! {
                let spoken = MarkdownFile.stripInline(ns.substring(with: s.range)).trimmingCharacters(in: .whitespaces)
                guard !spoken.isEmpty else { continue }
                if let c = carry {
                    carry = (c.paragraph, c.sentence, c.text + " " + spoken)
                } else {
                    carry = (p, s.number, spoken)
                }
                if carry!.text.count >= 30 {
                    out.append(Passage(paragraph: carry!.paragraph, sentence: carry!.sentence, text: carry!.text))
                    carry = nil
                }
            }
            // A paragraph's last short sentence does not run into the next paragraph.
            if let c = carry { out.append(Passage(paragraph: c.paragraph, sentence: c.sentence, text: c.text)); carry = nil }
        }
        return out
    }

    /// About how long reading takes aloud, at an unhurried 2.6 words a second.
    public static func seconds(for passages: [Passage]) -> Int {
        Int((Double(passages.reduce(0) { $0 + $1.text.split(separator: " ").count }) / 2.6).rounded())
    }
}
