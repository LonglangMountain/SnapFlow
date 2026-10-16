import AppKit

/// Coordinates the long-capture pipeline (design §8–§14):
/// capture → (user scrolls) → capture → match overlap → append new strip → stitch.
///
/// Scrolling is driven by the user, not synthetic events: the manager just polls
/// the region and appends whatever new content the user reveals by scrolling.
final class LongCaptureManager {

    private enum State { case running, finishRequested, cancelRequested }

    private let capturer: ScreenCapturer
    private let matcher = ImageMatcher()
    private let stitcher = ImageStitcher()
    private var hud: LongCaptureHUD?
    private var bar: LongCaptureBar?
    private var regionFrame: RegionFrameWindow?
    private var state: State = .running

    // Auto scroll: one fixed step per processed frame, so the content moves a
    // bounded amount between consecutive frames no matter how fast matching
    // runs — unlike a hand-flicked scroll that can outrun the matcher.
    //
    // Steps are plain wheel events at the pointer, posted ONLY while the
    // pointer is inside the capture region (same model as CleanShot X): moving
    // the mouse out pauses, moving it back resumes. Nothing ever moves or pins
    // the pointer — targeting another spot made macOS drag the cursor there,
    // and Chrome ignores wheel events posted straight to its process.
    private let scroller = ScrollController()
    private var autoScrolling = false
    /// Last time an auto step actually moved the page (page-end detection);
    /// time spent with the pointer outside the region doesn't count.
    private var lastAutoMoveAt = Date.distantPast
    private let autoStallSeconds: TimeInterval = 2.0

    /// Called with the stitched image (or nil on failure/cancel).
    var onFinish: (@MainActor (CGImage?) -> Void)?

    // The user decides when to stop, so height is the real bound; segment count
    // is just a backstop against runaway growth.
    private let maxSegments = 2000
    private let maxTotalHeight = 30_000

    init(capturer: ScreenCapturer) {
        self.capturer = capturer
    }

    func start(region: CGRect, screen: NSScreen) {
        Task { @MainActor in await run(region: region, screen: screen) }
    }

    @MainActor
    private func run(region: CGRect, screen: NSScreen) async {
        state = .running

        // Resolve the content filter ONCE. Enumerating shareable content is slow
        // (~100s of ms); doing it per frame was the real cause of the laggy
        // counter/preview. Reuse this filter for every poll.
        guard let filter = await capturer.makeContentFilter(for: screen),
              let first = await capturer.captureRegion(region, on: screen, using: filter) else {
            onFinish?(nil)
            return
        }

        var segments: [CGImage] = [first]
        var totalHeight = first.height
        var previous = first

        let hud = LongCaptureHUD()
        hud.present(region: region, on: screen)
        self.hud = hud

        // Bottom action bar carries the height readout and the 取消 / 完成 controls.
        let bar = LongCaptureBar()
        bar.onDone = { [weak self] in
            self?.state = .finishRequested
            self?.hideUIImmediately()
        }
        bar.onCancel = { [weak self] in
            self?.state = .cancelRequested
            self?.hideUIImmediately()
        }
        bar.onToggleAutoScroll = { [weak self] in
            self?.toggleAutoScroll()
        }
        bar.present(region: region, on: screen)
        bar.update(heightPx: totalHeight)
        self.bar = bar

        // Keep a border around the capture region so the user can see the range
        // while scrolling. It's click-through and excluded from the shot.
        let frame = RegionFrameWindow(region: region, screen: screen)
        frame.orderFrontRegardless()
        self.regionFrame = frame

        // Movement smaller than this (relative to the last committed frame) is
        // treated as "the user hasn't scrolled yet".
        let minMove = max(2, first.height / 200)
        // Auto-scroll step in points per processed frame. Kept small so the
        // scroll reads as a slow, steady crawl.
        let autoStep = Int(max(4, min(16, region.height * 0.035)))
        // The region in global Cocoa coordinates, for the pointer-inside test.
        let regionGlobal = region.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)

        // Live preview is built INCREMENTALLY. New slice thumbnails are queued
        // and flushed to the HUD at most ~8×/sec, so the preview (and its window
        // resize) don't update on every single slice and lag behind.
        var previewThumb = Self.thumbnail(first)
        if let previewThumb { hud.updatePreview(previewThumb) }
        var pendingThumbs: [CGImage] = []
        var lastPreviewAt = Date.distantPast

        // Keep one capture in flight at all times: the NEXT frame is grabbed
        // while the current one is being matched, so the loop rate is bound by
        // the slower of the two instead of their sum. (The full-screen grab +
        // crop is used because `sourceRect` region captures come back soft.)
        var inFlight = Task { await capturer.captureRegion(region, on: screen, using: filter) }

        while true {
            if state == .cancelRequested { inFlight.cancel(); cleanup(); onFinish?(nil); return }
            if state == .finishRequested { inFlight.cancel(); break }
            if segments.count >= maxSegments || totalHeight >= maxTotalHeight {
                inFlight.cancel(); break
            }

            let captured = await inFlight.value
            // Advance the auto scroll by one step per frame, before grabbing
            // the next one — only while the pointer is over the region.
            let pointerInside = NSMouseInRect(NSEvent.mouseLocation, regionGlobal, false)
            if autoScrolling {
                if pointerInside {
                    scroller.scrollDown(pixels: autoStep)
                } else {
                    lastAutoMoveAt = Date()   // paused by the user, not stalled
                }
                bar.setAutoScrollPaused(!pointerInside)
            }
            // Start the next grab immediately so it overlaps the matching below.
            inFlight = Task { await capturer.captureRegion(region, on: screen, using: filter) }

            guard let current = captured else {
                try? await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            // Run the (CPU-heavy) frame matching off the main thread so scrolling
            // and button clicks stay responsive.
            let result = await Task.detached(priority: .userInitiated) { [previous] in
                ImageMatcher().findOverlap(previous: previous, current: current)
            }.value

            // No confident downward movement since the last committed frame —
            // the user is paused or scrolled back. Wait for the next poll rather
            // than stopping, since only the user decides when to finish.
            if result.confidence < 0.5 || result.offset < minMove {
                // Auto scroll that stops moving for a while has hit the page
                // end: turn it off (don't finish — the user still decides ✓).
                if autoScrolling, Date().timeIntervalSince(lastAutoMoveAt) > autoStallSeconds {
                    setAutoScroll(false)
                }
                continue
            }
            lastAutoMoveAt = Date()

            let d = min(result.offset, current.height)
            let sliceRect = CGRect(x: 0, y: current.height - d, width: current.width, height: d)
            if let slice = current.cropping(to: sliceRect) {
                segments.append(slice)
                totalHeight += d
                bar.update(heightPx: totalHeight)

                // Queue the slice thumbnail; flush to the HUD at most ~8×/sec.
                if let sliceThumb = Self.thumbnail(slice) { pendingThumbs.append(sliceThumb) }
                let now = Date()
                if now.timeIntervalSince(lastPreviewAt) > 0.12, !pendingThumbs.isEmpty {
                    lastPreviewAt = now
                    for t in pendingThumbs {
                        previewThumb = previewThumb.flatMap { Self.stack($0, t) } ?? t
                    }
                    pendingThumbs.removeAll()
                    if let previewThumb { hud.updatePreview(previewThumb) }
                }
            }
            previous = current
        }

        cleanup()
        // Final full-resolution stitch off the main thread so the 完成 click
        // doesn't freeze the UI while a long shot is assembled.
        let finalSegments = segments
        let stitched = await Task.detached(priority: .userInitiated) {
            ImageStitcher().stitch(finalSegments)
        }.value
        onFinish?(stitched)
    }

    /// Vertically stack two same-width thumbnails (top above bottom).
    private static func stack(_ top: CGImage, _ bottom: CGImage) -> CGImage? {
        let w = max(top.width, bottom.width)
        let h = top.height + bottom.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Bottom-left origin: `bottom` sits at y=0, `top` above it.
        ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height))
        ctx.draw(top, in: CGRect(x: 0, y: bottom.height, width: top.width, height: top.height))
        return ctx.makeImage()
    }

    /// Downscale a stitched image to a light preview (cap the wider dimension).
    private static func thumbnail(_ image: CGImage, maxWidth: CGFloat = 240) -> CGImage? {
        let scale = min(1, maxWidth / CGFloat(image.width))
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// ▶ / ❚❚ on the bar. Turning it on doesn't move the pointer; scrolling
    /// starts once the user moves the pointer into the capture region.
    private func toggleAutoScroll() {
        if !autoScrolling {
            // Posting scroll events needs the Accessibility grant. If macOS
            // still says no although the switch looks on, the stored grant
            // belongs to an older build's signature — explain how to reset it
            // instead of re-showing the system prompt every click.
            guard scroller.ensureAccessibilityPermission() else {
                MainActor.assumeIsolated { showAccessibilityHelp() }
                return
            }
        }
        setAutoScroll(!autoScrolling)
    }

    private func setAutoScroll(_ on: Bool) {
        autoScrolling = on
        lastAutoMoveAt = Date()
        MainActor.assumeIsolated { bar?.setAutoScrolling(on) }
    }

    @MainActor
    private func showAccessibilityHelp() {
        let alert = NSAlert()
        alert.messageText = "自动滚动需要「辅助功能」权限"
        alert.informativeText = """
            如果列表里 SnapFlow 已经是打开状态仍无效，说明授权记录属于旧版本：\
            请在列表中选中 SnapFlow，点「−」删除，再点 ▶ 重新授权。
            """
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    private func cleanup() {
        autoScrolling = false
        hud?.orderOut(nil)
        hud = nil
        bar?.dismiss()
        bar = nil
        regionFrame?.orderOut(nil)
        regionFrame = nil
    }

    /// Hide the overlay chrome the instant 完成 / 取消 is clicked, so the action
    /// feels immediate instead of waiting for the capture loop to notice.
    private func hideUIImmediately() {
        autoScrolling = false
        MainActor.assumeIsolated {
            hud?.orderOut(nil)
            bar?.dismiss()
            regionFrame?.orderOut(nil)
        }
    }
}
