import AppKit
import TranscriptazeCore

/// Three ink swatches that rise beside a selection. Click one to highlight;
/// the hollow swatch, shown when the selection already holds highlights,
/// clears them.
final class HighlightPalette: NSView {
    /// nil means erase.
    var onPick: ((HighlightColor?) -> Void)?
    var showsEraser = false { didSet { if showsEraser != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }

    private var hover: Int?
    private let dot: CGFloat = 13
    private let gap: CGFloat = 7
    private let pad: CGFloat = 7

    private var items: [HighlightColor?] { HighlightColor.allCases.map { Optional($0) } + (showsEraser ? [nil] : []) }

    override var isFlipped: Bool { true }
    /// Upright, to stand in the margin beside the line; flat, to sit above it.
    var vertical = true { didSet { if vertical != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(items.count)
        let long = pad * 2 + n * dot + (n - 1) * gap, short = dot + pad * 2
        return vertical ? NSSize(width: short, height: long) : NSSize(width: long, height: short)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityLabel("Highlight")
    }
    required init?(coder: NSCoder) { fatalError() }

    private func dotRect(_ i: Int) -> NSRect {
        let along = pad + CGFloat(i) * (dot + gap)
        return vertical ? NSRect(x: pad, y: along, width: dot, height: dot) : NSRect(x: along, y: pad, width: dot, height: dot)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.width, bounds.height) / 2
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        Palette.paper.setFill()
        capsule.fill()
        Palette.faintInk.withAlphaComponent(0.55).setStroke()
        capsule.lineWidth = 0.5
        capsule.stroke()
        for (i, item) in items.enumerated() {
            var r = dotRect(i)
            if hover == i { r = r.insetBy(dx: -1.5, dy: -1.5) }
            let circle = NSBezierPath(ovalIn: r)
            if let color = item {
                Palette.swatch(color).setFill()
                circle.fill()
                NSColor.black.withAlphaComponent(0.12).setStroke()
                circle.lineWidth = 0.5
                circle.stroke()
            } else {
                // Eraser: a hollow ring with a stroke through it.
                Palette.secondaryInk.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.2
                ring.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: r.minX + 3, y: r.maxY - 3))
                slash.line(to: NSPoint(x: r.maxX - 3, y: r.minY + 3))
                slash.lineWidth = 1.2
                slash.stroke()
            }
        }
    }

    private func index(at point: NSPoint) -> Int? {
        items.indices.first { dotRect($0).insetBy(dx: vertical ? -pad : -gap / 2, dy: vertical ? -gap / 2 : -pad).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
        NSCursor.pointingHand.set()
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick?(items[i])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
}
