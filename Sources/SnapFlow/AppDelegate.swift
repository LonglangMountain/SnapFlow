import AppKit
import Carbon.HIToolbox

/// Owns the app-wide singletons and wires the menu bar to the capture pipeline.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController!
    private let captureManager = CaptureManager()
    private let hotKeys = HotKeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show hover tooltips almost immediately (default is ~1.5s, which felt
        // slow/unreliable). NSInitialToolTipDelay is read by AppKit in ms.
        UserDefaults.standard.set(300, forKey: "NSInitialToolTipDelay")

        menuBar = MenuBarController(captureManager: captureManager)

        registerShortcuts()
        // Re-register whenever the user edits a shortcut in Settings.
        NotificationCenter.default.addObserver(forName: ShortcutStore.didChange,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.registerShortcuts()
        }

        // Warm up the SwiftData history store so persistence issues surface now.
        MainActor.assumeIsolated { _ = HistoryStore.shared }
    }

    /// (Re)register every global shortcut from the store.
    private func registerShortcuts() {
        hotKeys.unregisterAll()
        for action in ShortcutAction.allCases {
            let shortcut = ShortcutStore.shortcut(for: action)
            hotKeys.register(id: action.hotKeyID,
                             keyCode: shortcut.keyCode,
                             carbonModifiers: shortcut.carbonModifiers) { [weak self] in
                self?.perform(action)
            }
        }
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .area: captureManager.begin(.area)
        case .window: captureManager.begin(.window)
        case .screen: captureManager.begin(.screen)
        case .scrolling: captureManager.begin(.scrolling)
        case .pin: captureManager.pinLatest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregisterAll()
    }
}
