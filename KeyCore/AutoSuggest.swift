import Foundation

/// Key-system auto-suggestion from cut geometry, independent of any single table
/// (docs/ALGORITHM.md §6). Always advisory: the UI must offer manual override.
public struct SystemSuggestion: Equatable {
    public let system: KeySystemDefinition
    public let score: Double
    public let detectedSpacingIn: Double?
    public let detectedCutCount: Int
    /// Why this ranks where it does ("stamped 'KW1' on bow", "spacing .151 ·
    /// 5 cuts"). Optional var so existing call sites keep compiling.
    public var reason: String? = nil

    public init(
        system: KeySystemDefinition, score: Double,
        detectedSpacingIn: Double?, detectedCutCount: Int, reason: String? = nil
    ) {
        self.system = system
        self.score = score
        self.detectedSpacingIn = detectedSpacingIn
        self.detectedCutCount = detectedCutCount
        self.reason = reason
    }
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
            var why: [String] = []
            if let spacing = detectedSpacingIn {
                why.append(String(format: "spacing ~%.3f in", spacing))
            }
            if detectedCutCount > 0 {
                why.append("\(detectedCutCount) cut\(detectedCutCount == 1 ? "" : "s")")
            }
            scored.append(SystemSuggestion(
                system: candidate, score: score,
                detectedSpacingIn: detectedSpacingIn, detectedCutCount: detectedCutCount,
                reason: why.isEmpty ? nil : why.joined(separator: " · ")
            ))
        }
        return scored.sorted { $0.score < $1.score }
    }

    /// Stamped brand text is the strongest identification signal there is —
    /// blanks are engraved at the factory. When OCR finds a system's stamp,
    /// that system leads the ranking (still advisory: the user confirms).
    public static func applyStamp(
        texts: [String],
        candidates: [KeySystemDefinition],
        to suggestions: [SystemSuggestion]
    ) -> [SystemSuggestion] {
        guard let match = BowStamp.match(texts: texts, in: candidates) else { return suggestions }
        var updated = suggestions
        if let i = updated.firstIndex(where: { $0.system.id == match.system.id }) {
            updated[i].reason = "stamped \u{201c}\(match.text)\u{201d} on the bow"
            let item = updated.remove(at: i)
            updated.insert(item, at: 0)
        } else {
            let entry = SystemSuggestion(
                system: match.system, score: 0,
                detectedSpacingIn: suggestions.first?.detectedSpacingIn,
                detectedCutCount: suggestions.first?.detectedCutCount ?? 0,
                reason: "stamped \u{201c}\(match.text)\u{201d} on the bow"
            )
            updated.insert(entry, at: 0)
        }
        // The stamped system leads regardless of fit score; the remainder
        // keeps score order.
        let head = updated.removeFirst()
        return [head] + updated.sorted { $0.score < $1.score }
    }
}
