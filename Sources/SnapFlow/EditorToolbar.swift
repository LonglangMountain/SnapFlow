import AppKit

/// Human-readable names for the palette swatches, used as hover tooltips.
/// The order matches the `palette` arrays in the editor controllers.
enum Palette {
    static let names = ["红", "橙", "黄", "绿", "蓝", "紫",
                        "黑", "灰", "白", "靛蓝", "青", "粉"]

    static func name(at index: Int) -> String {
        names.indices.contains(index) ? "\(names[index])色" : "颜色"
    }
}

/// Rounded, translucent floating bar used for the editor's tool and style rows.
/// A container hosts the shadow (which needs an unclipped layer) while an inner
/// visual-effect view provides the rounded, clipped material.
final class PillView: NSView {

    private let container = NSView()

    init(cornerRadius: CGFloat, bordered: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        // Solid white bar. aqua appearance makes label-coloured controls render
        // dark for contrast on the light background.
        container.wantsLayer = true
        container.appearance = NSAppearance(named: .aqua)
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.97).cgColor
        container.layer?.cornerRadius = cornerRadius
        // masksToBounds MUST stay false so the drop shadow renders; the rounded
        // background + border still clip to the corner radius. Buttons sit within
        // the content insets, so nothing pokes out of the rounded corners.
        container.layer?.masksToBounds = false
        container.layer?.borderWidth = bordered ? 0.5 : 0
        container.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        // Soft outer shadow on the shape-bearing layer (an empty outer layer
        // casts nothing).
        container.layer?.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        container.layer?.shadowOpacity = 1
        container.layer?.shadowRadius = 16
        container.layer?.shadowOffset = CGSize(width: 0, height: -2)
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// The content view where callers add their controls.
    var contentContainer: NSView { container }

    /// The window has no title bar, so dragging a pill's background moves it.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Always show the normal arrow over the bar (not the canvas's move cursor).
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Thin vertical divider between groups inside a pill.
final class PillSeparator: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 18) }
}

/// Base button that shows its hint via the custom white-on-dark HoverTip.
/// Overriding `toolTip` captures the string but does NOT forward it to AppKit,
/// so the light native tooltip never appears.
class TipButton: NSButton {
    private var tipText: String?
    override var toolTip: String? {
        get { tipText }
        set { tipText = newValue }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        HoverTip.shared.show(tipText ?? "", for: self)
    }

    override func mouseExited(with event: NSEvent) {
        HoverTip.shared.hide()
    }

    override func mouseDown(with event: NSEvent) {
        HoverTip.shared.hide()
        super.mouseDown(with: event)
    }

    /// Keep the normal arrow over toolbar buttons, never the canvas move cursor.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Flat icon button for the pill bars. Draws a rounded accent wash when `on`,
/// which is how the selected drawing tool is indicated.
final class PillIconButton: TipButton {

    /// One consistent glyph size for every toolbar icon. `.scaleProportionallyDown`
    /// keeps each symbol at this point size (no upscaling, so they look uniform)
    /// and only shrinks the rare glyph that would otherwise overflow — which is
    /// what was clipping the wider icons before.
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        // Dark by default so icons read on the white bar; tool selection and the
        // cancel/done/palette buttons override this.
        contentTintColor = .labelColor
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// Enlarge every assigned SF Symbol and keep it template-tinted.
    override var image: NSImage? {
        get { super.image }
        set {
            let configured = newValue?.withSymbolConfiguration(Self.symbolConfig) ?? newValue
            configured?.isTemplate = true
            super.image = configured
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 33, height: 31) }

    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                         xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// One of the stroke-width choices, drawn as a dot sized to the width.
final class SizeDotButton: TipButton {

    private let dotDiameter: CGFloat
    var isChosen = false { didSet { needsDisplay = true } }

    init(dotDiameter: CGFloat) {
        self.dotDiameter = dotDiameter
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        isBordered = false
        title = ""
    }

    required init?(coder: NSCoder) { preconditionFailure("SizeDotButton is code-only") }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
        let r = dotDiameter / 2
        let rect = NSRect(x: bounds.midX - r, y: bounds.midY - r,
                          width: dotDiameter, height: dotDiameter)
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

/// One colour in the palette grid.
final class ColorSwatchButton: TipButton {

    let swatchColor: NSColor
    var isChosen = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        swatchColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: 17, height: 17))
        isBordered = false
        title = ""
    }

    required init?(coder: NSCoder) { preconditionFailure("ColorSwatchButton is code-only") }

    override var intrinsicContentSize: NSSize { NSSize(width: 17, height: 17) }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
        swatchColor.setFill()
        dot.fill()
        dot.lineWidth = 0.5
        NSColor.separatorColor.setStroke()
        dot.stroke()

        if isChosen {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}
