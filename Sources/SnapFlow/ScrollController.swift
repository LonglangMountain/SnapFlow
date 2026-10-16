import AppKit
import ApplicationServices

/// Drives scrolling of the target during a long capture.
///
/// Posts plain synthetic scroll-wheel events (CGEvent) at the current pointer
/// position; the long-capture loop only does so while the pointer is over the
/// capture region. Actual movement is never trusted blindly — ImageMatcher
/// measures the real delta from the frames (see design §10) — so this only
/// needs to produce a consistent downward scroll with overlap.
final class ScrollController {

    /// Whether the process may post synthetic events. Prompts once if needed.
    ///
    /// Accessibility trust is what lets `CGEvent.post` reach other apps. The
    /// post-event preflight is also accepted, but it can keep returning false
    /// for the running process even after the grant (seen on macOS 15), so it
    /// must not be the only check.
    @discardableResult
    func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() || CGPreflightPostEventAccess() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Move the pointer over the region so scroll events hit the right view.
    /// - Parameter cgPoint: CoreGraphics global point (top-left origin).
    func warpCursor(to cgPoint: CGPoint) {
        CGWarpMouseCursorPosition(cgPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func scrollDown(pixels: Int) {
        postScroll(delta: -abs(pixels))
    }

    func scrollUp(pixels: Int) {
        postScroll(delta: abs(pixels))
    }

    func stop() {
        // No retained state yet; present for API completeness (design §13).
    }

    private func postScroll(delta: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 1,
                                  wheel1: Int32(delta),
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}
