import XCTest
@testable import ScriptoriumCore

/// An in-memory document standing in for the editor.
@MainActor
final class FakeHost: DocumentHost, NoteLibrary {
    var noteTitle = "Test"
    var text: String
    var revision = 0
    var userCursor: Int
    var isDictating = true
    var fresh: [(range: NSRange, batch: Int)] = []
    var freshRanges: [(range: NSRange, batch: Int)] { fresh }
    var edits: [String] = []
    var focus: NSRange?
    var ghostRange: NSRange?
    var highlights: [HighlightSpan] = []

    init(text: String, freshFrom: Int? = nil) {
        self.text = text
        self.userCursor = (text as NSString).length
        if let freshFrom { fresh = [(NSRange(location: freshFrom, length: (text as NSString).length - freshFrom), 1)] }
    }

    func applyGuardianEdit(_ edit: TextEdit, summary: String) {
        text = edit.applied(to: text)
        userCursor = edit.transform(userCursor)
        fresh = fresh.map { (NSRange(location: edit.transform($0.range.location), length: max(0, edit.transform(NSMaxRange($0.range)) - edit.transform($0.range.location))), $0.batch) }
        // As in the editor: an edit inside a highlight dismisses it.
        highlights.removeAll { NSIntersectionRange($0.range, edit.range).length > 0 || (edit.range.length == 0 && edit.range.location > $0.range.location && edit.range.location < NSMaxRange($0.range)) }
        highlights = highlights.map { var h = $0; let s = edit.transform(h.range.location); h.range = NSRange(location: s, length: edit.transform(NSMaxRange(h.range)) - s); return h }
        revision += 1
        edits.append(summary)
    }
    func setUserCursor(_ offset: Int) { userCursor = offset }
    var scrolledTo: Int?
    func scrollTo(_ offset: Int) { scrolledTo = offset }
    func setGuardianFocus(_ range: NSRange?, label: String?) { focus = range }
    func markReviewed(through batch: Int) { fresh.removeAll { $0.batch <= batch } }
    func addHighlight(_ range: NSRange, color: HighlightColor, note: String?, author: Author) {
        highlights.append(HighlightSpan(range: range, color: color, note: note, author: author))
    }
    func removeHighlights(overlapping range: NSRange?) {
        highlights.removeAll { h in range.map { NSIntersectionRange(h.range, $0).length > 0 } ?? true }
    }
    func listNotes() -> [(title: String, modified: Date, preview: String)] { [("Characters", Date(), "Fleur is the heroine.")] }
    func readNote(titled title: String) -> String? { title == "Characters" ? "Fleur is the heroine." : nil }
}

@MainActor
final class MCPTests: XCTestCase {
    func testRenderMarksFreshSentencesAndCursor() async throws {
        let text = "The river is wide. The flow is gentle."
        let host = FakeHost(text: text, freshFrom: 19)
        let box = GuardianToolbox(host: host, library: host)
        let view = box.render()
        XCTAssertTrue(view.contains("¶1 [1] The river is wide. [2]• The flow is gentle."), view)
        XCTAssertTrue(view.contains("review_token: 1"))
        XCTAssertTrue(view.contains("User's cursor: ¶1 [2], end of paragraph — dictating now"), view)
    }

    func testSpokenEditCommandScenario() async throws {
        // What the guardian does for "go to paragraph 1, sentence 2 and change flow for fleur".
        let text = "The river is wide. The flow is gentle.\nMore text. Go to paragraph one, sentence two and change flow for fleur."
        let host = FakeHost(text: text, freshFrom: 50)
        let box = GuardianToolbox(host: host, library: host)
        _ = try await box.call("replace_text", arguments: ["paragraph": 1, "sentence": 2, "find": "flow", "replace": "fleur"])
        let result = try await box.call("delete_text", arguments: ["paragraph": 2, "find": "Go to paragraph one, sentence two and change flow for fleur."])
        XCTAssertEqual(host.text, "The river is wide. The fleur is gentle.\nMore text.")
        XCTAssertTrue(result.contains("¶2 [1] More text."))
        _ = try await box.call("finish_review", arguments: ["review_token": 1])
        XCTAssertTrue(host.fresh.isEmpty)
    }

    func testHandlerSpeaksJSONRPC() async throws {
        let host = FakeHost(text: "Hello world.")
        let handler = MCPHandler(toolbox: GuardianToolbox(host: host, library: host))
        let initReply = await handler.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8))
        let initJSON = try JSONSerialization.jsonObject(with: initReply!) as! [String: Any]
        XCTAssertEqual((initJSON["result"] as! [String: Any])["protocolVersion"] as? String, "2025-06-18")
        let notification = await handler.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNil(notification)

        let list = try JSONSerialization.jsonObject(with: await handler.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))!) as! [String: Any]
        let names = ((list["result"] as! [String: Any])["tools"] as! [[String: Any]]).map { $0["name"] as! String }
        XCTAssertTrue(names.contains("split_paragraph"))

        let bad = try JSONSerialization.jsonObject(with: await handler.handle(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"replace_text","arguments":{"paragraph":4,"find":"x","replace":"y"}}}"#.utf8))!) as! [String: Any]
        XCTAssertEqual((bad["result"] as! [String: Any])["isError"] as? Bool, true)
    }

    func testOverHTTPWithClient() async throws {
        let host = FakeHost(text: "We met at the old mill. New paragraph. the rain came.", freshFrom: 24)
        let handler = MCPHandler(toolbox: GuardianToolbox(host: host, library: host))
        let port = UInt16.random(in: 40000...49000)
        let server = MCPHTTPServer(handler: handler, port: port)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let client = MCPClient(endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.count, GuardianToolbox.specs.count)
        let doc = try await client.callTool("wait_for_dictation", arguments: ["timeout_seconds": 1])
        XCTAssertTrue(doc.text.contains("[2]• New paragraph."), doc.text)
        let split = try await client.callTool("split_paragraph", arguments: ["paragraph": 1, "at": "New paragraph.", "remove_matched": true])
        XCTAssertFalse(split.isError, split.text)
        XCTAssertEqual(host.text, "We met at the old mill.\nThe rain came.")
        let notes = try await client.callTool("read_note", arguments: ["title": "Characters"])
        XCTAssertEqual(notes.text, "Fleur is the heroine.")
    }

    func testConnectionCardCarriesEverythingNeededToConnect() {
        let card = ConnectionCard.text(endpoint: URL(string: "http://127.0.0.1:7337/mcp")!, bridgePath: "/Apps/T.app/Contents/MacOS/scriptorium-mcp")
        XCTAssertTrue(card.contains("claude mcp add --transport http scriptorium http://127.0.0.1:7337/mcp"))
        XCTAssertTrue(card.contains(#""url": "http://127.0.0.1:7337/mcp""#))
        XCTAssertTrue(card.contains(#""command": "/Apps/T.app/Contents/MacOS/scriptorium-mcp""#))
        for tool in ["wait_for_dictation", "finish_review"] {
            XCTAssertTrue(GuardianToolbox.specs.contains { $0.name == tool })
            XCTAssertTrue(card.contains(tool))
        }
    }

    func testDisconnectRefusesToolsAndReleasesAWaitingGuardian() async throws {
        let host = FakeHost(text: "Hello there.")
        let box = GuardianToolbox(host: host, library: host)
        let started = Date()
        let waiting = Task { try await box.call("wait_for_dictation", arguments: ["timeout_seconds": 30]) }
        try await Task.sleep(nanoseconds: 400_000_000)
        box.isConnected = false
        do {
            _ = try await waiting.value
            XCTFail("a waiting guardian should be released with an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disconnected"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        do {
            _ = try await box.call("replace_text", arguments: ["paragraph": 1, "find": "Hello", "replace": "Bye"])
            XCTFail("edits must be refused while disconnected")
        } catch {}
        XCTAssertEqual(host.text, "Hello there.")
        box.isConnected = true
        _ = try await box.call("replace_text", arguments: ["paragraph": 1, "find": "Hello", "replace": "Bye"])
        XCTAssertEqual(host.text, "Bye there.")
    }

    func testChatWakesTheGuardianAndCarriesWhereTheUserPoints() async throws {
        let text = "The war ended in 1946. Everyone went home."
        let host = FakeHost(text: text)
        let chat = ChatLog()
        let box = GuardianToolbox(host: host, library: host, chat: chat)
        host.ghostRange = (text as NSString).range(of: "1946")
        let started = Date()
        let waiting = Task { try await box.call("wait_for_dictation", arguments: ["timeout_seconds": 20]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let pointer = GuardianToolbox.pointer(at: host.ghostRange!, in: text)!
        XCTAssertEqual(pointer.anchor, "¶1 [1]")
        chat.post(ChatMessage(role: .user, text: "Is this right?", anchor: pointer.anchor, quote: pointer.quote))
        let view = try await waiting.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "a chat message must end the wait")
        XCTAssertTrue(view.contains("CHAT — the user is talking to you"), view)
        XCTAssertTrue(view.contains("[pointing at ¶1 [1] “1946”] Is this right?"), view)
        XCTAssertTrue(view.contains("ghost cursor on the page is at ¶1 [1] selecting “1946”"), view)
        XCTAssertTrue(chat.undelivered.isEmpty)
        // Delivered once only.
        XCTAssertFalse(box.render(deliver: true).contains("CHAT —"))

        _ = try await box.call("reply_in_chat", arguments: ["text": "No: it ended in 1945."])
        XCTAssertEqual(chat.messages.last?.role, .guardian)
        let history = try await box.call("read_chat", arguments: [:])
        XCTAssertTrue(history.contains("You: No: it ended in 1945."), history)
    }

    func testLiveChatStreamsWithoutSending() async throws {
        let host = FakeHost(text: "The war ended in 1946.")
        let chat = ChatLog()
        let box = GuardianToolbox(host: host, library: host, chat: chat)
        ChatLog.settle = 0.3
        defer { ChatLog.settle = 1.2 }
        chat.live = "Is this"
        XCTAssertFalse(chat.hasNews, "words still arriving do not wake the guardian")
        let waiting = Task { try await box.call("wait_for_dictation", arguments: ["timeout_seconds": 10]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        chat.live = "Is this right?"
        let view = try await waiting.value
        XCTAssertTrue(view.contains("still open"), view)
        XCTAssertTrue(view.contains("“Is this right?”"), view)
        XCTAssertFalse(chat.hasNews, "read once")

        chat.live = "Is this right? And the second sentence"
        try await Task.sleep(nanoseconds: 400_000_000)
        let more = try await box.call("wait_for_dictation", arguments: ["timeout_seconds": 2])
        XCTAssertTrue(more.contains("New since you last looked: “And the second sentence”"), more)

        chat.live += " "   // a trailing space after reading is not news
        // The answer closes the open message into the history.
        _ = try await box.call("reply_in_chat", arguments: ["text": "It ended in 1945."])
        XCTAssertEqual(chat.live, "")
        XCTAssertEqual(chat.messages.map(\.role), [.user, .guardian])
        XCTAssertEqual(chat.messages.first?.text, "Is this right? And the second sentence")
        XCTAssertEqual(chat.messages.first?.delivered, true)
    }

    func testVoiceOnly_SpokenQuestionAndScroll() async throws {
        let text = "One.\nTwo.\nThree is here. Guardian, is this right?"
        let host = FakeHost(text: text)
        let chat = ChatLog()
        let box = GuardianToolbox(host: host, library: host, chat: chat)
        _ = try await box.call("scroll_to", arguments: ["paragraph": 2])
        XCTAssertEqual(host.scrolledTo, 5)
        XCTAssertEqual(host.userCursor, (text as NSString).length, "scrolling leaves the cursor alone")
        _ = try await box.call("delete_text", arguments: ["paragraph": 3, "find": "Guardian, is this right?"])
        _ = try await box.call("reply_in_chat", arguments: ["text": "Yes.", "heard": "Is this right?"])
        XCTAssertEqual(chat.messages.map(\.role), [.user, .guardian])
        XCTAssertEqual(chat.messages.first?.spoken, true)
        XCTAssertTrue(chat.undelivered.isEmpty, "a spoken question was already heard")
        XCTAssertEqual(host.text, "One.\nTwo.\nThree is here.")
    }

    func testGhostCaretQuotesTheWordsAroundIt() {
        let text = "First paragraph.\nThe flow is gentle and the river is wide."
        let caret = (text as NSString).range(of: " gentle").location
        let p = GuardianToolbox.pointer(at: NSRange(location: caret, length: 0), in: text)!
        XCTAssertEqual(p.anchor, "¶2 [1]")
        XCTAssertEqual(p.quote, "The flow is‸ gentle and the river is wide.")
    }

    func testHighlightsForFactChecking() async throws {
        let text = "The war ended in 1946. Paris is in France."
        let host = FakeHost(text: text)
        let box = GuardianToolbox(host: host, library: host)
        _ = try await box.call("highlight_text", arguments: ["paragraph": 1, "find": "ended in 1946", "color": "pink", "note": "It ended in 1945."])
        _ = try await box.call("highlight_text", arguments: ["paragraph": 1, "sentence": 2, "find": "Paris is in France", "color": "green"])
        host.highlights.append(HighlightSpan(range: (text as NSString).range(of: "war"), color: .yellow, note: nil, author: .user))
        let view = box.render()
        XCTAssertTrue(view.contains("- ¶1 [1] pink “ended in 1946” (by you) — It ended in 1945."), view)
        XCTAssertTrue(view.contains("- ¶1 [2] green “Paris is in France” (by you)"), view)
        XCTAssertTrue(view.contains("- ¶1 [1] yellow “war” (by the user)"), view)
        do {
            _ = try await box.call("highlight_text", arguments: ["paragraph": 1, "find": "war", "color": "blue"])
            XCTFail("only three inks")
        } catch {}

        // Correcting the fact dismisses its highlight; the others stay.
        _ = try await box.call("replace_text", arguments: ["paragraph": 1, "find": "1946", "replace": "1945"])
        XCTAssertEqual(host.highlights.map(\.color), [.green, .yellow])
        _ = try await box.call("clear_highlights", arguments: ["paragraph": 1, "find": "France"])
        XCTAssertEqual(host.highlights.map(\.color), [.yellow])
        _ = try await box.call("clear_highlights", arguments: [:])
        XCTAssertTrue(host.highlights.isEmpty)
    }

    func testSidecarReanchorsHighlightsAndKeepsChat() throws {
        let text = "Alpha beta gamma."
        let spans = [HighlightSpan(range: NSRange(location: 6, length: 4), color: .pink, note: "n", author: .guardian)]
        let sidecar = NoteSidecar(spans: spans, in: text, chat: [ChatMessage(role: .user, text: "hi")])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let note = dir.appendingPathComponent("A.md")
        sidecar.save(for: note)
        let loaded = NoteSidecar.load(for: note)
        XCTAssertEqual(loaded, sidecar)
        // The file gained words in front: the highlight follows its text.
        let moved = loaded.spans(in: "Oh. Alpha beta gamma.")
        XCTAssertEqual(moved.first?.range, NSRange(location: 10, length: 4))
        XCTAssertTrue(loaded.spans(in: "Nothing here.").isEmpty)
        NoteSidecar.move(from: note, to: dir.appendingPathComponent("B.md"))
        XCTAssertEqual(NoteSidecar.load(for: dir.appendingPathComponent("B.md")).chat.first?.text, "hi")
    }

    func testInitializeCarriesGuardianInstructions() async throws {
        let host = FakeHost(text: "")
        let handler = MCPHandler(toolbox: GuardianToolbox(host: host, library: host))
        let reply = await handler.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8))!
        let result = (try JSONSerialization.jsonObject(with: reply) as! [String: Any])["result"] as! [String: Any]
        let instructions = result["instructions"] as! String
        XCTAssertTrue(instructions.contains("wait_for_dictation"))
        XCTAssertTrue(instructions.contains("finish_review"))
        XCTAssertTrue(instructions.contains("outside this app"))
        XCTAssertTrue(instructions.contains("reply_in_chat"))
        XCTAssertTrue(instructions.contains("ghost cursor"))
        XCTAssertTrue(instructions.contains("pink = false"))
    }
}

final class NoteStoreTests: XCTestCase {
    func testSaveRenamesToTitleAndLists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(folder: dir)
        let url = try store.create()
        let saved = try store.save(editorText: "# A Walk: in Spring\nIt was warm.", to: url)
        XCTAssertEqual(saved.lastPathComponent, "A Walk in Spring.md")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "# A Walk: in Spring\n\nIt was warm.\n")
        let notes = store.list()
        XCTAssertEqual(notes.first?.title, "A Walk: in Spring")
        XCTAssertEqual(notes.first?.preview, "It was warm.")
        XCTAssertEqual(try store.load(saved), "# A Walk: in Spring\nIt was warm.")
    }
}
