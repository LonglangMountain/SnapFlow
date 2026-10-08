import AppKit

/// Reports the outcome of an area selection back to the CaptureManager.
protocol CaptureOverlayDelegate: AnyObject {
    /// `rect` is in the screen's local coordinate space (bottom-left origin,
    /// points), i.e. the overlay view's coordinates.
    func overlay(_ overlay: CaptureOverlayWindow, didSelect rect: CGRect, on screen: NSScreen)
    func overlayDidCancel(_ overlay: CaptureOverlayWindow)
}

/// Transparent full-screen window that hosts the selection UI.
///
/// Configured per the design doc: screenSaver level (above normal windows),
/// borderless, clear background. It must be able to become key so it can
/// receive ESC / Enter key events.
final class CaptureOverlayWindow: NSWindow {

    weak var overlayDelegate: CaptureOverlayDelegate?
    private let targetScreen: NSScreen

    init(screen: NSScreen) {
        self.targetScreen = screen
        // Use the 4-arg designated initializer. The 5-arg `screen:` convenience
        // initializer funnels back through this designated init via ObjC
        // dispatch, which would hit Swift's "unimplemented initializer" trap
        // because this subclass adds a stored property and doesn't override it.
        // contentRect is in global screen coordinates, so screen.frame positions
        // the borderless window on the correct display.
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true

        let view = CaptureOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onComplete = { [weak self] rect in
            guard let self else { return }
            self.overlayDelegate?.overlay(self, didSelect: rect, on: self.targetScreen)
        }
        view.onCancel = { [weak self] in
            guard let self else { return }
            self.overlayDelegate?.overlayDidCancel(self)
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Freeze the committed selection and turn the overlay into a passive
    /// dim + border backdrop for the in-place editor.
    func enterEditing() {
        (contentView as? CaptureOverlayView)?.enterEditing()
    }

    /// Keep the dim + border in sync while the editor resizes the selection.
    func updateSelection(_ rect: CGRect) {
        (contentView as? CaptureOverlayView)?.updateSelectionRect(rect)
    }
}
