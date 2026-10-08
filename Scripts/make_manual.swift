// Typesets Resources/Manual/manual.html into Resources/Manual.pdf with WebKit,
// so the manual is set in the same New York as the app.
//
//   swift Scripts/make_manual.swift [--preview <dir>]
//
// The HTML is laid out as fixed A5 pages (`.page`, 420 × 595 pt); each one is
// captured as one PDF page. With --preview, every page is also written as PNG.
import AppKit
import PDFKit
import WebKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Resources/Manual/manual.html")
let output = root.appendingPathComponent("Resources/Manual.pdf")
let args = CommandLine.arguments
let previewDir = args.firstIndex(of: "--preview").flatMap { args.count > $0 + 1 ? URL(fileURLWithPath: args[$0 + 1]) : nil }

let pageSize = CGSize(width: 420, height: 595)

@MainActor
final class Typesetter: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(origin: .zero, size: pageSize))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: pageSize), styleMask: .borderless, backing: .buffered, defer: false)

    func start() {
        web.appearance = NSAppearance(named: .aqua)
        window.contentView = web
        web.navigationDelegate = self
        web.loadFileURL(source, allowingReadAccessTo: source.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await self.typeset() }
    }

    func typeset() async {
        do {
            // Wait for fonts and images before measuring anything.
            let count = try await web.callAsyncJavaScript("""
                await document.fonts.ready;
                await Promise.all([...document.images].map(i => i.complete ? 0 : new Promise(r => { i.onload = r; i.onerror = r; })));
                const pages = document.querySelectorAll('.page');
                pages.forEach((p, i) => { const n = p.querySelector('.folio'); if (n) n.textContent = i + 1; });
                // Points by which a page's flowing content runs into its bottom margin.
                const over = [...pages].map((p, i) => {
                    const top = p.getBoundingClientRect().top;
                    const limit = p.clientHeight - parseFloat(getComputedStyle(p).paddingBottom) + 6;
                    const bottom = Math.max(0, ...[...p.children].filter(c => !['absolute'].includes(getComputedStyle(c).position)).map(c => c.getBoundingClientRect().bottom - top));
                    return bottom > limit ? `p${i + 1} +${Math.round(bottom - limit)}pt` : null;
                }).filter(Boolean);
                return [pages.length, over];
                """, contentWorld: .page) as? [Any]
            let n = (count?[0] as? Int) ?? 0
            let overflowing = (count?[1] as? [String]) ?? []
            if !overflowing.isEmpty { FileHandle.standardError.write("warning: content runs into the bottom margin: \(overflowing.joined(separator: ", "))\n".data(using: .utf8)!) }
            web.frame = NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height * CGFloat(n))
            window.setContentSize(web.frame.size)
            try await Task.sleep(nanoseconds: 300_000_000)

            let document = PDFDocument()
            for i in 0..<n {
                let config = WKPDFConfiguration()
                config.rect = CGRect(x: 0, y: CGFloat(i) * pageSize.height, width: pageSize.width, height: pageSize.height)
                let data = try await web.pdf(configuration: config)
                guard let page = PDFDocument(data: data)?.page(at: 0) else { continue }
                document.insert(page, at: document.pageCount)
            }
            document.documentAttributes = [
                PDFDocumentAttribute.titleAttribute: "Transcriptaze — The Manual",
                PDFDocumentAttribute.authorAttribute: "Transcriptaze",
                PDFDocumentAttribute.subjectAttribute: "How to write by voice with a guardian",
            ]
            document.write(to: output)
            print("Wrote \(output.path) (\(document.pageCount) pages)")

            if let previewDir {
                try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
                for i in 0..<document.pageCount {
                    guard let page = document.page(at: i) else { continue }
                    let image = page.thumbnail(of: NSSize(width: pageSize.width * 2, height: pageSize.height * 2), for: .mediaBox)
                    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: previewDir.appendingPathComponent(String(format: "page-%02d.png", i + 1)))
                    }
                }
            }
            exit(0)
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let typesetter = MainActor.assumeIsolated { Typesetter() }
MainActor.assumeIsolated { typesetter.start() }
app.run()
