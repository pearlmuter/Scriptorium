import AppKit
import SwiftUI
import TranscriptazeCore

/// Paper, ink, and two pigments from the manuscript tradition: vermilion for
/// rubrics (the verse numbers) and lapis for the guardian's hand.
enum Palette {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    /// Night is the page inverted: the ink becomes the paper and the paper the ink.
    static let paper = dynamic(light: hex(0xFAF7F0), dark: hex(0x22201C))
    static let sidebar = dynamic(light: hex(0xF2EEE5), dark: hex(0x2A2824))
    static let chat = dynamic(light: hex(0xF6F3EB), dark: hex(0x26241F))
    static let ink = dynamic(light: hex(0x22201C), dark: hex(0xFAF7F0))
    /// Dictated text not yet read by the guardian: ink still drying.
    static let wetInk = dynamic(light: hex(0x22201C, 0.52), dark: hex(0xFAF7F0, 0.5))
    static let secondaryInk = dynamic(light: hex(0x6E685E), dark: hex(0x9B958A))
    static let faintInk = dynamic(light: hex(0xB4AC9E), dark: hex(0x5C574F))
    static let rubric = dynamic(light: hex(0xB4462C), dark: hex(0xE0785C))
    static let lapis = dynamic(light: hex(0x2E4F9E), dark: hex(0x7C9BE8))
    static let lapisWash = dynamic(light: hex(0x2E4F9E, 0.10), dark: hex(0x7C9BE8, 0.16))
    static let selection = dynamic(light: hex(0xE9DFC9), dark: hex(0x3A362F))
    static let codeWash = dynamic(light: hex(0x22201C, 0.045), dark: hex(0xE6E1D6, 0.07))

    /// Highlighter inks: translucent, so the type reads through them.
    static func highlighter(_ color: HighlightColor) -> NSColor {
        switch color {
        case .yellow: return dynamic(light: hex(0xF4CF3A, 0.42), dark: hex(0xE8C547, 0.30))
        case .green: return dynamic(light: hex(0x7CC97A, 0.40), dark: hex(0x6FBF6D, 0.30))
        case .pink: return dynamic(light: hex(0xF28BB5, 0.40), dark: hex(0xE57AA6, 0.32))
        }
    }
    /// The same inks, solid, for the swatches that pick them.
    static func swatch(_ color: HighlightColor) -> NSColor {
        switch color {
        case .yellow: return hex(0xF0C832)
        case .green: return hex(0x6CC06A)
        case .pink: return hex(0xEE7FAE)
        }
    }
}

/// Paper (light) by default: the page is meant to look like a page. Night and
/// System are there for those who want them.
enum Appearance: String, CaseIterable, Identifiable {
    case paper, night, system
    static let key = "appearance"
    var id: String { rawValue }
    var label: String { ["paper": "Paper", "night": "Night", "system": "System"][rawValue]! }

    static var current: Appearance { Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .paper }

    /// Whether the page is dark right now, whatever the setting.
    static var isNight: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Paper ⇄ Night, from the toolbar or ⌃⌘N.
    static func toggle() {
        UserDefaults.standard.set((isNight ? Appearance.paper : .night).rawValue, forKey: key)
        apply()
    }

    static func apply() {
        switch current {
        case .paper: NSApp.appearance = NSAppearance(named: .aqua)
        case .night: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}

extension Color {
    init(_ ns: NSColor) { self.init(nsColor: ns) }
}

/// Typefaces that ship with macOS, so nothing is downloaded and nothing is substituted.
enum Typeface: String, CaseIterable, Identifiable {
    case newYork = "New York"
    case iowan = "Iowan Old Style"
    case charter = "Charter"
    case avenir = "Avenir Next"
    var id: String { rawValue }

    func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        var font: NSFont
        switch self {
        case .newYork:
            let base = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif)!
            font = NSFont(descriptor: base, size: size)!
        case .iowan:
            font = NSFont(name: weight >= .semibold ? "IowanOldStyle-Bold" : "IowanOldStyle-Roman", size: size) ?? .systemFont(ofSize: size)
        case .charter:
            font = NSFont(name: weight >= .semibold ? "Charter-Bold" : "Charter-Roman", size: size) ?? .systemFont(ofSize: size)
        case .avenir:
            font = NSFont(name: weight >= .semibold ? "AvenirNext-DemiBold" : "AvenirNext-Regular", size: size) ?? .systemFont(ofSize: size)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font.withOldStyleFigures()
    }
}

extension NSFont {
    /// Old-style (lowercase) figures sit in running text instead of shouting over it.
    func withOldStyleFigures() -> NSFont {
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [[
            .typeIdentifier: kNumberCaseType, .selectorIdentifier: kLowerCaseNumbersSelector,
        ]]
        let d = fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }

    func withSmallCaps() -> NSFont {
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector],
            [.typeIdentifier: kNumberCaseType, .selectorIdentifier: kLowerCaseNumbersSelector],
        ]
        return NSFont(descriptor: fontDescriptor.addingAttributes([.featureSettings: settings]), size: pointSize) ?? self
    }
}

/// Everything the editor needs to set type, derived from a few user settings.
struct Typesetting: Equatable {
    enum PageStyle: String, CaseIterable, Identifiable {
        /// Justified and hyphenated, indented paragraphs, no gaps: a printed page.
        case book
        /// Ragged right, spaced paragraphs: a manuscript in progress.
        case manuscript
        var id: String { rawValue }
        var label: String { self == .book ? "Book" : "Manuscript" }
    }

    var typeface: Typeface = .newYork
    var size: CGFloat = 19
    var lineHeight: CGFloat = 1.34
    var measure: CGFloat = 580
    var showNumbers = true
    var pageStyle: PageStyle = .book

    var body: NSFont { typeface.font(size: size) }
    var bold: NSFont { typeface.font(size: size, weight: .semibold) }
    var italic: NSFont { typeface.font(size: size, italic: true) }
    var boldItalic: NSFont { typeface.font(size: size, weight: .semibold, italic: true) }
    var mono: NSFont { NSFont.monospacedSystemFont(ofSize: size * 0.84, weight: .regular) }

    func heading(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [1.55, 1.3, 1.12, 1.0, 1.0, 1.0]
        return typeface.font(size: (size * scale[min(level, 6) - 1]).rounded(), weight: .semibold)
    }

    /// Paragraph numbers, set in the margin.
    var marginNumeral: NSFont { typeface.font(size: size * 0.62).withSmallCaps() }
    /// Sentence numbers, raised like verse numbers.
    var verseNumeral: NSFont { typeface.font(size: (size * 0.62).rounded(), weight: .medium) }
}
