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
            if result.confidence < 0.5 || result.offset < minMove { continue }

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

    @MainActor
    private func cleanup() {
        hud?.orderOut(nil)
        hud = nil
        bar?.orderOut(nil)
        bar = nil
        regionFrame?.orderOut(nil)
        regionFrame = nil
    }

    /// Hide the overlay chrome the instant 完成 / 取消 is clicked, so the action
    /// feels immediate instead of waiting for the capture loop to notice.
    private func hideUIImmediately() {
        MainActor.assumeIsolated {
            hud?.orderOut(nil)
            bar?.orderOut(nil)
            regionFrame?.orderOut(nil)
        }
    }
}
