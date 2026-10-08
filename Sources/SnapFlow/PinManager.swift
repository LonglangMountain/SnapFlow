import AppKit

/// Always-on-top, draggable, resizable floating window that "pins" a
/// screenshot on top of everything else (design §20).
final class FloatingImageWindow: NSPanel {

    private let cgImage: CGImage
    /// Transparent margin around the image (≈ shadow spread) so the soft shadow
    /// fully fades inside the window rather than being clipped to a hard edge.
    static let shadowPad: CGFloat = 52

    init(image: CGImage, preferredFrame: CGRect? = nil, displayScale: CGFloat = 2) {
        cgImage = image
        let imageSize: NSSize
        if let pf = preferredFrame, pf.width >= 20, pf.height >= 20 {
            // Pin in place: size the view to the bitmap's own pixels ÷ scale so
            // points map to pixels 1:1. Using the selection's point size instead
            // let a sub-pixel aspect mismatch (from the rounded capture crop)
            // feed `resizeAspect` a tiny resample — the "sometimes blurry" pin.
            let s = max(1, displayScale)
            imageSize = NSSize(width: CGFloat(image.width) / s,
                               height: CGFloat(image.height) / s)
        } else {
            let maxSide: CGFloat = 600
            let pixel = CGSize(width: image.width, height: image.height)
            let scale = min(1, min(maxSide / pixel.width, maxSide / pixel.height))
            imageSize = NSSize(width: max(80, pixel.width * scale),
                               height: max(60, pixel.height * scale))
        }

        let pad = Self.shadowPad
        let contentSize = NSSize(width: imageSize.width + pad * 2,
                                 height: imageSize.height + pad * 2)

        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.nonactivatingPanel, .resizable, .borderless],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false      // custom soft layer shadow instead (no black edge)
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The rounded image (clipped). A plain NSImageView swallows mouse-down,
        // so use a view that starts a window drag itself.
        let view = PinDragView(frame: NSRect(x: pad, y: pad,
                                             width: imageSize.width, height: imageSize.height))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsScale = max(1, displayScale)
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "复制", action: #selector(copyImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "关闭", action: #selector(closePin), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        view.menu = menu

        // Close button in the top-right corner, revealed on hover.
        let btn: CGFloat = 26
        let close = NSButton(frame: NSRect(x: imageSize.width - btn - 6,
                                           y: imageSize.height - btn - 6,
                                           width: btn, height: btn))
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(symbolConfig)
        close.imagePosition = .imageOnly
        close.isBordered = false
        close.contentTintColor = .white
        close.toolTip = "关闭"
        close.target = self
        close.action = #selector(closePin)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.isHidden = true
        close.wantsLayer = true
        close.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        close.layer?.cornerRadius = btn / 2
        close.layer?.masksToBounds = true
        view.addSubview(close)
        view.closeButton = close

        // Outer, unclipped view that carries the soft drop shadow (shaped to the
        // rounded image via shadowPath, updated on resize).
        let root = PinRootView(frame: NSRect(origin: .zero, size: contentSize))
        root.wantsLayer = true
        root.layer?.masksToBounds = false
        root.layer?.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        root.layer?.shadowOpacity = 1
        root.layer?.shadowRadius = 22
        root.layer?.shadowOffset = CGSize(width: 0, height: -3)
        root.shadowTarget = view
        root.addSubview(view)
        contentView = root
    }

    override var canBecomeKey: Bool { true }

    @objc private func copyImage() { ImageSaver.copyToClipboard(cgImage) }
    @objc private func closePin() { close() }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == 53 { // ESC closes the pin
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Outer container that draws the soft drop shadow, shaped to the rounded image
/// via a shadowPath kept in sync on resize.
private final class PinRootView: NSView {
    weak var shadowTarget: NSView?

    override func layout() {
        super.layout()
        guard let target = shadowTarget else { return }
        layer?.shadowPath = CGPath(roundedRect: target.frame,
                                   cornerWidth: 6, cornerHeight: 6, transform: nil)
    }

    // Let clicks in the transparent shadow margin pass through to whatever is
    // behind the pin, instead of the invisible padding swallowing them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Content view of a pin: shows the image via its layer and drags the whole
/// window when clicked anywhere on it. Reveals the close button on hover.
private final class PinDragView: NSView {
    weak var closeButton: NSButton?

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton?.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton?.isHidden = true }
}

/// Retains floating pins and cascades their positions.
final class PinManager: NSObject, NSWindowDelegate {

    private var windows: [FloatingImageWindow] = []
    private var cascade: CGFloat = 0

    /// Window IDs of the currently pinned screenshots (so a new capture can
    /// include them instead of excluding all of SnapFlow's windows).
    var pinnedWindowIDs: [CGWindowID] {
        windows.map { CGWindowID($0.windowNumber) }
    }

    func pin(_ image: CGImage, at rect: CGRect? = nil, on screen: NSScreen?) {
        let scale = (screen ?? NSScreen.main)?.backingScaleFactor ?? 2
        let window = FloatingImageWindow(image: image, preferredFrame: rect, displayScale: scale)
        window.delegate = self

        // Snap to WHOLE POINTS: a borderless NSWindow is placed on a whole-point
        // origin anyway, so handing it a half-point value just gets rounded —
        // which shifts the pin a pixel and makes its layer resample (soft). The
        // capture is already snapped to whole points, so this keeps the pin
        // pixel-exact and lined up with where the shot was taken.
        func snap(_ v: CGFloat) -> CGFloat { v.rounded() }

        if let rect {
            // Pin exactly where the shot was taken; offset by the shadow padding
            // so the image (not the padded window) lands on the selection.
            let pad = FloatingImageWindow.shadowPad
            window.setFrameOrigin(NSPoint(x: snap(rect.minX - pad), y: snap(rect.minY - pad)))
        } else if let screen = screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(x: snap(visible.maxX - window.frame.width - 40 - cascade),
                                 y: snap(visible.maxY - window.frame.height - 40 - cascade))
            window.setFrameOrigin(origin)
            cascade = cascade >= 120 ? 0 : cascade + 30
        }

        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? FloatingImageWindow else { return }
        windows.removeAll { $0 === window }
    }
}
