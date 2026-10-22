import AppKit
import ScriptoriumCore

/// Test automation, enabled only with SCRIPTORIUM_DEBUG=1. Lets a test
/// harness drive the app as a user would (type, dictate a recording, press
/// format buttons) and photograph its own window, without screen-recording
/// or accessibility permissions. Served on the MCP port under /debug/.
@MainActor
enum DebugControl {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["SCRIPTORIUM_DEBUG"] == "1" }

    static func handle(path: String, query: [String: String], model: AppModel) -> String {
        switch path {
        case "/debug/snapshot":
            let out = query["path"] ?? "/tmp/scriptorium.png"
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
        case "/debug/chat":
            // Writes and sends a chat message as the user would (focus=1 only focuses the field).
            model.focusChat()
            if let text = query["text"] { model.chat.live = text }
            if query["close"] == "1" { model.closeChatMessage() }
            return "ok"
        case "/debug/keypress":
            // A real key event through the window, as if typed: name=return|optreturn, or text=… to type.
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 200 }) else { return "no window" }
            func press(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { window.sendEvent(e) }
                }
            }
            if let text = query["text"] { for ch in text { press(String(ch), code: 0) } }
            switch query["name"] {
            case "return": press("\r", code: 36)
            case "optreturn": press("\r", code: 36, flags: .option)
            default: break
            }
            return "ok \(String(describing: type(of: window.firstResponder as Any)))"
        case "/debug/chatshow":
            model.showChat = query["show"] != "0"; return "ok"
        case "/debug/page":
            model.focusEditor(); return "ok"
        case "/debug/highlight":
            let ns = model.editor.text as NSString
            let r = ns.range(of: query["text"] ?? "")
            guard r.location != NSNotFound, let color = HighlightColor(rawValue: query["color"] ?? "yellow") else { return "not found" }
            model.focusEditor()
            model.editor.textView.setSelectedRange(r)
            model.editor.highlightSelection(color)
            return "ok"
        case "/debug/clickhighlight":
            let ns = model.editor.text as NSString
            let r = ns.range(of: query["text"] ?? "")
            guard r.location != NSNotFound, let id = model.editor.textView.textStorage?.attribute(.highlight, at: r.location, effectiveRange: nil) as? String else { return "no highlight" }
            model.editor.dismissHighlight(id)
            return "ok"
        case "/debug/highlights":
            return model.editor.highlights.map { "\($0.color.rawValue) \($0.author.rawValue) \((model.editor.text as NSString).substring(with: $0.range))" }.joined(separator: "\n")
        case "/debug/chatlog":
            return model.chat.messages.map { "\($0.role.rawValue)\($0.delivered ? "✓" : "") \($0.anchor ?? "") \($0.text)" }.joined(separator: "\n")
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
        case "/debug/geometry":
            let tv = model.editor.textView, sv = model.editor.scrollView
            return "scroll \(sv.frame) content \(sv.contentSize) clip \(sv.contentView.bounds)\ntext \(tv.frame) inset \(tv.textContainerInset) container \(tv.textContainer?.containerSize ?? .zero)"
        case "/debug/getmodel":
            model.dictation.downloadModel(); return "ok"
        case "/debug/reader":
            return "\(model.reader.state) muted=\(model.dictation.muted) \(model.reader.diagnostics)"
        case "/debug/log":
            return model.guardian.log.map { "\($0.isError ? "✗" : "✓") \($0.text)" }.joined(separator: "\n")
        case "/debug/appearance":
            NSApp.appearance = query["mode"] == "dark" ? NSAppearance(named: .darkAqua) : query["mode"] == "light" ? NSAppearance(named: .aqua) : nil
            return "ok"
        case "/debug/hittest":
            // What a click at (x, y), measured from the window's top-left, would land on.
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 200 }),
                  let frame = window.contentView?.superview,
                  let x = Double(query["x"] ?? ""), let y = Double(query["y"] ?? "") else { return "no window" }
            var view = frame.hitTest(NSPoint(x: x, y: frame.bounds.height - y))
            if query["click"] == "1", let control = view as? NSControl { control.performClick(nil) }
            var chain: [String] = []
            while let v = view, chain.count < 8 { chain.append(String(describing: type(of: v))); view = v.superview }
            return chain.joined(separator: " < ")
        case "/debug/fullscreen":
            NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 200 })?.toggleFullScreen(nil)
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
