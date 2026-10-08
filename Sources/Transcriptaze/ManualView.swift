import AppKit
import PDFKit
import SwiftUI

/// The manual, bundled as Manual.pdf and shown in its own window from the Help menu.
enum Manual {
    static var url: URL? { Bundle.main.url(forResource: "Manual", withExtension: "pdf") }
}

struct ManualWindow: View {
    var body: some View {
        Group {
            if let url = Manual.url, let document = PDFDocument(url: url) {
                ManualPDFView(document: document)
            } else {
                Text("The manual is missing from this build.")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(Color(Palette.secondaryInk))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(Palette.sidebar))
        .toolbar {
            ToolbarItem {
                Button { if let url = Manual.url { NSWorkspace.shared.open(url) } } label: {
                    Label("Open in Preview", systemImage: "arrow.up.forward.app")
                }
                .help("Open in Preview, to print or save a copy")
            }
        }
    }
}

/// Facing pages, like the book it is set as.
struct ManualPDFView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.autoScales = true
        view.backgroundColor = Palette.sidebar
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

/// Help › Transcriptaze Manual.
struct ManualMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Transcriptaze Manual") { openWindow(id: "manual") }
            .keyboardShortcut("?", modifiers: .command)
    }
}
