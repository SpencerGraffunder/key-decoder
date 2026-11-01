import Foundation

/// Key-system auto-suggestion from cut geometry, independent of any single table
/// (docs/ALGORITHM.md §6). Always advisory: the UI must offer manual override.
public struct SystemSuggestion: Equatable {
    public let system: KeySystemDefinition
    public let score: Double
    public let detectedSpacingIn: Double?
    public let detectedCutCount: Int
}

public enum SystemSuggester {
    public static func suggest(
        scene: MeasurementPipeline.Scene,
        candidates: [KeySystemDefinition]
    ) -> [SystemSuggestion] {
        guard !candidates.isEmpty else { return [] }
        let blade = scene.blade
        let ppmIn = blade.pixelsPerInch

        // Depth profile over the blade band, baseline-removed, for autocorrelation.
        let lo = Int((blade.headPresent ? blade.shoulderU : blade.uMin) - blade.columns.uMin)
        let hi = Int(blade.tipU - blade.columns.uMin)
        var profile = [Double?]()
        if lo <= hi, hi >= 0, lo < blade.columns.vTop.count {
            for i in max(0, lo)...min(blade.columns.vTop.count - 1, hi) {
                profile.append(blade.depthPx(at: blade.columns.uMin + Double(i)))
            }
        }
        let smoothed = Signal1D.smooth(profile, radius: max(1, Int((0.02 * ppmIn).rounded())))
        let dense = smoothed.compactMap { $0 }
        var detectedSpacingIn: Double?
        var detectedCutCount = 0
        if dense.count > 40 {
            let med = Statistics.median(dense) ?? 0
            let centered = dense.map { $0 - med }
            let lagMin = max(2, Int((0.100 * ppmIn).rounded()))
            let lagMax = min(centered.count - 2, Int((0.190 * ppmIn).rounded()))
            if let lag = Signal1D.autocorrelationPeak(centered, lagMin: lagMin, lagMax: lagMax) {
                detectedSpacingIn = Double(lag) / ppmIn
            }
            let sorted = dense.sorted()
            let spread = sorted[sorted.count - 1] - sorted[0]
            detectedCutCount = Signal1D.prominentPeakCount(
                smoothed,
                minDistance: max(2, Int((0.100 * ppmIn).rounded())),
                prominence: max(0.004 * ppmIn, 0.25 * spread)
            )
        }

        var scored = [SystemSuggestion]()
        for candidate in candidates {
            let params = CutMeasurementEngine.initialParams(
                blade: blade, direction: 1, systemID: candidate.id
            )
            var best = CutMeasurementEngine.measure(
                blade: blade, params: params, system: candidate, scanOffset: true
            )
            if !blade.headPresent {
                let flipped = CutMeasurementEngine.initialParams(
                    blade: blade, direction: -1, systemID: candidate.id
                )
                let other = CutMeasurementEngine.measure(
                    blade: blade, params: flipped, system: candidate, scanOffset: true
                )
                if other.score < best.score { best = other }
            }
            var score = best.score
            if let spacing = detectedSpacingIn {
                score += abs(spacing - candidate.spacingIn) * 4
            }
            if detectedCutCount > 0, detectedCutCount != candidate.pinCount {
                score += 0.4
            }
            scored.append(SystemSuggestion(
                system: candidate, score: score,
                detectedSpacingIn: detectedSpacingIn, detectedCutCount: detectedCutCount
            ))
        }
        return scored.sorted { $0.score < $1.score }
    }
}
