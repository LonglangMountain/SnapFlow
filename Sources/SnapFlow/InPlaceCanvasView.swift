import AppKit

/// Displays the frozen capture + annotations for the in-place editor.
///
/// Uses an NSImageView-based approach (image set from `EditorViewModel.render()`)
/// instead of a custom flipped `drawRect`. Inside the capture overlay's
/// layer-backed window a flipped drawRect view renders upside-down; NSImageView
/// always draws the bitmap upright and crisp, sidestepping that entirely.
final class InPlaceCanvasView: NSImageView {

    private weak var editor: EditorViewModel?
    /// Image pixels per view point (captured-pixel size ÷ on-screen point size).
    private var pxPerPoint: CGFloat = 1

    private var textField: NSTextField?
    private var pendingTextPoint: CGPoint?
    /// Last cursor position (image space) while dragging with the select tool.
    private var lastMovePoint: CGPoint?
    /// True while dragging a resize handle.
    private var resizing = false
    /// Whole-selection drag (in select mode, pressing empty area).
    private var regionMoving = false
    private var regionLastWindow: NSPoint = .zero

    /// Called to move the whole capture selection while dragging in select mode.
    var onMoveRegionBegan: (() -> Void)?
    var onMoveRegionDragged: ((CGSize) -> Void)?
    var onMoveRegionEnded: (() -> Void)?

    /// Four-way "move" cursor for dragging the selection. Drawn from an SF
    /// Symbol with a white halo so it stays visible on any background (avoids
    /// private AppKit cursors, which don't exist on all macOS versions).
    static let moveCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                   accessibilityDescription: "移动")?
            .withSymbolConfiguration(config) else {
            return .openHand
        }
        let pad: CGFloat = 3
        let size = NSSize(width: symbol.size.width + pad * 2, height: symbol.size.height + pad * 2)
        let rect = NSRect(x: pad, y: pad, width: symbol.size.width, height: symbol.size.height)
        let image = NSImage(size: size)
        image.lockFocus()
        let white = tinted(symbol, .white)
        for dx in [-1.0, 0, 1.0] where true {
            for dy in [-1.0, 0, 1.0] {
                white.draw(in: rect.offsetBy(dx: dx, dy: dy))
            }
        }
        tinted(symbol, .black).draw(in: rect)
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    override var acceptsFirstResponder: Bool { true }

    func configure(editor: EditorViewModel, pxPerPoint: CGFloat) {
        self.editor = editor
        self.pxPerPoint = pxPerPoint
        // Proportional (not per-axis) scaling: the capture and the canvas share
        // the selection's aspect ratio, so this is 1:1 and avoids the subtle
        // stretch-softening that .scaleAxesIndependently can introduce.
        imageScaling = .scaleProportionallyUpOrDown
        imageFrameStyle = .none
        // No rounded-corner masking layer: masksToBounds forces an off-screen
        // rasterization whose contentsScale can drop to 1x, softening the image
        // on Retina/HiDPI screens. Draw directly for a crisp 1:1 result.
        refresh()
    }

    func refresh() {
        guard let editor, let cg = editor.render(forExport: false) else { return }
        // Size the NSImage in POINTS (pixels ÷ backing scale) so the full-res
        // CGImage backs a point-sized image — the image view then renders it at
        // native device pixels instead of upscaling a point-sized bitmap.
        let scale = pxPerPoint > 0 ? pxPerPoint : 1
        let pointSize = NSSize(width: CGFloat(cg.width) / scale,
                               height: CGFloat(cg.height) / scale)
        image = NSImage(cgImage: cg, size: pointSize)
    }

    /// Show a freshly cropped image directly (used for crisp live resize, before
    /// the editor's view-model is rebuilt).
    func showLivePreview(_ cg: CGImage) {
        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // View is non-flipped (NSImageView default): invert Y to map to the
    // top-left-origin image pixel space annotations are stored in.
    private func imagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * pxPerPoint, y: (bounds.height - p.y) * pxPerPoint)
    }
    // PLACEHOLDER_MOUSE

    override func mouseDown(with event: NSEvent) {
        commitTextIfNeeded()
        guard let editor else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = imagePoint(viewPoint)
        // Grab a resize handle on the current selection first.
        if let handle = editor.resizeHandleHit(at: point) {
            editor.beginResize(handle)
            resizing = true
            lastMovePoint = point
            return
        }
        // Direct manipulation: pressing on an existing annotation grabs it to
        // move — no need to switch to the select tool first.
        if editor.selectAnnotation(at: point) {
            editor.beginMove()
            lastMovePoint = point
            NSCursor.closedHand.set()
            return
        }
        switch editor.currentTool {
        case .select:
            // No tool selected: drag the whole capture region to reposition it.
            regionMoving = true
            regionLastWindow = event.locationInWindow
            Self.moveCursor.set()
            onMoveRegionBegan?()
        case .text: beginTextEntry(atView: viewPoint, imagePoint: point)
        case .number: editor.addNumber(at: point)
        default: editor.beginDraft(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let editor else { return }
        if regionMoving {
            let now = event.locationInWindow
            onMoveRegionDragged?(CGSize(width: now.x - regionLastWindow.x,
                                        height: now.y - regionLastWindow.y))
            regionLastWindow = now
            return
        }
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        if resizing {
            editor.updateResize(to: point)
            return
        }
        if let last = lastMovePoint, editor.selectedID != nil {
            editor.moveSelected(by: CGPoint(x: point.x - last.x, y: point.y - last.y))
            lastMovePoint = point
            return
        }
        guard editor.draftAnnotation != nil else { return }
        editor.extendDraft(to: point, constrained: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        guard let editor else { return }
        if regionMoving {
            regionMoving = false
            Self.moveCursor.set()
            onMoveRegionEnded?()
            return
        }
        if resizing {
            resizing = false
            lastMovePoint = nil
            editor.endResize()
            return
        }
        if lastMovePoint != nil {
            lastMovePoint = nil
            NSCursor.openHand.set()
            return
        }
        editor.commitDraft()
    }

    // Hover to select: whatever the cursor rests on becomes movable/deletable.
    override func mouseMoved(with event: NSEvent) {
        guard let editor, editor.draftAnnotation == nil, lastMovePoint == nil else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        // As first responder the canvas receives mouse-moved events for the whole
        // window; ignore ones outside its own bounds so the move cursor doesn't
        // linger over the toolbar.
        guard bounds.contains(viewPoint) else { return }
        let point = imagePoint(viewPoint)
        // Over a resize handle of the current selection: keep it and show a
        // crosshair, don't let hover deselect.
        if editor.selectedID != nil, editor.resizeHandleHit(at: point) != nil {
            NSCursor.crosshair.set()
            return
        }
        editor.hover(at: point)
        if editor.selectedID != nil {
            NSCursor.openHand.set()            // hovering an annotation (movable)
        } else if editor.currentTool == .select {
            Self.moveCursor.set()              // empty area — drag to move the region
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard lastMovePoint == nil else { return }
        editor?.deselect()
        NSCursor.arrow.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func keyDown(with event: NSEvent) {
        // Delete / Backspace removes the selected (hovered) annotation.
        if event.keyCode == 51 || event.keyCode == 117 {
            editor?.deleteSelected()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Text entry

    private func beginTextEntry(atView viewPoint: CGPoint, imagePoint: CGPoint) {
        guard let editor else { return }
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y - 12,
                                              width: 200, height: 24))
        field.font = .systemFont(ofSize: editor.currentStyle.fontSize / pxPerPoint, weight: .semibold)
        field.textColor = editor.currentStyle.color
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "输入文字"
        field.target = self
        field.action = #selector(commitText)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        pendingTextPoint = imagePoint
    }

    @objc private func commitText() { commitTextIfNeeded() }

    private func commitTextIfNeeded() {
        guard let field = textField, let point = pendingTextPoint else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        textField = nil
        pendingTextPoint = nil
        if !text.isEmpty { editor?.commitText(text, at: point) }
    }
}
