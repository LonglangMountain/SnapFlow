import AppKit
import ApplicationServices

/// Drives scrolling of the target during a long capture.
///
/// V1 uses synthetic scroll-wheel events (CGEvent) posted after warping the
/// cursor over the capture region. Actual movement is never trusted blindly —
/// ImageMatcher measures the real delta from the frames (see design §10) — so
/// this only needs to produce a consistent downward scroll with overlap.
/// A future refinement is AXUIElement-based targeting (design §13).
final class ScrollController {

    /// Whether the process may post synthetic events. Prompts once if needed.
    @discardableResult
    func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
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
