import AppKit

/// Live preview of the stitched-so-far long image, shown as a clean floating
/// thumbnail on the LEFT edge of the screen (no background box, no buttons).
final class LongCaptureHUD: NSPanel {

    private let preview = NSImageView()
    /// Capture region (screen-local, bottom-left, points) and its screen, used
    /// to keep the preview pinned just left of the shot and sized to fit.
    private var region: CGRect = .zero
    private weak var targetScreen: NSScreen?
    /// Explicit size constraints so the image's intrinsic (pixel) size never
    /// drives the window — we set the point size ourselves.
    private var widthC: NSLayoutConstraint!
    private var heightC: NSLayoutConstraint!

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 300),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .screenSaver
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignTop
        preview.wantsLayer = true
        preview.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(preview)
        widthC = preview.widthAnchor.constraint(equalToConstant: 220)
        heightC = preview.heightAnchor.constraint(equalToConstant: 300)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            widthC, heightC
        ])
        contentView = content
    }

    /// Pin just left of the capture region on the given screen.
    func present(region: CGRect, on screen: NSScreen) {
        self.region = region
        self.targetScreen = screen
        orderFrontRegardless()
    }

    func updatePreview(_ image: CGImage) {
        preview.image = NSImage(cgImage: image,
                                size: NSSize(width: image.width, height: image.height))
        layoutPreview(imageW: CGFloat(image.width), imageH: CGFloat(image.height))
    }

    /// Size the preview so its WIDTH stays between 5% and 15% of the screen
    /// width, keep the image's aspect ratio, and cap the height at 50% of the
    /// screen height. Pin it 20 px to the left of the capture region.
    ///
    /// Sizing is display-scale independent (derived from points + aspect ratio),
    /// so it looks the same on a 2x built-in Retina display and a 1x monitor.
    private func layoutPreview(imageW: CGFloat, imageH: CGFloat) {
        guard let screen = targetScreen,
              imageW > 0, imageH > 0, region.width > 0 else { return }
        let maxW = screen.frame.width * 0.15
        let minW = screen.frame.width * 0.05
        let maxH = screen.visibleFrame.height * 0.5
        let aspectWH = imageW / imageH

        // Width is the primary control, clamped to [5%, 15%] of the screen.
        var displayW = min(max(region.width, minW), maxW)
        var displayH = displayW / aspectWH
        // Very long shots would overflow the height cap — respect it, keeping
        // the aspect ratio (width then narrows accordingly).
        if displayH > maxH {
            displayH = maxH
            displayW = displayH * aspectWH
        }
        widthC.constant = displayW
        heightC.constant = displayH
        setContentSize(NSSize(width: displayW, height: displayH))

        let regionLeftGlobal = screen.frame.minX + region.minX
        let regionTopGlobal = screen.frame.minY + region.maxY
        var x = regionLeftGlobal - 20 - displayW
        x = max(screen.visibleFrame.minX + 4, x)
        let y = regionTopGlobal - displayH
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    override var canBecomeKey: Bool { false }
}
/// Bottom-center action bar for the long capture: shows captured height and
/// the 取消 / 完成 controls, styled like the editor's floating pill toolbar.
final class LongCaptureBar: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let label = NSTextField(labelWithString: "已截取 0 px")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 52),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .screenSaver
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        // No window shadow (it renders as a black rectangular edge on a clear
        // borderless panel); the pill draws its own soft rounded shadow.
        hasShadow = false

        label.font = .systemFont(ofSize: 12, weight: .medium)
        let hint = NSTextField(labelWithString: "滚动页面，完成后点 ✓")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let cancel = PillIconButton(frame: .zero)
        cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消")
        cancel.contentTintColor = .systemRed
        cancel.toolTip = "取消 (ESC)"
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelTapped)

        let done = PillIconButton(frame: .zero)
        done.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "完成")
        done.contentTintColor = .systemGreen
        done.toolTip = "完成"
        done.keyEquivalent = "\r"
        done.target = self
        done.action = #selector(doneTapped)

        let texts = NSStackView(views: [label, hint])
        texts.orientation = .vertical
        texts.spacing = 1
        texts.alignment = .leading

        let stack = NSStackView(views: [texts, PillSeparator(), cancel, done])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pill = PillView(cornerRadius: 10, bordered: false)
        let host = pill.contentContainer
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -7)
        ])

        pill.translatesAutoresizingMaskIntoConstraints = false
        let content = PassthroughView()
        content.addSubview(pill)
        // Inset the pill so its own soft (rounded) layer shadow has room to show
        // — the window itself casts no shadow, so there's no black frame edge.
        // Generous margin (≈ shadow spread) so the soft shadow tail fully fades
        // inside the window instead of being clipped into a hard edge.
        let pad: CGFloat = 44
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            pill.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            pill.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            pill.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad)
        ])
        contentView = content
    }

    /// Just below the capture region (or above if there's no room) — same as the
    /// normal screenshot toolbar, rather than pinned to the screen bottom.
    func present(region: CGRect, on screen: NSScreen) {
        contentView?.layoutSubtreeIfNeeded()
        if let fitting = contentView?.fittingSize, fitting.width > 0 {
            setContentSize(fitting)
        }
        let s = frame.size
        let vf = screen.visibleFrame
        let midX = screen.frame.minX + region.minX + region.width / 2
        let regionBottom = screen.frame.minY + region.minY
        let regionTop = screen.frame.minY + region.maxY
        let gap: CGFloat = 10

        var x = midX - s.width / 2
        x = min(max(vf.minX + 4, x), vf.maxX - s.width - 4)
        var y = regionBottom - gap - s.height          // below the region
        if y < vf.minY + 4 { y = regionTop + gap }      // flip above if needed
        y = min(max(vf.minY + 4, y), vf.maxY - s.height - 4)
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        orderFrontRegardless()
    }

    func update(heightPx: Int) {
        label.stringValue = "已截取 \(heightPx) px"
    }

    override var canBecomeKey: Bool { true }

    @objc private func doneTapped() { onDone?() }
    @objc private func cancelTapped() { onCancel?() }
}

/// Container whose transparent margins are click-through (only its subviews,
/// e.g. the pill, are interactive) so the shadow padding doesn't swallow clicks.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

