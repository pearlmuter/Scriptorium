import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ScriptoriumCore

/// Everything the window shows: the notes, the open one, the microphone, the
/// guardian and the MCP server they meet through.
@MainActor
final class AppModel: ObservableObject, NoteLibrary {
    static let mcpPort: UInt16 = 7337

    @Published var notes: [NoteFile] = []
    @Published var selection: URL?
    @Published var search = ""
    @Published var typesetting: Typesetting { didSet { editor.typesetting = typesetting; typesetting.save() } }
    @Published var mcpStatus = "starting"
    @Published var focusMode = false
    @Published var chromeVisible = true
    @Published var showGuardianPanel = false
    /// Whether an LLM may act as guardian. Turning it off unhooks whichever one is connected.
    @Published private(set) var guardianAllowed = true
    @Published private(set) var wordCount = 0
    @Published private(set) var caretAddress = ""
    @Published var showChat = UserDefaults.standard.object(forKey: "showChat") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showChat, forKey: "showChat") }
    }
    /// The user is typing (or dictating) in the chat; their caret is a ghost on the page.
    @Published private(set) var chatFocused = false
    /// Bumped to ask the chat field to take focus.
    @Published private(set) var chatFocusRequest = 0

    let store = NoteStore(folder: NoteStore.defaultFolder)
    let editor: EditorController
    let dictation = DictationEngine()
    let guardian = GuardianActivity()
    let chat = ChatLog()
    let reader: ReadAloud
    private let toolbox: GuardianToolbox
    private var server: MCPHTTPServer?
    private var reflex = CommandReflex()
    private var saveTask: Task<Void, Never>?
    private var sidecarTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var chromeTask: Task<Void, Never>?
    private var openURL: URL?

    var mcpEndpoint: URL { URL(string: "http://127.0.0.1:\(Self.mcpPort)/mcp")! }

    init() {
        let typesetting = Typesetting.load()
        self.typesetting = typesetting
        editor = EditorController(typesetting: typesetting)
        reader = ReadAloud()
        toolbox = GuardianToolbox()
        toolbox.host = editor
        toolbox.library = self
        toolbox.chat = chat
        toolbox.narrator = reader
        guardian.editor = editor
        wire()
        startMCP()
        dictation.load(modelDirectory: nil)
        // After the speech model, so the two don't compete for the first seconds.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self?.reader.warmUp()
        }
        refreshNotes()
        if let first = notes.first { open(first.url) } else { newNote() }
    }

    private func wire() {
        editor.onTextChange = { [weak self] in self?.textChanged() }
        editor.onSelectionChange = { [weak self] in self?.caretAddress = self?.editor.caretAddress ?? "" }
        editor.onHighlightsChange = { [weak self] in self?.scheduleSidecarSave() }
        editor.onReturnToPage = { [weak self] in
            guard let self, self.chatFocused else { return }
            self.chatFocused = false
        }
        chat.onChange = { [weak self] in self?.scheduleSidecarSave() }
        reader.onPassage = { [weak self] passage in self?.showReading(passage) }
        // The microphone would transcribe the voice: dictation holds its ears while it reads.
        reader.onReadingChange = { [weak self] reading in
            self?.dictation.muted = reading
            if !reading { self?.editor.textView.readingRange = nil }
        }
        dictation.onText = { [weak self] text in
            guard let self else { return }
            self.pauseTask?.cancel()
            self.deliverDictation(self.reflex.feed(text))
            self.hideChrome()
        }
        dictation.onPause = { [weak self] in
            // Words trail the voice by the transcriber's 0.5 s delay line, so a pause
            // is heard before the last words arrive. Let them land first: releasing a
            // held "new" now would split "new … paragraph" into plain text, and waking
            // be premature.
            guard let self else { return }
            self.pauseTask?.cancel()
            self.pauseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.deliverDictation(self.reflex.flush())
            }
        }
        dictation.onStop = { [weak self] in
            guard let self else { return }
            self.pauseTask?.cancel()
            self.deliverDictation(self.reflex.flush())
            self.editor.isDictating = false
        }
    }

    private func startMCP() {
        let handler = MCPHandler(toolbox: toolbox)
        handler.onToolCall = { [weak self] name, arguments, result in
            guard let self else { return }
            self.guardian.observe(tool: name, arguments: arguments, result: result)
            // Its edits show in the conversation, quietly, so a reply can be read against them.
            if case .success = result, GuardianActivity.isEdit(name) {
                let ink = name == "highlight_text" ? HighlightColor(rawValue: (arguments["color"] as? String ?? "").lowercased()) : nil
                let text = ink == nil ? GuardianActivity.describe(name, arguments) : "¶\(arguments["paragraph"] ?? "") “\(arguments["find"] ?? "")”"
                self.chat.post(ChatMessage(role: .activity, text: text, ink: ink))
            }
        }
        let server = MCPHTTPServer(handler: handler, port: Self.mcpPort)
        if DebugControl.isEnabled {
            server.debugHandler = { [weak self] path, query in
                guard let self else { return "gone" }
                return DebugControl.handle(path: path, query: query, model: self)
            }
        }
        server.onStateChange = { [weak self] state in Task { @MainActor in self?.mcpStatus = state } }
        do { try server.start() } catch { mcpStatus = "failed: \(error.localizedDescription)" }
        self.server = server
    }

    func shutdown() {
        saveNow()
        dictation.stop()
        reader.shutdown()
        server?.stop()
    }

    // MARK: Notes

    var filteredNotes: [NoteFile] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.title.lowercased().contains(q) || $0.preview.lowercased().contains(q) }
    }

    func refreshNotes() { notes = store.list() }

    func open(_ url: URL) {
        guard url != openURL else { return }
        saveNow()
        let text = (try? store.load(url)) ?? ""
        let sidecar = NoteSidecar.load(for: url)
        openURL = url
        selection = url
        chat.replace(with: sidecar.chat)
        editor.load(text: text, title: NoteStore.title(ofEditorText: text, fallback: "Untitled"), highlights: sidecar.spans(in: text))
        wordCount = editor.wordCount
        caretAddress = editor.caretAddress
        focusEditor()
    }

    func newNote() {
        saveNow()
        guard let url = try? store.create() else { return }
        refreshNotes()
        open(url)
    }

    func delete(_ url: URL) {
        try? store.trash(url)
        NoteSidecar.trash(for: url)
        if url == openURL { openURL = nil }
        refreshNotes()
        if let first = notes.first { open(first.url) } else { newNote() }
    }

    func focusEditor() {
        DispatchQueue.main.async { self.editor.textView.window?.makeFirstResponder(self.editor.textView) }
    }

    private func textChanged() {
        wordCount = editor.wordCount
        caretAddress = editor.caretAddress
        editor.noteTitle = NoteStore.title(ofEditorText: editor.text, fallback: "Untitled")
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let url = openURL else { return }
        let text = editor.text
        if (try? store.load(url)) != text, let saved = try? store.save(editorText: text, to: url) {
            if saved != url { NoteSidecar.move(from: url, to: saved) }
            openURL = saved
            if selection != saved { selection = saved }
            refreshNotes()
        }
        saveSidecar()
    }

    private func saveSidecar() {
        sidecarTask?.cancel()
        guard let url = openURL else { return }
        let sidecar = NoteSidecar(spans: editor.highlights, in: editor.text, chat: chat.messages)
        if sidecar != NoteSidecar.load(for: url) { sidecar.save(for: url) }
    }

    private func scheduleSidecarSave() {
        sidecarTask?.cancel()
        sidecarTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSidecar()
        }
    }

    // MARK: Chat

    /// The chat field took or lost focus. Taking it leaves the user's caret as a ghost on the page.
    func chatFocusChanged(_ focused: Bool) {
        guard focused != chatFocused else { return }
        chatFocused = focused
        if focused { editor.leaveGhost() }
    }

    func focusChat() {
        if !showChat { showChat = true }
        chatFocusRequest += 1
    }

    /// What the ghost cursor points at, as the guardian will be told.
    var ghostPointer: (anchor: String, quote: String)? {
        editor.ghostRange.flatMap { GuardianToolbox.pointer(at: $0, in: editor.text) }
    }

    func dropGhost() { editor.clearGhost(); objectWillChange.send() }

    /// Return in the chat: what was said becomes a message, and a fresh one begins.
    func closeChatMessage() {
        let pointer = ghostPointer
        chat.seal(anchor: pointer?.anchor, quote: pointer?.quote)
    }

    /// Dictation goes where the user is writing: the page, or the chat.
    private func deliverDictation(_ actions: [DictationAction]) {
        guard chatFocused else {
            editor.insertDictation(actions)
            return
        }
        for action in actions {
            switch action {
            case .text(let chunk):
                let (edit, _) = DictationComposer.insert(chunk, at: (chat.live as NSString).length, in: chat.live)
                chat.live = edit.applied(to: chat.live)
            case .paragraphBreak:
                closeChatMessage()
            }
        }
    }

    // MARK: NoteLibrary

    func listNotes() -> [(title: String, modified: Date, preview: String)] {
        notes.filter { $0.url != openURL }.map { ($0.title, $0.modified, $0.preview) }
    }

    func readNote(titled title: String) -> String? {
        guard let note = notes.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) ?? notes.first(where: { $0.title.lowercased().contains(title.lowercased()) }) else { return nil }
        return try? store.load(note.url)
    }

    // MARK: Dictation

    func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
        } else {
            editor.isDictating = true
            if !chatFocused { focusEditor() }
            dictation.start()
        }
    }

    func dictateFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.isDictating = true
        dictation.dictate(file: url)
    }

    // MARK: Reading aloud

    /// Voice › Read Aloud: the selected paragraphs, or from the caret to the end of the note.
    func readAloud() {
        let text = editor.text
        let outline = Outline(text: text)
        let sel = editor.textView.selectedRange()
        guard let start = outline.address(of: sel.location) ?? outline.paragraphs.first.flatMap({ $0.number.map { ($0, Optional(1)) } }) else { return }
        let end = sel.length > 0 ? (outline.address(of: NSMaxRange(sel))?.paragraph ?? start.paragraph) : outline.paragraphs.count
        reader.read(Narration.passages(from: start.paragraph, to: end, sentence: start.sentence, in: text))
    }

    /// The sentence being heard is shown in the guardian's lapis, and kept in view.
    private func showReading(_ passage: Passage) {
        let text = editor.text
        guard let block = Outline(text: text).paragraph(passage.paragraph),
              let sentence = block.sentences.first(where: { $0.number == passage.sentence }) else { return }
        editor.textView.readingRange = sentence.range
        editor.textView.scrollRangeToVisible(sentence.range)
    }

    // MARK: Export

    func export(as kind: UTType) {
        saveNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind]
        let base = NoteStore.title(ofEditorText: editor.text, fallback: "Untitled").replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = base + (kind == .plainText ? ".txt" : ".md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = kind == .plainText ? MarkdownFile.plainText(fromEditorText: editor.text) : MarkdownFile.markdown(fromEditorText: editor.text)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Chrome (WriteRoom: controls recede while you write)

    func showChrome() {
        if !chromeVisible { withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true } }
        chromeTask?.cancel()
        chromeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.hideChrome()
        }
    }

    func hideChrome() {
        chromeTask?.cancel()
        if chromeVisible { withAnimation(.easeIn(duration: 0.6)) { chromeVisible = false } }
    }

    /// Unhooks the connected LLM: its calls are refused with a message telling it
    /// to stop, and a call it has waiting returns at once.
    func disconnectGuardian() {
        guardianAllowed = false
        toolbox.isConnected = false
        editor.marksFresh = false
        editor.releaseGuardian()
        guardian.disconnected()
    }

    func allowGuardian() {
        guardianAllowed = true
        toolbox.isConnected = true
        editor.marksFresh = true
        guardian.allowed()
    }

    /// Puts the MCP connection card on the clipboard for pasting into any LLM.
    func copyConnectionCard() {
        let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/scriptorium-mcp").path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ConnectionCard.text(endpoint: mcpEndpoint, bridgePath: bridge), forType: .string)
    }
}
