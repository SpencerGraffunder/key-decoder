import Foundation
import SwiftUI
import UIKit
import KeyCore

enum DecodeStep {
    case capture
    case cardEditor
    case processing
    case review
    case result
}

/// Orchestrates one decode: photo → card quad → corrected view → measurement → save.
/// Heavy CV runs detached; all state changes land on the main actor.
@MainActor
@Observable
final class DecodeFlow {
    var step: DecodeStep = .capture
    var photo: UIImage?
    var quad: [CGPoint]?
    var correctedImage: UIImage?
    var cardDetectionFailed = false
    var statusMessage = ""
    /// A key (re-)pick is running. The review screen stays on screen with its
    /// own spinner — leaving .review would tear the view down and its
    /// pickGeneration observer would miss the result.
    var isPicking = false

    var systems: [KeySystemDefinition] = KeySystemLibrary.bundled
    var systemID = "kw1"
    var suggestions: [SystemSuggestion] = []
    var result: CutScanResult?
    var params: CutGridParams?
    var warnings: [MeasurementPipeline.PipelineWarning] = []
    var pixelsPerMm = Perspective.pixelsPerMm()
    /// Pure manual fallback (segmentation failed): digits entered by hand.
    var manualDigits: [Int] = []

    private(set) var scene: MeasurementPipeline.Scene?
    /// Bumps each time a key (re-)pick finishes — success AND failure both
    /// change this, which the review screen watches to drive its two-stage
    /// flow (statusMessage alone can't signal "success" — it may already be "").
    private(set) var pickGeneration = 0

    /// Bounding box of the whole detected key (bow through tip) in corrected
    /// image coordinates — the target for "zoom to key".
    func keyBBox() -> CGRect? {
        guard let blade = scene?.blade, let params else { return nil }
        var minX = Double.greatestFiniteMagnitude, minY = minX
        var maxX = -Double.greatestFiniteMagnitude, maxY = maxX
        let samples = 24
        for k in 0...samples {
            let u = blade.uMin + (blade.uMax - blade.uMin) * Double(k) / Double(samples)
            let spineV = params.spine.v(at: u)
            let cutV = blade.cutEdgeV(at: u) ?? spineV + blade.bladeWidthPx
            for v in [spineV - blade.bladeWidthPx * 1.8, cutV + blade.bladeWidthPx * 0.6] {
                let p = blade.xy(u: u, v: v)
                minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
                minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -16, dy: -16)
    }

    var currentSystem: KeySystemDefinition? {
        KeySystemLibrary.system(id: systemID, in: systems)
    }

    var topSuggestion: SystemSuggestion? { suggestions.first }

    struct AutoOutcome {
        let scene: MeasurementPipeline.Scene
        let color: RGBAImage
        let pixelsPerMm: Double
        let result: CutScanResult
        let warnings: [MeasurementPipeline.PipelineWarning]
        let suggestions: [SystemSuggestion]
    }

    // MARK: - Flow

    func handlePhoto(_ image: UIImage) {
        let normalized = image.normalizedToUp ?? image
        photo = normalized
        cardDetectionFailed = false
        step = .processing
        guard let cg = normalized.cgImage else {
            step = .capture
            statusMessage = "Could not read the photo."
            return
        }
        Task { await detectCard(in: cg) }
    }

    private func detectCard(in cg: CGImage) async {
        let guide = CaptureGuide.photoRect(previewAspect: CaptureController.lastPreviewAspect)
        let found = await Task.detached(priority: .userInitiated) {
            CardDetector.detect(in: cg, prior: guide)
        }.value
        if let d = found, d.confident {
            // Always route through the corner editor (Spec: auto-skip jumped
            // straight to a badly-placed quad). The editor opens zoomed on the
            // card with these corners pre-seeded, so a good detection is one
            // "Use card" tap away.
            self.quad = d.quad
            cardDetectionFailed = false
            statusMessage = "Card found — check the corner rings, then Use card."
            step = .cardEditor
        } else if let d = found {
            // Low-confidence detection: seed the editor with the suggested
            // corners — confirming or nudging beats dragging four blanks, and
            // a suggestion is never auto-applied.
            quad = d.quad
            cardDetectionFailed = false
            step = .cardEditor
        } else {
            // Nothing found (a dark metal card on a dark table defeats even
            // relaxed Vision). The user was told to line the card up with
            // the guide outline — so scan a vertical band around it and run
            // the real pipeline at each offset: seed the editor where a
            // key-sized blob actually segments. Composition drift is the
            // norm, so a blind guide seed is only the last resort.
            let size = CGSize(width: cg.width, height: cg.height)
            var bestQuad: [CGPoint]?
            var bestScore = 1.4  // below this the guide default is just as good
            for dy in [-0.20, -0.10, 0.0, 0.10, 0.20] {
                let r = guide.offsetBy(dx: 0, dy: CGFloat(dy))
                guard r.minY >= 0, r.maxY <= 1 else { continue }
                let q = CaptureGuide.quad(in: size, normalized: r)
                let score = await Task.detached(priority: .userInitiated) {
                    MeasurementPipeline.keyScore(photo: cg, quad: q)
                }.value
                if let score, score > bestScore {
                    bestScore = score
                    bestQuad = q
                }
            }
            quad = bestQuad ?? CaptureGuide.quad(in: size, normalized: guide)
            cardDetectionFailed = true
            statusMessage = bestQuad != nil
                ? "Card not found — corners placed where the key shape appeared. Check the rings, then Use card."
                : "Card not found — corners set where the guide outline was. Check the rings, then Use card."
            step = .cardEditor
        }
    }

    func confirmQuad(_ newQuad: [CGPoint]) {
        // Re-canonicalize TL,TR,BR,BL: pinwheel/swapped corner pairs fed to
        // the homography produced mirrored or wildly stretched "rotated"
        // corrected photos; ordering first makes the user's ring ORDER not
        // matter, only WHICH corners they marked.
        quad = QuadOrdering.order(newQuad) ?? newQuad
        step = .processing
        guard let cg = photo?.cgImage else { step = .capture; return }
        Task { await analyze(with: newQuad, cg: cg) }
    }

    func analyze(with quad: [CGPoint], cg: CGImage) async {
        step = .processing
        let system = currentSystem ?? systems.first
        guard let system else { step = .capture; return }
        let outcome = await Task.detached(priority: .userInitiated) { () -> AutoOutcome? in
            guard let corrected = MeasurementPipeline.correct(photo: cg, quad: quad),
                  let scene = MeasurementPipeline.analyzeScene(
                    corrected: corrected.gray, pixelsPerMm: corrected.pixelsPerMm,
                    marginFrac: corrected.marginFrac
                  )
            else { return nil }
            var suggestions = SystemSuggester.suggest(
                scene: scene, candidates: KeySystemLibrary.defaultCandidates()
            )
            // Factory-stamped brand text outranks geometry guessing when present.
            if let correctedCG = corrected.color.toCGImage() {
                let texts = BowStampReader.readText(in: correctedCG)
                if !texts.isEmpty {
                    suggestions = SystemSuggester.applyStamp(
                        texts: texts,
                        candidates: KeySystemLibrary.defaultCandidates(),
                        to: suggestions
                    )
                }
            }
            let best = suggestions.first?.system ?? system
            let output = MeasurementPipeline.measure(scene: scene, system: best)
            return AutoOutcome(
                scene: scene, color: corrected.color,
                pixelsPerMm: corrected.pixelsPerMm,
                result: output.result, warnings: output.warnings, suggestions: suggestions
            )
        }.value

        guard let outcome else {
            // Never dead-end: fall back to manual handles / manual digits.
            statusMessage = "Could not find the key on the card. Adjust the card corners and retry, or enter the depths manually."
            manualDigits = Array(repeating: system.firstCode, count: system.pinCount)
            systemID = system.id
            result = nil
            params = nil
            step = .cardEditor
            return
        }

        scene = outcome.scene
        correctedImage = outcome.color.toCGImage().map { UIImage(cgImage: $0) }
        pixelsPerMm = outcome.pixelsPerMm
        suggestions = outcome.suggestions
        result = outcome.result
        params = outcome.result.params
        warnings = outcome.warnings
        systemID = outcome.result.params.systemID
        statusMessage = ""
        step = .review
    }

    /// Switch key system and re-run the automatic grid fit.
    func setSystem(_ id: String) {
        systemID = id
        guard let scene, let system = currentSystem else {
            manualDigits = Array(repeating: currentSystem?.firstCode ?? 0, count: currentSystem?.pinCount ?? 5)
            return
        }
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                MeasurementPipeline.measure(scene: scene, system: system)
            }.value
            result = output.result
            params = output.result.params
            warnings = output.warnings
        }
    }

    // MARK: - Manual adjust (review markers)

    func remeasureManual() {
        guard let scene, let system = currentSystem, var params else { return }
        params.systemID = system.id
        result = MeasurementPipeline.remeasure(scene: scene, system: system, params: params)
        self.params = params
    }

    /// "That's not my key" fix: re-run the whole pipeline treating the tapped
    /// point as the key blob. Image coordinates = corrected-view pixels.
    func pickKeyRegion(atImagePoint point: CGPoint) {
        guard let photoCG = photo?.cgImage, let quad, let system = currentSystem, !isPicking else { return }
        isPicking = true
        let seed = CGPoint(x: point.x, y: point.y)
        Task { @MainActor in
            let rebuilt = await Task.detached(priority: .userInitiated) { ()
                -> (color: RGBAImage, scene: MeasurementPipeline.Scene,
                    out: MeasurementPipeline.Output,
                    suggestions: [SystemSuggestion])? in
                guard let corrected = MeasurementPipeline.correct(photo: photoCG, quad: quad),
                      let scene = MeasurementPipeline.analyzeScene(
                          corrected: corrected.gray, pixelsPerMm: corrected.pixelsPerMm, seed: seed,
                          marginFrac: corrected.marginFrac
                      )
                else { return nil }
                var suggestions = SystemSuggester.suggest(
                    scene: scene, candidates: KeySystemLibrary.defaultCandidates()
                )
                if let correctedCG = corrected.color.toCGImage() {
                    let texts = BowStampReader.readText(in: correctedCG)
                    if !texts.isEmpty {
                        suggestions = SystemSuggester.applyStamp(
                            texts: texts, candidates: KeySystemLibrary.defaultCandidates(),
                            to: suggestions
                        )
                    }
                }
                return (corrected.color, scene,
                        MeasurementPipeline.measure(scene: scene, system: system), suggestions)
            }.value
            guard let rebuilt else {
                statusMessage = "Couldn't find a key region where you tapped — tap directly on the metal."
                pickGeneration += 1
                isPicking = false
                return
            }
            scene = rebuilt.scene
            pixelsPerMm = rebuilt.scene.pixelsPerMm
            correctedImage = rebuilt.color.toCGImage().map { UIImage(cgImage: $0) }
            suggestions = rebuilt.suggestions
            result = rebuilt.out.result
            params = rebuilt.out.result.params
            warnings = rebuilt.out.warnings
            manualDigits = []
            statusMessage = ""
            pickGeneration += 1
            isPicking = false
        }
    }

    func dragShoulder(toImagePoint point: CGPoint) {
        guard let blade = scene?.blade, var params else { return }
        params.shoulderU = blade.uv(point).u
        self.params = params
        remeasureManual()
    }

    func dragSpine(toImagePoint point: CGPoint) {
        guard let blade = scene?.blade, var params else { return }
        let uv = blade.uv(point)
        params.spine.intercept = uv.v - params.spine.slope * uv.u
        self.params = params
        remeasureManual()
    }

    /// Drag one END of the spine line: the line pivots about the other end,
    /// so the user can fix a spine that landed on the wrong axis (Spec).
    func dragSpineEnd(atU u: Double, toImagePoint point: CGPoint) {
        guard let blade = scene?.blade, var params else { return }
        let uv = blade.uv(point)
        let otherU: Double = (u == params.shoulderU) ? blade.tipU : params.shoulderU
        let v1 = params.spine.v(at: otherU)
        let du = uv.u - otherU
        if abs(du) > 3 {
            params.spine.slope = (uv.v - v1) / du
        }
        params.spine.intercept = uv.v - params.spine.slope * uv.u
        self.params = params
        remeasureManual()
    }

    /// Swap which side of the blade is the spine — when the auto analysis
    /// caught the blade upside down (top line and base line on the wrong
    /// axis) and no drag makes it right (Spec).
    func flipBladeAxis() {
        guard var params else { return }
        params.direction = -params.direction
        self.params = params
        remeasureManual()
    }

    func dragCut(_ index: Int, toImagePoint point: CGPoint) {
        guard let blade = scene?.blade, var params, let result,
              currentSystem != nil else { return }
        let existing = params.cutDeltaPx.indices.contains(index) ? params.cutDeltaPx[index] : 0
        let nominal = result.cuts[index].centerU - existing
        let newDelta = blade.uv(point).u - nominal
        while params.cutDeltaPx.count <= index { params.cutDeltaPx.append(0) }
        params.cutDeltaPx[index] = newDelta
        self.params = params
        remeasureManual()
    }

    /// Manual digit entry (works even when measurement data exists — overrides the digit).
    func setDigitOverride(_ index: Int, to digit: Int) {
        guard let system = currentSystem else { return }
        let clamped = min(max(digit, system.digitRange.lowerBound), system.digitRange.upperBound - 1)
        if result == nil {
            if manualDigits.indices.contains(index) { manualDigits[index] = clamped }
            return
        }
        guard var params else { return }
        params.digitOverrides[index] = clamped
        self.params = params
        remeasureManual()
    }

    func clearDigitOverride(_ index: Int) {
        guard var params else { return }
        params.digitOverrides[index] = nil
        self.params = params
        remeasureManual()
    }

    var effectiveCode: String {
        if let result { return result.codeString }
        return manualDigits.map(String.init).joined(separator: "-")
    }

    /// For the pure-manual path: build a saveable snapshot without measurements.
    var manualSnapshotCuts: [KeyMeasurementSnapshot.Cut] {
        manualDigits.enumerated().map { index, digit in
            KeyMeasurementSnapshot.Cut(
                index: index, depthIn: .nan, digit: digit, marginSteps: 0,
                outOfTable: false, lowConfidence: false, isManualOverride: true
            )
        }
    }

    func retake() {
        // Move away from every screen that renders from this state FIRST —
        // observers may re-render per mutation, not per batch.
        step = .capture
        quad = nil
        correctedImage = nil
        scene = nil
        result = nil
        params = nil
        suggestions = []
        warnings = []
        manualDigits = []
        cardDetectionFailed = false
        statusMessage = ""
        isPicking = false
    }
}

extension UIImage {
    /// Bake EXIF orientation into pixels so Vision/pipeline see upright pixels.
    var normalizedToUp: UIImage? {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
