import CoreGraphics

/// Concatenates the captured segments into the final tall image (design §8/§9).
///
/// `segments[0]` is the first full frame; each later segment is the strip of
/// new content revealed by a scroll. Stacking them top-to-bottom reconstructs
/// the full scrollable content.
final class ImageStitcher {

    func stitch(_ segments: [CGImage]) -> CGImage? {
        guard let first = segments.first else { return nil }
        let width = segments.map(\.width).max() ?? first.width
        let totalHeight = segments.reduce(0) { $0 + $1.height }
        guard width > 0, totalHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: totalHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else {
            return nil
        }

        // CGContext origin is bottom-left; fill from the top downwards.
        // Draw each segment at its OWN width with interpolation off, so slices
        // are copied 1:1 instead of being resampled (which softened the result
        // whenever a slice differed from the widest one by even a pixel).
        ctx.interpolationQuality = .none
        var top = totalHeight
        for segment in segments {
            let h = segment.height
            let rect = CGRect(x: 0, y: top - h, width: segment.width, height: h)
            ctx.draw(segment, in: rect)
            top -= h
        }

        return ctx.makeImage()
    }
}
