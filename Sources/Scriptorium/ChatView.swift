import SwiftUI
import AppKit
import ScriptoriumCore

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
            transcript
        }
        .background(Color(Palette.chat).ignoresSafeArea())
        .onChange(of: fieldFocused) { _, focused in model.chatFocusChanged(focused) }
        .onChange(of: model.chatFocusRequest) { _, _ in fieldFocused = true }
        .onChange(of: model.chatFocused) { _, focused in if !focused && fieldFocused { fieldFocused = false } }
    }

    // MARK: Header

    /// The voice and the guardian, at the top of the chat where they never cover the text.
    private var header: some View {
        HStack(spacing: 6) {
            DictateButton(dictation: dictation)
            GuardianStatusButton(guardian: guardian)
            ReadingIndicator(reader: model.reader)
            Spacer(minLength: 4)
            Menu {
                Button("Copy MCP Connection for LLM") { model.copyConnectionCard() }
                Divider()
                Button("Clear Conversation", role: .destructive) { chat.clear() }
                    .disabled(chat.messages.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(Palette.secondaryInk))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, -12)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
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
                VStack(alignment: .leading, spacing: 0) {
                    if chat.messages.isEmpty && chat.live.isEmpty { introduction }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(message: message, previous: index > 0 ? chat.messages[index - 1] : nil)
                    }
                    if chat.live.isEmpty, let receipt { receiptView(receipt) }
                    openMessage
                        .padding(.top, chat.messages.isEmpty ? 0 : 14)
                    Color.clear.frame(height: 10).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, minHeight: 0, alignment: .bottom)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: chat.live) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
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
        .font(.system(size: 12.5, design: .serif))
        .foregroundStyle(Color(Palette.secondaryInk).opacity(0.8))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 4)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Talk to the guardian about the text.")
                .font(.system(size: 16.5, weight: .medium, design: .serif))
                .foregroundStyle(Color(Palette.ink))
            Text("There is no send button: speak or type below and the guardian reads along, answering when you have finished a thought. Your caret stays on the page as a ghost, so “this sentence” means what you were pointing at.")
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(Color(Palette.secondaryInk))
                .fixedSize(horizontal: false, vertical: true)
            if guardian.status == .absent {
                Text("No guardian is connected. Give the connection to Claude Code, Claude Desktop or any MCP client.")
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(Color(Palette.secondaryInk))
                    .fixedSize(horizontal: false, vertical: true)
                CopyConnectionButton()
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 22)
    }

    // MARK: The open message

    /// What the user is saying now, already part of the conversation. It grows
    /// as they speak or type; the guardian's answer closes it.
    private var openMessage: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let pointer = model.ghostPointer {
                GhostChip(anchor: pointer.anchor, quote: pointer.quote) { model.dropGhost() }
                    .padding(.leading, 28)
            }
            HStack(alignment: .bottom, spacing: 4) {
                TextField(dictation.state == .listening && model.chatFocused ? "Listening…" : "Talk to the guardian…", text: $chat.live, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(Color(Palette.ink))
                    .lineLimit(1...12)
                    .focused($fieldFocused)
                    .onSubmit { model.closeChatMessage() }
                    .onExitCommand { model.focusEditor() }
                    .accessibilityIdentifier("chat-field")
                micButton
            }
            .padding(.leading, 11)
            .padding(.trailing, 4)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(Palette.selection).opacity(chat.live.isEmpty ? 0 : 0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color(fieldFocused ? Palette.lapis : Palette.faintInk).opacity(fieldFocused ? 0.4 : 0.6),
                                  style: StrokeStyle(lineWidth: 0.8, dash: chat.live.isEmpty ? [3, 3] : []))
            )
            .contentShape(Rectangle())
            .onTapGesture { fieldFocused = true }
            .padding(.leading, 28)
            if let note = liveNote {
                HStack(spacing: 5) {
                    if note.hasSuffix("thinking") { ThinkingDots() }
                    Text(note)
                }
                .font(.system(size: 12.5, design: .serif))
                .foregroundStyle(Color(Palette.secondaryInk).opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Beneath the open message: whether the guardian is reading along.
    private var liveNote: String? {
        guard !chat.live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch guardian.status {
        case .absent, .disconnected: return "No guardian is reading"
        default: return chat.liveSeen >= chat.live.count ? (guardian.status == .working ? "Read · thinking" : "Read") : "The guardian reads along"
        }
    }

    private var micButton: some View {
        let listeningHere = dictation.state == .listening && model.chatFocused
        return Button {
            if !model.chatFocused { fieldFocused = true }
            model.toggleDictation()
        } label: {
            Group {
                if listeningHere { LevelDots(level: dictation.level) } else { Image(systemName: "mic").font(.system(size: 14.5, weight: .medium)) }
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
                    Image(systemName: "mic").font(.system(size: 10))
                    Text("said on the page")
                }
                .font(.system(size: 12.5, design: .serif))
                .foregroundStyle(Color(Palette.secondaryInk))
            }
            if let anchor = message.anchor {
                HStack(spacing: 4) {
                    GhostGlyph().frame(width: 8, height: 14)
                    Text(anchor).foregroundStyle(Color(Palette.rubric).opacity(0.85))
                    if let quote = message.quote { Text("“\(quote)”").italic().lineLimit(1).truncationMode(.middle) }
                }
                .font(.system(size: 12.5, design: .serif))
                .foregroundStyle(Color(Palette.secondaryInk))
            }
            Text(message.text)
                .font(.system(size: 16, design: .serif))
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
                        Diamond().fill(Color(Palette.lapis)).frame(width: 6, height: 8)
                        Text("Guardian")
                    }
                    .font(.system(size: 12.5, weight: .medium, design: .serif))
                    .foregroundStyle(Color(Palette.lapis))
                }
                Text(message.text)
                    .font(.system(size: 16, design: .serif))
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
                RoundedRectangle(cornerRadius: 2).fill(Color(Palette.swatch(ink))).frame(width: 11, height: 11)
            } else {
                Image(systemName: "pencil.tip").font(.system(size: 11))
            }
            Text(message.text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 13, design: .serif))
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
            GhostGlyph().frame(width: 8, height: 15)
            Text(anchor).foregroundStyle(Color(Palette.rubric).opacity(0.9))
            Text("“\(quote)”").italic().lineLimit(1).truncationMode(.head)
                .foregroundStyle(Color(Palette.secondaryInk))
            Spacer(minLength: 4)
            Button(action: drop) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(Palette.secondaryInk))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don’t point at anything")
        }
        .font(.system(size: 13, design: .serif))
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
