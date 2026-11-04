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
    /// `seed` overrides the automatic pick: the component CONTAINING the seed
    /// pixel becomes the key blob (manual "that's not my key" correction).
    /// Returns nil when the seed lands on background.
    public static func segment(
        _ image: GrayImage, pixelsPerMm: Double, seed: (x: Int, y: Int)? = nil,
        marginFrac: Double = 0
    ) -> KeyMaskResult? {
        let w = image.width, h = image.height
        guard w > 64, h > 64 else { return nil }
        let padded = marginFrac > 0.01
        // Card rectangle in corrected coordinates: the full frame on legacy
        // views, an inner region on padded warps (MeasurementPipeline.correct).
        let cx0 = padded ? Int((marginFrac * Double(w)).rounded()) : 0
        let cy0 = padded ? Int((marginFrac * Double(h)).rounded()) : 0
        let cx1 = w - cx0, cy1 = h - cy0

        let margin = max(2, Int((2.0 * pixelsPerMm).rounded()))
        let band = max(1, Int((1.5 * pixelsPerMm).rounded()))

        // Card-face background: median of a band just inside the card edge
        // (the card rectangle's edge on padded frames, the frame's edge
        // otherwise) + its texture sigma for the contrast floor below.
        func ringBand(x0: Int, y0: Int, x1: Int, y1: Int) -> [Double] {
            var ring = [Double]()
            guard y1 - y0 > 2 * margin + band, x1 - x0 > 2 * margin + band else { return ring }
            for y in y0..<y1 {
                let inBandY = (y >= y0 + margin && y < y0 + margin + band)
                    || (y >= y1 - margin - band && y < y1 - margin)
                if inBandY {
                    for x in (x0 + margin)..<(x1 - margin) { ring.append(Double(image.pixel(x, y))) }
                }
            }
            for x in x0..<x1 {
                let inBandX = (x >= x0 + margin && x < x0 + margin + band)
                    || (x >= x1 - margin - band && x < x1 - margin)
                if inBandX {
                    for y in (y0 + margin)..<(y1 - margin) { ring.append(Double(image.pixel(x, y))) }
                }
            }
            return ring
        }
        let ring = ringBand(x0: cx0, y0: cy0, x1: cx1, y1: cy1)
        guard let bg = Statistics.median(ring), ring.count > 100 else { return nil }
        let bgInt = Int(bg.rounded())
        let cardSigma = (Statistics.medianAbsoluteDeviation(ring, around: bg) ?? 4.0) * 1.4826

        // Photo-surroundings background for padded frames: median of the
        // region outside the card rectangle. Key pixels overhanging the card
        // edge differ from THIS background, not the card face.
        var outerInt = bgInt
        if padded {
            var outer = [Double]()
            let g = max(3, margin / 2)
            for y in stride(from: g, to: h - g, by: 2) {
                for x in stride(from: g, to: w - g, by: 2) {
                    if x >= cx0, x < cx1, y >= cy0, y < cy1 { continue }
                    outer.append(Double(image.pixel(x, y)))
                }
            }
            if let m = Statistics.median(outer), outer.count > 100 { outerInt = Int(m.rounded()) }
        }

        // Per-pixel |luminance - relevant background|. A dark key over a
        // dark TABLE has weak table contrast while the same key over the
        // light card has huge card contrast, so ONE global threshold cannot
        // serve both regimes (and a max-of-both-reference diff would rate
        // the light card itself as "high contrast" against a dark table and
        // mask the entire card). Instead the threshold is spatial: Otsu is
        // fit on CARD-region pixels only, and the photo ring outside the
        // card gets its own relaxed threshold against the table background,
        // so ~50-contrast overhang survives a 50+ card threshold (probe
        // margin-overhang scenario is exactly this regime).
        // Padded frames: a few-px band around the card rect and the frame
        // edge holds warp seams and (from corner rounding) table slivers
        // inside the card rect. Those pixels must leave BOTH the mask and
        // the threshold histogram — left in, a 1-px sliver at |table - card|
        // diff ~192 adds a far mode that drags Otsu above the overhanging
        // key's diff and silently amputates the teeth (probe margin-overhang
        // caught exactly this).
        // Boundary handling for padded frames. INSIDE the card rect a 1-px
        // band along its border swallows warp seams and the table slivers
        // that corner rounding puts just inside the detected rect; keep it
        // that thin — a wider band slices a key that straddles the card edge
        // into two components (overhang + on-card part), and morphology
        // cannot rebridge it (margin-overhang probe caught exactly that).
        // OUTSIDE the card, table pixels ARE signal: that is where overhang
        // lives, so only the frame edge (clamped-warp garbage) is cut.
        func inBoundaryBand(_ x: Int, _ y: Int, insideCard: Bool) -> Bool {
            guard padded else { return false }
            let dFrame = min(min(x, y), min(w - 1 - x, h - 1 - y))
            if dFrame <= 3 { return true }
            if !insideCard { return false }
            let dCard = min(min(abs(x - cx0), abs(x - cx1)), min(abs(y - cy0), abs(y - cy1)))
            return dCard <= 1
        }
        var diff = [UInt8](repeating: 0, count: w * h)
        var hist = [Int](repeating: 0, count: 256)
        var histTotal = 0
        for i in 0..<(w * h) {
            let x = i % w, y = i / w
            let insideCard = x >= cx0 && x < cx1 && y >= cy0 && y < cy1
            if inBoundaryBand(x, y, insideCard: insideCard) { continue }
            let bgHere = padded && !insideCard ? outerInt : bgInt
            let d = abs(Int(image.pixels[i]) - bgHere)
            let v = UInt8(min(255, d))
            diff[i] = v
            if !padded || insideCard { hist[Int(v)] += 1; histTotal += 1 }
        }
        let floorT = UInt8(max(12, min(80, (3.5 * cardSigma).rounded())))
        let t = max(otsuThreshold(histogram: hist, total: max(histTotal, 1)), floorT)

        var mask = [Bool](repeating: false, count: w * h)
        if padded {
            let outerT = UInt8(max(20, min(120, (0.55 * Double(t)).rounded())))
            for i in 0..<(w * h) {
                let x = i % w, y = i / w
                let insideCard = x >= cx0 && x < cx1 && y >= cy0 && y < cy1
                if insideCard { if diff[i] > t { mask[i] = true } }
                else if diff[i] > outerT { mask[i] = true }
            }
        } else {
            for y in 0..<h {
                let inCardY = y >= margin && y < h - margin
                for x in 0..<w {
                    guard inCardY, x >= margin, x < w - margin else { continue }
                    if diff[y * w + x] > t { mask[y * w + x] = true }
                }
            }
        }

        mask = Morphology.close(mask, w, h, iterations: 2)
        mask = Morphology.open(mask, w, h, iterations: 1)
        // Only padded frames can bridge the key to the photo ring; legacy
        // frames put the table at diff≈0 where the bridge pass would find
        // nothing but its own cost.
        if padded { ConnectedComponents.detachWeakBridges(&mask, w, h) }

        // Elongation-aware pick: an on-card ring/fob must not hijack the key;
        // on padded frames the card-center prior adds a mild boost (the key
        // is guided to the middle of the card by the capture UI).
        var blob: [Bool], area: Int
        if let seed {
            (blob, area) = ConnectedComponents.component(atX: seed.x, y: seed.y, in: mask, w, h)
            // Seeded picks may legitimately be small (blade-only keys) but must
            // not be specks; 0.4% of the card floor filters noise.
            guard area > 0, Double(area) / Double(w * h) >= 0.004 else { return nil }
        } else {
            let center: CGPoint? = padded
                ? CGPoint(x: Double(cx0 + cx1) / 2, y: Double(cy0 + cy1) / 2)
                : nil
            let diag = (Double(w) * Double(w) + Double(h) * Double(h)).squareRoot()
            (blob, area, _) = ConnectedComponents.bestKeyComponent(
                mask, w, h,
                center: center,
                centerSigma: 0.5 * diag,
                elongBoost: padded ? 0.1 : 1.0
            )
            let cardAreaFraction = padded ? (1 - 2 * marginFrac) * (1 - 2 * marginFrac) : 1.0
            let fraction = Double(area) / Double(w * h)
            guard fraction >= 0.015 * cardAreaFraction else { return nil }
        }
        let fraction = Double(area) / Double(w * h)
        let filled = ConnectedComponents.fillHoles(blob, w, h)

        return KeyMaskResult(
            mask: filled, width: w, height: h, pixelsPerMm: pixelsPerMm,
            backgroundLevel: bg, threshold: t, blobAreaFraction: fraction
        )
    }
}
