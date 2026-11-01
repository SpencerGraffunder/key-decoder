import Foundation

/// What the cut grid is measured from (docs/ALGORITHM.md §4).
public enum KeyAlignment: String, Codable, Equatable, Sendable {
    case shoulder
    case tip
}

/// A data-driven key system definition (JSON in Resources/keysystems.json).
/// Numbers are root depths in decimal inches measured from the blade spine.
public struct KeySystemDefinition: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let manufacturer: String
    /// "verified" = cross-checked against published sheets; "draft" = single source.
    public let status: String
    public let pinCount: Int
    public let alignment: KeyAlignment
    /// Distance from the alignment reference to the center of the first (bow-side) cut.
    public let firstCutIn: Double
    public let spacingIn: Double
    public let incrementIn: Double
    /// Code value of `depthsIn[0]` (KW1 starts at 1, SC1 at 0).
    public let firstCode: Int
    public let depthsIn: [Double]
    public let cutWidthIn: Double?
    public let macs: Int?
    public let bladeWidthIn: Double?
    public let sources: [String]
    public let notes: String?

    public var isVerified: Bool { status == "verified" }

    public var digitRange: Range<Int> { firstCode ..< (firstCode + depthsIn.count) }

    public func depth(digit: Int) -> Double? {
        guard digitRange.contains(digit) else { return nil }
        return depthsIn[digit - firstCode]
    }

    /// Nearest table entry for a measured root depth, with boundary confidence.
    public func lookup(depthIn: Double) -> DigitLookup {
        var bestIndex = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, d) in depthsIn.enumerated() {
            let dist = abs(d - depthIn)
            if dist < bestDist { bestDist = dist; bestIndex = i }
        }
        let margin = incrementIn > 0 ? bestDist / incrementIn : bestDist
        return DigitLookup(
            digit: bestIndex + firstCode,
            residualIn: bestDist,
            marginSteps: margin,
            // 1e-9 tolerance: (a+b)/2 depths land at 0.5 + 1 ulp of binary
            // noise; the spec boundary is STRICTLY greater than 0.5.
            outOfTable: margin > 0.5 + 1e-9,
            nearBoundary: margin > 0.35
        )
    }
}

public struct DigitLookup: Codable, Equatable {
    public let digit: Int
    public let residualIn: Double
    /// Distance from the table value in depth increments (0 = exact hit, 0.5 = midpoint).
    public let marginSteps: Double
    public let outOfTable: Bool
    public let nearBoundary: Bool
}

/// Wrapper for Resources/keysystems.json.
struct KeySystemFile: Codable {
    let schemaVersion: Int
    let systems: [KeySystemDefinition]
}

public enum KeySystemLibrary {
    public static func decode(_ data: Data) throws -> [KeySystemDefinition] {
        try JSONDecoder().decode(KeySystemFile.self, from: data).systems
    }

    /// Definitions shipped with the framework (empty when the resource is missing).
    public static var bundled: [KeySystemDefinition] {
        let candidates = [
            Bundle(for: BundleToken.self),
            Bundle(for: BundleToken.self).url(forResource: "Frameworks/KeyCore", withExtension: "framework").flatMap(Bundle.init(url:)),
            .main,
        ]
        for bundle in candidates.compactMap({ $0 }) {
            if let url = bundle.url(forResource: "keysystems", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let systems = try? decode(data), !systems.isEmpty {
                return systems
            }
        }
        return []
    }

    public static func system(id: String, in systems: [KeySystemDefinition]) -> KeySystemDefinition? {
        systems.first { $0.id == id }
    }

    /// Verified systems ship enabled by default; drafts are opt-in surface.
    public static func defaultCandidates(in systems: [KeySystemDefinition]? = nil) -> [KeySystemDefinition] {
        (systems ?? bundled).filter { $0.isVerified }
    }
}

final class BundleToken {}
