import Foundation

public enum Statistics {
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    public static func medianAbsoluteDeviation(_ values: [Double], around center: Double? = nil) -> Double? {
        guard !values.isEmpty else { return nil }
        let c = center ?? median(values) ?? 0
        return median(values.map { abs($0 - c) })
    }
}

/// Ordinary least-squares line y = slope * x + intercept.
public struct LeastSquaresLine {
    public let slope: Double
    public let intercept: Double

    public func y(at x: Double) -> Double { slope * x + intercept }
}

public enum LineFitting {
    /// Least squares + one MAD-clipped refit pass (docs/ALGORITHM.md §3.5).
    /// Returns the line and its RMS residual over the surviving points.
    public static func robustFit(xs: [Double], ys: [Double], madClip: Double = 2.5)
        -> (line: LeastSquaresLine, rms: Double, used: Int)?
    {
        guard xs.count == ys.count, xs.count >= 3 else { return nil }
        guard var line = lsFit(xs: xs, ys: ys) else { return nil }
        var residuals = zip(xs, ys).map { abs($1 - line.y(at: $0)) }
        let mad = Statistics.medianAbsoluteDeviation(residuals) ?? 0
        let clip = max(mad * madClip, 1e-9)
        var keepX = [Double](), keepY = [Double]()
        for i in 0..<xs.count where residuals[i] <= clip || mad < 1e-9 {
            keepX.append(xs[i]); keepY.append(ys[i])
        }
        if keepX.count >= 3, let refit = lsFit(xs: keepX, ys: keepY) { line = refit }
        residuals = zip(xs, ys).map { abs($1 - line.y(at: $0)) }
        let survivors = residuals.filter { $0 <= clip || mad < 1e-9 }
        let list = survivors.isEmpty ? residuals : survivors
        let rms = (list.reduce(0) { $0 + $1 * $1 } / Double(list.count)).squareRoot()
        return (line, rms, list.count)
    }

    public static func lsFit(xs: [Double], ys: [Double]) -> LeastSquaresLine? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        let sxx = xs.reduce(0) { $0 + $1 * $1 }
        var sxy = 0.0
        for i in 0..<xs.count { sxy += xs[i] * ys[i] }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-12 else { return nil }
        let slope = (n * sxy - sx * sy) / denom
        let intercept = (sy - slope * sx) / n
        return LeastSquaresLine(slope: slope, intercept: intercept)
    }
}

/// 1-D helpers used by the cut-depth and auto-suggest stages.
public enum Signal1D {
    /// Boxcar smoothing of a sparse profile; nil entries are skipped (nearest-valid fill at edges).
    public static func smooth(_ values: [Double?], radius: Int) -> [Double?] {
        var filled = values
        // Fill holes by nearest valid neighbor.
        for i in values.indices where filled[i] == nil {
            var d = 1
            while d <= radius * 3 {
                if i - d >= 0, let v = values[i - d] { filled[i] = v; break }
                if i + d < values.count, let v = values[i + d] { filled[i] = v; break }
                d += 1
            }
        }
        var out = [Double?](repeating: nil, count: values.count)
        for i in values.indices {
            var sum = 0.0, count = 0
            for k in max(0, i - radius)...min(values.count - 1, i + radius) {
                if let v = filled[k] { sum += v; count += 1 }
            }
            out[i] = count > 0 ? sum / Double(count) : nil
        }
        return out
    }

    /// Count prominent local maxima; `minDistance` is the minimum index spacing between peaks.
    public static func prominentPeakCount(
        _ values: [Double?], minDistance: Int, prominence: Double
    ) -> Int {
        let compact = values.compactMap { $0 }
        guard compact.count >= 3, prominence > 0 else { return 0 }
        var peaks = [Int]()
        for i in 1..<(values.count - 1) {
            guard let v = values[i], let a = values[i - 1], let b = values[i + 1] else { continue }
            if v >= a, v >= b, v > a || v > b {
                // Prominence: must stand above the lower flanking trough within minDistance.
                let lo = max(0, i - minDistance * 2)
                let hi = min(values.count - 1, i + minDistance * 2)
                let flank = (lo...hi).compactMap { values[$0] }.min() ?? v
                if v - flank >= prominence { peaks.append(i) }
            }
        }
        // Enforce spacing by keeping the higher peak of too-close pairs.
        var kept = [Int]()
        for p in peaks {
            if let last = kept.last, p - last < minDistance {
                let lv = values[kept[kept.count - 1]] ?? 0
                let pv = values[p] ?? 0
                if pv > lv { kept[kept.count - 1] = p }
            } else {
                kept.append(p)
            }
        }
        return kept.count
    }

    /// Index of the best autocorrelation lag within [lagMin, lagMax] (zero-mean input expected).
    public static func autocorrelationPeak(_ values: [Double], lagMin: Int, lagMax: Int) -> Int? {
        guard values.count > 2, lagMin >= 1, lagMax < values.count else { return nil }
        var bestLag: Int?
        var bestScore = -Double.infinity
        for lag in lagMin...lagMax {
            var s = 0.0, n = 0
            for i in 0..<(values.count - lag) {
                s += values[i] * values[i + lag]
                n += 1
            }
            guard n > 0 else { continue }
            let score = s / Double(n)
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        return bestLag
    }
}
