import Combine
import Foundation

// MARK: Highlights

/// Three highlighter inks. What each means is the user's to say; the default
/// convention, for fact checking, is the one the guardian is taught.
public enum HighlightColor: String, CaseIterable, Codable, Sendable {
    case yellow, green, pink

    /// The default convention, as told to the guardian.
    public var meaning: String {
        switch self {
        case .green: return "confirmed / good"
        case .yellow: return "partly true / uncertain / check this"
        case .pink: return "false / a problem"
        }
    }
}

public enum Author: String, Codable, Sendable {
    case user, guardian
}

/// A highlighted run of the open note. The range moves with the text; any edit
/// inside it dismisses it.
public struct HighlightSpan: Equatable, Sendable {
    public let id: String
    public var range: NSRange
    public var color: HighlightColor
    public var note: String?
    public var author: Author

    public init(id: String = UUID().uuidString, range: NSRange, color: HighlightColor, note: String?, author: Author) {
        self.id = id
        self.range = range
        self.color = color
        self.note = note
        self.author = author
    }
}

// MARK: Chat

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, guardian
        /// A guardian edit, shown in the conversation for context. Never sent to the guardian.
        case activity
    }

    public var id = UUID()
    public var date = Date()
    public var role: Role
    public var text: String
    /// Where the user was pointing when they wrote it, e.g. "¶3 [2]".
    public var anchor: String?
    /// The text they had selected, or the words around their ghost cursor (‸ marks it).
    public var quote: String?
    /// Whether the guardian has read it.
    public var delivered = false
    /// For an activity line about a highlight: its ink.
    public var ink: HighlightColor?

    public init(role: Role, text: String, anchor: String? = nil, quote: String? = nil, ink: HighlightColor? = nil) {
        self.role = role
        self.text = text
        self.anchor = anchor
        self.quote = quote
        self.ink = ink
    }
}

/// The conversation about the open note, between the user and the guardian.
@MainActor
public final class ChatLog: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    /// Called after any change, for saving.
    public var onChange: (() -> Void)?

    public init() {}

    public var undelivered: [ChatMessage] { messages.filter { $0.role == .user && !$0.delivered } }

    public func replace(with messages: [ChatMessage]) {
        self.messages = messages
    }

    public func post(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > 500 { messages.removeFirst(messages.count - 500) }
        onChange?()
    }

    /// Marks every user message so far as read by the guardian, returning those that were new.
    public func deliver() -> [ChatMessage] {
        let fresh = undelivered
        guard !fresh.isEmpty else { return [] }
        for i in messages.indices where messages[i].role == .user { messages[i].delivered = true }
        onChange?()
        return fresh
    }

    public func clear() {
        messages.removeAll()
        onChange?()
    }
}

// MARK: Sidecar

/// What belongs to a note but not in its markdown: highlights and the chat.
/// Kept in a hidden folder beside the notes, one JSON file per note.
public struct NoteSidecar: Codable, Equatable {
    public struct StoredHighlight: Codable, Equatable {
        public var location: Int
        public var length: Int
        /// The highlighted text, to re-anchor it if the file was edited elsewhere.
        public var quote: String
        public var color: HighlightColor
        public var note: String?
        public var author: Author
    }

    public var highlights: [StoredHighlight] = []
    public var chat: [ChatMessage] = []

    public init(highlights: [StoredHighlight] = [], chat: [ChatMessage] = []) {
        self.highlights = highlights
        self.chat = chat
    }

    public init(spans: [HighlightSpan], in text: String, chat: [ChatMessage]) {
        let ns = text as NSString
        highlights = spans.compactMap { s in
            guard NSMaxRange(s.range) <= ns.length else { return nil }
            return StoredHighlight(location: s.range.location, length: s.range.length, quote: ns.substring(with: s.range), color: s.color, note: s.note, author: s.author)
        }
        self.chat = chat
    }

    public var isEmpty: Bool { highlights.isEmpty && chat.isEmpty }

    /// Highlights resolved against the note's current text. One whose text
    /// has moved is found again by its quote; one whose text is gone is dropped.
    public func spans(in text: String) -> [HighlightSpan] {
        let ns = text as NSString
        return highlights.compactMap { h in
            var range = NSRange(location: h.location, length: h.length)
            if NSMaxRange(range) > ns.length || ns.substring(with: range) != h.quote {
                range = ns.range(of: h.quote)
                guard range.location != NSNotFound, !h.quote.isEmpty else { return nil }
            }
            return HighlightSpan(range: range, color: h.color, note: h.note, author: h.author)
        }
    }

    public static func url(for note: URL) -> URL {
        note.deletingLastPathComponent()
            .appendingPathComponent(".transcriptaze", isDirectory: true)
            .appendingPathComponent(note.deletingPathExtension().lastPathComponent + ".json")
    }

    public static func load(for note: URL) -> NoteSidecar {
        guard let data = try? Data(contentsOf: url(for: note)),
              let sidecar = try? decoder.decode(NoteSidecar.self, from: data) else { return NoteSidecar() }
        return sidecar
    }

    public func save(for note: URL) {
        let target = Self.url(for: note)
        if isEmpty {
            try? FileManager.default.removeItem(at: target)
            return
        }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(self) { try? data.write(to: target, options: .atomic) }
    }

    /// Follows a note that was renamed.
    public static func move(from old: URL, to new: URL) {
        let source = url(for: old), target = url(for: new)
        guard source != target, FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: source, to: target)
    }

    /// Follows a note to the Trash.
    public static func trash(for note: URL) {
        let source = url(for: note)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder = JSONDecoder()
}
