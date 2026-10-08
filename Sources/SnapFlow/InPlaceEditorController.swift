import AppKit

/// In-place annotation editor that lives *inside* the capture overlay window.
///
/// Because the canvas is a subview placed at the exact selection rect (in the
/// overlay's own coordinate space) and shares the overlay's screen/scale, the
/// frozen image lines up with the selection pixel-for-pixel and renders 1:1 —
/// no cross-window coordinate or backing-scale conversions to get wrong.
@MainActor
final class InPlaceEditorController: NSObject {

    private var viewModel: EditorViewModel
    private let canvas = InPlaceCanvasView()

    private let toolOrder: [EditorTool] = [
        .rectangle, .ellipse, .arrow, .line, .pen, .mosaic, .text, .number
    ]
    private var toolButtons: [PillIconButton] = []
    private var undoButton: PillIconButton?
    private var redoButton: PillIconButton?

    private let lineWidths: [CGFloat] = [2, 4, 10, 18]
    private var sizeButtons: [SizeDotButton] = []

    private let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .black, .systemGray, .white, .systemIndigo, .systemTeal, .systemPink
    ]
    private var colorButtons: [ColorSwatchButton] = []

    private let paletteButton = PillIconButton(frame: .zero)
    private var stylePill: NSView?
    private var toolPill: NSView?
    private var installed: [NSView] = []
    private weak var hostWindow: NSWindow?

    // Live selection-resize state.
    private weak var host: NSView?
    private var selection: CGRect = .zero
    private var handles: [SelectionHandle] = []

    /// Pin the flattened image; provided by the owner.
    var onPin: ((CGImage) -> Void)?
    /// Start a scrolling long-capture (toolbar button); provided by the owner.
    var onLongCapture: (() -> Void)?
    /// Re-capture request when the selection is resized (overlay-view rect).
    var onResize: ((CGRect) -> Void)?
    /// Reports the live selection rect so the overlay backdrop stays in sync.
    var onSelectionChange: ((CGRect) -> Void)?
    /// Crops a fresh image for a given selection rect (from a frozen full-screen
    /// grab) so resizing shows the correct content instantly — no stretch.
    var imageProvider: ((CGRect) -> CGImage?)?
    /// Backing scale, used to snap the selection to the pixel grid while resizing.
    var pixelScale: CGFloat = 2
    /// Tear down the overlay (done or cancel).
    var onClose: (() -> Void)?

    init(image: CGImage) {
        viewModel = EditorViewModel(cgImage: image)
        super.init()
        viewModel.onChange = { [weak self] in
            self?.canvas.refresh()
            self?.refreshButtons()
        }
    }
    // PLACEHOLDER

    /// Install the canvas + toolbar into `host` (the overlay's content view),
    /// with the canvas sitting exactly on `rect` (overlay-view coordinates).
    func install(in host: NSView, selection rect: CGRect) {
        hostWindow = host.window
        self.host = host
        selection = rect

        // Canvas exactly over the selection. NSImageView draws the bitmap
        // upright and crisp regardless of the overlay window's layer-backing.
        let pxPerPoint = rect.width > 0 ? viewModel.imageSize.width / rect.width : 1
        canvas.frame = rect
        canvas.autoresizingMask = []
        host.addSubview(canvas)
        canvas.configure(editor: viewModel, pxPerPoint: pxPerPoint)
        installed.append(canvas)

        let tools = makeToolPill()
        let style = makeStylePill()
        style.isHidden = true
        stylePill = style
        toolPill = tools
        host.addSubview(tools)
        host.addSubview(style)
        installed += [tools, style]

        layoutPills(for: rect)
        installHandles(in: host)

        // Drag the whole selection (in select mode, pressing empty canvas area).
        canvas.onMoveRegionDragged = { [weak self] delta in self?.moveRegion(by: delta) }
        canvas.onMoveRegionEnded = { [weak self] in self?.commitResize() }

        // No tool selected by default — the toolbar starts unhighlighted and the
        // canvas won't draw until the user picks a tool (select/move still works).
        viewModel.currentTool = .select
        selectWidth(index: 0)
        selectColor(index: 0)
        refreshButtons()

        host.window?.makeFirstResponder(canvas)
    }

    /// Position the tool + style pills relative to the current selection.
    private func layoutPills(for rect: CGRect) {
        guard let host, let tools = toolPill, let style = stylePill else { return }
        tools.layoutSubtreeIfNeeded()
        style.layoutSubtreeIfNeeded()
        let toolsSize = tools.fittingSize
        let styleSize = style.fittingSize

        let gap: CGFloat = 10
        let hostBounds = host.bounds
        let below = (rect.minY - hostBounds.minY) >= (toolsSize.height + gap + 8)

        let toolsX = (rect.midX - toolsSize.width / 2)
            .clamped(to: hostBounds.minX + 4 ... hostBounds.maxX - toolsSize.width - 4)
        let toolsY = below ? rect.minY - gap - toolsSize.height : rect.maxY + gap
        tools.setFrameOrigin(NSPoint(x: toolsX.rounded(), y: toolsY.rounded()))
        tools.setFrameSize(toolsSize)

        let styleX = (rect.midX - styleSize.width / 2)
            .clamped(to: hostBounds.minX + 4 ... hostBounds.maxX - styleSize.width - 4)
        let styleY = below ? toolsY - 8 - styleSize.height : toolsY + toolsSize.height + 8
        style.setFrameOrigin(NSPoint(x: styleX.rounded(), y: styleY.rounded()))
        style.setFrameSize(styleSize)
    }

    // MARK: - Selection resize handles

    private func installHandles(in host: NSView) {
        for kind in SelectionHandle.Kind.allCases {
            let handle = SelectionHandle(kind: kind)
            handle.onDragged = { [weak self] point in self?.resizeSelection(kind, to: point) }
            handle.onEnded = { [weak self] in self?.commitResize() }
            host.addSubview(handle)
            handles.append(handle)
            installed.append(handle)
        }
        layoutHandles()
    }

    private func layoutHandles() {
        for handle in handles {
            let p = SelectionHandle.point(handle.kind, in: selection)
            handle.setFrameOrigin(NSPoint(x: p.x - handle.frame.width / 2,
                                          y: p.y - handle.frame.height / 2))
        }
    }

    private func snap(_ v: CGFloat) -> CGFloat { (v * pixelScale).rounded() / pixelScale }

    private func resizeSelection(_ kind: SelectionHandle.Kind, to point: NSPoint) {
        guard let host else { return }
        var r = SelectionHandle.resized(selection, kind: kind, to: point)
        r = CGRect(x: snap(r.minX), y: snap(r.minY), width: snap(r.width), height: snap(r.height))
            .intersection(host.bounds)
        guard r.width >= 20, r.height >= 20 else { return }
        selection = r
        canvas.frame = r
        layoutPills(for: r)
        layoutHandles()
        onSelectionChange?(r)
        // Crisp live content by cropping the frozen full-screen grab — no stretch.
        if let cg = imageProvider?(r) { canvas.showLivePreview(cg) }
    }

    /// Finalize a resize: rebuild the editor's model from the cropped image.
    private func commitResize() {
        if let cg = imageProvider?(selection) {
            updateCapture(image: cg, selection: selection)
        }
        onResize?(selection)
    }

    /// Move the whole selection by a delta (overlay points), re-cropping live.
    private func moveRegion(by delta: CGSize) {
        guard let host else { return }
        var r = selection
        r.origin.x = snap(min(max(host.bounds.minX, r.origin.x + delta.width),
                              host.bounds.maxX - r.width))
        r.origin.y = snap(min(max(host.bounds.minY, r.origin.y + delta.height),
                              host.bounds.maxY - r.height))
        selection = r
        canvas.frame = r
        layoutPills(for: r)
        layoutHandles()
        onSelectionChange?(r)
        if let cg = imageProvider?(r) { canvas.showLivePreview(cg) }
    }

    /// Swap in a freshly captured crop after a resize, keeping tool/colour state.
    func updateCapture(image: CGImage, selection rect: CGRect) {
        let tool = viewModel.currentTool
        let style = viewModel.currentStyle
        viewModel = EditorViewModel(cgImage: image)
        viewModel.currentTool = tool
        viewModel.currentStyle = style
        viewModel.onChange = { [weak self] in
            self?.canvas.refresh()
            self?.refreshButtons()
        }
        selection = rect
        let px = rect.width > 0 ? viewModel.imageSize.width / rect.width : 1
        canvas.frame = rect
        canvas.configure(editor: viewModel, pxPerPoint: px)
        layoutPills(for: rect)
        layoutHandles()
        refreshButtons()
        host?.window?.makeFirstResponder(canvas)
    }

    private func teardown() {
        for view in installed { view.removeFromSuperview() }
        installed.removeAll()
    }

    // MARK: - Toolbar construction

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

    private func pillButton(_ symbol: String, tip: String, action: Selector) -> PillIconButton {
        let button = PillIconButton(frame: .zero)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.target = self
        button.action = action
        return button
    }
    // TOOLBAR_PLACEHOLDER

    private func makeToolPill() -> NSView {
        let symbols: [EditorTool: (String, String)] = [
            .select: ("cursorarrow", "选择/移动（点击标注可拖动，Delete 删除）"), .rectangle: ("rectangle", "矩形"),
            .ellipse: ("circle", "圆形"), .arrow: ("arrow.up.right", "箭头"),
            .line: ("line.diagonal", "直线"), .pen: ("pencil.line", "画笔"),
            .mosaic: ("square.grid.3x3", "马赛克"), .text: ("textformat", "文字"),
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
        paletteButton.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "颜色与线宽")
        paletteButton.toolTip = "颜色与线宽"
        paletteButton.target = self
        paletteButton.action = #selector(toggleStyleBar)
        paletteButton.setButtonType(.pushOnPushOff)
        views += [paletteButton, PillSeparator()]

        let undo = pillButton("arrow.uturn.backward", tip: "撤销 ⌘Z", action: #selector(undoTapped))
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = .command
        undoButton = undo
        let redo = pillButton("arrow.uturn.forward", tip: "重做 ⌘⇧Z", action: #selector(redoTapped))
        redo.keyEquivalent = "z"; redo.keyEquivalentModifierMask = [.command, .shift]
        redoButton = redo
        views += [undo, redo, PillSeparator()]

        let pin = pillButton("pin", tip: "钉在屏幕上 ⌘⇧P", action: #selector(pinTapped))
        pin.keyEquivalent = "p"; pin.keyEquivalentModifierMask = [.command, .shift]
        let copy = pillButton("doc.on.doc", tip: "复制 ⌘⇧C", action: #selector(copyTapped))
        copy.keyEquivalent = "c"; copy.keyEquivalentModifierMask = [.command, .shift]
        let save = pillButton("square.and.arrow.down", tip: "保存 ⌘S", action: #selector(saveTapped))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let long = pillButton("scroll", tip: "长截图", action: #selector(longCaptureTapped))
        views += [pin, copy, save, long, PillSeparator()]

        let cancel = pillButton("xmark", tip: "放弃 (ESC)", action: #selector(cancelTapped))
        cancel.contentTintColor = .systemRed; cancel.keyEquivalent = "\u{1b}"
        let done = pillButton("checkmark", tip: "完成：复制并关闭", action: #selector(doneTapped))
        done.contentTintColor = .systemGreen; done.keyEquivalent = "\r"
        views += [cancel, done]

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY
        return pill(stack, radius: 10)
    }
    // STYLE_PLACEHOLDER

    private func makeStylePill() -> NSView {
        var dots: [NSView] = []
        for (index, width) in lineWidths.enumerated() {
            let dot = SizeDotButton(dotDiameter: 3 + width * 0.55)
            dot.target = self; dot.action = #selector(widthTapped(_:)); dot.tag = index
            dot.toolTip = "线宽 \(Int(width))"
            sizeButtons.append(dot); dots.append(dot)
        }
        let half = palette.count / 2
        var rows: [NSView] = []
        for row in 0..<2 {
            var swatches: [NSView] = []
            for column in 0..<half {
                let index = row * half + column
                let swatch = ColorSwatchButton(color: palette[index])
                swatch.target = self; swatch.action = #selector(colorTapped(_:)); swatch.tag = index
                swatch.toolTip = Palette.name(at: index)
                colorButtons.append(swatch); swatches.append(swatch)
            }
            let rowStack = NSStackView(views: swatches)
            rowStack.orientation = .horizontal; rowStack.spacing = 3
            rows.append(rowStack)
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical; grid.spacing = 3
        let stack = NSStackView(views: dots + [PillSeparator(), grid])
        stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY
        return pill(stack, radius: 10)
    }

    // MARK: - Actions

    @objc private func toolTapped(_ sender: PillIconButton) { selectTool(toolOrder[sender.tag]) }

    private func selectTool(_ tool: EditorTool) {
        viewModel.currentTool = tool
        if tool != .select { viewModel.deselect() }
        for (i, b) in toolButtons.enumerated() {
            let on = toolOrder[i] == tool
            b.state = on ? .on : .off
            b.contentTintColor = on ? .controlAccentColor : .labelColor
        }
    }

    @objc private func widthTapped(_ sender: SizeDotButton) { selectWidth(index: sender.tag) }

    private func selectWidth(index: Int) {
        guard lineWidths.indices.contains(index) else { return }
        let width = lineWidths[index]
        // Line widths/fonts are in image PIXELS. Scale by the capture's pixels-
        // per-point so the stroke looks the same thickness on a 2x Retina display
        // and a 1x external monitor (otherwise it looks half as thick on Retina).
        viewModel.currentStyle.lineWidth = width * pixelScale
        viewModel.currentStyle.fontSize = max(18, width * 6) * pixelScale
        for (i, dot) in sizeButtons.enumerated() { dot.isChosen = (i == index) }
    }

    @objc private func colorTapped(_ sender: ColorSwatchButton) { selectColor(index: sender.tag) }

    private func selectColor(index: Int) {
        guard palette.indices.contains(index) else { return }
        viewModel.currentStyle.color = palette[index]
        paletteButton.contentTintColor = palette[index]
        for (i, s) in colorButtons.enumerated() { s.isChosen = (i == index) }
    }

    @objc private func toggleStyleBar() {
        guard let stylePill else { return }
        stylePill.isHidden.toggle()
        paletteButton.state = stylePill.isHidden ? .off : .on
    }

    @objc private func undoTapped() { viewModel.undo() }
    @objc private func redoTapped() { viewModel.redo() }

    @objc private func copyTapped() {
        guard let image = viewModel.render() else { return }
        ImageSaver.copyToClipboard(image)
    }

    @objc private func pinTapped() {
        guard let image = viewModel.render() else { return }
        onPin?(image)
        teardown(); onClose?()
    }

    @objc private func doneTapped() {
        if let image = viewModel.render() { ImageSaver.copyToClipboard(image) }
        teardown(); onClose?()
    }

    @objc private func cancelTapped() {
        teardown(); onClose?()
    }

    /// Close the current shot and start a scrolling long-capture.
    @objc private func longCaptureTapped() {
        teardown(); onClose?(); onLongCapture?()
    }

    @objc private func saveTapped() {
        guard let image = viewModel.render(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              let window = hostWindow else { return }
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// A small draggable grip shown at the selection's corners and edge midpoints.
final class SelectionHandle: NSView {
    enum Kind: CaseIterable { case tl, t, tr, l, r, bl, b, br }

    let kind: Kind
    var onDragged: ((NSPoint) -> Void)?
    var onEnded: (() -> Void)?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
    }

    required init?(coder: NSCoder) { preconditionFailure("SelectionHandle is code-only") }

    override func mouseDown(with event: NSEvent) {
        cursor.set() // keep the resize cursor for the whole drag
    }

    override func mouseDragged(with event: NSEvent) {
        cursor.set()
        onDragged?(superview?.convert(event.locationInWindow, from: nil) ?? .zero)
    }

    override func mouseUp(with event: NSEvent) { onEnded?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    /// A directional resize cursor matching this handle's edge/corner.
    private var cursor: NSCursor {
        switch kind {
        case .l, .r: return .resizeLeftRight
        case .t, .b: return .resizeUpDown
        case .tl, .br: return SelectionHandle.diagonal("_windowResizeNorthWestSouthEastCursor")
        case .tr, .bl: return SelectionHandle.diagonal("_windowResizeNorthEastSouthWestCursor")
        }
    }

    /// AppKit has no public diagonal resize cursors; fall back to crosshair if
    /// the private one isn't available.
    private static func diagonal(_ name: String) -> NSCursor {
        let selector = NSSelectorFromString(name)
        if NSCursor.responds(to: selector),
           let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .crosshair
    }

    static func point(_ kind: Kind, in r: CGRect) -> CGPoint {
        switch kind {
        case .tl: return CGPoint(x: r.minX, y: r.maxY)
        case .t:  return CGPoint(x: r.midX, y: r.maxY)
        case .tr: return CGPoint(x: r.maxX, y: r.maxY)
        case .l:  return CGPoint(x: r.minX, y: r.midY)
        case .r:  return CGPoint(x: r.maxX, y: r.midY)
        case .bl: return CGPoint(x: r.minX, y: r.minY)
        case .b:  return CGPoint(x: r.midX, y: r.minY)
        case .br: return CGPoint(x: r.maxX, y: r.minY)
        }
    }

    static func resized(_ r: CGRect, kind: Kind, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch kind {
        case .tl: minX = p.x; maxY = p.y
        case .t:  maxY = p.y
        case .tr: maxX = p.x; maxY = p.y
        case .l:  minX = p.x
        case .r:  maxX = p.x
        case .bl: minX = p.x; minY = p.y
        case .b:  minY = p.y
        case .br: maxX = p.x; minY = p.y
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }
}
