import AppKit
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement

/// Minimal settings/permissions window (design Phase 5: 设置 / 权限 / 多屏).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let screenStatus = NSTextField(labelWithString: "")
    private let axStatus = NSTextField(labelWithString: "")
    private let launchToggle = NSButton(checkboxWithTitle: "开机时启动 SnapFlow",
                                        target: nil, action: nil)
    var onClose: (() -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                          styleMask: [.titled, .closable],
                          backing: .buffered,
                          defer: false)
        super.init()
        window.title = "设置"
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildLayout()
    }

    func show(on screen: NSScreen?) {
        refreshStatus()
        Geometry.center(window, on: screen)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: "权限")
        title.font =         .systemFont(ofSize: 15, weight: .semibold)

        let screenRow = permissionRow(label: "屏幕录制（截图必需）",
                                      status: screenStatus,
                                      buttonTitle: "打开设置",
                                      action: #selector(openScreenPrefs))
        let axRow = permissionRow(label: "辅助功能（长截图滚动必需）",
                                  status: axStatus,
                                  buttonTitle: "打开设置",
                                  action: #selector(openAXPrefs))

        let note = NSTextField(wrappingLabelWithString:
            "多屏：区域/窗口截图会在每个屏幕分别叠加选择层；全屏截图默认捕获鼠标所在屏幕。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)

        // General options.
        let generalTitle = NSTextField(labelWithString: "通用")
        generalTitle.font =         .systemFont(ofSize: 15, weight: .semibold)
        launchToggle.target = self
        launchToggle.action = #selector(toggleLaunchAtLogin(_:))

        // Shortcut editor.
        let shortcutTitle = NSTextField(labelWithString: "快捷键")
        shortcutTitle.font =         .systemFont(ofSize: 15, weight: .semibold)
        var views: [NSView] = [title, screenRow, axRow, note,
                               generalTitle, launchToggle, shortcutTitle]
        views += ShortcutAction.allCases.map(shortcutRow)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])
        window.contentView = content
    }

    private func permissionRow(label: String,
                               status: NSTextField,
                               buttonTitle: String,
                               action: Selector) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        let row = NSStackView(views: [name, status, button])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    private func shortcutRow(_ action: ShortcutAction) -> NSView {
        let name = NSTextField(labelWithString: action.title)
        name.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let recorder = ShortcutRecorderButton(shortcut: ShortcutStore.shortcut(for: action))
        recorder.onChange = { shortcut in ShortcutStore.set(shortcut, for: action) }
        let hint = NSTextField(labelWithString: "点击后按下组合键")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [name, recorder, hint])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    private func refreshStatus() {
        let screenOK = CGPreflightScreenCaptureAccess()
        screenStatus.stringValue = screenOK ? "已授权" : "未授权"
        screenStatus.textColor = screenOK ? .systemGreen : .systemRed

        let axOK = AXIsProcessTrusted()
        axStatus.stringValue = axOK ? "已授权" : "未授权"
        axStatus.textColor = axOK ? .systemGreen : .systemRed

        launchToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("SnapFlow: launch-at-login toggle failed: \(error.localizedDescription)")
            // Revert to the real status if the change didn't take.
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc private func openScreenPrefs() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @objc private func openAXPrefs() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
