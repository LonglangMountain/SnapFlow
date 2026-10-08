import AppKit
import ImageIO

/// The four capture modes from the design doc.
enum CaptureMode: Int {
    case area = 1
    case window = 2
    case screen = 3
    case scrolling = 4
}

/// Orchestrates the capture pipeline: HotKey / menu -> mode -> overlay (for
/// area/window) -> ScreenCaptureKit -> PNG + clipboard.
final class CaptureManager: NSObject, CaptureOverlayDelegate, WindowSelectionDelegate {

    private var overlays: [CaptureOverlayWindow] = []
    private var windowOverlays: [WindowSelectionOverlayWindow] = []
    private var candidateWindows: [WindowInfo] = []
    private let capturer = ScreenCapturer()
    private let windowEnumerator = WindowEnumerator()
    private lazy var longCapture = LongCaptureManager(capturer: capturer)
    private let pinManager = PinManager()
    private var lastImage: CGImage?
    private var areaSelectionForLong = false
    private var editors: [EditorWindowController] = []
    private var inPlaceEditor: InPlaceEditorController?
    private var settingsController: SettingsWindowController?
    private var isCapturing = false

    func begin(_ mode: CaptureMode) {
        // Include already-pinned screenshots in this capture (they're our own
        // windows, which are otherwise excluded).
        capturer.includedWindowNumbers = pinManager.pinnedWindowIDs
        switch mode {
        case .area:
            beginAreaCapture()
        case .window:
            beginWindowCapture()
        case .screen:
            beginScreenCapture()
        case .scrolling:
            beginLongCapture()
        }
    }

    // MARK: - Area capture

    private func beginAreaCapture() {
        areaSelectionForLong = false
        presentAreaOverlays()
    }

    /// Long capture reuses the area-selection UI to pick the scroll region.
    private func beginLongCapture() {
        areaSelectionForLong = true
        presentAreaOverlays()
    }

    private func presentAreaOverlays() {
        guard !isCapturing else { return }
        isCapturing = true

        teardownOverlays()
        // One overlay per screen so multi-monitor selections stay in the
        // correct display's coordinate space.
        for screen in NSScreen.screens {
            let overlay = CaptureOverlayWindow(screen: screen)
            overlay.overlayDelegate = self
            overlays.append(overlay)
        }

        NSApp.activate(ignoringOtherApps: true)
        for overlay in overlays {
            overlay.makeKeyAndOrderFront(nil)
        }
    }

    func overlay(_ overlay: CaptureOverlayWindow, didSelect rect: CGRect, on screen: NSScreen) {
        let forLong = areaSelectionForLong
        areaSelectionForLong = false
        guard rect.width >= 1, rect.height >= 1 else {
            teardownOverlays()
            isCapturing = false
            return
        }
        if forLong {
            teardownOverlays()
            longCapture.onFinish = { [weak self] image in
                self?.finishLong(with: image)
            }
            longCapture.start(region: rect, screen: screen)
        } else {
        // Snap the selection to WHOLE POINTS, then use the exact same rect for
        // both the capture crop and the on-screen canvas placement. Whole points
        // (not just the device-pixel grid) matter because a pinned NSWindow can
        // only sit on a whole-point origin — an odd (half-point) selection forces
        // the window server to round it, which both nudges the pin a pixel off
        // and makes its layer resample (blurry). Keeping capture, editor and pin
        // all on whole points makes them line up exactly and render 1:1.
            func snap(_ v: CGFloat) -> CGFloat { v.rounded() }
            let aligned = CGRect(x: snap(rect.minX), y: snap(rect.minY),
                                 width: snap(rect.width), height: snap(rect.height))

            // Keep the selected screen's overlay as the dim + selection backdrop
            // and edit *inside* it, so the frozen image lines up with the
            // selection exactly and renders 1:1 (design: keep the shot in place).
            for other in overlays where other !== overlay { other.orderOut(nil) }
            overlays = [overlay]
            overlay.enterEditing()
            Task { @MainActor in
                // Freeze the WHOLE screen once, then crop. Live resizing re-crops
                // from this frozen grab, so it stays crisp with no stretch and no
                // extra ScreenCaptureKit round-trips.
                guard let full = await capturer.captureFullScreen(screen),
                      let image = self.crop(full, region: aligned, screen: screen) else {
                    teardownOverlays(); isCapturing = false; return
                }
                persist(image, type: "area")
                presentInPlaceEditor(image: image, full: full, in: overlay,
                                     selection: aligned, on: screen)
            }
        }
    }

    /// Crop a screen-local region (points, bottom-left) out of a frozen full
    /// screen grab (pixels, top-left).
    private func crop(_ full: CGImage, region: CGRect, screen: NSScreen) -> CGImage? {
        let sx = CGFloat(full.width) / screen.frame.width
        let sy = CGFloat(full.height) / screen.frame.height
        let screenHeight = screen.frame.height
        let rect = CGRect(x: (region.minX * sx).rounded(.down),
                          y: ((screenHeight - region.maxY) * sy).rounded(.down),
                          width: (region.width * sx).rounded(),
                          height: (region.height * sy).rounded())
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return full.cropping(to: rect)
    }

    /// Auto-save + clipboard + history for a fresh capture (design §18).
    @MainActor
    private func persist(_ image: CGImage, type: String) {
        lastImage = image
        let savedURL = ImageSaver.save(image)
        ImageSaver.copyToClipboard(image)
        if let savedURL {
            HistoryStore.shared.record(filePath: savedURL.path,
                                       width: image.width,
                                       height: image.height,
                                       type: type)
        }
    }

    @MainActor
    private func presentInPlaceEditor(image: CGImage, full: CGImage, in overlay: CaptureOverlayWindow,
                                      selection rect: CGRect, on screen: NSScreen) {
        guard let host = overlay.contentView else {
            teardownOverlays(); isCapturing = false; return
        }
        let controller = InPlaceEditorController(image: image)
        inPlaceEditor = controller
        controller.pixelScale = screen.backingScaleFactor
        // Live resize crops from the frozen full-screen grab — instant & crisp.
        controller.imageProvider = { [weak self] r in self?.crop(full, region: r, screen: screen) }
        // `region` tracks the CURRENT selection (screen-local) as it's resized,
        // so pin / long-capture always use the latest rect. Keep it on whole
        // points so the pin can land exactly and render 1:1 (see the capture
        // snap above for why half-point rects blur / shift the pin).
        func snapRegion(_ v: CGFloat) -> CGFloat { v.rounded() }
        var region = rect
        // Pin in place: keep the pin exactly where the shot was captured.
        controller.onPin = { [weak self] pinned in
            let global = CGRect(x: screen.frame.minX + region.minX,
                                y: screen.frame.minY + region.minY,
                                width: region.width, height: region.height)
            self?.pinManager.pin(pinned, at: global, on: screen)
        }
        // Long-capture reuses the CURRENT selection region directly — no new
        // selection overlay. The frozen editor tears down, then we scroll-capture
        // the exact same rect on the same screen.
        controller.onLongCapture = { [weak self] in
            guard let self else { return }
            self.longCapture.onFinish = { [weak self] image in
                self?.finishLong(with: image)
            }
            self.longCapture.start(region: region, screen: screen)
        }
        // Resize tracks the latest region, snapped to the pixel grid (the crop
        // itself is done by imageProvider).
        controller.onResize = { r in
            region = CGRect(x: snapRegion(r.minX), y: snapRegion(r.minY),
                            width: snapRegion(r.width), height: snapRegion(r.height))
        }
        // Keep the overlay's dim + border in sync while resizing.
        controller.onSelectionChange = { [weak overlay] r in overlay?.updateSelection(r) }
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.teardownOverlays()
            self.inPlaceEditor = nil
            self.isCapturing = false
        }
        controller.install(in: host, selection: rect)
        overlay.makeKeyAndOrderFront(nil)   // so ✓/✗ key equivalents fire
    }

    func overlayDidCancel(_ overlay: CaptureOverlayWindow) {
        teardownOverlays()
        areaSelectionForLong = false
        isCapturing = false
    }

    private func teardownOverlays() {
        for overlay in overlays { overlay.orderOut(nil) }
        overlays.removeAll()
        for overlay in windowOverlays { overlay.orderOut(nil) }
        windowOverlays.removeAll()
        candidateWindows.removeAll()
    }

    // MARK: - Window capture

    private func beginWindowCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            candidateWindows = await windowEnumerator.windows()
            guard !candidateWindows.isEmpty else {
                isCapturing = false
                return
            }
            teardownWindowOverlays()
            for screen in NSScreen.screens {
                let overlay = WindowSelectionOverlayWindow(screen: screen)
                overlay.selectionDelegate = self
                windowOverlays.append(overlay)
            }
            NSApp.activate(ignoringOtherApps: true)
            for overlay in windowOverlays {
                overlay.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func teardownWindowOverlays() {
        for overlay in windowOverlays { overlay.orderOut(nil) }
        windowOverlays.removeAll()
    }

    func windowSelection(_ overlay: WindowSelectionOverlayWindow, didPick window: WindowInfo) {
        teardownOverlays()
        // Open the editor on the display the picked window lives on.
        let screen = Geometry.screen(forCGRect: window.frame)
        Task { @MainActor in
            let image = await capturer.captureWindow(window)
            finish(with: image, type: "window", screen: screen)
        }
    }

    func windowSelectionDidCancel(_ overlay: WindowSelectionOverlayWindow) {
        teardownOverlays()
        isCapturing = false
    }

    func windowSelection(_ overlay: WindowSelectionOverlayWindow,
                         windowAt cgPoint: CGPoint) -> WindowInfo? {
        // candidateWindows is front-to-back, so the first hit is the topmost.
        candidateWindows.first { $0.frame.contains(cgPoint) }
    }

    // MARK: - Full-screen capture

    private func beginScreenCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { isCapturing = false; return }

        Task { @MainActor in
            let image = await capturer.captureFullScreen(screen)
            finish(with: image, type: "screen", screen: screen)
        }
    }

    // MARK: - Shared completion

    @MainActor
    private func finish(with image: CGImage?, type: String, screen: NSScreen?) {
        defer { isCapturing = false }
        guard let image else {
            NSLog("SnapFlow: capture failed")
            teardownOverlays()
            return
        }
        persist(image, type: type)
        // Open the editor on the fresh capture (design §15).
        openEditor(with: image, on: screen)
    }

    /// Long-capture completion: save + clipboard + history, but do NOT open the
    /// editor window (the long shot is delivered silently).
    @MainActor
    private func finishLong(with image: CGImage?) {
        defer { isCapturing = false }
        guard let image else {
            NSLog("SnapFlow: long capture failed")
            teardownOverlays()
            return
        }
        lastImage = image
        // A long shot can be tens of thousands of pixels tall — PNG/TIFF encoding
        // it on the main thread is what made 完成 feel frozen. Do it in the
        // background and return immediately.
        Task { @MainActor in
            let url = await ImageSaver.saveInBackground(image)
            await ImageSaver.copyToClipboardInBackground(image)
            if let url {
                HistoryStore.shared.record(filePath: url.path,
                                           width: image.width,
                                           height: image.height,
                                           type: "long")
            }
        }
    }

    // MARK: - Pin (design §20)

    /// Pins the most recent capture as a floating window (⌘⇧V).
    func pinLatest() {
        MainActor.assumeIsolated {
            let screen = Geometry.screenUnderMouse
            if let image = lastImage {
                pinManager.pin(image, on: screen)
            } else if let record = HistoryStore.shared.mostRecent(),
                      let image = CaptureManager.loadImage(record.filePath) {
                pinManager.pin(image, on: screen)
            }
        }
    }

    static func loadImage(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func openEditor(with image: CGImage, on screen: NSScreen?) {
        let controller = makeEditor(with: image)
        controller.pixelScale = (screen ?? NSScreen.main)?.backingScaleFactor ?? 2
        controller.show(on: screen)
    }

    private func makeEditor(with image: CGImage) -> EditorWindowController {
        let controller = EditorWindowController(image: image)
        controller.onPin = { [weak self] pinned in
            // Pin onto whichever display the user is currently working on.
            self?.pinManager.pin(pinned, on: Geometry.screenUnderMouse)
        }
        controller.onLongCapture = { [weak self] in self?.begin(.scrolling) }
        controller.onClose = { [weak self] closed in
            guard let self else { return }
            self.editors.removeAll { $0 === closed }
            self.updateActivationPolicy()
        }
        editors.append(controller)
        updateActivationPolicy()
        return controller
    }

    // MARK: - Settings

    func openSettings() {
        MainActor.assumeIsolated {
            if settingsController == nil {
                let controller = SettingsWindowController()
                controller.onClose = { [weak self] in
                    self?.settingsController = nil
                    self?.updateActivationPolicy()
                }
                settingsController = controller
            }
            updateActivationPolicy()
            settingsController?.show(on: Geometry.screenUnderMouse)
        }
    }

    /// Show a Dock icon while any window is open; otherwise stay menu-bar-only.
    private func updateActivationPolicy() {
        let hasWindows = !editors.isEmpty
            || settingsController != nil
        NSApp.setActivationPolicy(hasWindows ? .regular : .accessory)
    }
}
