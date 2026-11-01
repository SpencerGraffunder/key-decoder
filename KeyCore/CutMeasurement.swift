#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Measurement state a user can adjust on the review screen: everything needed to
/// recompute the cut grid after manual marker drags.
public struct CutGridParams: Codable, Equatable {
    public var shoulderU: Double
    /// +1 = cuts advance along +u (bow at low u); -1 resolves headless blobs the other way.
    public var direction: Int
    public var spine: SpineLine
    /// Auto-align scan result added to every cut center (pixels along u).
    public var offsetPx: Double
    public var systemID: String
    /// Manual digit entry per cut index; wins over the measured digit.
    public var digitOverrides: [Int: Int]
    /// Per-cut center nudges from the review markers (pixels along u, additive).
    public var cutDeltaPx: [Double]

    public init(
        shoulderU: Double, direction: Int, spine: SpineLine,
        offsetPx: Double, systemID: String, digitOverrides: [Int: Int] = [:],
        cutDeltaPx: [Double] = []
    ) {
        self.shoulderU = shoulderU
        self.direction = direction
        self.spine = spine
        self.offsetPx = offsetPx
        self.systemID = systemID
        self.digitOverrides = digitOverrides
        self.cutDeltaPx = cutDeltaPx
    }
}

public struct CutMeasurement: Codable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let centerU: Double
    /// Measured root depth in inches (NaN when no mask columns were available).
    public let depthIn: Double
    public let digit: Int
    public let residualIn: Double
    public let marginSteps: Double
    public let outOfTable: Bool
    public let lowConfidence: Bool
    public let noiseRmsIn: Double
    public let missingColumns: Int
    public let isManualOverride: Bool
}

public struct CutScanResult: Equatable {
    public let params: CutGridParams
    public let cuts: [CutMeasurement]
    /// RMS of |measured depth − table depth| over the cuts (direction pick / auto-suggest).
    public let score: Double
    public let gridBeyondBlade: Bool

    public var codeString: String {
        cuts.map { String($0.digit) }.joined(separator: "-")
    }
}

public enum CutMeasurementEngine {
    /// Review flags from docs/ALGORITHM.md §4.
    public static let nearBoundarySteps = 0.35
    public static let outOfTableSteps = 0.50
    public static let scanRangeIn = 0.060
    public static let scanStepIn = 0.004

    public static func initialParams(blade: BladeAnalysis, direction: Int, systemID: String) -> CutGridParams {
        let shoulder = blade.headPresent ? blade.shoulderU : (direction >= 0 ? blade.uMin : blade.uMax)
        return CutGridParams(
            shoulderU: shoulder, direction: direction >= 0 ? 1 : -1,
            spine: blade.spine, offsetPx: 0, systemID: systemID
        )
    }

    public static func measure(
        blade: BladeAnalysis, params: CutGridParams, system: KeySystemDefinition,
        scanOffset: Bool = true
    ) -> CutScanResult {
        var params = params
        if scanOffset, let best = bestOffset(blade: blade, params: params, system: system) {
            params.offsetPx = best
        }
        let ppmIn = blade.pixelsPerInch
        // Window sits on the cut's flat bottom (root flats are ~0.02-0.045 in wide);
        // a wider window would average the ramp flanks and bias depths shallow.
        let windowPx = max(
            1, Int((min(0.012, 0.25 * system.spacingIn) * ppmIn).rounded())
        )
        var cuts = [CutMeasurement]()
        var residuals = [Double]()
        var beyond = false

        for i in 0..<system.pinCount {
            let nudge = params.cutDeltaPx.indices.contains(i) ? params.cutDeltaPx[i] : 0
            let center = params.shoulderU
                + Double(params.direction) * (system.firstCutIn + Double(i) * system.spacingIn) * ppmIn
                + params.offsetPx + nudge
            if center < blade.uMin || center > blade.uMax { beyond = true }

            let sample = depthSample(blade: blade, params: params, center: center, windowPx: windowPx)
            let depthIn = sample.medianPx / ppmIn
            let lookup = system.lookup(depthIn: depthIn)
            let noiseRmsIn = sample.rmsPx / ppmIn
            let digitOverride = params.digitOverrides[i]
            let noiseHigh = noiseRmsIn > 0.25 * system.incrementIn
            cuts.append(CutMeasurement(
                index: i, centerU: center,
                depthIn: depthIn,
                digit: digitOverride ?? lookup.digit,
                residualIn: digitOverride != nil ? 0 : lookup.residualIn,
                marginSteps: digitOverride != nil ? 0 : lookup.marginSteps,
                outOfTable: digitOverride == nil && lookup.outOfTable,
                lowConfidence: digitOverride != nil
                    ? false
                    : lookup.nearBoundary || noiseHigh || sample.missing > 0 || sample.noData,
                noiseRmsIn: noiseRmsIn,
                missingColumns: sample.missing,
                isManualOverride: digitOverride != nil
            ))
            if digitOverride == nil, !sample.noData { residuals.append(lookup.residualIn) }
        }

        let score = residuals.isEmpty
            ? Double.greatestFiniteMagnitude
            : (residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)).squareRoot()
        return CutScanResult(params: params, cuts: cuts, score: score, gridBeyondBlade: beyond)
    }

    /// Table-RMS minimized over a ±0.060 in shoulder-offset scan, with a
    /// 0.03/in |δ| regularizer (tools/proto/REPORT.md "offset auto-align"):
    /// the spec's "maximize Σ depth" aligns windows on the blade FLOOR between
    /// cuts, and Σ is flat across the notch root band so sub-pixel noise picks
    /// the argmin. RMS-to-table + regularizer prefers the centered alignment.
    private static func bestOffset(
        blade: BladeAnalysis, params: CutGridParams, system: KeySystemDefinition
    ) -> Double? {
        let ppmIn = blade.pixelsPerInch
        let windowPx = max(1, Int((min(0.012, 0.25 * system.spacingIn) * ppmIn).rounded()))
        let rangePx = scanRangeIn * ppmIn
        let stepPx = max(1.0, scanStepIn * ppmIn)
        let alignTauPerIn = 0.03
        var bestOffset = 0.0
        var bestScore = Double.greatestFiniteMagnitude
        var anyData = false
        var delta = -rangePx
        while delta <= rangePx {
            var ss = 0.0, n = 0
            for i in 0..<system.pinCount {
                let center = params.shoulderU
                    + Double(params.direction) * (system.firstCutIn + Double(i) * system.spacingIn) * ppmIn
                    + delta
                let s = depthSample(blade: blade, params: params, center: center, windowPx: windowPx)
                if s.noData { continue }
                anyData = true
                let r = system.lookup(depthIn: s.medianPx / ppmIn).residualIn
                ss += r * r
                n += 1
            }
            if n > 0 {
                let score = (ss / Double(n)).squareRoot() + alignTauPerIn * abs(delta / ppmIn)
                if score < bestScore { bestScore = score; bestOffset = delta }
            }
            delta += stepPx
        }
        return anyData ? bestOffset : nil
    }

    private static func depthSample(
        blade: BladeAnalysis, params: CutGridParams, center: Double, windowPx: Int
    ) -> (medianPx: Double, rmsPx: Double, missing: Int, noData: Bool) {
        let lo = (center - Double(windowPx)).rounded(.down)
        let hi = (center + Double(windowPx)).rounded(.up)
        var values = [Double]()
        var missing = 0
        var u = lo
        while u <= hi {
            guard let edge = blade.cutEdgeV(at: u) else {
                missing += 1
                u += 1
                continue
            }
            let line = params.spine.v(at: u)
            values.append(blade.spineIsTop ? edge - line : line - edge)
            u += 1
        }
        guard let median = Statistics.median(values), !values.isEmpty else {
            return (.nan, .nan, missing, true)
        }
        let rms = (values.reduce(0) { $0 + ($1 - median) * ($1 - median) } / Double(values.count)).squareRoot()
        return (median, rms, missing, false)
    }
}
