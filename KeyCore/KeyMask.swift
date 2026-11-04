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
        // Brushed-metal / gradient reference cards (field photo: 50→250
        // across the face) defeat any single-median background — wrong by
        // ±60 levels locally while the key sits at 20–60 contrast. On such
        // cards the background becomes a MEDIAN FIELD (LocalBackground)
        // that follows the gradient. The field is gated on an actual
        // coarse gradient probe though: flat cards keep the v3b global
        // background (measured: hysteresis interacts badly with the field
        // near hard-edged structures), and the probe scenes / typical matte
        // cards are flat.
        // Object-immune: per-row medians (a key occupying <50% of a row
        // cannot move its median), then |median(top rows) - median(bottom
        // rows)| and the horizontal analogue. Means were tripped by the key
        // itself: a dark key on a light face fakes a "gradient" of 30+
        // levels and would switch the field on for flat cards (measured).
        let useField: Bool = {
            guard padded else { return false }
            func rowMed(_ y: Int) -> Double {
                var vals = [Double]()
                vals.reserveCapacity((cx1 - cx0) / 8 + 2)
                for x in stride(from: cx0, to: cx1, by: 8) { vals.append(Double(image.pixels[y * w + x])) }
                vals.sort()
                return vals[vals.count / 2]
            }
            func colMed(_ x: Int) -> Double {
                var vals = [Double]()
                vals.reserveCapacity((cy1 - cy0) / 8 + 2)
                for y in stride(from: cy0, to: cy1, by: 8) { vals.append(Double(image.pixels[y * w + x])) }
                vals.sort()
                return vals[vals.count / 2]
            }
            var tops = [Double](), bots = [Double](), lefts = [Double](), rights = [Double]()
            let yc = (cy0 + cy1) / 2, xc = (cx0 + cx1) / 2
            for y in stride(from: cy0 + 4, to: cy1 - 4, by: 8) {
                let m = rowMed(y)
                if y < yc { tops.append(m) } else { bots.append(m) }
            }
            for x in stride(from: cx0 + 4, to: cx1 - 4, by: 8) {
                let m = colMed(x)
                if x < xc { lefts.append(m) } else { rights.append(m) }
            }
            func med(_ a: [Double]) -> Double { var a = a; a.sort(); return a[a.count / 2] }
            guard tops.count > 8, bots.count > 8, lefts.count > 8, rights.count > 8 else { return false }
            let grad = max(abs(med(tops) - med(bots)), abs(med(lefts) - med(rights)))
            return grad > max(24.0, 2.5 * cardSigma)
        }()
        let bgField: [UInt8]? = useField
            ? LocalBackground.field(
                image,
                rect: CGRect(x: cx0, y: cy0, width: cx1 - cx0, height: cy1 - cy0),
                radiusMm: 30.0, pixelsPerMm: pixelsPerMm
              )
            : nil
        var histTotal = 0
        for i in 0..<(w * h) {
            let x = i % w, y = i / w
            let insideCard = x >= cx0 && x < cx1 && y >= cy0 && y < cy1
            if inBoundaryBand(x, y, insideCard: insideCard) { continue }
            let d: Int
            if padded, insideCard, let bgField {
                d = abs(Int(image.pixels[i]) - Int(bgField[i]))
            } else {
                let bgHere = padded && !insideCard ? outerInt : bgInt
                d = abs(Int(image.pixels[i]) - bgHere)
            }
            let v = UInt8(min(255, d))
            diff[i] = v
            if !padded || insideCard { hist[Int(v)] += 1; histTotal += 1 }
        }
        // Gradient-field frames self-cancel shadows and gradients, so the
        // floor can be gentler there (a busy metallic card's ring sigma
        // would otherwise floor above the key's local contrast and delete
        // it). Flat padded and legacy frames keep v3b's exact 3.5σ floor.
        let floorT: UInt8 = padded && useField
            ? UInt8(max(8, min(45, (2.0 * cardSigma).rounded())))
            : UInt8(max(12, min(80, (3.5 * cardSigma).rounded())))
        let t = max(otsuThreshold(histogram: hist, total: max(histTotal, 1)), floorT)

        var mask = [Bool](repeating: false, count: w * h)
        if padded {
            let outerT = UInt8(max(20, min(120, (0.55 * Double(t)).rounded())))
            // HYSTERESIS WITH GROWTH CAP. A key can sit only ~20 levels
            // above a metallic card while the card's print sits at 50-130
            // (field photo): one threshold either drowns the key in print
            // or severs it. Pixels above the WEAK threshold are candidates,
            // but survive only within a few px of a STRONG pixel (specular
            // stripes, contact-gap ring, print). The cap is what makes
            // this safe for cast shadows: a shadow is exactly a broad
            // weak-contrast region touching the key, and unbounded
            // component-growth used to swallow it whole (measured). 5 px
            // of shadow lip is shaved by the opening below; interior key
            // holes are closed by fillHoles downstream. Flat cards: the
            // whole key is strong and behavior is unchanged.
            // Weak = noise-relative, NOT a fixed fraction of the strong
            // threshold: a busy card's own |diff| noise (~2 sigma) percolates
            // into a card-spanning blob at half-threshold and the hysteresis
            // growth swallows the whole card. At 2.2 sigma, noise stays sub-
            // percolation and only real structures grow from strong seeds.
            // Coefficient follows the same gate: FLAT cards are the cast-
            // shadow case, so weak sits at v3b's 3.5 sigma (above a ~20-
            // level shadow on a sigma-6 card). Gradient cards run the
            // field, which cancels shadows and texture alike, so their
            // residual sigma is small and weak drops to 2.2 sigma to catch
            // a low-contrast key body.
            let weakK: Double = useField ? 2.2 : 3.5
            let tWeak = UInt8(max(8, min((weakK * cardSigma).rounded(), Double(t) - 1)))
            // Overhang rescue zone: outside the card, only within 30 mm of
            // its edge joins the mask (a large bow hanging off the card
            // needs ~20 mm; 8 mm chopped bows — measured 100k px lost. A
            // connectivity rule can't replace geometry here: the 1.5 mm
            // boundary band excluded from the diff map severs every
            // in/outside component pair). Far-field clutter (hands, glare
            // beyond 30 mm) stays out, and isolated strips that DO fall in
            // the zone lose to the key on the center-prior pick.
            let ringPx = Int(30.0 * pixelsPerMm)
            var weak = [Bool](repeating: false, count: w * h)
            for i in 0..<(w * h) {
                let x = i % w, y = i / w
                let insideCard = x >= cx0 && x < cx1 && y >= cy0 && y < cy1
                if insideCard {
                    // Flat cards take the proven single-threshold path:
                    // hysteresis' AA-ring growth measurably shifted the
                    // tooth bottom by 2-3 px (a full depth digit at the
                    // probe's scale). Growth exists only to reach a
                    // low-contrast key body, which only occurs on the
                    // gradient cards the field handles.
                    if useField ? (diff[i] > tWeak) : (diff[i] > t) { weak[i] = true }
                } else if diff[i] > outerT {
                    let inBand = (x >= cx0 - ringPx && x < cx0 && y >= cy0 - ringPx && y < cy1 + ringPx)
                        || (x >= cx1 && x < cx1 + ringPx && y >= cy0 - ringPx && y < cy1 + ringPx)
                        || (y >= cy0 - ringPx && y < cy0 && x >= cx0 - ringPx && x < cx1 + ringPx)
                        || (y >= cy1 && y < cy1 + ringPx && x >= cx0 - ringPx && x < cx1 + ringPx)
                    if inBand { mask[i] = true }
                }
            }
            if useField {
                var strong = [Bool](repeating: false, count: w * h)
                for i in 0..<(w * h) {
                    if weak[i] && diff[i] > t { strong[i] = true }
                }
                let grown = Morphology.dilate(strong, w, h, iterations: 5)
                for i in 0..<(w * h) where weak[i] && grown[i] { mask[i] = true }
            } else {
                for i in 0..<(w * h) where weak[i] { mask[i] = true }
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
        // Padded frames ran hysteresis; the growth cap (3-5 px) bounds the
        // fuzz, so a 2 px opening trims what the cap leaves (AA transitions
        // near adjacent shadows) without eating blade/teeth geometry — a
        // 4 px opening shaved a full digit off every depth (measured:
        // 270k→173k blob pixels). Legacy keeps 1 px for the tiny probe keys.
        mask = Morphology.open(mask, w, h, iterations: padded ? 2 : 1)
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
                elongBoost: padded ? 0.1 : 1.0,
                rejectBorderTouch: padded
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
