#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Perspective correction of the card quad to a metric top-down view.
public enum Perspective {
    /// Corrected card width used by the pipeline (docs/ALGORITHM.md §1).
    public static let defaultOutputWidth = 2600

    /// Output height for a given width, honoring the ID-1 aspect 85.60 x 53.98 mm.
    public static func outputHeight(forWidth width: Int = defaultOutputWidth) -> Int {
        Int((Double(width) * 53.98 / 85.60).rounded())
    }

    public static func pixelsPerMm(forWidth width: Int = defaultOutputWidth) -> Double {
        Double(width) / 85.60
    }

    /// Margin-aware scale: with `marginFrac` of the output frame padded with
    /// surroundings on every side, the card spans only (1 - 2*marginFrac) of
    /// the width, so its pixels-per-mm drops accordingly. Every downstream
    /// consumer (segmentation margins, blade widths, cut windows) takes this
    /// value — the padded frame is metrically consistent end to end.
    public static func pixelsPerMm(forWidth width: Int, marginFrac: Double) -> Double {
        Double(width) * (1.0 - 2.0 * marginFrac) / 85.60
    }

    /// Grow a card quad about its centroid so the warp source frame contains
    /// the surroundings (`marginFrac` per side). A key hanging off the card
    /// edge keeps its overhanging teeth in the corrected view instead of at
    /// the warp boundary. Degenerate quads return nil.
    public static func expandedQuad(_ quad: [CGPoint], marginFrac: Double) -> [CGPoint]? {
        guard quad.count == 4, marginFrac > 0 else { return nil }
        let cx = quad.reduce(0) { $0 + $1.x } / 4
        let cy = quad.reduce(0) { $0 + $1.y } / 4
        let scale = 1.0 / (1.0 - 2.0 * marginFrac)
        guard scale.isFinite, scale > 1, scale < 8 else { return nil }
        return quad.map { CGPoint(x: cx + ($0.x - cx) * scale, y: cy + ($0.y - cy) * scale) }
    }

    /// Map `quad` (TL,TR,BR,BL in y-down pixels of `src`) onto a top-down card rectangle.
    public static func warpGray(
        _ src: GrayImage, quad: [CGPoint],
        outputWidth: Int = defaultOutputWidth, outputHeight: Int? = nil
    ) -> (image: GrayImage, transform: Homography3)? {
        let outH = outputHeight ?? self.outputHeight(forWidth: outputWidth)
        guard let h = homography(quad: quad, width: outputWidth, height: outH),
              let inv = h.inverted() else { return nil }
        var out = [UInt8](repeating: 0, count: outputWidth * outH)
        for oy in 0..<outH {
            for ox in 0..<outputWidth {
                let s = inv.apply(CGPoint(x: Double(ox), y: Double(oy)))
                out[oy * outputWidth + ox] = bilinear(src, x: s.x, y: s.y)
            }
        }
        guard let img = GrayImage(width: outputWidth, height: outH, pixels: out) else { return nil }
        return (img, h)
    }

    /// Same mapping for a color raster (UI corrected image / saved corrected photo).
    public static func warpColor(
        _ src: RGBAImage, quad: [CGPoint],
        outputWidth: Int = defaultOutputWidth, outputHeight: Int? = nil
    ) -> RGBAImage? {
        let outH = outputHeight ?? self.outputHeight(forWidth: outputWidth)
        guard let h = homography(quad: quad, width: outputWidth, height: outH),
              let inv = h.inverted() else { return nil }
        var out = [UInt8](repeating: 0, count: outputWidth * outH * 4)
        for oy in 0..<outH {
            for ox in 0..<outputWidth {
                let s = inv.apply(CGPoint(x: Double(ox), y: Double(oy)))
                let (fx, fy) = clampedFractional(x: s.x, y: s.y, w: src.width, h: src.height)
                let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                let x1 = min(x0 + 1, src.width - 1), y1 = min(y0 + 1, src.height - 1)
                let tx = fx - Double(x0), ty = fy - Double(y0)
                let o = (oy * outputWidth + ox) * 4
                for c in 0..<4 {
                    let p00 = Double(src.bytes[(y0 * src.width + x0) * 4 + c])
                    let p10 = Double(src.bytes[(y0 * src.width + x1) * 4 + c])
                    let p01 = Double(src.bytes[(y1 * src.width + x0) * 4 + c])
                    let p11 = Double(src.bytes[(y1 * src.width + x1) * 4 + c])
                    let v = (p00 * (1 - tx) + p10 * tx) * (1 - ty) + (p01 * (1 - tx) + p11 * tx) * ty
                    out[o + c] = UInt8(min(255, v.rounded()))
                }
            }
        }
        return RGBAImage(width: outputWidth, height: outH, bytes: out)
    }

    public static func homography(quad: [CGPoint], width: Int, height: Int) -> Homography3? {
        let dst = [
            CGPoint(x: 0, y: 0), CGPoint(x: CGFloat(width), y: 0),
            CGPoint(x: CGFloat(width), y: CGFloat(height)), CGPoint(x: 0, y: CGFloat(height)),
        ]
        return Homography3.fromQuad(quad, to: dst)
    }

    private static func bilinear(_ img: GrayImage, x: CGFloat, y: CGFloat) -> UInt8 {
        let (fx, fy) = clampedFractional(x: x, y: y, w: img.width, h: img.height)
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let x1 = min(x0 + 1, img.width - 1), y1 = min(y0 + 1, img.height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let p00 = Double(img.pixel(x0, y0)), p10 = Double(img.pixel(x1, y0))
        let p01 = Double(img.pixel(x0, y1)), p11 = Double(img.pixel(x1, y1))
        let v = (p00 * (1 - tx) + p10 * tx) * (1 - ty) + (p01 * (1 - tx) + p11 * tx) * ty
        // Plain nearest-rounding: (v + 0.5).rounded() is NOT half-up — with the
        // sub-ulp noise of an inverted homography (n + 1e-10) it crosses the
        // .5 boundary and biases every positive-noise pixel up by 1.
        return UInt8(min(255, v.rounded()))
    }

    private static func clampedFractional(x: CGFloat, y: CGFloat, w: Int, h: Int) -> (Double, Double) {
        let fx = min(Double(w - 1), max(0, Double(x)))
        let fy = min(Double(h - 1), max(0, Double(y)))
        return (fx, fy)
    }
}
