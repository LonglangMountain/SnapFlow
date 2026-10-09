import AppKit
import CoreImage

/// Tools selectable in the editor toolbar (design §15).
enum EditorTool {
    case select, rectangle, ellipse, arrow, line, pen, text, number, mosaic

    var annotationType: AnnotationType? {
        switch self {
        case .select: return nil
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .line: return .line
        case .pen: return .pen
        case .text: return .text
        case .number: return .number
        case .mosaic: return .mosaic
        }
    }
}

/// Corner grips shown on a selected annotation for resizing.
enum ResizeHandle { case topLeft, topRight, bottomLeft, bottomRight }

/// Owns the editor's document state: the base image, the annotation list, the
/// in-progress draft, and a snapshot-based undo/redo stack (design §16/§17).
final class EditorViewModel {

    let baseImage: NSImage
    let baseCG: CGImage
    let imageSize: CGSize
    lazy var pixelated: NSImage? = makePixelated()

    weak var canvas: EditorCanvasView?
    var onChange: (() -> Void)?

    var currentTool: EditorTool = .rectangle
    var currentStyle = AnnotationStyle()

    private(set) var annotations: [Annotation] = []
    private(set) var draftAnnotation: Annotation?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var numberCounter = 0

    /// The currently selected annotation (select/move tool). Its highlight is
    /// shown only in the on-screen preview, never in the exported image.
    private(set) var selectedID: UUID?
    /// Whether the in-progress drag has already pushed an undo snapshot.
    private var movePushedUndo = false

    // Resize drag state (snapshotted at the start so each move is absolute).
    private var resizeHandle: ResizeHandle?
    private var resizeOriginalPoints: [CGPoint]?
    private var resizeOriginalFrame: CGRect = .zero
    private var resizeOriginalFontSize: CGFloat = 0
    private var resizePushedUndo = false

    init(cgImage: CGImage) {
        baseCG = cgImage
        imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        baseImage = NSImage(cgImage: cgImage, size: imageSize)
    }

    // MARK: - Draft lifecycle

    func beginDraft(at point: CGPoint) {
        guard let type = currentTool.annotationType else { return }
        draftAnnotation = Annotation(type: type, points: [point, point], style: currentStyle)
        redraw()
    }

    func extendDraft(to point: CGPoint, constrained: Bool = false) {
        guard var draft = draftAnnotation else { return }
        if draft.type == .pen {
            if constrained {
                // Hold Shift with the pen: draw a straight line from the stroke's
                // start point to the cursor (a 2-point polyline renders as a line).
                let start = draft.points.first ?? point
                draft.points = [start, point]
            } else {
                draft.points.append(point)
            }
        } else {
            let start = draft.points.first ?? point
            let end = constrained ? Self.constrain(draft.type, from: start, to: point) : point
            draft.points = [start, end]
        }
        draftAnnotation = draft
        redraw()
    }

    /// Shift-constrain a shape: squares/circles for boxes, 45° steps for lines.
    static func constrain(_ type: AnnotationType, from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        switch type {
        case .rectangle, .ellipse, .mosaic:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -side : side),
                           y: a.y + (dy < 0 ? -side : side))
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let snapped = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: a.x + cos(snapped) * length,
                           y: a.y + sin(snapped) * length)
        default:
            return b
        }
    }

    func commitDraft() {
        guard let draft = draftAnnotation else { return }
        draftAnnotation = nil
        // Discard trivial (zero-size) shapes.
        if draft.type != .pen, draft.frame.width < 2, draft.frame.height < 2 {
            redraw()
            return
        }
        pushUndo()
        annotations.append(draft)
        redraw()
    }

    func addNumber(at point: CGPoint) {
        pushUndo()
        numberCounter += 1
        annotations.append(Annotation(type: .number, points: [point],
                                       number: numberCounter, style: currentStyle))
        redraw()
    }

    func commitText(_ text: String, at point: CGPoint) {
        pushUndo()
        annotations.append(Annotation(type: .text, points: [point],
                                       text: text, style: currentStyle))
        redraw()
    }

    // MARK: - Selection & move (select tool)

    /// Selects the topmost annotation under `point`; clears selection on a miss.
    /// Returns true if something was hit.
    @discardableResult
    func selectAnnotation(at point: CGPoint) -> Bool {
        if let index = hitIndex(at: point) {
            selectedID = annotations[index].id
            redraw()
            return true
        }
        if selectedID != nil { selectedID = nil }
        redraw()
        return false
    }

    func deselect() {
        guard selectedID != nil else { return }
        selectedID = nil
        redraw()
    }

    /// Hover-select: highlight the topmost annotation under the cursor (or clear
    /// the highlight on a miss). Only redraws when the target actually changes,
    /// so it is cheap to call on every mouse-moved event.
    func hover(at point: CGPoint) {
        let id = hitIndex(at: point).map { annotations[$0].id }
        guard id != selectedID else { return }
        selectedID = id
        redraw()
    }

    /// Whether an annotation sits under `point` (used for direct manipulation).
    func annotationExists(at point: CGPoint) -> Bool { hitIndex(at: point) != nil }

    /// Call once at the start of a drag so the whole move is a single undo step.
    func beginMove() { movePushedUndo = false }

    /// Translates the selected annotation by `delta` (image-pixel space).
    func moveSelected(by delta: CGPoint) {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if !movePushedUndo { pushUndo(); movePushedUndo = true }
        annotations[index].points = annotations[index].points.map {
            CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
        }
        redraw()
    }

    /// Deletes the selected annotation (Delete / Backspace).
    func deleteSelected() {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        annotations.remove(at: index)
        selectedID = nil
        redraw()
    }

    /// Bounding box of the selection in image-pixel space, if any.
    var selectedFrame: CGRect? {
        guard let id = selectedID,
              let annotation = annotations.first(where: { $0.id == id }) else { return nil }
        return Self.boundingBox(of: annotation)
    }

    private func hitIndex(at point: CGPoint) -> Int? {
        // Topmost (last drawn) first.
        for index in annotations.indices.reversed()
        where Self.hitTest(annotations[index], point: point) {
            return index
        }
        return nil
    }

    // MARK: - Resize (corner handles)

    /// The selection outline rect (bounding box padded a little).
    static func selectionBox(_ frame: CGRect) -> CGRect { frame.insetBy(dx: -5, dy: -5) }

    static func corner(_ handle: ResizeHandle, of box: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: box.minX, y: box.minY)
        case .topRight: return CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeft: return CGPoint(x: box.minX, y: box.maxY)
        case .bottomRight: return CGPoint(x: box.maxX, y: box.maxY)
        }
    }

    /// Returns the resize handle under `point` for the current selection, if any.
    func resizeHandleHit(at point: CGPoint) -> ResizeHandle? {
        guard let frame = selectedFrame else { return nil }
        let box = Self.selectionBox(frame)
        let tol: CGFloat = 18
        let all: [ResizeHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        return all.first { hypot(point.x - Self.corner($0, of: box).x,
                                 point.y - Self.corner($0, of: box).y) <= tol }
    }

    func beginResize(_ handle: ResizeHandle) {
        guard let id = selectedID,
              let a = annotations.first(where: { $0.id == id }) else { return }
        resizeHandle = handle
        resizeOriginalPoints = a.points
        resizeOriginalFrame = Self.boundingBox(of: a)
        resizeOriginalFontSize = a.style.fontSize
        resizePushedUndo = false
    }

    /// Drag a corner: the opposite corner stays anchored; geometry scales to fit.
    func updateResize(to point: CGPoint) {
        guard let handle = resizeHandle,
              let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              let orig = resizeOriginalPoints else { return }
        if !resizePushedUndo { pushUndo(); resizePushedUndo = true }

        let f = resizeOriginalFrame
        // Opposite corner of the ORIGINAL frame is the fixed anchor.
        let opposite: ResizeHandle
        switch handle {
        case .topLeft: opposite = .bottomRight
        case .topRight: opposite = .bottomLeft
        case .bottomLeft: opposite = .topRight
        case .bottomRight: opposite = .topLeft
        }
        let anchor = Self.corner(opposite, of: f)
        let newFrame = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                              width: max(2, abs(point.x - anchor.x)),
                              height: max(2, abs(point.y - anchor.y)))

        switch annotations[index].type {
        case .text, .number:
            // Point annotations scale their font size, not their geometry.
            let ratio = max(newFrame.width / max(f.width, 1),
                            newFrame.height / max(f.height, 1))
            annotations[index].style.fontSize = max(8, resizeOriginalFontSize * ratio)
        default:
            // Remap each original point from the original frame into the new one.
            annotations[index].points = orig.map { p in
                let nx = f.width > 0 ? (p.x - f.minX) / f.width : 0
                let ny = f.height > 0 ? (p.y - f.minY) / f.height : 0
                return CGPoint(x: newFrame.minX + nx * newFrame.width,
                               y: newFrame.minY + ny * newFrame.height)
            }
        }
        redraw()
    }

    func endResize() {
        resizeHandle = nil
        resizeOriginalPoints = nil
    }

    // MARK: - Undo / redo (design §17)

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        redraw()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        redraw()
    }

    private func pushUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    private func redraw() {
        canvas?.needsDisplay = true
        onChange?()
    }

    // MARK: - Export

    /// Flattens the base image + annotations into a full-resolution CGImage.
    /// - Parameter forExport: when true (save/copy/pin) the selection highlight
    ///   is omitted; the live preview passes false to show it.
    func render(forExport: Bool = true) -> CGImage? {
        let w = Int(imageSize.width)
        let h = Int(imageSize.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Mirror the on-screen canvas exactly: a flipped NSView applies BOTH a
        // top-left CTM *and* reports isFlipped=true. The old code did the CTM
        // flip but passed flipped:false, so NSImage.draw double-flipped the base
        // upside-down. Do the CTM flip AND pass flipped:true.
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        // Draw the base capture. NSImage.draw respects the flipped
        // NSGraphicsContext and lands upright; drawing the raw CGImage via
        // ctx.draw() instead ignores that and renders it upside-down.
        baseImage.draw(in: CGRect(origin: .zero, size: imageSize))
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, pixelated: pixelated)
        }
        // Include the in-progress draft so live previews match the final image.
        if let draft = draftAnnotation {
            AnnotationRenderer.draw(draft, pixelated: pixelated)
        }
        if !forExport, let box = selectedFrame {
            Self.strokeSelection(box)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Dashed accent outline plus corner grips to indicate the selected annotation.
    static func strokeSelection(_ frame: CGRect) {
        let box = selectionBox(frame)
        let path = NSBezierPath(rect: box)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        // Corner grips (solid white square with an accent border).
        let side: CGFloat = 12
        for handle in [ResizeHandle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let c = corner(handle, of: box)
            let r = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            NSColor.white.setFill()
            NSBezierPath(rect: r).fill()
            let border = NSBezierPath(rect: r)
            border.lineWidth = 1
            NSColor.controlAccentColor.setStroke()
            border.stroke()
        }
    }

    // MARK: - Hit testing

    static func boundingBox(of a: Annotation) -> CGRect {
        switch a.type {
        case .number:
            let r = a.style.fontSize * 0.8
            let c = a.points.first ?? .zero
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case .text:
            let c = a.points.first ?? .zero
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: a.style.fontSize, weight: .semibold)
            ]
            let size = (a.text as NSString).size(withAttributes: attrs)
            return CGRect(x: c.x, y: c.y, width: max(size.width, 12), height: max(size.height, 12))
        case .pen, .line, .arrow:
            return polylineBounds(a.points).insetBy(dx: -a.style.lineWidth, dy: -a.style.lineWidth)
        default:
            return a.frame
        }
    }

    static func hitTest(_ a: Annotation, point p: CGPoint) -> Bool {
        let tol = max(8, a.style.lineWidth + 6)
        switch a.type {
        case .rectangle, .ellipse, .mosaic:
            return a.frame.insetBy(dx: -tol, dy: -tol).contains(p)
        case .line, .arrow:
            return distanceToSegment(p, a.points.first ?? .zero, a.points.last ?? .zero) <= tol
        case .pen:
            guard a.points.count >= 2 else { return false }
            for i in 1..<a.points.count
            where distanceToSegment(p, a.points[i - 1], a.points[i]) <= tol {
                return true
            }
            return false
        case .text, .number:
            return boundingBox(of: a).insetBy(dx: -tol, dy: -tol).contains(p)
        }
    }

    private static func polylineBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    private func makePixelated() -> NSImage? {
        let input = CIImage(cgImage: baseCG)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        let scale = max(8, min(imageSize.width, imageSize.height) / 40)
        filter.setValue(scale, forKey: "inputScale")
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cg, size: imageSize)
    }
}
