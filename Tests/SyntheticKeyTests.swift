import CoreGraphics
import Foundation
import XCTest
@testable import KeyCore

/// Ground-truth validation: synthesize a key on an ISO card with a KNOWN bitting
/// code, warp it into a photo with a known perspective quad, run the real pipeline,
/// and require the recovered code to match (docs/ALGORITHM.md "Validation protocol").
final class SyntheticKeyTests: XCTestCase {
    // MARK: - Deterministic RNG

    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed | 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    // MARK: - Scene synthesis

    static let cardWidthPx = 2600
    static let ppm = Perspective.pixelsPerMm()          // px per mm
    static var cardHeightPx: Int { Perspective.outputHeight() }
    static var ppmIn: Double { ppm * 25.4 }             // px per inch

    struct SceneStyle {
        var noise = 0.0
        var gradient = 0.0        // card-face luminance ramp (left→right)
        var shadowBand = false    // dark vertical band across the card
        var headVisible = true
        var photoDownscale: Double = 1.0
    }

    /// Draw the top-down card face with a key (spine up, cuts on the bottom edge).
    private func renderCard(
        system: KeySystemDefinition, code: [Int], style: SceneStyle, rng: inout SeededRNG
    ) -> GrayImage {
        let w = Self.cardWidthPx, h = Self.cardHeightPx, ppmIn = Self.ppmIn
        let bladeWidth = system.bladeWidthIn ?? 0.36
        let shoulderX = 1.3 * ppmIn
        let spineY = 0.82 * ppmIn
        let bladeBottom = spineY + bladeWidth * ppmIn
        let lastCutX = shoulderX
            + (system.firstCutIn + Double(system.pinCount - 1) * system.spacingIn) * ppmIn
        let tipX = lastCutX + 0.16 * ppmIn  // proto lead-in range; 0.35" is mirror-ambiguous
        let keyLevel: Double = 90
        let cardFace: Double = 232

        var pixels = [UInt8](repeating: 0, count: w * h)
        // Uneven illumination: a dark strip across the card face just ABOVE the
        // key's spine (shadows adjacent to the key are the realistic hard case;
        // a full-card shadow is indistinguishable from a dark key without priors).
        let stripBottom = 0.74 * Self.ppmIn
        for y in 0..<h {
            for x in 0..<w {
                var v = cardFace - style.gradient * Double(x) / Double(w)
                if style.shadowBand, y < Int(stripBottom), x > w / 4, x < w * 55 / 100 { v -= 45 }
                pixels[y * w + x] = UInt8(max(0, min(255, v)))
            }
        }

        func put(_ x: Int, _ y: Int, _ v: Double) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            pixels[y * w + x] = UInt8(max(0, min(255, v)))
        }

        // Blade: every column spans spineY → edge profile (notches recede upward).
        var x = Int(shoulderX.rounded())
        while x <= Int(tipX.rounded()) {
            var yEdge = bladeBottom
            for i in 0..<system.pinCount where code.indices.contains(i) {
                guard let depthIn = system.depth(digit: code[i]) else { continue }
                let xc = shoulderX + (system.firstCutIn + Double(i) * system.spacingIn) * ppmIn
                let halfWidth = (system.cutWidthIn ?? 0.080) * ppmIn / 2
                let rootY = spineY + depthIn * ppmIn
                let halfFlat = 0.010 * ppmIn
                let dx = abs(Double(x) - xc)
                guard dx <= halfWidth, rootY < bladeBottom else { continue }
                let ramp = dx <= halfFlat ? 0.0 : (dx - halfFlat) / max(halfWidth - halfFlat, 1)
                let yv = rootY + (bladeBottom - rootY) * min(1, ramp)
                yEdge = min(yEdge, yv)
            }
            var y = Int(spineY.rounded())
            while y <= Int(yEdge.rounded()) {
                put(x, y, keyLevel)
                y += 1
            }
            x += 1
        }

        // Bow: rounded-rect-ish head with a SHARP shoulder edge at the blade start
        // (real blanks have a flat shoulder face — see ALGORITHM.md head model).
        if style.headVisible {
            let headLeft = shoulderX - 1.05 * ppmIn
            let headTop = spineY - 0.21 * ppmIn
            let headBottom = spineY + (bladeWidth + 0.21) * ppmIn
            var hx = Int(headLeft.rounded())
            while hx <= Int(shoulderX.rounded()) {
                // Taper the far end slightly (rounded bow corner).
                let taperStart = headLeft + 0.18 * ppmIn
                let inset: Double = hx < Int(taperStart) ? 0.10 * ppmIn : 0
                var hy = Int((headTop + inset).rounded())
                while hy <= Int((headBottom - inset).rounded()) {
                    put(hx, hy, keyLevel)
                    hy += 1
                }
                hx += 1
            }
        }

        if style.noise > 0 {
            for i in 0..<(w * h) {
                let n = Double.random(in: -style.noise...style.noise, using: &rng)
                pixels[i] = UInt8(max(0, min(255, Double(pixels[i]) + n)))
            }
        }
        return GrayImage(width: w, height: h, pixels: pixels)!
    }

    /// Inverse-map the flat card onto a perspective quad inside a photo canvas.
    private func warpToPhoto(
        _ card: GrayImage, quad: [CGPoint], canvas: CGSize,
        style: SceneStyle, rng: inout SeededRNG
    ) -> GrayImage {
        let rect: [CGPoint] = [
            .zero,
            CGPoint(x: CGFloat(Self.cardWidthPx), y: 0),
            CGPoint(x: CGFloat(Self.cardWidthPx), y: CGFloat(Self.cardHeightPx)),
            CGPoint(x: 0, y: CGFloat(Self.cardHeightPx)),
        ]
        let forward = Homography3.fromQuad(rect, to: quad)!   // card → photo
        let inv = forward.inverted()!
        let cw = Int(canvas.width), ch = Int(canvas.height)
        var pixels = [UInt8](repeating: 40, count: cw * ch)
        for py in 0..<ch {
            for px in 0..<cw {
                let c = inv.apply(CGPoint(x: px, y: py))
                if c.x >= 0, c.x < CGFloat(card.width), c.y >= 0, c.y < CGFloat(card.height) {
                    pixels[py * cw + px] = UInt8(max(0, min(255, bilinear(card, c.x, c.y))))
                } else {
                    var v = 40.0
                    if style.shadowBand, px > cw / 4, px < cw / 3 { v -= 20 }
                    pixels[py * cw + px] = UInt8(max(0, min(255, v)))
                }
            }
        }
        if style.noise > 0 {
            for i in 0..<(cw * ch) {
                let n = Double.random(in: -style.noise...style.noise, using: &rng)
                pixels[i] = UInt8(max(0, min(255, Double(pixels[i]) + n)))
            }
        }
        return GrayImage(width: cw, height: ch, pixels: pixels)!
    }

    private func bilinear(_ img: GrayImage, _ x: CGFloat, _ y: CGFloat) -> Double {
        let fx = min(max(0, Double(x)), Double(img.width - 1))
        let fy = min(max(0, Double(y)), Double(img.height - 1))
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let x1 = min(x0 + 1, img.width - 1), y1 = min(y0 + 1, img.height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let p00 = Double(img.pixel(x0, y0)), p10 = Double(img.pixel(x1, y0))
        let p01 = Double(img.pixel(x0, y1)), p11 = Double(img.pixel(x1, y1))
        return (p00 * (1 - tx) + p10 * tx) * (1 - ty) + (p01 * (1 - tx) + p11 * tx) * ty
    }

    /// Perspective quad (TL,TR,BR,BL) in a photo canvas, card ~70% of the frame.
    private func photoQuad(canvas: CGSize, rng: inout SeededRNG) -> [CGPoint] {
        let w = Double(canvas.width), h = Double(canvas.height)
        func jitter() -> Double { Double.random(in: -0.02...0.02, using: &rng) * w }
        return [
            CGPoint(x: w * 0.12 + jitter(), y: h * 0.12 + jitter()),
            CGPoint(x: w * 0.92 + jitter(), y: h * 0.07 + jitter()),
            CGPoint(x: w * 0.96 + jitter(), y: h * 0.88 + jitter()),
            CGPoint(x: w * 0.08 + jitter(), y: h * 0.93 + jitter()),
        ]
    }

    // MARK: - End-to-end decode

    private func decode(
        system: KeySystemDefinition, code: [Int], style: SceneStyle, seed: UInt64,
        file: StaticString = #filePath, line: UInt = #line
    ) -> MeasurementPipeline.Output? {
        var rng = SeededRNG(seed: seed)
        let card = renderCard(system: system, code: code, style: style, rng: &rng)
        let scale = CGFloat(style.photoDownscale)
        let canvas = CGSize(
            width: (3400 * scale).rounded(), height: (2400 * scale).rounded()
        )
        let quad = photoQuad(canvas: canvas, rng: &rng)
        let photo = warpToPhoto(card, quad: quad, canvas: canvas, style: style, rng: &rng)
        guard let warped = Perspective.warpGray(photo, quad: quad),
              let scene = MeasurementPipeline.analyzeScene(
                  corrected: warped.image, pixelsPerMm: warped.image.pixelsPerMmForTest
              )
        else {
            XCTFail("pipeline could not segment the synthetic key", file: file, line: line)
            return nil
        }
        return MeasurementPipeline.measure(scene: scene, system: system)
    }

    // MARK: - Tests

    private func system(_ id: String) throws -> KeySystemDefinition {
        try XCTUnwrap(KeySystemLibrary.system(id: id, in: KeySystemLibrary.bundled))
    }

    func testKW1CleanDecodesExactly() throws {
        let kw1 = try system("kw1")
        for (index, code) in [[1, 5, 3, 2, 4], [6, 2, 4, 1, 5], [1, 1, 1, 1, 1]].enumerated() {
            let out = try XCTUnwrap(decode(system: kw1, code: code, style: SceneStyle(), seed: 1000 + UInt64(index)))
            XCTAssertEqual(out.result.cuts.map(\.digit), code, "code \(code) → \(out.result.codeString)")
            XCTAssertFalse(out.result.gridBeyondBlade)
            for cut in out.result.cuts {
                XCTAssertEqual(cut.depthIn, kw1.depth(digit: code[cut.index])!, accuracy: 0.004,
                               "cut \(cut.index) depth \(cut.depthIn)")
            }
        }
    }

    func testSC1CleanDecodesExactly() throws {
        let sc1 = try system("sc1")
        for (index, code) in [[3, 0, 6, 1, 8], [9, 2, 5, 5, 0]].enumerated() {
            let out = try XCTUnwrap(decode(system: sc1, code: code, style: SceneStyle(), seed: 2000 + UInt64(index)))
            XCTAssertEqual(out.result.cuts.map(\.digit), code, "code \(code) → \(out.result.codeString)")
        }
    }

    func testSC1SixPinCleanDecodes() throws {
        let sc1 = try system("sc1-6p")
        let code = [4, 7, 1, 9, 3, 6]
        let out = try XCTUnwrap(decode(system: sc1, code: code, style: SceneStyle(), seed: 3000))
        XCTAssertEqual(out.result.cuts.map(\.digit), code)
    }

    func testNoiseKeepsPerCutAccuracy() throws {
        let style = SceneStyle(noise: 8, photoDownscale: 1.0)
        var total = 0, correct = 0
        var rngSeed: UInt64 = 5000
        for sysID in ["kw1", "sc1"] {
            let sys = try system(sysID)
            for _ in 0..<4 {
                rngSeed += 37
                var rng = SeededRNG(seed: rngSeed)
                let code = (0..<sys.pinCount).map { _ in Int.random(in: sys.digitRange, using: &rng) }
                if let out = decode(system: sys, code: code, style: style, seed: rngSeed) {
                    for cut in out.result.cuts {
                        total += 1
                        if cut.digit == code[cut.index] { correct += 1 }
                    }
                } else {
                    total += sys.pinCount
                }
            }
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThanOrEqual(Double(correct) / Double(total), 0.9,
                                    "noisy per-cut accuracy \(correct)/\(total)")
    }

    func testGradientAndShadowDecodeClean() throws {
        let kw1 = try system("kw1")
        let code = [4, 1, 6, 3, 2]
        let gradient = SceneStyle(gradient: 35)
        let shadow = SceneStyle(shadowBand: true)
        if let out = decode(system: kw1, code: code, style: gradient, seed: 7000) {
            XCTAssertEqual(out.result.cuts.map(\.digit), code, "gradient case")
        } else {
            XCTFail("gradient case failed to segment")
        }
        if let out = decode(system: kw1, code: code, style: shadow, seed: 7001) {
            XCTAssertEqual(out.result.cuts.map(\.digit), code, "shadow case")
        } else {
            XCTFail("shadow case failed to segment")
        }
    }

    func testHeadlessBlobResolvesDirection() throws {
        let kw1 = try system("kw1")
        let code = [2, 6, 1, 4, 3]
        let style = SceneStyle(headVisible: false)
        let out = try XCTUnwrap(decode(system: kw1, code: code, style: style, seed: 8000))
        XCTAssertEqual(out.result.cuts.map(\.digit), code,
                       "headless direction failed: \(out.result.codeString)")
    }

    func testLowResStillMostlyCorrect() throws {
        let kw1 = try system("kw1")
        let code = [5, 2, 6, 1, 4]
        let style = SceneStyle(photoDownscale: 0.4)
        let out = try XCTUnwrap(decode(system: kw1, code: code, style: style, seed: 9000))
        let correct = zip(out.result.cuts, code).filter { $0.0.digit == $0.1 }.count
        XCTAssertGreaterThanOrEqual(correct, 4, "low-res recovered \(out.result.codeString)")
    }

    func testManualOverrideAndMarkerShift() throws {
        let kw1 = try system("kw1")
        let code = [1, 5, 3, 2, 4]
        var rng = SeededRNG(seed: 4200)
        let card = renderCard(system: kw1, code: code, style: SceneStyle(), rng: &rng)
        let canvas = CGSize(width: 3400, height: 2400)
        let quad = photoQuad(canvas: canvas, rng: &rng)
        let photo = warpToPhoto(card, quad: quad, canvas: canvas, style: SceneStyle(), rng: &rng)
        let warped = try XCTUnwrap(Perspective.warpGray(photo, quad: quad))
        let scene = try XCTUnwrap(
            MeasurementPipeline.analyzeScene(corrected: warped.image, pixelsPerMm: warped.image.pixelsPerMmForTest)
        )

        // Digit override wins and is reported as manual.
        let auto = MeasurementPipeline.measure(scene: scene, system: kw1)
        var params = auto.result.params
        params.digitOverrides[0] = 6
        let manual = MeasurementPipeline.remeasure(scene: scene, system: kw1, params: params)
        XCTAssertEqual(manual.cuts[0].digit, 6)
        XCTAssertTrue(manual.cuts[0].isManualOverride)

        // Marker nudge shifts the measured center by the requested delta.
        var nudgeParams = auto.result.params
        nudgeParams.cutDeltaPx = [40] + Array(repeating: 0.0, count: kw1.pinCount - 1)
        let nudged = MeasurementPipeline.remeasure(scene: scene, system: kw1, params: nudgeParams)
        XCTAssertEqual(nudged.cuts[0].centerU - auto.result.cuts[0].centerU, 40, accuracy: 1e-6)
    }

    func testAutoSuggestPrefersCorrectSystem() throws {
        let kw1 = try system("kw1")
        var rng = SeededRNG(seed: 4400)
        let card = renderCard(system: kw1, code: [2, 5, 3, 6, 1], style: SceneStyle(), rng: &rng)
        let canvas = CGSize(width: 3400, height: 2400)
        let quad = photoQuad(canvas: canvas, rng: &rng)
        let photo = warpToPhoto(card, quad: quad, canvas: canvas, style: SceneStyle(), rng: &rng)
        let warped = try XCTUnwrap(Perspective.warpGray(photo, quad: quad))
        let scene = try XCTUnwrap(
            MeasurementPipeline.analyzeScene(corrected: warped.image, pixelsPerMm: warped.image.pixelsPerMmForTest)
        )
        let suggestions = SystemSuggester.suggest(
            scene: scene, candidates: KeySystemLibrary.defaultCandidates()
        )
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertEqual(suggestions.first?.system.id, "kw1",
                       "suggestions: \(suggestions.map { "\($0.system.id):\($0.score)" })")
    }

    func testConfidenceFlagsOnSyntheticNoise() throws {
        // On clean synthetics nothing should be flagged; that is the "never lie"
        // half of the contract — flags must be silent when the fit is solid.
        let kw1 = try system("kw1")
        let out = try XCTUnwrap(decode(system: kw1, code: [4, 2, 5, 1, 6], style: SceneStyle(), seed: 11000))
        XCTAssertTrue(
            out.result.cuts.allSatisfy { !$0.lowConfidence && !$0.outOfTable },
            "clean synthetic cuts flagged: \(out.result.cuts.map { ($0.index, $0.marginSteps) })"
        )
    }
}

/// The corrected test images are produced by Perspective.warpGray, so the mm
/// scale is the pipeline constant — surfaced here to keep the tests explicit.
private extension GrayImage {
    var pixelsPerMmForTest: Double { Perspective.pixelsPerMm() }
}
