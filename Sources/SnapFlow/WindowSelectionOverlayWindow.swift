import AppKit

/// Reports the outcome of a window pick and answers hit-test queries.
protocol WindowSelectionDelegate: AnyObject {
    func windowSelection(_ overlay: WindowSelectionOverlayWindow, didPick window: WindowInfo)
    func windowSelectionDidCancel(_ overlay: WindowSelectionOverlayWindow)
    /// Topmost window under a CoreGraphics global point, or nil.
    func windowSelection(_ overlay: WindowSelectionOverlayWindow,
                         windowAt cgPoint: CGPoint) -> WindowInfo?
}

/// Transparent full-screen window used to pick a window to capture. Same
/// configuration as the area-capture overlay (screenSaver level, borderless,
/// clear), but hosts the hover-to-highlight interaction.
final class WindowSelectionOverlayWindow: NSWindow {

    weak var selectionDelegate: WindowSelectionDelegate?
    private let targetScreen: NSScreen

    init(screen: NSScreen) {
        self.targetScreen = screen
        // Use the 4-arg designated initializer; the 5-arg `screen:` variant
        // re-dispatches through it and hits Swift's unimplemented-initializer
        // trap for this subclass. contentRect (global coords) positions the
        // borderless window on the target display.
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

        let view = WindowSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                       screenOrigin: screen.frame.origin)
        view.hitTest = { [weak self] cgPoint in
            guard let self else { return nil }
            return self.selectionDelegate?.windowSelection(self, windowAt: cgPoint)
        }
        view.onSelect = { [weak self] window in
            guard let self else { return }
            self.selectionDelegate?.windowSelection(self, didPick: window)
        }
        view.onCancel = { [weak self] in
            guard let self else { return }
            self.selectionDelegate?.windowSelectionDidCancel(self)
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
