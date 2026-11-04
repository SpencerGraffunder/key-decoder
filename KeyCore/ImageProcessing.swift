import Foundation

// MARK: - Otsu

/// Otsu's method on a UInt8 histogram. Returns a threshold (pixels > threshold pass).
public func otsuThreshold(_ pixels: [UInt8]) -> UInt8 {
    var hist = [Int](repeating: 0, count: 256)
    for p in pixels { hist[Int(p)] += 1 }
    return otsuThreshold(histogram: hist, total: pixels.count)
}

public func otsuThreshold(histogram: [Int], total: Int) -> UInt8 {
    guard total > 0 else { return 128 }
    var sum = 0.0
    for v in 0..<256 { sum += Double(v * histogram[v]) }
    var sumB = 0.0
    var wB = 0.0
    var bestLo = 0
    var bestHi = 0
    var bestVar = -1.0
    for t in 0..<256 {
        wB += Double(histogram[t])
        if wB == 0 { continue }
        let wF = Double(total) - wB
        if wF == 0 { break }
        sumB += Double(t * histogram[t])
        let mB = sumB / wB
        let mF = (sum - sumB) / wF
        let between = wB * wF * (mB - mF) * (mB - mF)
        // Track the FULL band of thresholds attaining max between-class
        // variance (a gap between two modes yields a wide plateau) and return
        // its midpoint, so the threshold lands between the modes, not on the
        // near edge of the plateau.
        if between > bestVar + max(bestVar, 1) * 1e-9 {
            bestVar = between
            bestLo = t
            bestHi = t
        } else if abs(between - bestVar) <= max(bestVar, 1) * 1e-9 {
            bestHi = t
        }
    }
    return UInt8((bestLo + bestHi) / 2)
}

// MARK: - Morphology (3x3 square structuring element)

public enum Morphology {
    public static func dilate(_ mask: [Bool], _ w: Int, _ h: Int, iterations: Int = 1) -> [Bool] {
        var cur = mask
        for _ in 0..<iterations { cur = pass(cur, w, h, grow: true) }
        return cur
    }

    public static func erode(_ mask: [Bool], _ w: Int, _ h: Int, iterations: Int = 1) -> [Bool] {
        var cur = mask
        for _ in 0..<iterations { cur = pass(cur, w, h, grow: false) }
        return cur
    }

    public static func close(_ mask: [Bool], _ w: Int, _ h: Int, iterations: Int = 1) -> [Bool] {
        erode(dilate(mask, w, h, iterations: iterations), w, h, iterations: iterations)
    }

    public static func open(_ mask: [Bool], _ w: Int, _ h: Int, iterations: Int = 1) -> [Bool] {
        dilate(erode(mask, w, h, iterations: iterations), w, h, iterations: iterations)
    }

    private static func pass(_ mask: [Bool], _ w: Int, _ h: Int, grow: Bool) -> [Bool] {
        var out = [Bool](repeating: grow ? false : true, count: mask.count)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var hit = grow ? false : true
                for dy in (-1)...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in (-1)...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= w { continue }
                        let v = mask[yy * w + xx]
                        if grow, v { hit = true }
                        if !grow, !v { hit = false }
                    }
                }
                out[i] = hit
            }
        }
        return out
    }
}

// MARK: - Connected components

public enum ConnectedComponents {
    /// 4-connected flood fill from a seed pixel; returns the component mask
    /// and pixel count, or (empty, 0) when the seed is not on a set pixel.
    public static func component(atX x: Int, y: Int, in mask: [Bool], _ w: Int, _ h: Int)
        -> ([Bool], Int)
    {
        var out = [Bool](repeating: false, count: w * h)
        guard x >= 0, y >= 0, x < w, y < h, mask[y * w + x] else { return (out, 0) }
        var stack = [y * w + x]
        out[y * w + x] = true
        var n = 1
        while let i = stack.popLast() {
            let cx = i % w, cy = i / w
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = cx + dx, ny = cy + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                if mask[j], !out[j] { out[j] = true; n += 1; stack.append(j) }
            }
        }
        return (out, n)
    }

    /// Pick the component most likely to be a key: among components of at
    /// least `minAreaFraction` of the card, prefer the one with the most
    /// elongated pixel-covariance aspect (sqrt(λ1/λ2) ≥ minAspect), largest
    /// area among those. This keeps a split ring or fob lying on the card —
    /// often rounder, sometimes larger than the key — from hijacking a plain
    /// largest-area pick. Falls back to the largest component when none is
    /// elongated, so downstream aspect gates still route to the manual path.
    /// Returns (mask, pixelCount, aspectOfPick).
    public static func bestKeyComponent(
        _ mask: [Bool], _ w: Int, _ h: Int,
        minAreaFraction: Double = 0.015, minAspect: Double = 2.5,
        center: CGPoint? = nil, centerSigma: Double = 0,
        aspectBoost: Double = 0.06, aspectBoostCap: Double = 1.5,
        elongBoost: Double = 1.0
    ) -> ([Bool], Int, Double) {
        let ids = label(mask, w, h)
        guard let ids else {
            let (m, n) = largestComponent(mask, w, h)
            return (m, n, 0)
        }
        var counts = [Int: Int](), sx = [Int: Double](), sy = [Int: Double]()
        var sxx = [Int: Double](), syy = [Int: Double](), sxy = [Int: Double]()
        for i in ids.indices {
            let l = ids[i]
            guard l > 0 else { continue }
            let x = Double(i % w), y = Double(i / w)
            counts[l, default: 0] += 1
            sx[l, default: 0] += x; sy[l, default: 0] += y
            sxx[l, default: 0] += x * x; syy[l, default: 0] += y * y; sxy[l, default: 0] += x * y
        }
        let minArea = minAreaFraction * Double(w * h)
        // Scored pick: area x mild elongation boost x center proximity (the
        // capture UI guides keys to the card center; long thin text bands and
        // off-center accessories lose to the real key). Falls back to plain
        // largest-area when nothing is elongated, so downstream aspect gates
        // still route to the manual path.
        struct Cand { let l: Int, n: Int, aspect: Double, score: Double }
        var elig = [Cand](), all = [Cand]()
        for (l, n) in counts {
            guard let sxL = sx[l] else { continue }
            let nd = Double(n)
            let mx = sxL / nd, my = sy[l]! / nd
            let cxx = max(sxx[l]! / nd - mx * mx, 0)
            let cyy = max(syy[l]! / nd - my * my, 0)
            let cxy = sxy[l]! / nd - mx * my
            let tr = cxx + cyy, det = cxx * cyy - cxy * cxy
            let disc = (tr * tr / 4 - det).squareRoot()
            let l1 = tr / 2 + disc
            let l2 = max(tr / 2 - disc, 1e-9)
            let aspect = (l1 / l2).squareRoot()
            let centerBoost: Double
            if let center, centerSigma > 0 {
                let dx = mx - center.x, dy = my - center.y
                let d2 = (dx * dx + dy * dy) / (centerSigma * centerSigma)
                centerBoost = max(0.25, exp(-d2 * 2))
            } else {
                centerBoost = 1.0
            }
            // elongBoost < 1 (padded frames): shape becomes a tie-breaker
            // and center proximity is squared — a seam ring hugging the card
            // edge is long, thin AND off-center, exactly the failure mode of
            // shape-dominant scoring when the key itself sits at the center.
            let shapeFactor = pow(1.0 + min(aspectBoostCap, max(0, aspect - 2.5) * aspectBoost), elongBoost)
            let centerFactor = elongBoost < 1 ? centerBoost * centerBoost : centerBoost
            let score = nd * shapeFactor * centerFactor
            let cand = Cand(l: l, n: n, aspect: aspect, score: score)
            all.append(cand)
            if nd >= minArea, aspect >= minAspect { elig.append(cand) }
        }
        guard let pick = elig.max(by: { $0.score < $1.score }) ?? all.max(by: { $0.score < $1.score }) else {
            return (Array(repeating: false, count: mask.count), 0, 0)
        }
        let out = ids.map { $0 == pick.l }
        return (out, pick.n, pick.aspect)
    }

    /// Sever thin bridges that glue soft shadows or specks onto the key:
    /// erode twice, drop components that can't be the key (area < 0.4% of the
    /// frame), dilate the survivors' labels back and AND with the original.
    /// Broad-brimmed shadows survive erosion and stay attached — the MAD
    /// threshold floor is what rejects those.
    public static func detachWeakBridges(_ mask: inout [Bool], _ w: Int, _ h: Int) {
        let eroded = Morphology.erode(mask, w, h, iterations: 2)
        guard let ids = label(eroded, w, h) else { mask = Array(repeating: false, count: mask.count); return }
        var counts = [Int: Int]()
        for l in ids where l > 0 { counts[l, default: 0] += 1 }
        let minArea = Int(0.004 * Double(w * h))
        var keep = Set<Int>()
        for (l, n) in counts where n >= minArea { keep.insert(l) }
        guard !keep.isEmpty else { return }  // everything tiny: leave input untouched
        // Multi-source BFS from surviving cores, 4-connected, max 2 rings.
        var owner = [Int](repeating: 0, count: w * h)
        var frontier = [Int]()
        for i in ids.indices where keep.contains(ids[i]) { owner[i] = ids[i]; frontier.append(i) }
        for _ in 0..<2 {
            var next = [Int]()
            for i in frontier {
                let cx = i % w, cy = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if owner[j] == 0, mask[j] { owner[j] = owner[i]; next.append(j) }
                }
            }
            frontier = next
        }
        for i in mask.indices { mask[i] = mask[i] && owner[i] != 0 }
    }

    /// Keep only the largest 8-connected component. Returns (mask, pixelCount).
    public static func largestComponent(_ mask: [Bool], _ w: Int, _ h: Int) -> ([Bool], Int) {
        let labels = label(mask, w, h)
        guard let ids = labels else { return (mask, mask.filter { $0 }.count) }
        var counts = [Int: Int]()
        for l in ids where l > 0 { counts[l, default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value }) else {
            return (Array(repeating: false, count: mask.count), 0)
        }
        let out = ids.map { $0 == best.key }
        return (out, best.value)
    }

    /// BFS labeling; 0 = background. nil when the mask is empty.
    public static func label(_ mask: [Bool], _ w: Int, _ h: Int) -> [Int]? {
        guard mask.contains(true) else { return nil }
        var ids = [Int](repeating: 0, count: mask.count)
        var next = 1
        var stack = [Int]()
        for start in 0..<mask.count where mask[start] && ids[start] == 0 {
            ids[start] = next
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                for dy in (-1)...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in (-1)...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= w { continue }
                        let j = yy * w + xx
                        if mask[j] && ids[j] == 0 {
                            ids[j] = next
                            stack.append(j)
                        }
                    }
                }
            }
            next += 1
        }
        return ids
    }

    /// Fill enclosed background (holes): background pixels unreachable from the border.
    public static func fillHoles(_ mask: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: mask.count)
        var stack = [Int]()
        func push(_ i: Int) {
            if !mask[i] && !outside[i] {
                outside[i] = true
                stack.append(i)
            }
        }
        for x in 0..<w { push(x); push((h - 1) * w + x) }
        for y in 0..<h { push(y * w); push(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { push(i - 1) }
            if x < w - 1 { push(i + 1) }
            if y > 0 { push(i - w) }
            if y < h - 1 { push(i + w) }
        }
        return zip(mask, outside).map { $0 || !$1 }
    }
}
