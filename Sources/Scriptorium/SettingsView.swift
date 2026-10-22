import SwiftUI
import ScriptoriumCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            TypographySettings().tabItem { Label("Typography", systemImage: "textformat") }
            ConnectSettings().tabItem { Label("Guardian", systemImage: "diamond") }
        }
        .frame(width: 560)
        .padding(20)
    }
}

struct TypographySettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Appearance.key) private var appearance = Appearance.paper.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { _, _ in Appearance.apply() }
            Picker("Page", selection: $model.typesetting.pageStyle) {
                ForEach(Typesetting.PageStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Typeface", selection: $model.typesetting.typeface) {
                ForEach(Typeface.allCases) { Text($0.rawValue).tag($0) }
            }
            Slider(value: $model.typesetting.size, in: 14...28, step: 1) { Text("Size  \(Int(model.typesetting.size)) pt") }
            Slider(value: $model.typesetting.lineHeight, in: 1.2...2.0, step: 0.02) { Text("Leading  \(model.typesetting.lineHeight, specifier: "%.2f")") }
            Slider(value: $model.typesetting.measure, in: 480...900, step: 10) { Text("Measure  \(Int(model.typesetting.measure)) pt") }
            Toggle("Chapter-and-verse numbering", isOn: $model.typesetting.showNumbers)
            Text("¶ numbers sit in the margin; sentence numbers are raised in red, as verse numbers are in a printed Bible.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct ConnectSettings: View {
    @EnvironmentObject var model: AppModel

    var claudeCode: String { "claude mcp add --transport http scriptorium \(model.mcpEndpoint.absoluteString)" }
    var desktopJSON: String {
        """
        "scriptorium": {
          "command": "\(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/scriptorium-mcp").path)"
        }
        """
    }

    var body: some View {
        Form {
            LabeledContent("Endpoint") {
                Text(model.mcpEndpoint.absoluteString).textSelection(.enabled).font(.system(.body, design: .monospaced))
            }
            LabeledContent("Status", value: model.mcpStatus)
            LabeledContent("Connect an LLM") {
                CopyConnectionButton()
            }
            Section("Claude Code") {
                copyable(claudeCode)
            }
            Section("Claude Desktop and other stdio clients (mcpServers)") {
                copyable(desktopJSON)
            }
            Text("The guardian is whichever MCP-capable LLM you connect — one that already knows your work. It loops on wait_for_dictation → edit → finish_review; full instructions arrive when it connects.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    func copyable(_ s: String) -> some View {
        HStack(alignment: .top) {
            Text(s).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
        }
    }
}
