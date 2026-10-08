import SwiftUI
import AppKit
import TranscriptazeCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var columns: NavigationSplitViewVisibility = .all
    @AppStorage("chatWidth") private var chatWidth: Double = 320

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            HStack(spacing: 0) {
                if model.showChat && !model.focusMode {
                    ChatPanel(chat: model.chat, guardian: model.guardian, dictation: model.dictation)
                        .frame(width: chatWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    ChatDivider(width: $chatWidth)
                }
                EditorPane()
            }
            .toolbar(model.focusMode ? .hidden : .visible, for: .windowToolbar)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { withAnimation(.easeInOut(duration: 0.25)) { model.showChat.toggle() } } label: {
                        Image(systemName: model.showChat ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
                    }
                    .help(model.showChat ? "Hide Chat (⌃⌘C)" : "Show Chat (⌃⌘C)")
                }
            }
        }
        .onChange(of: model.focusMode) { _, focus in
            withAnimation(.easeInOut(duration: 0.35)) { columns = focus ? .detailOnly : .all }
        }
        .background(Color(Palette.paper))
    }
}

/// A hairline that can be dragged to size the chat.
struct ChatDivider: View {
    @Binding var width: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(Palette.faintInk).opacity(0.35))
            .frame(width: 0.5)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if start == nil { start = width }
                        width = min(520, max(240, (start ?? width) + g.translation.width))
                    }
                    .onEnded { _ in start = nil }))
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { if let url = $0 { model.open(url) } })) {
            ForEach(model.filteredNotes) { note in
                NoteRow(note: note)
                    .tag(note.url)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { model.delete(note.url) }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(Palette.sidebar))
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search")
        .toolbar {
            ToolbarItem {
                Button { model.newNote() } label: { Image(systemName: "square.and.pencil") }
                    .help("New Note (⌘N)")
            }
        }
    }
}

struct NoteRow: View {
    let note: NoteFile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(.system(size: 13.5, weight: .semibold, design: .serif))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(Self.date(note.modified))
                    .foregroundStyle(.secondary)
                Text(note.preview.isEmpty ? "No additional text" : note.preview)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .font(.system(size: 11.5))
        }
        .padding(.vertical, 4)
    }

    static func date(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: Editor

struct EditorPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            EditorHost(controller: model.editor)
                .ignoresSafeArea()
            VStack {
                FormatBar()
                    .opacity(model.chromeVisible ? 1 : 0)
                    .padding(.top, 10)
                Spacer()
                Footer(dictation: model.dictation, guardian: model.guardian, reader: model.reader)
            }
        }
        .background(Color(Palette.paper))
        .onContinuousHover { phase in
            if case .active = phase { model.showChrome() }
        }
    }
}

struct EditorHost: NSViewRepresentable {
    let controller: EditorController
    func makeNSView(context: Context) -> NSScrollView { controller.scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

struct FormatBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            group {
                button("H1", text: "H1", help: "Heading 1 (⌘1)")
                button("h2", text: "H2", help: "Heading 2 (⌘2)")
                button("h3", text: "H3", help: "Heading 3 (⌘3)")
            }
            divider
            group {
                button("bold", symbol: "bold", help: "Bold (⌘B)")
                button("italic", symbol: "italic", help: "Italic (⌘I)")
                button("strike", symbol: "strikethrough", help: "Strikethrough")
                button("code", symbol: "chevron.left.forwardslash.chevron.right", help: "Code")
                button("link", symbol: "link", help: "Link (⌘K)")
            }
            divider
            group {
                button("quote", symbol: "text.quote", help: "Quote")
                button("bullet", symbol: "list.bullet", help: "Bulleted list")
                button("numbered", symbol: "list.number", help: "Numbered list")
            }
            divider
            Button {
                model.typesetting.showNumbers.toggle()
            } label: {
                Text("¶")
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(model.typesetting.showNumbers ? Color(Palette.rubric) : Color(Palette.secondaryInk))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .help("Chapter and verse numbers")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(Palette.faintInk).opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View { HStack(spacing: 0) { c() } }
    private var divider: some View { Rectangle().fill(Color(Palette.faintInk).opacity(0.4)).frame(width: 0.5, height: 16).padding(.horizontal, 5) }

    private func button(_ action: String, text: String? = nil, symbol: String? = nil, help: String) -> some View {
        Button { model.editor.format(action == "H1" ? "h1" : action); model.focusEditor() } label: {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 12.5, weight: .medium)) }
                else { Text(text ?? "").font(.system(size: 12, weight: .semibold, design: .serif)) }
            }
            .foregroundStyle(Color(Palette.secondaryInk))
            .frame(width: 28, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct Footer: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var dictation: DictationEngine
    @ObservedObject var guardian: GuardianActivity
    @ObservedObject var reader: ReadAloud

    /// With the chat open, the voice and guardian controls live at its top,
    /// where they never sit on the text; here only when it is hidden.
    private var controlsHere: Bool { !model.showChat || model.focusMode }

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Text("\(model.wordCount) words")
                if !model.caretAddress.isEmpty { Text(model.caretAddress).foregroundStyle(Color(Palette.rubric).opacity(0.8)) }
            }
            .font(.system(size: 11.5, design: .serif))
            .foregroundStyle(Color(Palette.secondaryInk))
            .opacity(model.chromeVisible ? 1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)

            if controlsHere {
                DictateButton(dictation: dictation, recedes: true)
                ReadingIndicator(reader: reader)
                GuardianStatusButton(guardian: guardian, recedes: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }
}

/// Starts and stops dictation; shows the level while listening.
struct DictateButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var dictation: DictationEngine
    /// In the page's footer it recedes while you write; in the chat it stays.
    var recedes = false

    var body: some View { micButton }

    var micButton: some View {
        Button {
            switch dictation.state {
            case .missing, .failed: dictation.downloadModel()
            default: model.toggleDictation()
            }
        } label: {
            HStack(spacing: 7) {
                switch dictation.state {
                case .missing:
                    Image(systemName: "arrow.down.circle")
                    Text("Get the voice model (\(ByteCountFormatter.string(fromByteCount: KyutaiModel.totalBytes, countStyle: .file)))")
                case .downloading(let fraction):
                    ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 60)
                    Text("Downloading voice model \(Int(fraction * 100))%")
                case .loading:
                    ProgressView().controlSize(.mini)
                    Text("Loading voice model")
                case .ready:
                    Image(systemName: "mic")
                    Text("Dictate").opacity(!recedes || model.chromeVisible ? 1 : 0)
                case .listening:
                    LevelDots(level: dictation.level)
                    Text("Listening")
                case .failed:
                    Image(systemName: "mic.slash")
                    Text("Voice unavailable")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(dictation.state == .listening ? Color(Palette.rubric) : Color(Palette.secondaryInk))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(Palette.rubric).opacity(dictation.state == .listening ? 0.09 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help({
            switch dictation.state {
            case .failed(let m): return m + "\nClick to try fetching the model again."
            case .missing: return "Transcriptaze listens with Kyutai STT, which runs on this Mac. Click to download it from Kyutai’s page on Hugging Face (one time)."
            default: return "Dictate (⌘⇧D)"
            }
        }())
        .accessibilityIdentifier("dictate")
    }

}

/// While the voice reads: where it is, and a way to stop it.
struct ReadingIndicator: View {
    @ObservedObject var reader: ReadAloud

    var body: some View { readingButton }

    /// While the voice reads: where it is, and a way to stop it.
    @ViewBuilder var readingButton: some View {
        switch reader.state {
        case .idle:
            EmptyView()
        case .loading, .reading:
            Button { reader.stopReading() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                    if case .reading(let p) = reader.state { Text("Reading ¶\(p)") }
                    else { Text("Preparing voice") }
                    Image(systemName: "stop.fill").font(.system(size: 8.5))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(Palette.lapis))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(Palette.lapis).opacity(0.09)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Stop reading (⌘.)")
        case .failed(let message):
            Button { reader.stopReading() } label: {
                Label("Voice unavailable", systemImage: "speaker.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(Palette.secondaryInk))
            }
            .buttonStyle(.plain)
            .help(message)
        }
    }

}

/// The guardian's state and last action; opens its log and the disconnect switch.
struct GuardianStatusButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var guardian: GuardianActivity
    var recedes = false

    var body: some View {
        Button { model.showGuardianPanel.toggle() } label: { guardianLabel }
            .buttonStyle(.plain)
            .popover(isPresented: $model.showGuardianPanel, arrowEdge: .bottom) { GuardianLog(guardian: guardian) }
    }

    private var guardianLabel: some View {
        HStack(spacing: 6) {
            Diamond()
                .fill(Color(Palette.lapis).opacity(guardian.status == .working ? 1 : guardian.status == .connected ? 0.6 : 0.25))
                .frame(width: 7, height: 9)
                .scaleEffect(guardian.status == .working ? 1.15 : 1)
                .animation(guardian.status == .working ? .easeInOut(duration: 0.6).repeatForever() : .default, value: guardian.status)
            Text(guardianText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11.5, design: .serif))
        .foregroundStyle(Color(Palette.lapis).opacity(0.85))
        .opacity(!recedes || model.chromeVisible || guardian.status == .working ? 1 : 0.55)
    }

    private var guardianText: String {
        switch guardian.status {
        case .absent: return "No guardian connected"
        case .connected: return guardian.lastAction.isEmpty ? "Guardian connected" : guardian.lastAction
        case .working: return guardian.lastAction.isEmpty ? "Reading…" : guardian.lastAction
        case .disconnected: return "Guardian disconnected"
        }
    }
}

struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath()
        }
    }
}

struct LevelDots: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { i in
                Capsule()
                    .frame(width: 2.5, height: 4 + CGFloat(max(0, min(1, level * 1.4 - Float(i) * 0.15))) * 10)
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: level)
    }
}

struct GuardianLog: View {
    @ObservedObject var guardian: GuardianActivity
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Guardian").font(.system(size: 14, weight: .semibold, design: .serif))
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            if guardian.status == .absent && guardian.log.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The guardian is an LLM you connect over MCP — one that already knows your work. Copy the connection and give it to Claude Code, Claude Desktop, Pendragon or any other MCP client.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CopyConnectionButton().controlSize(.regular)
                }
                .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if guardian.log.isEmpty { Text("No edits yet.").foregroundStyle(.secondary) }
                        ForEach(guardian.log.reversed()) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(e.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.tertiary).monospacedDigit()
                                Text(e.text).foregroundStyle(e.isError ? Color(Palette.rubric) : .primary).textSelection(.enabled)
                            }
                            .font(.system(size: 11.5))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            if guardian.status == .disconnected {
                Text("Its calls are refused and it has been told to stop. Dictation is no longer marked for review.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Guardian") { model.allowGuardian() }
            } else if guardian.status != .absent {
                Button(role: .destructive) { model.disconnectGuardian() } label: {
                    Label("Disconnect Guardian", systemImage: "bolt.horizontal.circle")
                }
                .help("Unhook the connected LLM and stop it editing")
            }
            Divider()
            HStack {
                Text("MCP: \(model.mcpEndpoint.absoluteString) · \(model.mcpStatus)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if !(guardian.status == .absent && guardian.log.isEmpty) { CopyConnectionButton() }
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    private var statusText: String {
        switch guardian.status {
        case .absent: return "not connected"
        case .connected: return "connected"
        case .working: return "reading"
        case .disconnected: return "disconnected"
        }
    }
}

/// Copies everything an LLM needs to find and use the guardian MCP server.
struct CopyConnectionButton: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    var body: some View {
        Button {
            model.copyConnectionCard()
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_600_000_000); copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy for LLM", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
        .help("Copy the MCP server address and setup for any LLM")
    }
}
