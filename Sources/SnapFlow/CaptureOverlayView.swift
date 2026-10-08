import AppKit

/// Draws the dimming mask and the live selection rectangle, and drives the
/// area-selection interaction (mouse drag + ESC/Enter).
final class CaptureOverlayView: NSView {

    /// Called with the selection rect in view (screen-local) coordinates.
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?

    // Color picker (magnifier) shown while hovering, before a selection begins.
    private var loupeImage: CGImage?
    private var loupeColor: NSColor?
    private var loupePoint: NSPoint?

    /// After the user commits a selection we keep drawing the dim + border as a
    /// backdrop for the in-place editor, but stop reacting to the mouse.
    private var editing = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// Freeze the current selection and become a passive backdrop.
    func enterEditing() {
        editing = true
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Update the drawn selection (hole + border) while the in-place editor
    /// resizes it, so the backdrop stays in sync (no leftover second rectangle).
    func updateSelectionRect(_ rect: NSRect) {
        currentRect = rect
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: editing ? .arrow : .crosshair)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard !editing else { return }
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        // Starting a selection hides the color loupe.
        loupeImage = nil
        loupeColor = nil
        loupePoint = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !editing, let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = rect(from: start, to: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !editing else { return }
        // No confirm step: releasing the drag commits and shows the toolbar.
        guard let rect = currentRect, rect.width >= 1, rect.height >= 1 else {
            onCancel?()
            return
        }
        onComplete?(rect)
    }

    // MARK: - Color picker (magnifier)

    override func mouseMoved(with event: NSEvent) {
        guard !editing, startPoint == nil else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        loupePoint = viewPoint
        sampleColor(atWindow: event.locationInWindow)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        loupeImage = nil
        loupeColor = nil
        loupePoint = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    /// Grab a small patch of the screen *below* this overlay (so the dim mask is
    /// excluded) around the cursor, and read the exact pixel colour at center.
    private func sampleColor(atWindow windowPoint: NSPoint) {
        guard let window else { return }
        let globalCocoa = window.convertPoint(toScreen: windowPoint)
        let cg = Geometry.cocoaToCG(globalCocoa)
        // Capture a fixed, odd number of PIXELS around the cursor (regardless of
        // display scale) so the loupe shows a reasonable, not-too-dense grid with
        // a true center pixel.
        let scale = window.backingScaleFactor
        let side = 13 / max(1, scale)
        let rect = CGRect(x: cg.x - side / 2, y: cg.y - side / 2, width: side, height: side)
        guard let image = CGWindowListCreateImage(
            rect, .optionOnScreenBelowWindow,
            CGWindowID(window.windowNumber), [.bestResolution]) else { return }
        loupeImage = image
        let rep = NSBitmapImageRep(cgImage: image)
        loupeColor = rep.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB)
    }

    private func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard !editing else { super.keyDown(with: event); return }
        switch Int(event.keyCode) {
        case 53: // ESC
            onCancel?()
        case 36, 76: // Return / Keypad Enter
            if let rect = currentRect, rect.width >= 1, rect.height >= 1 {
                onComplete?(rect)
            } else {
                onCancel?()
            }
        case 8: // C — copy the hovered colour's hex to the clipboard
            copyLoupeColor()
        default:
            super.keyDown(with: event)
        }
    }

    /// Handle ⌘C (the conventional copy shortcut) for the picked colour.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !editing, event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c",
           loupeColor != nil {
            copyLoupeColor()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func copyLoupeColor() {
        guard let color = loupeColor else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hexString(color), forType: .string)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.35).setFill()
        bounds.fill()

        guard let rect = currentRect, rect.width >= 1, rect.height >= 1 else {
            // No selection yet: show the colour-picker magnifier under the cursor.
            if !editing { drawLoupe() }
            return
        }

        // Punch a clear hole so the live screen shows through the selection.
        rect.fill(using: .clear)

        // Selection border (blue like the reference; thicker once editing).
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = editing ? 2 : 1
        border.stroke()

        // The dimension readout is only useful before committing.
        if !editing { drawDimensionLabel(for: rect) }
    }

    /// Magnifier loupe + hex readout under the cursor while hovering.
    private func drawLoupe() {
        guard let image = loupeImage, let center = loupePoint else { return }
        let zoom: CGFloat = 96
        let labelH: CGFloat = 22
        let hintH: CGFloat = 18
        let totalH = zoom + labelH + hintH

        var x = center.x + 16
        var y = center.y + 16
        if x + zoom > bounds.maxX { x = center.x - zoom - 16 }
        if y + totalH > bounds.maxY { y = center.y - totalH - 16 }
        x = max(bounds.minX + 4, x)
        y = max(bounds.minY + 4, y)

        // Zoomed pixels (nearest-neighbour, so it reads as crisp pixels).
        let zoomRect = NSRect(x: x, y: y + labelH, width: zoom, height: zoom)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: zoomRect, xRadius: 6, yRadius: 6).addClip()
        NSColor.black.setFill()
        zoomRect.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: image, size: zoomRect.size).draw(in: zoomRect)
        NSGraphicsContext.restoreGraphicsState()

        // Pixel grid: one cell per captured pixel, so it reads like a loupe.
        let cols = max(1, image.width), rows = max(1, image.height)
        let cellW = zoom / CGFloat(cols), cellH = zoom / CGFloat(rows)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: zoomRect).addClip()
        // Mid-grey lines read on both light and dark pixels (white was invisible
        // on a white background).
        NSColor(white: 0.5, alpha: 0.6).setStroke()
        let grid = NSBezierPath()
        for i in 0...cols {
            let gx = (zoomRect.minX + CGFloat(i) * cellW).rounded() + 0.5
            grid.move(to: NSPoint(x: gx, y: zoomRect.minY))
            grid.line(to: NSPoint(x: gx, y: zoomRect.maxY))
        }
        for j in 0...rows {
            let gy = (zoomRect.minY + CGFloat(j) * cellH).rounded() + 0.5
            grid.move(to: NSPoint(x: zoomRect.minX, y: gy))
            grid.line(to: NSPoint(x: zoomRect.maxX, y: gy))
        }
        grid.lineWidth = 0.5
        grid.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let frame = NSBezierPath(roundedRect: zoomRect, xRadius: 6, yRadius: 6)
        frame.lineWidth = 1
        frame.stroke()

        // Highlight the exact center pixel (the colour being read).
        let centerCell = NSRect(x: zoomRect.midX - cellW / 2, y: zoomRect.midY - cellH / 2,
                                width: cellW, height: cellH)
        let hl = NSBezierPath(rect: centerCell)
        hl.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        hl.stroke()

        // Label: colour swatch + hex.
        let labelRect = NSRect(x: x, y: y, width: zoom, height: labelH)
        NSColor(white: 0, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        if let color = loupeColor {
            let sw = NSRect(x: labelRect.minX + 6, y: labelRect.midY - 6, width: 12, height: 12)
            color.setFill()
            NSBezierPath(rect: sw).fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            NSBezierPath(rect: sw).stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let text = hexString(color)
            let ts = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: sw.maxX + 6, y: labelRect.midY - ts.height / 2),
                                    withAttributes: attrs)
        }

        // Discoverable copy-shortcut hint above the loupe.
        let hint = "⌘C 复制颜色"
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let hs = (hint as NSString).size(withAttributes: hintAttrs)
        let chip = NSRect(x: zoomRect.midX - hs.width / 2 - 6,
                          y: zoomRect.maxY + 3, width: hs.width + 12, height: hintH - 4)
        NSColor(white: 0, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
        (hint as NSString).draw(at: NSPoint(x: chip.minX + 6, y: chip.midY - hs.height / 2),
                                withAttributes: hintAttrs)
    }

    private func drawDimensionLabel(for rect: NSRect) {
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let boxSize = NSSize(width: size.width + padding * 2, height: size.height + padding)

        // Prefer placing the label just below the selection; otherwise inside.
        var origin = NSPoint(x: rect.minX, y: rect.minY - boxSize.height - 4)
        if origin.y < 0 { origin = NSPoint(x: rect.minX + 4, y: rect.minY + 4) }
        let box = NSRect(origin: origin, size: boxSize)

        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()

        let textOrigin = NSPoint(x: box.minX + padding, y: box.minY + padding / 2)
        (text as NSString).draw(at: textOrigin, withAttributes: attributes)
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(a.x - b.x),
               height: abs(a.y - b.y))
    }
}
