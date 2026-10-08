import AppKit

/// Renders the base screenshot plus annotations and turns mouse gestures into
/// annotation edits. Flipped so its coordinate origin is top-left, matching the
/// image pixel space used to store annotations.
///
/// Acts as an NSScrollView document view: its size is the image scaled by
/// `zoom`, and the enclosing scroll view provides panning when zoomed in.
final class EditorCanvasView: NSView {

    weak var editor: EditorViewModel?
    private var textField: NSTextField?
    private var pendingTextPoint: CGPoint?
    /// Last cursor position (image space) while dragging with the select tool.
    private var lastMovePoint: CGPoint?
    /// True while dragging a resize handle.
    private var resizing = false

    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 8

    /// Display scale from image pixels to points. Changing it resizes the view
    /// (so the scroll view gains/loses scrollers) and repaints.
    var zoom: CGFloat = 1 {
        didSet {
            guard zoom != oldValue else { return }
            setFrameSize(documentSize)
            needsDisplay = true
        }
    }

    /// Called after the view zooms itself (pinch gesture) so the owner can sync UI.
    var onZoomChanged: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var documentSize: CGSize {
        guard let size = editor?.imageSize, size.width > 0, size.height > 0 else { return bounds.size }
        return CGSize(width: size.width * zoom, height: size.height * zoom)
    }

    override var intrinsicContentSize: NSSize { documentSize }

    // MARK: - Layout mapping

    private func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        let scale = zoom == 0 ? 1 : zoom
        return CGPoint(x: viewPoint.x / scale, y: viewPoint.y / scale)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        guard let editor else { return }

        NSGraphicsContext.saveGraphicsState()
        let tf = NSAffineTransform()
        tf.scale(by: zoom)
        tf.concat()

        NSGraphicsContext.current?.imageInterpolation = .high
        editor.baseImage.draw(in: CGRect(origin: .zero, size: editor.imageSize))
        for annotation in editor.annotations {
            AnnotationRenderer.draw(annotation, pixelated: editor.pixelated)
        }
        if let draft = editor.draftAnnotation {
            AnnotationRenderer.draw(draft, pixelated: editor.pixelated)
        }
        if let box = editor.selectedFrame {
            EditorViewModel.strokeSelection(box)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Zoom gesture

    override func magnify(with event: NSEvent) {
        let next = min(EditorCanvasView.maxZoom,
                       max(EditorCanvasView.minZoom, zoom * (1 + event.magnification)))
        zoom = next
        onZoomChanged?(next)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextFieldIfNeeded()
        guard let editor else { return }
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))

        // Grab a resize handle on the current selection first.
        if let handle = editor.resizeHandleHit(at: point) {
            editor.beginResize(handle)
            resizing = true
            lastMovePoint = point
            return
        }
        // Direct manipulation: pressing on an existing annotation grabs it to
        // move, regardless of the active tool.
        if editor.selectAnnotation(at: point) {
            editor.beginMove()
            lastMovePoint = point
            NSCursor.closedHand.set()
            return
        }

        switch editor.currentTool {
        case .select:
            break
        case .text:
            beginTextEntry(atView: convert(event.locationInWindow, from: nil), imagePoint: point)
        case .number:
            editor.addNumber(at: point)
        default:
            editor.beginDraft(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let editor else { return }
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))
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

    override func mouseMoved(with event: NSEvent) {
        guard let editor, editor.draftAnnotation == nil, lastMovePoint == nil else { return }
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))
        if editor.selectedID != nil, editor.resizeHandleHit(at: point) != nil {
            NSCursor.crosshair.set()
            return
        }
        editor.hover(at: point)
        (editor.selectedID != nil ? NSCursor.openHand : NSCursor.arrow).set()
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
        field.font = .systemFont(ofSize: editor.currentStyle.fontSize * zoom, weight: .semibold)
        field.textColor = editor.currentStyle.color
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "输入文字"
        field.target = self
        field.action = #selector(commitTextField)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        pendingTextPoint = imagePoint
    }

    @objc private func commitTextField() {
        commitTextFieldIfNeeded()
    }

    private func commitTextFieldIfNeeded() {
        guard let field = textField, let point = pendingTextPoint else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        textField = nil
        pendingTextPoint = nil
        if !text.isEmpty {
            editor?.commitText(text, at: point)
        }
    }
}
