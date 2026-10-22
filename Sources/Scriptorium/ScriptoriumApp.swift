import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScriptoriumCore

@main
struct ScriptoriumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() { Rename.migrate() }

    var body: some Scene {
        WindowGroup("Scriptorium", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 420)
                .onAppear { delegate.model = model; Appearance.apply() }
        }
        .defaultSize(width: 1180, height: 820)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { model.newNote() }.keyboardShortcut("n")
            }
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Export as Markdown…") { model.export(as: UTType(filenameExtension: "md") ?? .plainText) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export as Plain Text…") { model.export(as: .plainText) }
            }
            CommandMenu("Format") {
                Button("Bold") { model.editor.format("bold") }.keyboardShortcut("b")
                Button("Italic") { model.editor.format("italic") }.keyboardShortcut("i")
                Button("Strikethrough") { model.editor.format("strike") }
                Button("Code") { model.editor.format("code") }
                Button("Link") { model.editor.format("link") }.keyboardShortcut("k")
                Divider()
                Button("Heading 1") { model.editor.format("h1") }.keyboardShortcut("1")
                Button("Heading 2") { model.editor.format("h2") }.keyboardShortcut("2")
                Button("Heading 3") { model.editor.format("h3") }.keyboardShortcut("3")
                Button("Body") { model.editor.format("body") }.keyboardShortcut("0")
                Divider()
                Button("Quote") { model.editor.format("quote") }
                Button("Bulleted List") { model.editor.format("bullet") }
                Button("Numbered List") { model.editor.format("numbered") }
                Divider()
                Button("Highlight Yellow") { model.editor.format("highlight-yellow") }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Highlight Green") { model.editor.format("highlight-green") }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Highlight Pink") { model.editor.format("highlight-pink") }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Remove Highlights") { model.editor.format("highlight-clear") }.keyboardShortcut("0", modifiers: [.command, .option])
            }
            CommandMenu("Voice") {
                Button("Start / Stop Dictation") { model.toggleDictation() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Dictate from Audio File…") { model.dictateFromFile() }
                Divider()
                Button("Read Aloud") { model.readAloud() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Stop Reading") { model.reader.stopReading() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button(model.guardianAllowed ? "Disconnect Guardian" : "Allow Guardian") {
                    if model.guardianAllowed { model.disconnectGuardian() } else { model.allowGuardian() }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Talk to Guardian") { model.focusChat() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Copy MCP Connection for LLM") { model.copyConnectionCard() }
                    .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            }
            CommandGroup(replacing: .help) {
                ManualMenuItem()
            }
            CommandGroup(after: .sidebar) {
                Button(model.showChat ? "Hide Chat" : "Show Chat") { withAnimation(.easeInOut(duration: 0.25)) { model.showChat.toggle() } }
                    .keyboardShortcut("c", modifiers: [.command, .control])
                Button(model.focusMode ? "Leave Focus Mode" : "Focus Mode") { model.focusMode.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .control, .shift])
                Button("Paper or Night") { Appearance.toggle() }
                    .keyboardShortcut("n", modifiers: [.command, .control])
                Button(model.typesetting.showNumbers ? "Hide Numbering" : "Show Numbering") { model.typesetting.showNumbers.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Window("Scriptorium Manual", id: "manual") {
            ManualWindow()
        }
        .defaultSize(width: 620, height: 860)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
