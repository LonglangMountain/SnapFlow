import AppKit
import ScreenCaptureKit

/// Wraps ScreenCaptureKit to produce a CGImage for a region or a full display.
/// Uses SCScreenshotManager (macOS 14+) for one-shot captures.
final class ScreenCapturer {

    /// Window numbers that should still be captured even though they belong to
    /// SnapFlow (i.e. pinned screenshots), so a new shot can include them.
    var includedWindowNumbers: [CGWindowID] = []

    /// Captures a sub-region of `screen`.
    /// - Parameter rect: selection in screen-local coordinates (bottom-left
    ///   origin, points), as produced by the overlay view.
    func captureRegion(_ rect: CGRect, on screen: NSScreen) async -> CGImage? {
        guard let (_, filter) = await displayAndFilter(for: screen) else { return nil }
        return await captureRegion(rect, on: screen, using: filter)
    }

    /// Resolve the content filter once (enumerating shareable content is slow —
    /// the long-capture loop reuses the result rather than doing it per frame).
    func makeContentFilter(for screen: NSScreen) async -> SCContentFilter? {
        await displayAndFilter(for: screen)?.1
    }

    /// Capture a region using a precomputed filter (no per-call enumeration).
    func captureRegion(_ rect: CGRect, on screen: NSScreen,
                       using filter: SCContentFilter) async -> CGImage? {
        // Capture the WHOLE display at native pixel resolution, then crop.
        // ScreenCaptureKit's `sourceRect` uses point/pixel units inconsistently
        // across macOS versions and scaled display modes, which quietly produced
        // a half-resolution (blurry) or shifted region. Cropping a full native
        // capture sidesteps that entirely and is pixel-exact.
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int((screen.frame.width * scale).rounded())
        config.height = Int((screen.frame.height * scale).rounded())
        config.showsCursor = false

        guard let full = await capture(filter: filter, config: config) else { return nil }

        // Derive the real pixels-per-point from what we actually got back, so the
        // crop stays correct even if the system clamped the requested size.
        let sx = CGFloat(full.width) / screen.frame.width
        let sy = CGFloat(full.height) / screen.frame.height
        let screenHeight = screen.frame.height

        // rect is screen-local, bottom-left origin (points). CGImage is
        // top-left origin (pixels). Round to whole pixels so no edge is lost.
        let cropX = (rect.minX * sx).rounded(.down)
        let cropY = ((screenHeight - rect.maxY) * sy).rounded(.down)
        let cropW = (rect.width * sx).rounded()
        let cropH = (rect.height * sy).rounded()
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))

        guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1,
              let cropped = full.cropping(to: cropRect) else { return full }
        return cropped
    }

    /// Captures the entire `screen`.
    func captureFullScreen(_ screen: NSScreen) async -> CGImage? {
        guard let (_, filter) = await displayAndFilter(for: screen) else { return nil }

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int((screen.frame.width * scale).rounded())
        config.height = Int((screen.frame.height * scale).rounded())
        config.showsCursor = false

        return await capture(filter: filter, config: config)
    }

    /// Captures a single window, independent of what is in front of it.
    func captureWindow(_ window: WindowInfo) async -> CGImage? {
        let scale = scaleFactor(for: window.frame)
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: window.scWindow)
        return await capture(filter: filter, config: config)
    }

    // MARK: - Helpers

    /// Backing scale of the screen the window mostly lives on.
    private func scaleFactor(for cgFrame: CGRect) -> CGFloat {
        let cocoa = Geometry.cgToCocoa(cgFrame)
        let center = CGPoint(x: cocoa.midX, y: cocoa.midY)
        let screen = Geometry.screen(atCocoa: center) ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2
    }

    private func capture(filter: SCContentFilter, config: SCStreamConfiguration) async -> CGImage? {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: config)
        } catch {
            NSLog("SnapFlow: SCScreenshotManager failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolves the SCDisplay for an NSScreen and builds a filter that excludes
    /// SnapFlow's own windows (so the dimming overlay never lands in the shot).
    private func displayAndFilter(for screen: NSScreen) async -> (SCDisplay, SCContentFilter)? {
        guard let displayID = screen.displayID else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            let selfApps = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            // Exclude our own UI (overlay/editor/HUD) but KEEP pinned screenshots
            // so a new capture can include them.
            let keep = content.windows.filter { includedWindowNumbers.contains($0.windowID) }
            let filter = SCContentFilter(display: display,
                                         excludingApplications: selfApps,
                                         exceptingWindows: keep)
            return (display, filter)
        } catch {
            NSLog("SnapFlow: SCShareableContent failed: \(error.localizedDescription)")
            return nil
        }
    }
}

private extension NSScreen {
    /// The CoreGraphics display ID backing this screen.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
