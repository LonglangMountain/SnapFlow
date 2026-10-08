import AppKit

/// Highlights the window under the cursor and reports a pick on click.
final class WindowSelectionView: NSView {

    var hitTest: ((CGPoint) -> WindowInfo?)?
    var onSelect: ((WindowInfo) -> Void)?
    var onCancel: (() -> Void)?

    private let screenOrigin: CGPoint
    private var current: WindowInfo?
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, screenOrigin: CGPoint) {
        self.screenOrigin = screenOrigin
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateHighlight(atCocoaGlobal: NSEvent.mouseLocation)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        updateHighlight(atCocoaGlobal: CGPoint(x: local.x + screenOrigin.x,
                                               y: local.y + screenOrigin.y))
    }

    override func mouseDown(with event: NSEvent) {
        if let current {
            onSelect?(current)
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == 53 { // ESC
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func updateHighlight(atCocoaGlobal cocoaGlobal: CGPoint) {
        let cgPoint = Geometry.cocoaToCG(cocoaGlobal)
        current = hitTest?(cgPoint)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.25).setFill()
        bounds.fill()

        guard let window = current else { return }
        let rect = localRect(for: window.frame)

        rect.fill(using: .clear)

        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()

        drawLabel(for: window, in: rect)
    }

    /// Converts a window's CoreGraphics global frame to this view's coordinates.
    private func localRect(for cgFrame: CGRect) -> NSRect {
        let cocoa = Geometry.cgToCocoa(cgFrame)
        return NSRect(x: cocoa.minX - screenOrigin.x,
                      y: cocoa.minY - screenOrigin.y,
                      width: cocoa.width,
                      height: cocoa.height)
    }

    private func drawLabel(for window: WindowInfo, in rect: NSRect) {
        var text = window.ownerName
        if let title = window.title, !title.isEmpty, title != window.ownerName {
            text += " — \(title)"
        }
        text += "  \(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let boxSize = NSSize(width: size.width + padding * 2, height: size.height + padding)

        var origin = NSPoint(x: rect.minX, y: rect.maxY + 4)
        if origin.y + boxSize.height > bounds.maxY {
            origin = NSPoint(x: rect.minX, y: rect.minY - boxSize.height - 4)
        }
        let box = NSRect(origin: origin, size: boxSize)

        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()

        let textOrigin = NSPoint(x: box.minX + padding, y: box.minY + padding / 2)
        (text as NSString).draw(at: textOrigin, withAttributes: attributes)
    }
}
