import AppKit
import Carbon.HIToolbox

/// A user-configurable global shortcut (key + modifiers).
struct KeyShortcut: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var key: String   // display glyph, e.g. "X"

    /// Human-readable combo, e.g. "⇧⌘X".
    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    var keyEquivalent: String { key.lowercased() }

    var nsModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    var serialized: String { "\(keyCode):\(carbonModifiers):\(key)" }

    init(keyCode: UInt32, carbonModifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.key = key
    }

    init?(serialized: String) {
        let parts = serialized.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = UInt32(parts[0]), let mods = UInt32(parts[1]) else {
            return nil
        }
        self.init(keyCode: code, carbonModifiers: mods, key: String(parts[2]))
    }

    /// Build from a recorded key event; requires ⌘/⌥/⌃ (shift alone isn't enough).
    static func from(_ event: NSEvent) -> KeyShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        let key = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard key.count == 1, key != " " else { return nil }
        return KeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, key: key)
    }
}
// ACTIONS_PLACEHOLDER

/// The shortcut-configurable actions.
enum ShortcutAction: String, CaseIterable {
    case area, window, screen, scrolling, pin

    var title: String {
        switch self {
        case .area: return "区域截图"
        case .window: return "窗口截图"
        case .screen: return "全屏截图"
        case .scrolling: return "长截图"
        case .pin: return "钉最近截图"
        }
    }

    /// Unique id for RegisterEventHotKey.
    var hotKeyID: UInt32 {
        switch self {
        case .area: return 1
        case .window: return 2
        case .screen: return 3
        case .scrolling: return 4
        case .pin: return 100
        }
    }

    var defaultShortcut: KeyShortcut {
        let cmdShift = UInt32(cmdKey | shiftKey)
        switch self {
        case .area:      return KeyShortcut(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: cmdShift, key: "X")
        case .window:    return KeyShortcut(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: cmdShift, key: "3")
        case .screen:    return KeyShortcut(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: cmdShift, key: "4")
        case .scrolling: return KeyShortcut(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: cmdShift, key: "5")
        case .pin:       return KeyShortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: cmdShift, key: "V")
        }
    }
}

/// Persists user-customized shortcuts and notifies on change.
enum ShortcutStore {
    static let didChange = Notification.Name("SnapFlowShortcutsChanged")

    static func shortcut(for action: ShortcutAction) -> KeyShortcut {
        if let raw = UserDefaults.standard.string(forKey: key(action)),
           let shortcut = KeyShortcut(serialized: raw) {
            return shortcut
        }
        return action.defaultShortcut
    }

    static func set(_ shortcut: KeyShortcut, for action: ShortcutAction) {
        UserDefaults.standard.set(shortcut.serialized, forKey: key(action))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func key(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }
}

/// Click to record a new global shortcut; shows the current combo otherwise.
final class ShortcutRecorderButton: NSButton {
    private(set) var shortcut: KeyShortcut
    var onChange: ((KeyShortcut) -> Void)?
    private var recording = false { didSet { updateTitle() } }

    init(shortcut: KeyShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(equalToConstant: 130).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { preconditionFailure("code-only") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    private func updateTitle() {
        title = recording ? "按下快捷键…" : shortcut.display
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; return }   // ESC cancels
        if let shortcut = KeyShortcut.from(event) {
            self.shortcut = shortcut
            recording = false
            onChange?(shortcut)
        }
        // Otherwise keep waiting for a valid combo.
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }
}


