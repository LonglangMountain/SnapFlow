import AppKit

/// Floating confirmation shown after a standalone 提取屏幕文字 capture
/// (scenario A). Displays the result message and auto-dismisses.
@MainActor
final class OCRResultHUD: NSPanel {

    private var dismissWork: DispatchWorkItem?

    init(message: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .screenSaver
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        build(message: message)
    }

    private func build(message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = PillView(cornerRadius: 10, bordered: false)
        let host = pill.contentContainer
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -9)
        ])
        pill.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(pill)
        let pad: CGFloat = 30
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            pill.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            pill.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            pill.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad)
        ])
        contentView = content
    }

    override var canBecomeKey: Bool { false }

    /// Show centered just below the capture region (or above if there's no
    /// room), then auto-dismiss after `duration` seconds.
    func present(region: CGRect, on screen: NSScreen, duration: TimeInterval = 2.5) {
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
        var y = regionBottom - gap - s.height
        if y < vf.minY + 4 { y = regionTop + gap }
        y = min(max(vf.minY + 4, y), vf.maxY - s.height - 4)
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
// LIST_PLACEHOLDER

/// 识别结果 list panel (scenario B — fine extraction). Shows each recognized
/// segment as a row; the user multi-selects rows and copies just those (or
/// all). Opened from the editor's 识别文字 button — no screen re-capture.
@MainActor
final class OCRResultListController: NSObject, NSWindowDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate {

    private let window: NSWindow
    private let segments: [String]
    private let table = NSTableView()
    private let copySelected = NSButton(title: "复制所选", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?

    init(segments: [String]) {
        self.segments = segments
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered,
                          defer: false)
        super.init()
        window.title = "识别文字"
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Float above the editor's full-screen capture overlay (which sits at
        // .screenSaver level) so the panel isn't hidden behind it.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        buildLayout()
    }

    /// Position the panel just to the RIGHT of the capture region (falling back
    /// to the left, then centered) so it never covers the captured content.
    /// `region` is screen-local (points, bottom-left origin).
    func present(region: CGRect, on screen: NSScreen) {
        let w = window.frame.width
        let h = window.frame.height
        let vf = screen.visibleFrame
        let gap: CGFloat = 12

        let regionRightGlobal = screen.frame.minX + region.maxX
        let regionLeftGlobal = screen.frame.minX + region.minX
        var x = regionRightGlobal + gap
        if x + w > vf.maxX - 4 {
            // No room on the right — try the left of the region.
            let leftX = regionLeftGlobal - gap - w
            x = leftX >= vf.minX + 4 ? leftX : (vf.midX - w / 2)
        }
        x = min(max(vf.minX + 4, x), vf.maxX - w - 4)

        // Top-align the panel with the region's top edge.
        var y = (screen.frame.minY + region.maxY) - h
        y = min(max(vf.minY + 4, y), vf.maxY - h - 4)

        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    private func buildLayout() {
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.rowSizeStyle = .default
        table.usesAutomaticRowHeights = true
        let column = NSTableColumn(identifier: .init("segment"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        updateHint()

        copySelected.target = self
        copySelected.action = #selector(copySelectedTapped)
        copySelected.bezelStyle = .rounded
        copySelected.keyEquivalent = "\r"
        let copyAll = NSButton(title: "复制全部", target: self, action: #selector(copyAllTapped))
        copyAll.bezelStyle = .rounded

        // Left-right layout: the text list on the left, controls stacked in a
        // fixed-width column on the right (so neither hides the other).
        let controls = NSStackView(views: [hint, copySelected, copyAll, NSView()])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(controls)
        let columnWidth: CGFloat = 120
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            controls.widthAnchor.constraint(equalToConstant: columnWidth),
            copySelected.widthAnchor.constraint(equalToConstant: columnWidth),
            copyAll.widthAnchor.constraint(equalToConstant: columnWidth)
        ])
        window.contentView = content
    }
    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { segments.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? {
                let field = NSTextField(wrappingLabelWithString: "")
                field.identifier = id
                field.isSelectable = true
                field.isEditable = false
                field.drawsBackground = false
                field.font = .systemFont(ofSize: 13)
                return field
            }()
        cell.stringValue = segments[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateHint() }

    private func updateHint() {
        let n = table.selectedRowIndexes.count
        hint.stringValue = n > 0 ? "已选 \(n)/\(segments.count) 段" : "共 \(segments.count) 段"
        copySelected.isEnabled = n > 0
    }

    @objc private func copySelectedTapped() {
        let rows = table.selectedRowIndexes
        let text = rows.map { segments[$0] }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        copy(text)
    }

    @objc private func copyAllTapped() { copy(segments.joined(separator: "\n")) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}