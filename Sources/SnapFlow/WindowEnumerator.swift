import AppKit
import ScreenCaptureKit

/// A capturable on-screen window, per the design doc's WindowInfo.
struct WindowInfo {
    let windowID: CGWindowID
    /// Global frame in CoreGraphics coordinates (top-left origin, points).
    let frame: CGRect
    let title: String?
    let ownerName: String
    /// Underlying ScreenCaptureKit window used for the actual capture.
    let scWindow: SCWindow
}

/// Coordinate conversions between Cocoa (bottom-left origin, global) and
/// CoreGraphics (top-left origin, global) point spaces.
enum Geometry {
    /// Height of the primary screen — the origin reference for both spaces.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Cocoa global point -> CoreGraphics global point.
    static func cocoaToCG(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// CoreGraphics global rect -> Cocoa global rect.
    static func cgToCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// The screen containing a Cocoa global point.
    static func screen(atCocoa point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// The screen the pointer is on, falling back to the main screen.
    static var screenUnderMouse: NSScreen? {
        screen(atCocoa: NSEvent.mouseLocation) ?? NSScreen.main
    }

    /// The screen a CoreGraphics-space rect (e.g. a window frame) sits on.
    static func screen(forCGRect rect: CGRect) -> NSScreen? {
        let cocoa = cgToCocoa(rect)
        return screen(atCocoa: CGPoint(x: cocoa.midX, y: cocoa.midY)) ?? NSScreen.main
    }

    /// Centers `window` inside `screen`'s visible frame.
    ///
    /// `NSWindow.center()` centers on the window's *current* screen, which for a
    /// freshly created window at origin (0,0) is always the primary display — so
    /// it can't place a window on the screen a capture came from.
    static func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2))
    }
}

/// Enumerates capturable windows via ScreenCaptureKit, front-to-back.
final class WindowEnumerator {

    /// Returns on-screen, normal-layer windows excluding SnapFlow's own,
    /// ordered front (index 0) to back.
    func windows() async -> [WindowInfo] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            let selfPID = ProcessInfo.processInfo.processIdentifier

            return content.windows.compactMap { scWindow -> WindowInfo? in
                guard scWindow.isOnScreen,
                      scWindow.windowLayer == 0,
                      scWindow.frame.width >= 20,
                      scWindow.frame.height >= 20 else { return nil }
                if let owner = scWindow.owningApplication, owner.processID == selfPID {
                    return nil
                }
                return WindowInfo(windowID: scWindow.windowID,
                                  frame: scWindow.frame,
                                  title: scWindow.title,
                                  ownerName: scWindow.owningApplication?.applicationName ?? "",
                                  scWindow: scWindow)
            }
        } catch {
            NSLog("SnapFlow: window enumeration failed: \(error.localizedDescription)")
            return []
        }
    }
}
