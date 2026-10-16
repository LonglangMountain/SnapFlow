import Accelerate
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
    // Coarse-pass height cap. Too low and large regions get downsampled 10×+,
    // text lines alias, and the coarse pass locks onto a wrong (larger) period —
    // which the ±vf refine can't recover from → repeated content in the stitch.
    private let maxMatchHeight = 400
    // Refine pass: columns kept (enough that a small row label still differs)
    // how many full-res rows are compared, and how many coarse minima to try.
    private let refineWidth = 512
    private let maxRefineBand = 480
    private let maxCandidates = 16

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

        // Search BOTH directions. Backward motion (scrolling back, or the
        // rubber-band bounce at the end of a page) has no positive answer, and
        // on periodic content a "+N rows" alias then matches almost perfectly
        // and gets appended — the 37/38/37/38… repeats at the bottom of a
        // table. With negative shifts in range the true backward offset wins
        // and the caller simply skips the frame.
        let coarse = shift(prev: p, cur: c, width: w, anchor: anchor,
                           range: -maxShift...maxShift)
        guard let best = coarse.first else { return OverlapResult(offset: 0, confidence: 0) }

        // Pixel-accurate refine over SEVERAL coarse candidates. On periodic
        // content (tables whose rows differ only by a small index/label) every
        // row-pitch alias scores about the same in the low-res coarse pass, so
        // its winner is often a wrong period → rows duplicated or skipped in the
        // stitch. Re-scoring each candidate at full vertical and much higher
        // horizontal resolution lets the true offset (an exact pixel match) win.
        // Confidence comes from that pixel-exact score.
        if let refined = refine(previous: previous, current: current,
                                candidates: coarse.map { $0.offset * vf }, window: vf,
                                fullHeight: fullHeight) {
            return OverlapResult(offset: refined.offset, confidence: confidence(refined.score))
        }
        return OverlapResult(offset: best.offset * vf, confidence: confidence(best.score))
    }

    private func confidence(_ score: Double) -> Double { max(0, 1 - score / 24.0) }

    /// Re-scores shifts in `candidate ± window` for each candidate using
    /// full-resolution rows and up to `refineWidth` columns, so the returned
    /// offset is pixel-exact, along with its mean-absolute-difference score.
    /// Returns nil when no candidate's band fits in the frame (caller falls
    /// back to the coarse estimate).
    private func refine(previous: CGImage, current: CGImage,
                        candidates: [Int], window: Int,
                        fullHeight: Int) -> (offset: Int, score: Double)? {
        let w = min(refineWidth, current.width)
        let anchorPx = max(1, fullHeight / 20)
        // Only gray what is compared: a short band of `current`, and the rows
        // of `previous` the candidate shifts can reach. For a shift d,
        // cur[top + y] is compared with prev[top + d + y]; `top` is pushed down
        // by the most negative shift so prev rows never go above the anchor.
        let lo = max(-(fullHeight / 2), (candidates.min() ?? 0) - window)
        let top = anchorPx + max(0, -lo)
        let hi = min(fullHeight - top - 9, (candidates.max() ?? 0) + window)
        guard hi >= lo else { return nil }
        let curBand = min(maxRefineBand, fullHeight - top - max(0, lo))
        let prevTop = top + lo
        let prevRows = min(fullHeight - prevTop, (hi - lo) + maxRefineBand)
        guard curBand > 8,
              let curBytes = grayscaleBand(current, top: top, height: curBand, width: w),
              let prevBytes = grayscaleBand(previous, top: prevTop, height: prevRows, width: w) else {
            return nil
        }
        let cur = toFloat(curBytes), prev = toFloat(prevBytes)
        var scratch = [Float](repeating: 0, count: curBand * w)

        var bestD = Int.min
        var bestScore = Float.greatestFiniteMagnitude
        var tried = Set<Int>()
        for approx in candidates {
            let dLo = max(lo, approx - window), dHi = min(hi, approx + window)
            guard dLo <= dHi else { continue }
            for d in dLo...dHi where tried.insert(d).inserted {
                // Previous needs rows up to top + d + band; cap the band to fit.
                let band = min(curBand, prevRows - (d - lo))
                guard band > 8 else { continue }
                let score = meanAbsDiff(cur, 0, prev, (d - lo) * w,
                                        count: band * w, scratch: &scratch)
                // Near-ties go to the smaller shift: an alias then can't
                // over-estimate, and a backward/forward tie is skipped.
                if score < bestScore - 1e-4 || (abs(score - bestScore) <= 1e-4 && d < bestD) {
                    bestScore = score
                    bestD = d
                }
            }
        }
        return bestD != Int.min ? (bestD, Double(bestScore)) : nil
    }


    /// Scores each signed shift `d` over the full overlap (`cur[y]` vs
    /// `prev[y + d]`, rows below the anchor) and returns the best few local
    /// minima (lowest score first) as candidates for the refine pass.
    private func shift(prev prevBytes: [UInt8], cur curBytes: [UInt8], width w: Int,
                       anchor: Int, range: ClosedRange<Int>) -> [(offset: Int, score: Double)] {
        let height = prevBytes.count / w
        let cur = toFloat(curBytes), prev = toFloat(prevBytes)
        var scratch = [Float](repeating: 0, count: cur.count)
        var scores: [Float] = []
        var offsets: [Int] = []
        for d in range {
            let curStart = anchor + max(0, -d)
            let rows = height - curStart - max(0, d)
            guard rows > 0 else { continue }
            // Rows are contiguous, so each overlap is one flat run of bytes.
            scores.append(meanAbsDiff(cur, curStart * w, prev, (curStart + d) * w,
                                      count: rows * w, scratch: &scratch))
            offsets.append(d)
        }
        var minima: [(offset: Int, score: Double)] = []
        for (i, s) in scores.enumerated() {
            let left = i > 0 ? scores[i - 1] : .greatestFiniteMagnitude
            let right = i + 1 < scores.count ? scores[i + 1] : .greatestFiniteMagnitude
            if s <= left && s <= right { minima.append((offsets[i], Double(s))) }
        }
        return Array(minima.sorted { $0.score < $1.score }.prefix(maxCandidates))
    }

    private func toFloat(_ bytes: [UInt8]) -> [Float] {
        vDSP.integerToFloatingPoint(bytes, floatingPointType: Float.self)
    }

    /// Mean |a - b| over `count` elements starting at the given offsets.
    /// Vectorized via vDSP so it stays fast even in unoptimized debug builds
    /// (the scalar loop took ~650ms/frame there and lagged the HUD).
    private func meanAbsDiff(_ a: [Float], _ aOff: Int, _ b: [Float], _ bOff: Int,
                             count: Int, scratch: inout [Float]) -> Float {
        var sum: Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                scratch.withUnsafeMutableBufferPointer { sp in
                    let n = vDSP_Length(count)
                    // vDSP_vsub computes B - A.
                    vDSP_vsub(bp.baseAddress! + bOff, 1, ap.baseAddress! + aOff, 1,
                              sp.baseAddress!, 1, n)
                    vDSP_svemg(sp.baseAddress!, 1, &sum, n)
                }
            }
        }
        return sum / Float(count)
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
            // Area-averaged downsampling; `.low` is near point-sampling and
            // aliases text rows when a large frame is shrunk a lot.
            ctx.interpolationQuality = .high
            // A bitmap context's memory starts at the image's top row, so
            // drawing straight in already gives buffer row 0 == top of image.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }
}
