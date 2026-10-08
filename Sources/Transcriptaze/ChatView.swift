import SwiftUI
import AppKit
import TranscriptazeCore

/// The conversation with the guardian, between the notes and the page. While
/// the user writes here their caret stays on the page as a ghost, and each
/// message carries what it pointed at.
struct ChatPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var chat: ChatLog
    @ObservedObject var guardian: GuardianActivity
    @ObservedObject var dictation: DictationEngine
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color(Palette.faintInk).opacity(0.35)).frame(height: 0.5)
            if chat.messages.isEmpty {
                emptyState
            } else {
                transcript
            }
            composer
        }
        .background(Color(Palette.chat).ignoresSafeArea())
        .onChange(of: fieldFocused) { _, focused in model.chatFocusChanged(focused) }
        .onChange(of: model.chatFocusRequest) { _, _ in fieldFocused = true }
        .onChange(of: model.chatFocused) { _, focused in if !focused && fieldFocused { fieldFocused = false } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Diamond()
                .fill(Color(Palette.lapis).opacity(guardian.status == .working ? 1 : guardian.status == .connected ? 0.7 : 0.25))
                .frame(width: 7, height: 9)
            Text("Guardian")
                .font(.system(size: 13.5, weight: .semibold, design: .serif))
                .foregroundStyle(Color(Palette.ink))
            Text(statusText)
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(Color(Palette.secondaryInk))
            Spacer()
            Menu {
                Button("Copy MCP Connection for LLM") { model.copyConnectionCard() }
                Divider()
                Button("Clear Conversation", role: .destructive) { chat.clear() }
                    .disabled(chat.messages.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(Palette.secondaryInk))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 9)
    }

    private var statusText: String {
        switch guardian.status {
        case .absent: return "not connected"
        case .connected: return "listening"
        case .working: return "reading"
        case .disconnected: return "disconnected"
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(message: message, previous: index > 0 ? chat.messages[index - 1] : nil)
                    }
                    if let receipt { receiptView(receipt) }
                    Color.clear.frame(height: 6).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// Below the user's last message: whether the guardian has it yet.
    private var receipt: String? {
        guard let lastUser = chat.messages.lastIndex(where: { $0.role == .user }),
              !chat.messages[(lastUser + 1)...].contains(where: { $0.role == .guardian }) else { return nil }
        let m = chat.messages[lastUser]
        if !m.delivered {
            return guardian.status == .absent || guardian.status == .disconnected ? "Waiting for a guardian to connect" : "Sent"
        }
        return guardian.status == .working ? "Read · thinking" : "Read"
    }

    private func receiptView(_ text: String) -> some View {
        HStack(spacing: 5) {
            if text.hasSuffix("thinking") { ThinkingDots() }
            Text(text)
        }
        .font(.system(size: 10.5, design: .serif))
        .foregroundStyle(Color(Palette.secondaryInk).opacity(0.8))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("Talk to the guardian about the text.")
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(Color(Palette.ink))
            Text("Your caret stays on the page as a ghost while you write here, so “this sentence” means what you were pointing at. Ask it to fact-check, and it will mark claims green, yellow or pink.")
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(Color(Palette.secondaryInk))
                .fixedSize(horizontal: false, vertical: true)
            if guardian.status == .absent {
                Text("No guardian is connected. Give the connection to Claude Code, Claude Desktop or any MCP client.")
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(Color(Palette.secondaryInk))
                    .fixedSize(horizontal: false, vertical: true)
                CopyConnectionButton()
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pointer = model.ghostPointer {
                GhostChip(anchor: pointer.anchor, quote: pointer.quote) { model.dropGhost() }
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(dictation.state == .listening && model.chatFocused ? "Listening…" : "Talk to the guardian…", text: $model.chatDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, design: .serif))
                    .foregroundStyle(Color(Palette.ink))
                    .lineLimit(1...8)
                    .focused($fieldFocused)
                    .onSubmit { model.sendChat() }
                    .onExitCommand { model.focusEditor() }
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("chat-field")
                micButton
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(Palette.paper)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(fieldFocused ? Color(Palette.lapis).opacity(0.45) : Color(Palette.faintInk).opacity(0.5), lineWidth: fieldFocused ? 1 : 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { fieldFocused = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var micButton: some View {
        let listeningHere = dictation.state == .listening && model.chatFocused
        return Button {
            if !model.chatFocused { fieldFocused = true }
            model.toggleDictation()
        } label: {
            Group {
                if listeningHere { LevelDots(level: dictation.level) } else { Image(systemName: "mic").font(.system(size: 12.5, weight: .medium)) }
            }
            .foregroundStyle(listeningHere ? Color(Palette.rubric) : Color(Palette.secondaryInk))
            .frame(width: 26, height: 24)
            .background(Circle().fill(Color(Palette.rubric).opacity(listeningHere ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dictation.state == .loading)
        .help("Dictate into the chat (⌘⇧D)")
    }
}

/// One line of the conversation.
struct MessageRow: View {
    let message: ChatMessage
    let previous: ChatMessage?

    var body: some View {
        switch message.role {
        case .user: user
        case .guardian: guardianReply
        case .activity: activity
        }
    }

    private var gap: CGFloat {
        guard let previous else { return 0 }
        if previous.role == .activity && message.role == .activity { return 2 }
        return previous.role == message.role ? 6 : 14
    }

    private var user: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if message.spoken == true {
                HStack(spacing: 3) {
                    Image(systemName: "mic").font(.system(size: 8.5))
                    Text("said on the page")
                }
                .font(.system(size: 10.5, design: .serif))
                .foregroundStyle(Color(Palette.secondaryInk))
            }
            if let anchor = message.anchor {
                HStack(spacing: 4) {
                    GhostGlyph().frame(width: 7, height: 12)
                    Text(anchor).foregroundStyle(Color(Palette.rubric).opacity(0.85))
                    if let quote = message.quote { Text("“\(quote)”").italic().lineLimit(1).truncationMode(.middle) }
                }
                .font(.system(size: 10.5, design: .serif))
                .foregroundStyle(Color(Palette.secondaryInk))
            }
            Text(message.text)
                .font(.system(size: 13.5, design: .serif))
                .foregroundStyle(Color(Palette.ink))
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(Palette.selection)))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 28)
        .padding(.top, gap)
    }

    private var guardianReply: some View {
        HStack(alignment: .top, spacing: 9) {
            Rectangle().fill(Color(Palette.lapis).opacity(0.55)).frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                if previous?.role != .guardian {
                    HStack(spacing: 4) {
                        Diamond().fill(Color(Palette.lapis)).frame(width: 5, height: 7)
                        Text("Guardian")
                    }
                    .font(.system(size: 10.5, weight: .medium, design: .serif))
                    .foregroundStyle(Color(Palette.lapis))
                }
                Text(message.text)
                    .font(.system(size: 13.5, design: .serif))
                    .foregroundStyle(Color(Palette.ink))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 20)
        .padding(.top, gap)
    }

    private var activity: some View {
        HStack(alignment: .center, spacing: 6) {
            if let ink = message.ink {
                RoundedRectangle(cornerRadius: 2).fill(Color(Palette.swatch(ink))).frame(width: 9, height: 9)
            } else {
                Image(systemName: "pencil.tip").font(.system(size: 9))
            }
            Text(message.text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11, design: .serif))
        .foregroundStyle(Color(Palette.lapis).opacity(0.7))
        .padding(.leading, 11)
        .padding(.top, gap)
    }
}

/// What the ghost cursor points at, shown above the field while the user writes.
struct GhostChip: View {
    let anchor: String
    let quote: String
    let drop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            GhostGlyph().frame(width: 7, height: 13)
            Text(anchor).foregroundStyle(Color(Palette.rubric).opacity(0.9))
            Text("“\(quote)”").italic().lineLimit(1).truncationMode(.head)
                .foregroundStyle(Color(Palette.secondaryInk))
            Spacer(minLength: 4)
            Button(action: drop) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color(Palette.secondaryInk))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don’t point at anything")
        }
        .font(.system(size: 11, design: .serif))
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(Capsule().strokeBorder(Color(Palette.faintInk).opacity(0.6), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2])))
        .help("Your cursor on the page. The guardian sees what it points at.")
    }
}

/// The ghost cursor's mark: a ring on a thin bar.
struct GhostGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let ring = CGRect(x: size.width / 2 - 3, y: 0.5, width: 6, height: 6)
            ctx.stroke(Path(ellipseIn: ring), with: .color(Color(Palette.ink).opacity(0.5)), lineWidth: 1.1)
            ctx.fill(Path(CGRect(x: size.width / 2 - 0.6, y: 7, width: 1.2, height: size.height - 7)), with: .color(Color(Palette.ink).opacity(0.45)))
        }
    }
}

struct ThinkingDots: View {
    @State private var phase = 0
    let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3) { i in
                Circle().fill(Color(Palette.lapis)).frame(width: 3.5, height: 3.5).opacity(phase == i ? 0.9 : 0.3)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
