import Foundation

public struct NoteFile: Identifiable, Equatable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var title: String
    public var preview: String
    public var modified: Date
}

/// Notes are ordinary markdown files in one folder, so any other tool — and
/// any guardian — can read them.
public final class NoteStore {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// `SCRIPTORIUM_NOTES_DIR` overrides it, for test runs.
    public static var defaultFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["SCRIPTORIUM_NOTES_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scriptorium")
    }

    public func list() -> [NoteFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "md" }.compactMap { url in
            guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return NoteFile(url: url, title: Self.title(ofEditorText: MarkdownFile.editorText(fromMarkdown: markdown), fallback: url.deletingPathExtension().lastPathComponent),
                            preview: Self.preview(of: markdown), modified: modified)
        }.sorted { $0.modified > $1.modified }
    }

    /// The editor text of a note.
    public func load(_ url: URL) throws -> String {
        MarkdownFile.editorText(fromMarkdown: try String(contentsOf: url, encoding: .utf8))
    }

    /// Saves, renaming the file to follow the title. Returns the (possibly new) URL.
    @discardableResult
    public func save(editorText: String, to url: URL) throws -> URL {
        let markdown = MarkdownFile.markdown(fromEditorText: editorText)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let wanted = Self.fileName(for: Self.title(ofEditorText: editorText, fallback: "Untitled"))
        guard wanted != url.deletingPathExtension().lastPathComponent else { return url }
        let target = uniqueURL(base: wanted, excluding: url)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return url
        }
    }

    public func create() throws -> URL {
        let url = uniqueURL(base: "Untitled", excluding: nil)
        try "".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Moves to the Trash (recoverable), never a hard delete.
    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func uniqueURL(base: String, excluding: URL?) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate.standardizedFileURL != excluding?.standardizedFileURL {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("md")
            n += 1
        }
        return candidate
    }

    /// First non-empty line, without markdown, truncated.
    public static func title(ofEditorText text: String, fallback: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let (_, prefix) = Outline.classify(line)
            let content = (line as NSString).substring(from: min(prefix, (line as NSString).length))
            let clean = MarkdownFile.stripInline(content).trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { return String(clean.prefix(80)) }
        }
        return fallback
    }

    static func fileName(for title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>\n").union(.controlCharacters)
        let cleaned = title.components(separatedBy: illegal).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let short = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Untitled" : short
    }

    static func preview(of markdown: String) -> String {
        let text = MarkdownFile.plainText(fromEditorText: MarkdownFile.editorText(fromMarkdown: markdown))
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return paragraphs.dropFirst().joined(separator: " ").prefix(160).description
    }
}
