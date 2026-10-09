import AppKit

/// Builds the menu bar status item and its dropdown, matching the layout in
/// the design doc. Only area + full-screen capture are wired in Phase 1; the
/// remaining items are present but disabled to preview the final shape.
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let captureManager: CaptureManager

    init(captureManager: CaptureManager) {
        self.captureManager = captureManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "SnapFlow")
            button.image?.isTemplate = true
        }

        statusItem.menu = buildMenu()

        // Rebuild so the displayed key equivalents track edited shortcuts.
        NotificationCenter.default.addObserver(forName: ShortcutStore.didChange,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    private func rebuildMenu() {
        trampolines.removeAll()
        closureTrampolines.removeAll()
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(sectionHeader("截图"))

        let area = ShortcutStore.shortcut(for: .area)
        menu.addItem(actionItem(title: "区域截图",
                                key: area.keyEquivalent,
                                modifiers: area.nsModifierFlags,
                                mode: .area,
                                enabled: true))
        let window = ShortcutStore.shortcut(for: .window)
        menu.addItem(actionItem(title: "窗口截图",
                                key: window.keyEquivalent,
                                modifiers: window.nsModifierFlags,
                                mode: .window,
                                enabled: true))
        let screen = ShortcutStore.shortcut(for: .screen)
        menu.addItem(actionItem(title: "全屏截图",
                                key: screen.keyEquivalent,
                                modifiers: screen.nsModifierFlags,
                                mode: .screen,
                                enabled: true))
        let scrolling = ShortcutStore.shortcut(for: .scrolling)
        menu.addItem(actionItem(title: "长截图",
                                key: scrolling.keyEquivalent,
                                modifiers: scrolling.nsModifierFlags,
                                mode: .scrolling,
                                enabled: true))
        let ocr = ShortcutStore.shortcut(for: .ocr)
        menu.addItem(actionItem(title: "提取屏幕文字",
                                key: ocr.keyEquivalent,
                                modifiers: ocr.nsModifierFlags,
                                mode: .ocr,
                                enabled: true))

        menu.addItem(.separator())
        let pin = ShortcutStore.shortcut(for: .pin)
        menu.addItem(closureItem(title: "最近截图",
                                 key: pin.keyEquivalent,
                                 modifiers: pin.nsModifierFlags) {
            [weak self] in self?.captureManager.pinLatest()
        })

        menu.addItem(.separator())
        menu.addItem(closureItem(title: "设置", key: ",") {
            [weak self] in self?.captureManager.openSettings()
        })

        menu.addItem(NSMenuItem(title: "退出 SnapFlow",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(title: String,
                            key: String,
                            modifiers: NSEvent.ModifierFlags,
                            mode: CaptureMode,
                            enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: enabled ? #selector(Trampoline.fire(_:)) : nil,
                              keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if enabled {
            let trampoline = Trampoline(mode: mode, captureManager: captureManager)
            trampolines.append(trampoline)
            item.target = trampoline
        } else {
            item.isEnabled = false
        }
        return item
    }

    private func closureItem(title: String,
                             key: String,
                             modifiers: NSEvent.ModifierFlags = [],
                             action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(ClosureTrampoline.fire),
                              keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        let trampoline = ClosureTrampoline(action: action)
        closureTrampolines.append(trampoline)
        item.target = trampoline
        return item
    }

    // NSMenuItem keeps only a weak target, so retain the trampolines here.
    private var trampolines: [Trampoline] = []
    private var closureTrampolines: [ClosureTrampoline] = []
}

/// Forwards a menu click to a stored closure.
private final class ClosureTrampoline: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// Small target object that forwards a menu click to a specific CaptureMode.
private final class Trampoline: NSObject {
    private let mode: CaptureMode
    private let captureManager: CaptureManager

    init(mode: CaptureMode, captureManager: CaptureManager) {
        self.mode = mode
        self.captureManager = captureManager
    }

    @objc func fire(_ sender: Any?) {
        captureManager.begin(mode)
    }
}
