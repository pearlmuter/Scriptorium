import AppKit
import TranscriptazeCore

/// Test automation, enabled only with TRANSCRIPTAZE_DEBUG=1. Lets a test
/// harness drive the app as a user would (type, dictate a recording, press
/// format buttons) and photograph its own window, without screen-recording
/// or accessibility permissions. Served on the MCP port under /debug/.
@MainActor
enum DebugControl {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["TRANSCRIPTAZE_DEBUG"] == "1" }

    static func handle(path: String, query: [String: String], model: AppModel) -> String {
        switch path {
        case "/debug/snapshot":
            let out = query["path"] ?? "/tmp/transcriptaze.png"
            return snapshot(to: URL(fileURLWithPath: out), popover: query["window"] == "popover") ? "ok \(out)" : "no window"
        case "/debug/type":
            model.focusEditor()
            model.editor.textView.insertText(query["text"] ?? "", replacementRange: model.editor.textView.selectedRange())
            return "ok"
        case "/debug/key":
            if query["name"] == "return" { model.editor.textView.insertNewline(nil) }
            return "ok"
        case "/debug/dictate":
            guard let file = query["file"] else { return "missing file" }
            model.editor.isDictating = true
            model.dictation.dictate(file: URL(fileURLWithPath: file))
            return "ok"
        case "/debug/format":
            model.editor.format(query["style"] ?? "")
            return "ok"
        case "/debug/select":
            let ns = model.editor.text as NSString
            let r = ns.range(of: query["text"] ?? "")
            guard r.location != NSNotFound else { return "not found" }
            model.editor.textView.setSelectedRange(r)
            return "ok"
        case "/debug/caret":
            let pos = Int(query["at"] ?? "") ?? (model.editor.text as NSString).length
            model.editor.setUserCursor(pos)
            return "ok"
        case "/debug/new":
            model.newNote(); return "ok"
        case "/debug/chrome":
            if query["show"] == "1" { model.showChrome() } else { model.hideChrome() }
            return "ok"
        case "/debug/focus":
            model.focusMode = query["on"] == "1"; return "ok"
        case "/debug/panel":
            model.showGuardianPanel = query["show"] == "1"; return "ok"
        case "/debug/guardian":
            if query["allow"] == "1" { model.allowGuardian() } else { model.disconnectGuardian() }
            return "ok"
        case "/debug/copycard":
            model.copyConnectionCard(); return "ok"
        case "/debug/state":
            return "dictation=\(model.dictation.state) guardian=\(model.guardian.status) words=\(model.wordCount)\n---\n\(model.editor.text)"
        case "/debug/log":
            return model.guardian.log.map { "\($0.isError ? "✗" : "✓") \($0.text)" }.joined(separator: "\n")
        case "/debug/appearance":
            NSApp.appearance = query["mode"] == "dark" ? NSAppearance(named: .darkAqua) : query["mode"] == "light" ? NSAppearance(named: .aqua) : nil
            return "ok"
        case "/debug/size":
            if let w = Double(query["w"] ?? ""), let h = Double(query["h"] ?? ""), let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                window.setContentSize(NSSize(width: w, height: h))
            }
            return "ok"
        default:
            return "unknown"
        }
    }

    /// Renders the window (title bar included) from the inside.
    static func snapshot(to url: URL, popover: Bool = false) -> Bool {
        let isPopover: (NSWindow) -> Bool = { String(describing: type(of: $0)).contains("Popover") }
        guard let window = NSApp.windows.first(where: { $0.isVisible && (popover ? isPopover($0) : (!isPopover($0) && $0.frame.height > 200)) }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
