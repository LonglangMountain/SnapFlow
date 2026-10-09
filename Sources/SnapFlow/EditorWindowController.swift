import AppKit

/// Hosts the editor window: a full-bleed canvas with two floating pill bars
/// (tools + actions, then stroke sizes + colour palette) overlaid at the bottom,
/// in the style of Snipaste's annotation bar. Bridges them to the
/// EditorViewModel (design §15).
final class EditorWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let viewModel: EditorViewModel
    private let canvas = EditorCanvasView()
    private let scrollView = NSScrollView()
    private let zoomButton = NSButton(title: "100%", target: nil, action: nil)
    private var zoom: CGFloat = 1
    /// Capture pixels-per-point; keeps stroke thickness consistent across displays.
    var pixelScale: CGFloat = 2

    private let toolOrder: [EditorTool] = [
        .rectangle, .ellipse, .arrow, .pen, .text, .mosaic, .number
    ]
    private var toolButtons: [PillIconButton] = []
    private var undoButton: PillIconButton?
    private var redoButton: PillIconButton?

    /// Stroke widths offered by the four dots, smallest first.
    private let lineWidths: [CGFloat] = [2, 4, 10, 18]
    private var sizeButtons: [SizeDotButton] = []

    /// Palette laid out as two rows of six.
    private let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .black, .systemGray, .white, .systemIndigo, .systemTeal, .systemPink
    ]
    private var colorButtons: [ColorSwatchButton] = []

    /// Size + palette row; hidden until the palette button is tapped.
    private var styleBar: NSView?
    private let paletteButton = PillIconButton(frame: .zero)

    /// Invoked when the window closes so the owner can release this controller.
    var onClose: ((EditorWindowController) -> Void)?

    /// Invoked with the flattened image when the user pins it to the screen.
    var onPin: ((CGImage) -> Void)?

    /// Invoked when the toolbar's long-capture button is tapped.
    var onLongCapture: (() -> Void)?

    init(image: CGImage) {
        viewModel = EditorViewModel(cgImage: image)

        let maxW: CGFloat = 1200, maxH: CGFloat = 800
        let fit = min(1, min(maxW / viewModel.imageSize.width,
                             maxH / viewModel.imageSize.height))
        let disp = CGSize(width: viewModel.imageSize.width * fit,
                          height: viewModel.imageSize.height * fit)
        // The image fills the whole window; the toolbar pills float over it near
        // the bottom (no docked strip, no extra background).
        let contentW = max(disp.width, 560)
        let contentH = disp.height
        defaultContentW = contentW

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        super.init()

        window.title = "SnapFlow"
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Force a light appearance so the editor matches the reference UI even
        // when the system is in Dark Mode.
        window.appearance = NSAppearance(named: .aqua)
        // A normal titled window: drag by the title bar (dragging the canvas
        // draws). Standard buttons stay so the window behaves predictably.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        canvas.editor = viewModel
        viewModel.canvas = canvas
        viewModel.onChange = { [weak self] in self?.refreshButtons() }
        canvas.onZoomChanged = { [weak self] z in self?.updateZoomLabel(z) }
        // Layout is built lazily by show(on:) / showInPlace(...) so each
        // presentation style builds its pills exactly once.
    }

    private let defaultContentW: CGFloat
    private var built = false

    /// Shared post-layout setup: default tool/size/color + initial zoom.
    private func finishBuild(initialZoom: CGFloat) {
        selectTool(.rectangle)
        selectWidth(index: 0)
        selectColor(index: 0)
        refreshButtons()
        setZoom(initialZoom)
    }

    /// - Parameter screen: the display the capture came from, so the editor
    ///   opens on the same screen the user was working on.
    func show(on screen: NSScreen?) {
        if !built {
            buildLayout()
            built = true
            // Fit the image width so tall captures are readable and scroll.
            finishBuild(initialZoom: min(1, defaultContentW / viewModel.imageSize.width))
        }
        Geometry.center(window, on: screen)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// In-place presentation (design: keep the shot where it was captured).
    /// The frozen image sits exactly over the selection and the toolbar floats
    /// just below it (or above, if the selection hugs the screen bottom).
    func showInPlace(at globalRect: CGRect, on screen: NSScreen) {
        let toolZone: CGFloat = 64
        // Pixel-align the selection to the display's backing grid so the frozen
        // image isn't placed on a sub-pixel boundary — a common cause of blur on
        // external monitors.
        let scale = screen.backingScaleFactor
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let aligned = CGRect(x: snap(globalRect.minX), y: snap(globalRect.minY),
                             width: snap(globalRect.width), height: snap(globalRect.height))

        // Display the frozen image at the selection's true point size. Derive
        // the zoom from the actual captured pixel dimensions rather than
        // assuming a backing scale — otherwise a mismatch (e.g. the capture came
        // back at 2x on a 1x display) shows the image magnified.
        let displaySize = aligned.size
        let zoom = viewModel.imageSize.width > 0
            ? aligned.width / viewModel.imageSize.width
            : 1

        // Put the toolbar below the selection when there's room, else above, so
        // it is always visible.
        let visible = screen.visibleFrame
        let below = (aligned.minY - visible.minY) >= (toolZone + 8)

        if !built {
            buildInPlaceLayout(imageSize: displaySize, toolbarBelow: below)
            built = true
            finishBuild(initialZoom: zoom)
        }

        // Borderless, translucent so the toolbar zone shows the desktop through.
        window.isOpaque = false
        window.backgroundColor = .clear
        // No window shadow: it would draw a rectangle around the transparent
        // tool zone. The pill carries its own shadow instead.
        window.hasShadow = false
        // Sit just above the capture overlay (screenSaver level) so the frozen
        // image and toolbar render over the dim backdrop.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

        let contentW = max(displaySize.width, 620)
        let contentH = displaySize.height + toolZone
        window.setContentSize(NSSize(width: contentW, height: contentH))
        // Center the window (and thus the image) on the selection so a wide
        // toolbar isn't clipped when the selection is narrower than the pill.
        let originX = aligned.midX - contentW / 2
        let originY = below ? aligned.minY - toolZone : aligned.minY
        window.setFrameOrigin(NSPoint(x: originX.rounded(), y: originY))

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
    // PLACEHOLDER_LAYOUT

    // MARK: - Layout

    /// In-place layout: image at its true size, toolbar pill floating in the
    /// transparent zone on the chosen side (below the image, or above it).
    private func buildInPlaceLayout(imageSize displaySize: CGSize, toolbarBelow: Bool) {
        scrollView.contentView = FlippedClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 4
        scrollView.layer?.masksToBounds = true
        canvas.translatesAutoresizingMaskIntoConstraints = true

        let style = makeStylePill()
        style.isHidden = true
        styleBar = style
        let toolPill = makeToolPill()

        let container = NSView()
        for v in [scrollView, toolPill, style] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }

        var constraints: [NSLayoutConstraint] = [
            scrollView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: displaySize.width),
            scrollView.heightAnchor.constraint(equalToConstant: displaySize.height),
            toolPill.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            style.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ]
        if toolbarBelow {
            // Image at the top of the content, toolbar in the zone beneath it.
            constraints += [
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                toolPill.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
                style.bottomAnchor.constraint(equalTo: toolPill.topAnchor, constant: -8)
            ]
        } else {
            // Image at the bottom, toolbar in the zone above it.
            constraints += [
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                toolPill.bottomAnchor.constraint(equalTo: scrollView.topAnchor, constant: -10),
                style.topAnchor.constraint(equalTo: toolPill.bottomAnchor, constant: 8)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        window.contentView = container
    }

    private func buildLayout() {
        // Flipped clip view so the document pins to the top-left and tall
        // captures start scrolled at the top.
        scrollView.contentView = FlippedClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.autohidesScrollers = true
        // Overlay scrollers float and don't reserve space, so they never sit
        // under (occlude) the floating toolbar pill at the bottom.
        scrollView.scrollerStyle = .overlay
        canvas.translatesAutoresizingMaskIntoConstraints = true

        // Size + palette row floats just above the tool pill; hidden until toggled.
        let style = makeStylePill()
        style.isHidden = true
        styleBar = style

        let toolPill = makeToolPill()

        let container = NSView()
        // Canvas fills the window; the pills float over it near the bottom.
        for v in [scrollView, toolPill, style] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            toolPill.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toolPill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            style.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            style.bottomAnchor.constraint(equalTo: toolPill.topAnchor, constant: -8)
        ])
        window.contentView = container
    }

    /// Wraps `content` in a rounded floating bar.
    private func pill(_ content: NSView, radius: CGFloat) -> NSView {
        let pill = PillView(cornerRadius: radius)
        let host = pill.contentContainer
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -6)
        ])
        return pill
    }
    // PLACEHOLDER_TOOLBAR

    private func makeToolPill() -> NSView {
        let symbols: [EditorTool: (String, String)] = [
            .select: ("cursorarrow", "选择/移动（点击标注可拖动，Delete 删除）"),
            .rectangle: ("rectangle", "矩形（按住 Shift 画正方形）"),
            .ellipse: ("circle", "圆形（按住 Shift 画正圆）"),
            .arrow: ("arrow.up.right", "箭头"),
            .pen: ("pencil.line", "画笔（按住 Shift 画直线）"),
            .mosaic: ("square.grid.3x3", "马赛克"),
            .text: ("t.square", "文字"),
            .number: ("number.circle", "编号")
        ]

        var views: [NSView] = []
        for (index, tool) in toolOrder.enumerated() {
            let (symbol, tip) = symbols[tool] ?? ("questionmark", "")
            let button = pillButton(symbol, tip: tip, action: #selector(toolTapped(_:)))
            button.setButtonType(.pushOnPushOff)
            button.tag = index
            toolButtons.append(button)
            views.append(button)
        }

        views.append(PillSeparator())

        // Toggles the size/colour row; its tint mirrors the current colour.
        paletteButton.image = NSImage(systemSymbolName: "paintpalette",
                                      accessibilityDescription: "颜色与线宽")
        paletteButton.toolTip = "颜色与线宽"
        paletteButton.target = self
        paletteButton.action = #selector(toggleStyleBar)
        paletteButton.setButtonType(.pushOnPushOff)
        views.append(paletteButton)

        views.append(PillSeparator())

        let undo = pillButton("arrow.uturn.backward", tip: "撤销 ⌘Z", action: #selector(undoTapped))
        undo.keyEquivalent = "z"
        undo.keyEquivalentModifierMask = .command
        undoButton = undo

        let redo = pillButton("arrow.uturn.forward", tip: "重做 ⌘⇧Z", action: #selector(redoTapped))
        redo.keyEquivalent = "z"
        redo.keyEquivalentModifierMask = [.command, .shift]
        redoButton = redo
        views.append(contentsOf: [undo, redo, PillSeparator()])

        let zoomOut = pillButton("minus.magnifyingglass", tip: "缩小 ⌘-",
                                 action: #selector(zoomOutTapped))
        zoomOut.keyEquivalent = "-"
        zoomOut.keyEquivalentModifierMask = .command

        zoomButton.target = self
        zoomButton.action = #selector(zoomActualTapped)
        zoomButton.isBordered = false
        zoomButton.font = .systemFont(ofSize: 11)
        zoomButton.toolTip = "恢复 100% ⌘0"
        zoomButton.keyEquivalent = "0"
        zoomButton.keyEquivalentModifierMask = .command
        zoomButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let zoomIn = pillButton("plus.magnifyingglass", tip: "放大 ⌘=",
                                action: #selector(zoomInTapped))
        zoomIn.keyEquivalent = "="
        zoomIn.keyEquivalentModifierMask = .command

        let fit = pillButton("arrow.up.left.and.arrow.down.right", tip: "适应窗口",
                             action: #selector(zoomFitTapped))
        views.append(contentsOf: [zoomOut, zoomButton, zoomIn, fit, PillSeparator()])

        let pin = pillButton("pin", tip: "钉在屏幕上 ⌘⇧P", action: #selector(pinTapped))
        pin.keyEquivalent = "p"
        pin.keyEquivalentModifierMask = [.command, .shift]

        let copy = pillButton("doc.on.doc", tip: "复制 ⌘⇧C", action: #selector(copyTapped))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command, .shift]

        let save = pillButton("square.and.arrow.down", tip: "保存 ⌘S", action: #selector(saveTapped))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        let long = pillButton("scroll", tip: "长截图", action: #selector(longCaptureTapped))
        views.append(contentsOf: [pin, copy, save, long, PillSeparator()])

        let cancel = pillButton("xmark", tip: "放弃 (ESC)", action: #selector(cancelTapped))
        cancel.contentTintColor = .systemRed
        cancel.keyEquivalent = "\u{1b}"

        let done = pillButton("checkmark", tip: "完成：复制并关闭", action: #selector(doneTapped))
        done.contentTintColor = .systemGreen
        done.keyEquivalent = "\r"
        views.append(contentsOf: [cancel, done])

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        return pill(stack, radius: 10)
    }

    private func makeStylePill() -> NSView {
        var dots: [NSView] = []
        for (index, width) in lineWidths.enumerated() {
            let dot = SizeDotButton(dotDiameter: 3 + width * 0.55)
            dot.target = self
            dot.action = #selector(widthTapped(_:))
            dot.tag = index
            dot.toolTip = "线宽 \(Int(width))"
            sizeButtons.append(dot)
            dots.append(dot)
        }

        // Palette as two rows of six, like the reference bar.
        let half = palette.count / 2
        var rows: [NSView] = []
        for row in 0..<2 {
            var swatches: [NSView] = []
            for column in 0..<half {
                let index = row * half + column
                let swatch = ColorSwatchButton(color: palette[index])
                swatch.target = self
                swatch.action = #selector(colorTapped(_:))
                swatch.tag = index
                swatch.toolTip = Palette.name(at: index)
                colorButtons.append(swatch)
                swatches.append(swatch)
            }
            let rowStack = NSStackView(views: swatches)
            rowStack.orientation = .horizontal
            rowStack.spacing = 3
            rows.append(rowStack)
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.spacing = 3

        let stack = NSStackView(views: dots + [PillSeparator(), grid])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        return pill(stack, radius: 10)
    }

    private func pillButton(_ symbol: String, tip: String, action: Selector) -> PillIconButton {
        let button = PillIconButton(frame: .zero)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.target = self
        button.action = action
        return button
    }

    // MARK: - Zoom

    private func setZoom(_ z: CGFloat) {
        let clamped = min(EditorCanvasView.maxZoom, max(EditorCanvasView.minZoom, z))
        canvas.zoom = clamped
        updateZoomLabel(clamped)
    }

    private func updateZoomLabel(_ z: CGFloat) {
        zoom = z
        zoomButton.title = "\(Int((z * 100).rounded()))%"
    }

    private func fitZoom() -> CGFloat {
        let vis = scrollView.contentSize
        let img = viewModel.imageSize
        guard img.width > 0, img.height > 0 else { return 1 }
        return min(vis.width / img.width, vis.height / img.height)
    }

    @objc private func zoomInTapped() { setZoom(zoom * 1.25) }
    @objc private func zoomOutTapped() { setZoom(zoom / 1.25) }
    @objc private func zoomActualTapped() { setZoom(1) }
    @objc private func zoomFitTapped() { setZoom(fitZoom()) }

    // MARK: - Actions

    @objc private func toolTapped(_ sender: NSButton) {
        selectTool(toolOrder[sender.tag])
    }

    private func selectTool(_ tool: EditorTool) {
        viewModel.currentTool = tool
        if tool != .select { viewModel.deselect() }
        for (index, button) in toolButtons.enumerated() {
            let on = toolOrder[index] == tool
            button.state = on ? .on : .off
            button.contentTintColor = on ? .controlAccentColor : .labelColor
        }
    }

    @objc private func widthTapped(_ sender: SizeDotButton) {
        selectWidth(index: sender.tag)
    }

    private func selectWidth(index: Int) {
        guard lineWidths.indices.contains(index) else { return }
        let width = lineWidths[index]
        // Scale by capture pixels-per-point so strokes look consistent across
        // Retina (2x) and 1x displays.
        viewModel.currentStyle.lineWidth = width * pixelScale
        viewModel.currentStyle.fontSize = max(18, width * 6) * pixelScale
        for (i, dot) in sizeButtons.enumerated() { dot.isChosen = (i == index) }
    }

    @objc private func colorTapped(_ sender: ColorSwatchButton) {
        selectColor(index: sender.tag)
    }

    @objc private func toggleStyleBar() {
        guard let styleBar else { return }
        styleBar.isHidden.toggle()
        paletteButton.state = styleBar.isHidden ? .off : .on
    }

    private func selectColor(index: Int) {
        guard palette.indices.contains(index) else { return }
        viewModel.currentStyle.color = palette[index]
        paletteButton.contentTintColor = palette[index]
        for (i, swatch) in colorButtons.enumerated() { swatch.isChosen = (i == index) }
    }

    @objc private func undoTapped() { viewModel.undo() }
    @objc private func redoTapped() { viewModel.redo() }

    @objc private func copyTapped() {
        guard let image = viewModel.render() else { return }
        ImageSaver.copyToClipboard(image)
    }

    /// Pins the flattened image (annotations included) and closes the editor —
    /// the pinned window is what stays on screen.
    @objc private func pinTapped() {
        guard let image = viewModel.render() else { return }
        onPin?(image)
        window.performClose(nil)
    }

    /// ✓ — copy to the clipboard and close, the usual "confirm" action.
    @objc private func doneTapped() {
        guard let image = viewModel.render() else { return }
        ImageSaver.copyToClipboard(image)
        window.performClose(nil)
    }

    /// ✗ — discard this capture and close.
    @objc private func cancelTapped() {
        window.performClose(nil)
    }

    /// Close this editor and start a scrolling long-capture.
    @objc private func longCaptureTapped() {
        window.performClose(nil)
        onLongCapture?()
    }

    @objc private func saveTapped() {
        guard let image = viewModel.render(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "SnapFlow.png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func refreshButtons() {
        undoButton?.isEnabled = viewModel.canUndo
        redoButton?.isEnabled = viewModel.canRedo
    }
}

/// A top-left-origin clip view so the document view pins to the top and tall
/// captures start scrolled at the top edge.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
