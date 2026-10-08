import CoreGraphics

/// The result of matching two consecutive long-capture frames (design §11).
struct OverlapResult {
    /// How far (in full-resolution pixels) the content moved up between frames.
    let offset: Int
    /// 0...1 match quality; low values mean the frames didn't align well.
    let confidence: Double
}

/// Estimates the vertical scroll delta between two frames.
///
/// For a downward scroll of `d` rows, `current[y]` shows the same content as
/// `previous[y + d]`. We find `d` by scoring the alignment over the **entire
/// overlap region** (mean absolute difference), not a small window.
///
/// Scoring the whole overlap is what makes this robust on repetitive content
/// (lists, JSON): a small window matches equally well at every row-pitch, but
/// the full overlap only matches at the true offset because real pages carry
/// non-repeating detail (avatars, text, timestamps) that a periodic shift can't
/// line up. To keep the average fair we require at least half the frame to
/// overlap (so every candidate is scored over many rows) and cap the search
/// there — the user just scrolls in steps smaller than half the capture height.
final class ImageMatcher {

    private let matchWidth = 64
    private let maxMatchHeight = 150

    func findOverlap(previous: CGImage, current: CGImage) -> OverlapResult {
        let fullHeight = current.height
        guard fullHeight > 20, current.width > 0 else {
            return OverlapResult(offset: 0, confidence: 0)
        }

        let vf = max(1, fullHeight / maxMatchHeight)
        let h = max(10, fullHeight / vf)
        let w = matchWidth

        guard let p = grayscale(previous, width: w, height: h),
              let c = grayscale(current, width: w, height: h) else {
            return OverlapResult(offset: 0, confidence: 0)
        }

        // Skip a sliver off the top so a sticky header doesn't pin the match.
        let anchor = max(1, h / 20)
        let maxShift = h / 2
        guard maxShift >= 1 else { return OverlapResult(offset: 0, confidence: 0) }

        let coarse = shift(prev: p, cur: c, width: w, anchor: anchor,
                           range: 0...maxShift)
        let approx = coarse.offset * vf

        // Pixel-accurate refine. The coarse pass is quantized to `vf` px, which
        // leaves every stitch seam a few pixels off (faint doubling → the image
        // looks soft). Re-score a SMALL window of shifts around `approx` at full
        // vertical resolution. Unlike the old refine this never re-renders the
        // whole frame — it only grays a short band — so it stays cheap.
        let refined = refine(previous: previous, current: current,
                             approx: approx, window: vf,
                             fullHeight: fullHeight, width: w)
        return OverlapResult(offset: refined ?? approx, confidence: confidence(coarse.score))
    }

    private func confidence(_ score: Double) -> Double { max(0, 1 - score / 64.0) }

    /// Re-scores shifts in `approx ± window` using full-resolution rows, so the
    /// returned offset is pixel-exact. Returns nil when the band would run past
    /// the frame (caller falls back to the coarse estimate).
    private func refine(previous: CGImage, current: CGImage,
                        approx: Int, window: Int,
                        fullHeight: Int, width w: Int) -> Int? {
        let anchorPx = max(1, fullHeight / 20)
        let lo = max(0, approx - window)
        let hi = approx + window
        // Previous needs rows up to anchorPx + hi + band; cap the band to fit.
        let maxBand = fullHeight - anchorPx - hi
        guard maxBand > 8 else { return nil }
        let band = min(240, maxBand)

        guard let cur = grayscaleBand(current, top: anchorPx, height: band, width: w),
              let prev = grayscaleBand(previous, top: anchorPx + lo,
                                       height: (hi - lo) + band, width: w) else {
            return nil
        }

        var bestD = approx
        var bestScore = Double.greatestFiniteMagnitude
        for d in lo...hi {
            let pBase = (d - lo) * w
            var sum = 0
            for y in 0..<band {
                let cRow = y * w
                let pRow = pBase + y * w
                for x in 0..<w {
                    sum += abs(Int(cur[cRow + x]) - Int(prev[pRow + x]))
                }
            }
            if Double(sum) < bestScore {
                bestScore = Double(sum)
                bestD = d
            }
        }
        return bestD
    }


    /// Scores each shift `d` over the full overlap `cur[anchor..<H-d]` vs
    /// `prev[anchor+d..<H]` and returns the best. Ties break toward the smaller
    /// shift so a marginally-better periodic match can't over-estimate.
    private func shift(prev: [UInt8], cur: [UInt8], width w: Int,
                       anchor: Int, range: ClosedRange<Int>) -> (offset: Int, score: Double) {
        let height = prev.count / w
        var bestD = range.lowerBound
        var bestScore = Double.greatestFiniteMagnitude
        for d in range {
            let rows = height - anchor - d
            guard rows > 0 else { break }
            var sum = 0
            for y in 0..<rows {
                let cRow = (anchor + y) * w
                let pRow = (anchor + d + y) * w
                for x in 0..<w {
                    sum += abs(Int(cur[cRow + x]) - Int(prev[pRow + x]))
                }
            }
            let norm = Double(sum) / Double(rows * w)
            if norm < bestScore {
                bestScore = norm
                bestD = d
            }
        }
        return (bestD, bestScore)
    }

    /// Grays a vertical band `[top, top+height)` of `image` at **full vertical
    /// resolution** (only the width is reduced to `w`). Used by the refine pass
    /// so the per-row comparison is pixel-exact.
    private func grayscaleBand(_ image: CGImage, top: Int, height: Int, width w: Int) -> [UInt8]? {
        guard top >= 0, height > 0, top + height <= image.height else { return nil }
        guard let crop = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height)) else {
            return nil
        }
        return grayscale(crop, width: w, height: height)
    }

    /// Renders `image` into a top-left-origin grayscale byte buffer.
    private func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var data = [UInt8](repeating: 0, count: width * height)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .low
            // A bitmap context's memory starts at the image's top row, so
            // drawing straight in already gives buffer row 0 == top of image.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }
}
