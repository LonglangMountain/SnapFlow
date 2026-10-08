import AppKit

// Phase 1 entry point. SnapFlow runs as a menu bar accessory (no Dock icon,
// no main window), so we build the NSApplication manually rather than using
// @main / SwiftUI App lifecycle.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
