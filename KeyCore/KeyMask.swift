import Foundation

/// Key blob mask on a perspective-corrected card image (docs/ALGORITHM.md §2).
public struct KeyMaskResult {
    public let mask: [Bool]
    public let width: Int
    public let height: Int
    public let pixelsPerMm: Double
    public let backgroundLevel: Double
    public let threshold: UInt8
    public let blobAreaFraction: Double
}

public enum KeySegmentation {
    /// Segment the key from the card face. Returns nil when nothing key-sized is found —
    /// every caller must then offer the manual path, never a dead end.
    public static func segment(_ image: GrayImage, pixelsPerMm: Double) -> KeyMaskResult? {
        let w = image.width, h = image.height
        guard w > 64, h > 64 else { return nil }
        let margin = max(2, Int((2.0 * pixelsPerMm).rounded()))
        let band = max(1, Int((1.5 * pixelsPerMm).rounded()))

        // Background level: median of a 1.5 mm band just inside the ignored margin.
        var ring = [Double]()
        if band > 0, h > 2 * margin + band {
            for y in 0..<h {
                let inBandY = (y >= margin && y < margin + band) || (y >= h - margin - band && y < h - margin)
                if inBandY {
                    for x in margin..<(w - margin) { ring.append(Double(image.pixel(x, y))) }
                }
            }
            for x in 0..<w {
                let inBandX = (x >= margin && x < margin + band) || (x >= w - margin - band && x < w - margin)
                if inBandX {
                    for y in margin..<(h - margin) { ring.append(Double(image.pixel(x, y))) }
                }
            }
        }
        guard let bg = Statistics.median(ring), ring.count > 100 else { return nil }
        let bgInt = Int(bg.rounded())

        // Absolute luminance difference from the card face, Otsu-thresholded.
        var diff = [UInt8](repeating: 0, count: w * h)
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<(w * h) {
            let d = abs(Int(image.pixels[i]) - bgInt)
            let v = UInt8(min(255, d))
            diff[i] = v
            hist[Int(v)] += 1
        }
        let t = otsuThreshold(histogram: hist, total: w * h)

        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let inCardY = y >= margin && y < h - margin
            for x in 0..<w {
                guard inCardY, x >= margin, x < w - margin else { continue }
                if diff[y * w + x] > t { mask[y * w + x] = true }
            }
        }

        mask = Morphology.close(mask, w, h, iterations: 2)
        mask = Morphology.open(mask, w, h, iterations: 1)

        // Elongation-aware pick: an on-card ring/fob must not hijack the key.
        let (blob, area, _) = ConnectedComponents.bestKeyComponent(mask, w, h)
        let fraction = Double(area) / Double(w * h)
        guard fraction >= 0.015 else { return nil }
        let filled = ConnectedComponents.fillHoles(blob, w, h)

        return KeyMaskResult(
            mask: filled, width: w, height: h, pixelsPerMm: pixelsPerMm,
            backgroundLevel: bg, threshold: t, blobAreaFraction: fraction
        )
    }
}
