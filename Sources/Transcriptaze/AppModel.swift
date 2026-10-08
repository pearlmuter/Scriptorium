import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TranscriptazeCore

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

    let store = NoteStore(folder: NoteStore.defaultFolder)
    let editor: EditorController
    let dictation = DictationEngine()
    let guardian = GuardianActivity()
    private let toolbox: GuardianToolbox
    private var server: MCPHTTPServer?
    private var reflex = CommandReflex()
    private var saveTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var chromeTask: Task<Void, Never>?
    private var openURL: URL?

    var mcpEndpoint: URL { URL(string: "http://127.0.0.1:\(Self.mcpPort)/mcp")! }

    init() {
        let typesetting = Typesetting.load()
        self.typesetting = typesetting
        editor = EditorController(typesetting: typesetting)
        toolbox = GuardianToolbox()
        toolbox.host = editor
        toolbox.library = self
        guardian.editor = editor
        wire()
        startMCP()
        dictation.load(modelDirectory: nil)
        refreshNotes()
        if let first = notes.first { open(first.url) } else { newNote() }
    }

    private func wire() {
        editor.onTextChange = { [weak self] in self?.textChanged() }
        editor.onSelectionChange = { [weak self] in self?.caretAddress = self?.editor.caretAddress ?? "" }
        dictation.onText = { [weak self] text in
            guard let self else { return }
            self.pauseTask?.cancel()
            self.editor.insertDictation(self.reflex.feed(text))
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
                self.editor.insertDictation(self.reflex.flush())
            }
        }
        dictation.onStop = { [weak self] in
            guard let self else { return }
            self.pauseTask?.cancel()
            self.editor.insertDictation(self.reflex.flush())
            self.editor.isDictating = false
        }
    }

    private func startMCP() {
        let handler = MCPHandler(toolbox: toolbox)
        handler.onToolCall = { [weak self] name, arguments, result in
            self?.guardian.observe(tool: name, arguments: arguments, result: result)
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
        openURL = url
        selection = url
        editor.load(text: text, title: NoteStore.title(ofEditorText: text, fallback: "Untitled"))
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
        guard (try? store.load(url)) != text else { return }
        if let saved = try? store.save(editorText: text, to: url) {
            openURL = saved
            if selection != saved { selection = saved }
            refreshNotes()
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
            focusEditor()
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
        let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/transcriptaze-mcp").path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ConnectionCard.text(endpoint: mcpEndpoint, bridgePath: bridge), forType: .string)
    }
}
