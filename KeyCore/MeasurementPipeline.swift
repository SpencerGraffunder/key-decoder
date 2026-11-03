#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Persistable pipeline state: enough to redraw the review overlay and remeasure
/// after manual adjustments without keeping large rasters alive.
public struct MeasurementState: Codable, Equatable {
    public var systemID: String
    public var cardQuad: [CGPoint]
    public var grid: CutGridParams
    /// Depth per cut in inches at the time of the saved measurement (reporting only).
    public var depthsIn: [Double]
    public var pixelsPerMm: Double
}

public enum MeasurementPipeline {
    public struct Scene {
        public let corrected: GrayImage
        public let mask: KeyMaskResult
        public let blade: BladeAnalysis
        public let pixelsPerMm: Double
        /// Padded-frame fraction the scene was segmented with (0 = legacy
        /// full-card frame, 0.16 = surroundings ring around the card).
        public var marginFrac: Double = 0
    }

    public struct Output {
        public let scene: Scene
        public let result: CutScanResult
        public let warnings: [PipelineWarning]
    }

    public enum PipelineWarning: String, Codable, Equatable {
        case segmentationFailed
        case bladeAnalysisFailed
        case bladeLengthSuspicious
        case gridBeyondBlade
        case outOfTableCuts
        case lowConfidenceCuts
    }

    /// Full photo + card quad → corrected gray/color views.
    #if canImport(CoreGraphics)
    public static func correct(
        photo: CGImage, quad: [CGPoint], outputWidth: Int = Perspective.defaultOutputWidth,
        marginFrac: Double = 0.16
    ) -> (gray: GrayImage, color: RGBAImage, pixelsPerMm: Double)? {
        let height = Perspective.outputHeight(forWidth: outputWidth)
        // Padded warp: grow the source quad about the card centroid so the
        // corrected frame carries a ring of the photo around the card. A key
        // whose teeth hang past the card edge then survives the warp instead
        // of being cropped at the boundary. Card and key land at different
        // depths (a few mm over ~60 cm), so the homography is slightly off
        // for the overhang — millimeters, far inside the measurement window.
        let source = marginFrac > 0 ? (Perspective.expandedQuad(quad, marginFrac: marginFrac) ?? quad) : quad
        let ppm = marginFrac > 0
            ? Perspective.pixelsPerMm(forWidth: outputWidth, marginFrac: marginFrac)
            : Perspective.pixelsPerMm(forWidth: outputWidth)
        guard let warped = GrayImage(cgImage: photo),
              let gray = Perspective.warpGray(warped, quad: source, outputWidth: outputWidth, outputHeight: height),
              let rgba = RGBAImage(cgImage: photo),
              let color = Perspective.warpColor(rgba, quad: source, outputWidth: outputWidth, outputHeight: height)
        else { return nil }
        return (gray.image, color, ppm)
    }
    #endif

    /// Corrected view → key mask + blade geometry. nil → manual review path.
    public static func analyzeScene(
        corrected: GrayImage, pixelsPerMm: Double, seed: CGPoint? = nil, marginFrac: Double = 0
    ) -> Scene? {
        let seedPair = seed.map { (x: Int($0.x.rounded()), y: Int($0.y.rounded())) }
        guard let mask = KeySegmentation.segment(corrected, pixelsPerMm: pixelsPerMm, seed: seedPair, marginFrac: marginFrac),
              let blade = BladeAnalyzer.analyze(mask) else { return nil }
        return Scene(corrected: corrected, mask: mask, blade: blade, pixelsPerMm: pixelsPerMm, marginFrac: marginFrac)
    }

    /// Auto measurement. Headless blobs are resolved by trying both axis directions.
    public static func measure(scene: Scene, system: KeySystemDefinition) -> Output {
        var warnings = [PipelineWarning]()
        let directions: [Int] = scene.blade.headPresent ? [1] : [1, -1]
        var results: [(result: CutScanResult, direction: Int)] = []
        for dir in directions {
            let params = CutMeasurementEngine.initialParams(
                blade: scene.blade, direction: dir, systemID: system.id
            )
            results.append((
                CutMeasurementEngine.measure(
                    blade: scene.blade, params: params, system: system, scanOffset: true
                ), dir
            ))
        }
        // Prototype-validated tie-breakers (tools/proto/REPORT.md §"headless
        // direction"): a mirrored grid can only align by sliding the offset scan,
        // so penalize far offsets and grids that run past the blade; residuals
        // alone are provably ambiguous when the depth multiset reads in reverse.
        func selectionScore(_ r: CutScanResult) -> Double {
            let deltaIn = abs(r.params.offsetPx) / scene.pixelsPerMm / 25.4
            return r.score + 0.05 * max(0, deltaIn - 0.030) + (r.gridBeyondBlade ? 0.10 : 0)
        }
        let picked = results.min(by: { selectionScore($0.result) < selectionScore($1.result) })!
        let output = picked.result

        let shoulderEnd = scene.blade.headPresent
            ? scene.blade.shoulderU
            : (picked.direction >= 0 ? scene.blade.uMin : scene.blade.uMax)
        let bladeLenIn = abs(scene.blade.tipU - shoulderEnd) / scene.pixelsPerMm / 25.4
        if bladeLenIn < 0.5 || bladeLenIn > 1.9 { warnings.append(.bladeLengthSuspicious) }
        if output.gridBeyondBlade { warnings.append(.gridBeyondBlade) }
        if output.cuts.contains(where: { $0.outOfTable }) { warnings.append(.outOfTableCuts) }
        if output.cuts.contains(where: { $0.lowConfidence }) { warnings.append(.lowConfidenceCuts) }
        return Output(scene: scene, result: output, warnings: warnings)
    }

    /// Manual-adjust remeasure: user dragged markers/overrode digits.
    public static func remeasure(
        scene: Scene, system: KeySystemDefinition, params: CutGridParams
    ) -> CutScanResult {
        CutMeasurementEngine.measure(blade: scene.blade, params: params, system: system, scanOffset: false)
    }

    public static func state(from result: CutScanResult, cardQuad: [CGPoint], pixelsPerMm: Double) -> MeasurementState {
        MeasurementState(
            systemID: result.params.systemID,
            cardQuad: cardQuad,
            grid: result.params,
            depthsIn: result.cuts.map { $0.depthIn },
            pixelsPerMm: pixelsPerMm
        )
    }
}
