#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Straight-line fit of the blade spine in (u, v) space of a BladeAnalysis frame.
public struct SpineLine: Codable, Equatable {
    public var slope: Double
    public var intercept: Double

    public init(slope: Double, intercept: Double) {
        self.slope = slope
        self.intercept = intercept
    }

    public func v(at u: Double) -> Double { slope * u + intercept }
}

/// Per-1px-bin extremes of the key mask in blade coordinates.
public struct ColumnProfile {
    public let uMin: Double
    public let vTop: [Double?]
    public let vBot: [Double?]
    public let counts: [Int]

    public var uMax: Double { uMin + Double(vTop.count - 1) }

    public func vTopAt(u: Double) -> Double? {
        sample(vTop, u: u)
    }

    public func vBotAt(u: Double) -> Double? {
        sample(vBot, u: u)
    }

    private func sample(_ arr: [Double?], u: Double) -> Double? {
        let i = Int((u - uMin).rounded())
        guard i >= 0, i < arr.count else { return nil }
        return arr[i]
    }
}

/// Blade frame: axis u runs along the blade, v is perpendicular (y-down image space).
public struct BladeAnalysis {
    /// +u points from the bow/head side toward the tip when a head was detected;
    /// headless blobs keep the raw PCA sign and the pipeline resolves direction.
    public let angle: Double
    public let origin: CGPoint
    public let axis: (x: Double, y: Double)
    public let perp: (x: Double, y: Double)
    public let pixelsPerMm: Double

    public let uMin: Double
    public let uMax: Double
    public let headPresent: Bool
    /// Shoulder (bow-side blade start) — only trusted when `headPresent`.
    public let shoulderU: Double
    /// Far blade end (tip side) after normalization.
    public let tipU: Double
    public let spineIsTop: Bool
    public let spine: SpineLine
    public let spineRms: Double
    public let cutSideRms: Double
    public let bladeWidthPx: Double
    public let headLenPx: Double
    public let columns: ColumnProfile

    public var pixelsPerInch: Double { pixelsPerMm * 25.4 }

    public func uv(_ p: CGPoint) -> (u: Double, v: Double) {
        let dx = Double(p.x) - origin.x, dy = Double(p.y) - origin.y
        return (dx * axis.x + dy * axis.y, dx * perp.x + dy * perp.y)
    }

    public func xy(u: Double, v: Double) -> CGPoint {
        CGPoint(
            x: origin.x + u * axis.x + v * perp.x,
            y: origin.y + u * axis.y + v * perp.y
        )
    }

    /// v of the cut-side boundary at u.
    public func cutEdgeV(at u: Double) -> Double? {
        spineIsTop ? columns.vBotAt(u: u) : columns.vTopAt(u: u)
    }

    public func depthPx(at u: Double) -> Double? {
        guard let edge = cutEdgeV(at: u) else { return nil }
        let line = spine.v(at: u)
        return spineIsTop ? edge - line : line - edge
    }
}

public enum BladeAnalyzer {
    /// Derive blade frame, head/shoulder, spine line and cut side (docs/ALGORITHM.md §3).
    public static func analyze(_ m: KeyMaskResult) -> BladeAnalysis? {
        let w = m.width, h = m.height, mask = m.mask
        var n = 0, sumX = 0.0, sumY = 0.0
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] {
                sumX += Double(x); sumY += Double(y); n += 1
            }
        }
        guard n > 500 else { return nil }
        let cx = sumX / Double(n), cy = sumY / Double(n)

        var cxx = 0.0, cyy = 0.0, cxy = 0.0
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] {
                let dx = Double(x) - cx, dy = Double(y) - cy
                cxx += dx * dx; cyy += dy * dy; cxy += dx * dy
            }
        }
        let inv = 1.0 / Double(n)
        cxx *= inv; cyy *= inv; cxy *= inv
        let theta = 0.5 * atan2(2 * cxy, cxx - cyy)
        let axis = (x: cos(theta), y: sin(theta))
        let perp = (x: -sin(theta), y: cos(theta))

        // Project to (u, v) bounds.
        var uLo = Double.greatestFiniteMagnitude, uHi = -uLo
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let u = dx * axis.x + dy * axis.y
                if u < uLo { uLo = u }
                if u > uHi { uHi = u }
            }
        }
        let rawBins = Int((uHi - uLo).rounded()) + 1
        guard rawBins > 20 else { return nil }

        var rawTop = [Double?](repeating: nil, count: rawBins)
        var rawBot = [Double?](repeating: nil, count: rawBins)
        var rawCount = [Int](repeating: 0, count: rawBins)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let u = dx * axis.x + dy * axis.y
                let v = dx * perp.x + dy * perp.y
                let i = Int((u - uLo).rounded())
                guard i >= 0, i < rawBins else { continue }
                if let t = rawTop[i] { rawTop[i] = min(t, v) } else { rawTop[i] = v }
                if let b = rawBot[i] { rawBot[i] = max(b, v) } else { rawBot[i] = v }
                rawCount[i] += 1
            }
        }

        func widthAt(_ i: Int) -> Double? {
            guard let t = rawTop[i], let b = rawBot[i], rawCount[i] > 0 else { return nil }
            return b - t
        }
        let widths = (0..<rawBins).compactMap(widthAt)
        // Blade width proxy = 25th percentile, NOT median: with a big bow the
        // over-wide head columns can exceed 50% of the blob (head 1.05in vs
        // blade 1.63in is common), which poisons a plain median. The head only
        // ever shifts the upper tail, so a low percentile stays on the blade;
        // cut columns sit just below the floor cluster and barely move p25.
        let sortedWidths = widths.sorted()
        guard sortedWidths.count > 10,
              let wMedian = Optional(sortedWidths[sortedWidths.count / 4]), wMedian > 1 else { return nil }
        if getenv("KEYCORE_DEBUG") != nil {
            FileHandle.standardError.write("DBG theta=\(String(format: "%.2f", theta * 180 / .pi))deg p25W=\(String(format: "%.1f", wMedian)) rawBins=\(rawBins)\n".data(using: .utf8)!)
            var k = 0
            var line = "DBG widths:"
            while k < rawBins { line += " \(k):\(rawTop[k] != nil && rawBot[k] != nil ? String(format: "%.0f", (rawBot[k]! - rawTop[k]!)) : "x")"; k += 100 }
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        }
        let minCount = max(2, Int((0.05 * wMedian).rounded()))
        let valid = (0..<rawBins).map { rawCount[$0] >= minCount && widthAt($0) != nil }

        var first = 0
        var last = rawBins - 1
        while first < rawBins, !valid[first] { first += 1 }
        while last >= 0, !valid[last] { last -= 1 }
        guard last - first > 20 else { return nil }
        // Trim fringe.
        let trimmed = last - first + 1

        // Head detection per the validated prototype (tools/proto/REPORT.md
        // "head region"): a contiguous run of w > 1.9·Wb columns anchored at the
        // blob end; a narrow rounded cap of ≤0.30in with w ≥ 1.6·Wb at the outer
        // end is skipped before the run starts; the run re-joins across dips
        // ≤3px wide whose columns stay ≥1.6·Wb.
        let ppi = m.pixelsPerMm * 25.4
        let overThresh = 1.9 * wMedian
        let capThresh = 1.6 * wMedian
        let capMaxPx = Int((0.30 * ppi).rounded())
        let dipRejoinPx = 3
        let invalidGapPx = 2

        /// Head-run length measured from the outer end of one side.
        func headLen(startLow: Bool) -> Double {
            var overSeen = false, dip = 0, gaps = 0, lastOver = -1, walked = 0
            var i = startLow ? 0 : trimmed - 1
            let step = startLow ? 1 : -1
            while i >= 0, i < trimmed {
                let gi = first + i
                if valid[gi], let wv = widthAt(gi) {
                    gaps = 0
                    if wv > overThresh {
                        overSeen = true; dip = 0; lastOver = walked
                    } else if !overSeen {
                        // Rounded/tapered cap zone: any width tolerated for
                        // ≤0.30in before the over-wide run must begin.
                        if walked > capMaxPx { break }
                    } else if wv >= capThresh {
                        dip += 1
                        if dip > dipRejoinPx { break }
                    } else {
                        break
                    }
                } else {
                    gaps += 1
                    if gaps > invalidGapPx { break }
                }
                i += step
                walked += 1
            }
            return overSeen ? Double(lastOver + 1) : 0
        }
        let minRunPx = 0.10 * ppi
        let lowLen = headLen(startLow: true)
        let highLen = headLen(startLow: false)
        let flip: Bool
        var headPresent = false
        let headSideLow: Bool
        if highLen >= minRunPx && highLen >= lowLen {
            flip = true; headPresent = true; headSideLow = false
        } else if lowLen >= minRunPx {
            flip = false; headPresent = true; headSideLow = true
        } else {
            flip = false; headSideLow = true
        }

        // Final column arrays, flipped +u→bow at low u when required.
        var vTop = [Double?](repeating: nil, count: trimmed)
        var vBot = [Double?](repeating: nil, count: trimmed)
        var counts = [Int](repeating: 0, count: trimmed)
        let uMin = flip ? -(uLo + Double(last)) : uLo + Double(first)
        for i in 0..<trimmed {
            let gi = first + i
            let ii = flip ? trimmed - 1 - i : i
            counts[ii] = rawCount[gi]
            vTop[ii] = rawTop[gi].map { flip ? -$0 : $0 }
            vBot[ii] = rawBot[gi].map { flip ? -$0 : $0 }
        }
        let angle = flip ? theta + .pi : theta
        let finalAxis = flip ? (x: -axis.x, y: -axis.y) : axis
        let finalPerp = flip ? (x: -perp.x, y: -perp.y) : perp
        let uMax = uMin + Double(trimmed - 1)

        func width(_ i: Int) -> Double? {
            guard let t = vTop[i], let b = vBot[i], counts[i] > 0 else { return nil }
            return b - t
        }
        let finalValid = (0..<trimmed).map { counts[$0] >= minCount && width($0) != nil }

        // The flat-shoulder face sits at the run end: the first normal-width
        // column after the last over-wide bin is the shoulder. Sub-bin error is
        // absorbed by the offset auto-align scan (±0.060in).
        let shoulderIdx: Int
        let headLenPx: Double
        if headPresent {
            let runBins = headSideLow ? lowLen : highLen
            shoulderIdx = min(max(Int(runBins.rounded()), 0), trimmed - 2)
            headLenPx = Double(shoulderIdx)
        } else {
            shoulderIdx = 0
            headLenPx = 0
        }
        let tipIdx = trimmed - 1

        // Spine vs cut side by robust-fit residual over the blade band.
        var bandTopX = [Double](), bandTopY = [Double]()
        var bandBotX = [Double](), bandBotY = [Double]()
        for i in shoulderIdx...tipIdx where finalValid[i] {
            let u = uMin + Double(i)
            if let t = vTop[i] { bandTopX.append(u); bandTopY.append(t) }
            if let b = vBot[i] { bandBotX.append(u); bandBotY.append(b) }
        }
        guard bandTopX.count >= 5, bandBotX.count >= 5,
              let fitTop = LineFitting.robustFit(xs: bandTopX, ys: bandTopY),
              let fitBot = LineFitting.robustFit(xs: bandBotX, ys: bandBotY) else { return nil }
        let spineIsTop = fitTop.rms <= fitBot.rms
        let spine = spineIsTop
            ? SpineLine(slope: fitTop.line.slope, intercept: fitTop.line.intercept)
            : SpineLine(slope: fitBot.line.slope, intercept: fitBot.line.intercept)

        let bladeWidths = (shoulderIdx...tipIdx).compactMap(width)
        guard let bladeWidthPx = Statistics.median(bladeWidths) else { return nil }

        let profile = ColumnProfile(uMin: uMin, vTop: vTop, vBot: vBot, counts: counts)

        // Aspect gate: blade length / width (docs/ALGORITHM.md §2.6).
        let lengthPx = Double(tipIdx - shoulderIdx)
        guard lengthPx / max(bladeWidthPx, 1) >= 2.5 else { return nil }

        return BladeAnalysis(
            angle: angle, origin: CGPoint(x: cx, y: cy),
            axis: finalAxis, perp: finalPerp, pixelsPerMm: m.pixelsPerMm,
            uMin: uMin, uMax: uMax,
            headPresent: headPresent,
            shoulderU: uMin + Double(shoulderIdx), tipU: uMin + Double(tipIdx),
            spineIsTop: spineIsTop, spine: spine,
            spineRms: min(fitTop.rms, fitBot.rms),
            cutSideRms: max(fitTop.rms, fitBot.rms),
            bladeWidthPx: bladeWidthPx, headLenPx: headLenPx,
            columns: profile
        )
    }
}
