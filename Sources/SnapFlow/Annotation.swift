import AppKit

/// Annotation tools offered by the editor (design §15 toolbar).
enum AnnotationType {
    case rectangle
    case ellipse
    case arrow
    case line
    case pen
    case text
    case number
    case mosaic
}

/// Visual style shared by annotations (design §16).
struct AnnotationStyle {
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var fontSize: CGFloat = 28
}

/// A single non-destructive annotation. Geometry is stored in the base image's
/// pixel coordinate space (top-left origin) so it renders identically on screen
/// and on export (design §16).
struct Annotation {
    let id = UUID()
    let type: AnnotationType
    /// Semantics vary by type: shapes/line/arrow use [start, end]; pen uses the
    /// full stroke; text/number use [anchor].
    var points: [CGPoint]
    var text: String = ""
    var number: Int = 0
    var style: AnnotationStyle

    /// Normalized rect spanning the first two points.
    var frame: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x),
                      y: min(a.y, b.y),
                      width: abs(a.x - b.x),
                      height: abs(a.y - b.y))
    }
}

/// Draws annotations into the current graphics context, which callers must set
/// up with a top-left origin (flipped) coordinate space in image pixels.
enum AnnotationRenderer {

    /// - Parameter pixelated: a pre-pixelated copy of the base image (sized in
    ///   image pixels), drawn clipped to the annotation frame for mosaics.
    static func draw(_ annotation: Annotation, pixelated: NSImage?) {
        let style = annotation.style
        style.color.setStroke()
        style.color.setFill()

        switch annotation.type {
        case .rectangle:
            let path = NSBezierPath(rect: annotation.frame)
            path.lineWidth = style.lineWidth
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: annotation.frame)
            path.lineWidth = style.lineWidth
            path.stroke()

        case .line:
            strokePolyline(annotation.points, width: style.lineWidth)

        case .arrow:
            drawArrow(from: annotation.points.first ?? .zero,
                      to: annotation.points.last ?? .zero,
                      width: style.lineWidth)

        case .pen:
            strokePolyline(annotation.points, width: style.lineWidth)

        case .text:
            drawText(annotation)

        case .number:
            drawNumber(annotation)

        case .mosaic:
            drawMosaic(annotation, pixelated: pixelated)
        }
    }

    private static func strokePolyline(_ points: [CGPoint], width: CGFloat) {
        guard points.count >= 2 else { return }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        path.stroke()
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.move(to: start)
        path.line(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12, width * 3)
        let headAngle = CGFloat.pi / 6
        let left = CGPoint(x: end.x - headLength * cos(angle - headAngle),
                           y: end.y - headLength * sin(angle - headAngle))
        let right = CGPoint(x: end.x - headLength * cos(angle + headAngle),
                            y: end.y - headLength * sin(angle + headAngle))
        path.move(to: end); path.line(to: left)
        path.move(to: end); path.line(to: right)
        path.stroke()
    }

    private static func drawText(_ annotation: Annotation) {
        guard let anchor = annotation.points.first, !annotation.text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .semibold),
            .foregroundColor: annotation.style.color
        ]
        (annotation.text as NSString).draw(at: anchor, withAttributes: attrs)
    }

    private static func drawNumber(_ annotation: Annotation) {
        guard let center = annotation.points.first else { return }
        let radius = annotation.style.fontSize * 0.8
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        annotation.style.color.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let text = "\(annotation.number)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: center.x - size.width / 2,
                                            y: center.y - size.height / 2),
                                withAttributes: attrs)
    }

    private static func drawMosaic(_ annotation: Annotation, pixelated: NSImage?) {
        guard let pixelated else { return }
        let frame = annotation.frame
        guard frame.width >= 1, frame.height >= 1 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame).addClip()
        // Draw the full pixelated image aligned to the base; the clip reveals
        // only the mosaic region.
        pixelated.draw(in: CGRect(origin: .zero, size: pixelated.size))
        NSGraphicsContext.restoreGraphicsState()
    }
}
