import Foundation

/// Conversion between the editor's one-line-per-paragraph text and a
/// conventional markdown file, where paragraphs are separated by blank lines.
public enum MarkdownFile {
    /// File → editor. Blank lines separate paragraphs; consecutive prose lines
    /// (markdown soft wraps) are joined with a space. Code fences are kept verbatim.
    public static func editorText(fromMarkdown markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        var inFence = false
        var previousWasProse = false
        for raw in lines {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                out.append(line)
                previousWasProse = false
                continue
            }
            if inFence { out.append(line); continue }
            if trimmed.isEmpty { previousWasProse = false; continue }
            let (kind, _) = Outline.classify(line)
            let isTableRow = trimmed.hasPrefix("|")
            if kind == .prose && !isTableRow {
                let clean = trimmed.hasSuffix("  ") ? String(trimmed.dropLast(2)) : trimmed
                if previousWasProse, let last = out.popLast() {
                    out.append(last + " " + clean)
                } else {
                    out.append(clean)
                }
                previousWasProse = true
            } else {
                out.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
                previousWasProse = false
            }
        }
        return out.joined(separator: "\n")
    }

    /// Editor → file. Paragraphs get a blank line between them; runs of list
    /// items, table rows and code stay tight.
    public static func markdown(fromEditorText text: String) -> String {
        let outline = Outline(text: text)
        let ns = text as NSString
        var out = ""
        var previous: Outline.Kind?
        var previousIsTable = false
        for block in outline.blocks {
            if block.kind == .blank { continue }
            let line = ns.substring(with: block.range).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let isTable = line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
            if let previous {
                let tight = (previous == .listItem && block.kind == .listItem)
                    || (previous == .code && block.kind == .code)
                    || (previousIsTable && isTable)
                out += tight ? "\n" : "\n\n"
            }
            out += line
            previous = block.kind
            previousIsTable = isTable
        }
        return out.isEmpty ? "" : out + "\n"
    }

    /// Editor → plain text. Markup removed, paragraphs separated by blank lines.
    public static func plainText(fromEditorText text: String) -> String {
        let outline = Outline(text: text)
        let ns = text as NSString
        var paragraphs: [String] = []
        var codeRun: [String] = []
        func flushCode() {
            if !codeRun.isEmpty { paragraphs.append(codeRun.joined(separator: "\n")); codeRun = [] }
        }
        for block in outline.blocks {
            let line = ns.substring(with: block.range)
            switch block.kind {
            case .blank, .rule:
                flushCode()
            case .code:
                let t = line.trimmingCharacters(in: .whitespaces)
                if !(t.hasPrefix("```") || t.hasPrefix("~~~")) { codeRun.append(line) }
            case .listItem:
                flushCode()
                let content = ns.substring(with: block.contentRange)
                let isOrdered = line.trimmingCharacters(in: .whitespaces).first?.isNumber == true
                let marker = isOrdered ? String(line.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) + ". " : "• "
                paragraphs.append(marker + stripInline(content))
            default:
                flushCode()
                paragraphs.append(stripInline(ns.substring(with: block.contentRange)))
            }
        }
        flushCode()
        let joined = paragraphs.joined(separator: "\n\n")
        return joined.isEmpty ? "" : joined + "\n"
    }

    /// Removes inline markdown: emphasis, code ticks, links (keeping their text).
    public static func stripInline(_ s: String) -> String {
        var r = s
        let rules: [(String, String)] = [
            ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
            ("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1", "$2"),
            ("(?<![\\w*])([*_])(?=\\S)(.+?)(?<=\\S)\\1(?![\\w*])", "$2"),
            ("~~(.+?)~~", "$1"),
            ("`([^`]+)`", "$1"),
        ]
        for (pattern, template) in rules {
            r = r.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return r
    }
}

/// Inline markdown spans within one line, for styling. Ranges are UTF-16 and
/// relative to the string scanned.
public struct InlineSpan: Equatable {
    public enum Kind: Equatable { case strong, emphasis, code, strike, link }
    public let kind: Kind
    /// The whole span, markers included.
    public let range: NSRange
    /// The markup characters themselves (dimmed in the editor).
    public let markers: [NSRange]
}

public enum InlineMarkdown {
    private static let patterns: [(InlineSpan.Kind, NSRegularExpression, Int)] = [
        (.code, try! NSRegularExpression(pattern: "(`)([^`\\n]+)(`)"), 1),
        (.strong, try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)(\\1)"), 2),
        (.emphasis, try! NSRegularExpression(pattern: "(?<![\\w*])([*_])(?=[^\\s*])(.+?)(?<=[^\\s*])(\\1)(?![\\w*])"), 1),
        (.strike, try! NSRegularExpression(pattern: "(~~)(?=\\S)(.+?)(?<=\\S)(~~)"), 2),
        (.link, try! NSRegularExpression(pattern: "(\\[)([^\\]\\n]+)(\\]\\([^)\\n]*\\))"), 1),
    ]

    public static func spans(in text: String) -> [InlineSpan] {
        let ns = text as NSString
        var spans: [InlineSpan] = []
        var codeRanges: [NSRange] = []
        for (kind, regex, _) in patterns {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                // Nothing is styled inside code.
                if kind != .code, codeRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
                let span = InlineSpan(kind: kind, range: m.range, markers: [m.range(at: 1), m.range(at: 3)])
                if kind == .code { codeRanges.append(m.range) }
                spans.append(span)
            }
        }
        return spans
    }
}
