import Foundation
import TranscriptazeCore

/// What the connected guardian is doing, as seen from the MCP server. The app
/// runs no model of its own: the guardian is whichever LLM the user connects,
/// and this only watches its tool calls.
@MainActor
final class GuardianActivity: ObservableObject {
    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
        let isError: Bool
    }

    enum Status: Equatable {
        /// Nothing has called the server recently.
        case absent
        /// A client is connected (it has called within the last couple of minutes).
        case connected
        /// It has fresh text in hand and has not yet finished its review.
        case working
        /// The user has unhooked it; all calls are refused.
        case disconnected
    }

    @Published private(set) var status: Status = .absent
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var lastAction = ""
    weak var editor: EditorController?

    private var lastSeen: Date?
    private var heartbeat: Timer?

    /// wait_for_dictation holds a call for up to 50 s, so a looping guardian
    /// shows up at least that often.
    static let presenceWindow: TimeInterval = 120

    init() {
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPresence() }
        }
    }

    /// Fed by the MCP handler on every tool call.
    func observe(tool name: String, arguments: [String: Any], result: Result<String, Error>) {
        // Refused calls after a disconnect are expected, not news.
        guard status != .disconnected else { return }
        lastSeen = Date()
        switch result {
        case .failure(let error):
            append("\(name): \(error.localizedDescription)", isError: true)
        case .success(let text):
            switch name {
            case "wait_for_dictation", "read_document":
                // A document with unreviewed sentences in it means work has begun.
                if text.contains("•") || text.contains("CHAT —") { setStatus(.working) } else if status == .absent { setStatus(.connected) }
            case "finish_review":
                setStatus(.connected)
            case "list_notes", "read_note", "focus", "read_chat", "reply_in_chat":
                if status == .absent { setStatus(.connected) }
            default:
                setStatus(.working)
                let summary = Self.describe(name, arguments)
                lastAction = summary
                append(summary, isError: false)
            }
        }
    }

    func disconnected() {
        setStatus(.disconnected)
        lastAction = ""
        append("Disconnected by you", isError: false)
    }

    func allowed() {
        lastSeen = nil
        setStatus(.absent)
        append("Guardian access allowed", isError: false)
    }

    private func setStatus(_ s: Status) {
        if status != s { status = s }
        editor?.guardianActive = s == .working
    }

    private func refreshPresence() {
        guard status != .disconnected, let lastSeen else { return }
        if Date().timeIntervalSince(lastSeen) > Self.presenceWindow { setStatus(.absent) }
    }

    func append(_ text: String, isError: Bool) {
        log.append(LogEntry(text: text, isError: isError))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// Tools that change the note (or its highlights).
    static func isEdit(_ name: String) -> Bool {
        !["wait_for_dictation", "read_document", "finish_review", "list_notes", "read_note", "focus", "read_chat", "reply_in_chat"].contains(name)
    }

    static func describe(_ name: String, _ a: [String: Any]) -> String {
        let p = a["paragraph"].map { "¶\($0) " } ?? ""
        switch name {
        case "replace_text": return "\(p)“\(a["find"] ?? "")” → “\(a["replace"] ?? "")”"
        case "delete_text": return "\(p)removed “\(a["find"] ?? "")”"
        case "split_paragraph": return "\(p)new paragraph"
        case "merge_paragraphs": return "\(p)joined with next"
        case "format_text": return "\(p)\(a["style"] ?? "")"
        case "rewrite_sentence": return "\(p)rewrote sentence \(a["sentence"] ?? "")"
        case "move_user_cursor": return "moved your cursor to \(p)"
        case "highlight_text": return "\(p)highlighted “\(a["find"] ?? "")” \(a["color"] ?? "")"
        case "clear_highlights": return "\(p)cleared highlights"
        default: return "\(name.replacingOccurrences(of: "_", with: " ")) \(p)"
        }
    }
}
