import AppKit

/// A thin, click-through border drawn around the long-capture region so the
/// user can see exactly what area is being captured while they scroll.
///
/// It sits above normal windows but ignores mouse events, so scrolling lands on
/// the target underneath. Being a SnapFlow window, it is excluded from the shot
/// by ScreenCapturer's content filter.
final class RegionFrameWindow: NSWindow {

    init(region: CGRect, screen: NSScreen) {
        // `region` is screen-local (bottom-left origin, points); offset by the
        // screen origin to get the global frame.
        let global = CGRect(x: screen.frame.origin.x + region.minX,
                            y: screen.frame.origin.y + region.minY,
                            width: region.width,
                            height: region.height)
        super.init(contentRect: global,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        contentView = RegionFrameView(frame: NSRect(origin: .zero, size: global.size))
    }
}

/// Draws just a dashed rectangle around the edge of its bounds.
private final class RegionFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}
