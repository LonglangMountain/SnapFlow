import AppKit

/// A small custom tooltip — white text on a dark rounded panel — shown on hover.
/// Used for the toolbar icons so the hint matches the dark operation bar (the
/// native macOS tooltip is a light panel with dark text and can't be recoloured).
final class HoverTip {
    static let shared = HoverTip()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?

    private init() {
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .center
    }

    /// Show `text` centered above `view` after a short delay.
    func show(_ text: String, for view: NSView, delay: TimeInterval = 0.1) {
        pending?.cancel()
        guard !text.isEmpty else { hide(); return }
        let item = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, let window = view.window else { return }
            self.present(text, over: view, in: window)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
    }
    // BODY_PLACEHOLDER
    private func present(_ text: String, over view: NSView, in window: NSWindow) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // sizeToFit gives the label's true cell size (incl. text margins) so the
        // content is never clipped.
        label.stringValue = text
        label.sizeToFit()
        let textSize = label.frame.size
        let padX: CGFloat = 4, padY: CGFloat = 4
        let size = NSSize(width: ceil(textSize.width) + padX * 2,
                          height: ceil(textSize.height) + padY * 2)
        panel.setContentSize(size)
        label.setFrameOrigin(NSPoint(x: padX, y: padY))

        let onScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        let vf = (window.screen ?? NSScreen.main)?.visibleFrame
        var x = onScreen.midX - size.width / 2
        // Prefer below the icon (like a normal tooltip); flip above when there
        // isn't room below.
        var y = onScreen.minY - 6 - size.height
        if let vf {
            if y < vf.minY { y = onScreen.maxY + 6 }
            x = min(max(vf.minX + 4, x), vf.maxX - size.width - 4)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 24),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor
        bg.layer?.cornerRadius = 6
        bg.addSubview(label)
        panel.contentView = bg
        return panel
    }
}
