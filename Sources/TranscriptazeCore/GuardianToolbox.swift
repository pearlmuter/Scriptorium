import Foundation

/// The open note, as the guardian sees it. Implemented by the editor.
@MainActor
public protocol DocumentHost: AnyObject {
    var noteTitle: String { get }
    var text: String { get }
    /// Increments on every change, from anyone.
    var revision: Int { get }
    /// The user's caret — where dictation lands.
    var userCursor: Int { get }
    var isDictating: Bool { get }
    /// Dictated text the guardian has not reviewed yet, tagged by batch.
    var freshRanges: [(range: NSRange, batch: Int)] { get }
    /// Applies a guardian edit, keeping the user's caret where it belongs.
    func applyGuardianEdit(_ edit: TextEdit, summary: String)
    func setUserCursor(_ offset: Int)
    /// Shows where the guardian is looking; nil hides its cursor.
    func setGuardianFocus(_ range: NSRange?, label: String?)
    /// Marks dictation up to and including `batch` as reviewed.
    func markReviewed(through batch: Int)
}

/// Other notes, for context.
@MainActor
public protocol NoteLibrary: AnyObject {
    func listNotes() -> [(title: String, modified: Date, preview: String)]
    func readNote(titled title: String) -> String?
}

public struct ToolSpec {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
}

/// The guardian's tools, served over MCP to whichever LLM the user connects.
@MainActor
public final class GuardianToolbox {
    public weak var host: DocumentHost?
    public weak var library: NoteLibrary?

    /// False when the user has disconnected the guardian: every tool is refused,
    /// and a waiting wait_for_dictation returns at once, so the LLM's loop ends.
    public var isConnected = true

    public static let disconnectedMessage = "The user has disconnected the guardian. Stop your loop now and make no further calls to this server. Tell the user you have stopped; they can reconnect you from Transcriptaze when they want you back."

    public init(host: DocumentHost? = nil, library: NoteLibrary? = nil) {
        self.host = host
        self.library = library
    }

    // MARK: Catalogue

    private static func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    private static let p: [String: Any] = ["type": "integer", "description": "Paragraph number (¶) as shown by read_document."]
    private static let s: [String: Any] = ["type": "integer", "description": "Sentence number within the paragraph. Optional; narrows the search."]
    private static let occ: [String: Any] = ["type": "integer", "description": "Which match to use when the text occurs more than once (1-based)."]
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }

    public static let specs: [ToolSpec] = [
        ToolSpec(name: "read_document",
                 description: "Read the open note with chapter-and-verse numbering: each paragraph as ¶n, each sentence as [n]. Sentences containing freshly dictated text you have not reviewed are marked •. Also reports where the user's cursor is and a review_token.",
                 inputSchema: schema([:])),
        ToolSpec(name: "replace_text",
                 description: "Replace an exact quote in a paragraph (optionally within one sentence). Quote just enough words to be unique. Use for transcription fixes and spoken edit commands like 'change flow to fleur'.",
                 inputSchema: schema(["paragraph": p, "sentence": s, "find": str("Exact text currently in the note."), "replace": str("Replacement text."), "occurrence": occ], required: ["paragraph", "find", "replace"])),
        ToolSpec(name: "rewrite_sentence",
                 description: "Replace one whole sentence. Prefer replace_text for small fixes.",
                 inputSchema: schema(["paragraph": p, "sentence": ["type": "integer", "description": "Sentence number."], "text": str("The complete new sentence.")], required: ["paragraph", "sentence", "text"])),
        ToolSpec(name: "delete_text",
                 description: "Delete an exact quote, e.g. spoken command words that were transcribed into the note. Neighbouring spaces are tidied.",
                 inputSchema: schema(["paragraph": p, "sentence": s, "find": str("Exact text to delete."), "occurrence": occ], required: ["paragraph", "find"])),
        ToolSpec(name: "split_paragraph",
                 description: "Start a new paragraph at a quote. With remove_matched=true the quoted words are deleted, which is how to carry out a spoken 'new paragraph': quote the command words (e.g. 'new paragraph') and the text after them starts the next paragraph, capitalised.",
                 inputSchema: schema(["paragraph": p, "at": str("Exact text where the new paragraph begins (or the command words to remove)."), "remove_matched": ["type": "boolean", "description": "Delete the quoted text itself."], "occurrence": occ], required: ["paragraph", "at", "remove_matched"])),
        ToolSpec(name: "merge_paragraphs",
                 description: "Join paragraph n with paragraph n+1.",
                 inputSchema: schema(["paragraph": p], required: ["paragraph"])),
        ToolSpec(name: "insert_text",
                 description: "Insert words into a paragraph after (or before) a quoted anchor, or at the paragraph's end if no anchor is given.",
                 inputSchema: schema(["paragraph": p, "text": str("Text to insert."), "after": str("Insert after this exact text."), "before": str("Insert before this exact text.")], required: ["paragraph", "text"])),
        ToolSpec(name: "insert_paragraph",
                 description: "Insert a new paragraph after paragraph n (0 inserts at the top).",
                 inputSchema: schema(["after_paragraph": ["type": "integer"], "text": str("The new paragraph's text.")], required: ["after_paragraph", "text"])),
        ToolSpec(name: "delete_paragraph",
                 description: "Delete a whole paragraph.",
                 inputSchema: schema(["paragraph": p], required: ["paragraph"])),
        ToolSpec(name: "format_text",
                 description: "Apply markdown formatting. Inline styles (bold, italic, code, strike) wrap the quoted text, or the whole paragraph if no quote. Block styles (heading1-3, quote, bullet, numbered, plain) change the paragraph's kind.",
                 inputSchema: schema(["paragraph": p, "style": ["type": "string", "enum": TextOperations.Style.allCases.map(\.rawValue)], "find": str("Text to style (inline styles only)."), "occurrence": occ], required: ["paragraph", "style"])),
        ToolSpec(name: "move_user_cursor",
                 description: "Move the user's dictation cursor, when they say e.g. 'go to the end of paragraph 3' and intend to keep dictating there. Do not move it merely to make an edit.",
                 inputSchema: schema(["paragraph": p, "sentence": s, "position": ["type": "string", "enum": ["start", "end"]]], required: ["paragraph"])),
        ToolSpec(name: "focus",
                 description: "Move your own (guardian) cursor to show the user where you are looking.",
                 inputSchema: schema(["paragraph": p, "sentence": s], required: ["paragraph"])),
        ToolSpec(name: "list_notes",
                 description: "List the user's other notes (titles and previews), for context such as names and terminology.",
                 inputSchema: schema(["query": str("Optional filter on title or content.")])),
        ToolSpec(name: "read_note",
                 description: "Read another note in full, by title.",
                 inputSchema: schema(["title": str("Title as given by list_notes.")], required: ["title"])),
        ToolSpec(name: "wait_for_dictation",
                 description: "For external guardians: block until there is freshly dictated text you have not reviewed (or the timeout passes), then return the document as read_document would.",
                 inputSchema: schema(["timeout_seconds": ["type": "number", "description": "At most 50."]])),
        ToolSpec(name: "finish_review",
                 description: "Mark fresh dictation as reviewed, up to the review_token from read_document. Call after you have made your edits.",
                 inputSchema: schema(["review_token": ["type": "integer"]], required: ["review_token"])),
    ]

    // MARK: Dispatch

    public func call(_ name: String, arguments args: [String: Any]) async throws -> String {
        guard isConnected else { throw OperationError(Self.disconnectedMessage) }
        if name == "wait_for_dictation" { return try await waitForDictation(args) }
        if name == "list_notes" { return listNotes(args) }
        if name == "read_note" { return try readNote(args) }
        guard let host else { throw OperationError("No note is open.") }
        let text = host.text

        func int(_ key: String) throws -> Int {
            if let v = args[key] as? Int { return v }
            if let v = args[key] as? Double { return Int(v) }
            if let v = args[key] as? String, let i = Int(v.trimmingCharacters(in: CharacterSet(charactersIn: "¶ "))) { return i }
            throw OperationError("Missing integer argument '\(key)'.")
        }
        func optInt(_ key: String) -> Int? { args[key] == nil || args[key] is NSNull ? nil : try? int(key) }
        func string(_ key: String) throws -> String {
            guard let v = args[key] as? String else { throw OperationError("Missing string argument '\(key)'.") }
            return v
        }
        func optString(_ key: String) -> String? { args[key] as? String }

        let edit: TextEdit
        let summary: String
        var paragraphShown: Int?
        switch name {
        case "read_document":
            return render()
        case "replace_text":
            let (pn, find, rep) = (try int("paragraph"), try string("find"), try string("replace"))
            edit = try TextOperations.replace(find, with: rep, paragraph: pn, sentence: optInt("sentence"), occurrence: optInt("occurrence"), in: text)
            summary = "“\(find)” → “\(rep)”"; paragraphShown = pn
        case "rewrite_sentence":
            let (pn, sn) = (try int("paragraph"), try int("sentence"))
            edit = try TextOperations.rewriteSentence(paragraph: pn, sentence: sn, text: try string("text"), in: text)
            summary = "rewrote ¶\(pn) s\(sn)"; paragraphShown = pn
        case "delete_text":
            let (pn, find) = (try int("paragraph"), try string("find"))
            edit = try TextOperations.delete(find, paragraph: pn, sentence: optInt("sentence"), occurrence: optInt("occurrence"), in: text)
            summary = "deleted “\(find)”"; paragraphShown = pn
        case "split_paragraph":
            let pn = try int("paragraph")
            let remove = (args["remove_matched"] as? Bool) ?? false
            edit = try TextOperations.splitParagraph(paragraph: pn, at: try string("at"), removeMatched: remove, occurrence: optInt("occurrence"), in: text)
            summary = "new paragraph after ¶\(pn)"; paragraphShown = pn
        case "merge_paragraphs":
            let pn = try int("paragraph")
            edit = try TextOperations.mergeParagraphs(pn, in: text)
            summary = "joined ¶\(pn) and ¶\(pn + 1)"; paragraphShown = pn
        case "insert_text":
            let pn = try int("paragraph")
            edit = try TextOperations.insert(try string("text"), paragraph: pn, after: optString("after"), before: optString("before"), in: text)
            summary = "inserted in ¶\(pn)"; paragraphShown = pn
        case "insert_paragraph":
            let after = try int("after_paragraph")
            edit = try TextOperations.insertParagraph(after: after, text: try string("text"), in: text)
            summary = "new ¶\(after + 1)"; paragraphShown = after + 1
        case "delete_paragraph":
            let pn = try int("paragraph")
            edit = try TextOperations.deleteParagraph(pn, in: text)
            summary = "deleted ¶\(pn)"
        case "format_text":
            let pn = try int("paragraph")
            guard let style = TextOperations.Style(rawValue: try string("style")) else { throw OperationError("Unknown style.") }
            edit = try TextOperations.format(style, paragraph: pn, find: optString("find"), occurrence: optInt("occurrence"), in: text)
            summary = "\(style.rawValue) in ¶\(pn)"; paragraphShown = pn
        case "move_user_cursor":
            let pn = try int("paragraph")
            let offset = try TextOperations.offset(paragraph: pn, sentence: optInt("sentence"), atEnd: optString("position") != "start", in: text)
            host.setUserCursor(offset)
            return "The user's cursor is now at the \(optString("position") ?? "end") of ¶\(pn)\(optInt("sentence").map { " sentence \($0)" } ?? "")."
        case "focus":
            let pn = try int("paragraph")
            let (block, range) = try TextOperations.scope(paragraph: pn, sentence: optInt("sentence"), in: Outline(text: text))
            host.setGuardianFocus(range, label: "¶\(pn)")
            _ = block
            return "Looking at ¶\(pn)."
        case "finish_review":
            host.markReviewed(through: try int("review_token"))
            host.setGuardianFocus(nil, label: nil)
            return "Reviewed."
        default:
            throw OperationError("Unknown tool \(name).")
        }

        host.applyGuardianEdit(edit, summary: summary)
        let after = host.text
        if let paragraphShown, let line = renderParagraph(paragraphShown, in: after) {
            return "Done. Now:\n" + line
        }
        return "Done."
    }

    // MARK: Reading

    /// The numbered view the guardian reasons over.
    public func render() -> String {
        guard let host else { return "No note is open." }
        let text = host.text
        let outline = Outline(text: text)
        let ns = text as NSString
        let fresh = host.freshRanges
        let token = fresh.map(\.batch).max() ?? 0
        var lines: [String] = []
        lines.append("Note: \"\(host.noteTitle)\"   paragraphs: \(outline.paragraphs.count)   review_token: \(token)")
        if let addr = outline.address(of: host.userCursor) {
            let block = outline.block(at: host.userCursor)
            let atEnd = block.map { host.userCursor >= NSMaxRange($0.range) } ?? false
            lines.append("User's cursor: ¶\(addr.paragraph)\(addr.sentence.map { " [\($0)]" } ?? "")\(atEnd ? ", end of paragraph" : "")\(host.isDictating ? " — dictating now" : "")")
        } else {
            lines.append("User's cursor: outside numbered text\(host.isDictating ? " — dictating now" : "")")
        }
        lines.append("")
        for block in outline.blocks {
            switch block.kind {
            case .blank: continue
            case .heading(let level):
                lines.append("H\(level) " + ns.substring(with: block.range))
            case .code:
                lines.append("    | " + ns.substring(with: block.range))
            case .rule:
                lines.append("---")
            default:
                lines.append(renderBlock(block, ns: ns, fresh: fresh.map(\.range)))
            }
        }
        if outline.paragraphs.isEmpty { lines.append("(empty note)") }
        return lines.joined(separator: "\n")
    }

    private func renderBlock(_ block: Outline.Block, ns: NSString, fresh: [NSRange]) -> String {
        guard let number = block.number else { return "" }
        var out = "¶\(number)"
        let prefix = ns.substring(with: NSRange(location: block.range.location, length: block.contentRange.location - block.range.location))
        if !prefix.isEmpty { out += " (\(prefix.trimmingCharacters(in: .whitespaces)))" }
        if block.sentences.isEmpty { return out + " (empty)" }
        for s in block.sentences {
            let isFresh = fresh.contains { NSIntersectionRange($0, s.range).length > 0 }
            out += " [\(s.number)]\(isFresh ? "•" : "") " + ns.substring(with: s.range)
        }
        return out
    }

    private func renderParagraph(_ number: Int, in text: String) -> String? {
        let outline = Outline(text: text)
        guard let block = outline.paragraph(number) else { return nil }
        var line = renderBlock(block, ns: text as NSString, fresh: host?.freshRanges.map(\.range) ?? [])
        if let next = outline.paragraph(number + 1) {
            line += "\n" + renderBlock(next, ns: text as NSString, fresh: host?.freshRanges.map(\.range) ?? [])
        }
        return line
    }

    private func waitForDictation(_ args: [String: Any]) async throws -> String {
        let timeout = min(50, (args["timeout_seconds"] as? Double) ?? Double(args["timeout_seconds"] as? Int ?? 25))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isConnected else { throw OperationError(Self.disconnectedMessage) }
            if let host, !host.freshRanges.isEmpty { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return render()
    }

    private func listNotes(_ args: [String: Any]) -> String {
        guard let library else { return "No library." }
        let query = (args["query"] as? String)?.lowercased() ?? ""
        let notes = library.listNotes().filter { query.isEmpty || $0.title.lowercased().contains(query) || $0.preview.lowercased().contains(query) }
        if notes.isEmpty { return "No notes match." }
        let f = ISO8601DateFormatter()
        return notes.prefix(60).map { "- \($0.title)  (\(f.string(from: $0.modified)))  \($0.preview.prefix(140))" }.joined(separator: "\n")
    }

    private func readNote(_ args: [String: Any]) throws -> String {
        guard let title = args["title"] as? String else { throw OperationError("Missing 'title'.") }
        guard let body = library?.readNote(titled: title) else { throw OperationError("No note titled \"\(title)\". Use list_notes.") }
        return String(body.prefix(20_000))
    }
}
