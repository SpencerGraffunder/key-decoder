#if canImport(Vision)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Vision

/// Auto-detection of the ISO ID-1 reference card via Vision.
/// Failure always returns nil — the UI must then offer the manual four-handle path.
public enum CardDetector {
    public struct CardDetection: Equatable {
        /// Quad ordered TL,TR,BR,BL in y-down pixel coordinates of the image.
        public let quad: [CGPoint]
        /// true → passed the strict auto-apply gate; false → best available
        /// suggestion, must be confirmed (seed the manual editor with it).
        public let confident: Bool
    }

    /// Blocking call — run on a background queue. Confident quad or nil.
    public static func detectCardQuad(in image: CGImage) -> [CGPoint]? {
        guard let d = detect(in: image), d.confident else { return nil }
        return d.quad
    }

    /// Two Vision detectors, two confidence tiers: rectangle corners and
    /// contour bounding quads are pooled as normalized quads, the strict gate
    /// tries first, then the relaxed suggestion gate. A suggestion is never
    /// auto-applied.
    public static func detect(in image: CGImage, prior: CGRect? = nil) -> CardDetection? {
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 16
        rectangles.minimumSize = 0.12
        rectangles.minimumAspectRatio = 0.4
        rectangles.quadratureTolerance = 25
        rectangles.minimumConfidence = 0.35

        // Contour detector: rescues low-contrast upright cards the rectangle
        // detector misses. Its request exposes no count/size/confidence knobs —
        // filtering happens on the extracted bounding quads instead, and
        // CardQuality gates are the real arbiter.
        let contours = VNDetectContoursRequest()
        contours.contrastAdjustment = 1.7

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([rectangles, contours]) } catch { return nil }

        // Normalized Vision corner quads (y-up, TL TR BR BL as reported).
        var quads: [[CGPoint]] = []
        for obs in rectangles.results ?? [] where obs.confidence >= 0.30 {
            quads.append([obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft])
        }
        quads.append(contentsOf: contourQuads(from: contours.results ?? []))
        guard !quads.isEmpty else { return nil }

        // Boundary-strength-scored pick: a quad only wins if the gradient
        // actually runs along all four of its sides. Placemats, tablets and
        // glare patches that Vision confidently boxes lose the sides with no
        // edge under them; real cards keep all four even under partial glare
        // (we take the middle two of the four per-side minima).
        let grayFull = GrayImage(cgImage: image)
        // Boundary gates scale with resolution: a 640 px live frame has
        // proportionally softer edges than a 12 MP still, and the still-tuned
        // threshold would silence the finder overlay entirely.
        let edgeScale = min(1.0, max(0.45, Double(min(image.width, image.height)) / 620.0))
        let strictMin = 25.0 * edgeScale
        let suggestMin = 10.0 * edgeScale
        func scoredPick(strict: Bool) -> [CGPoint]? {
            let imageArea = Double(image.width * image.height)
            var bestQuad: [CGPoint]?
            var bestScore = -Double.infinity
            for corners in quads {
                guard corners.count == 4,
                      let quad = orderedQuad(corners: corners, pixelWidth: image.width, pixelHeight: image.height)
                else { continue }
                let gate: ([CGPoint], Double) -> Bool =
                    strict ? CardQuality.isPlausibleCardQuad : CardQuality.isSuggestableCardQuad
                guard gate(quad, imageArea) else { continue }
                var score = CardQuality.score(quad, imageArea: imageArea)
                if let g = grayFull {
                    let b = boundaryStrength(g, quad: quad)
                    if strict, b < strictMin { continue }
                    if !strict, b < suggestMin { continue }
                    score *= 1.0 + b / 100.0
                }
                score *= priorBoost(quad: quad, prior: prior, imageSize: CGSize(width: image.width, height: image.height))
                if score > bestScore { bestScore = score; bestQuad = quad }
            }
            return bestQuad
        }
        if let quad = scoredPick(strict: true) {
            return CardDetection(quad: quad, confident: true)
        }
        if let quad = scoredPick(strict: false) {
            return CardDetection(quad: quad, confident: false)
        }
        return nil
    }

    /// Gradient-along-quad-sides score (see scoredPick). Samples every side,
    /// takes the strongest gradient within +/- `band` px along the side
    /// normal, keeps the per-side MINIMA, then averages the middle two so one
    /// glare-washed side can't veto an otherwise solid card.
    public static func boundaryStrength(_ image: GrayImage, quad: [CGPoint],
                                        band: Int = 4, samplesPerSide: Int = 20) -> Double {
        guard quad.count == 4, image.width > 8, image.height > 8, samplesPerSide > 1 else { return 0 }
        let w = image.width, h = image.height
        func grad(_ x: Int, _ y: Int) -> Double {
            guard x > 0, y > 0, x < w - 1, y < h - 1 else { return 0 }
            let gx = Double(Int(image.pixel(x + 1, y)) - Int(image.pixel(x - 1, y)))
            let gy = Double(Int(image.pixel(x, y + 1)) - Int(image.pixel(x, y - 1)))
            return (gx * gx + gy * gy).squareRoot() / 2
        }
        var sideMin = [Double]()
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            let ex = Double(b.x - a.x), ey = Double(b.y - a.y)
            let len = max(1e-6, (ex * ex + ey * ey).squareRoot())
            let nx = -ey / len, ny = ex / len
            var worst = Double.greatestFiniteMagnitude
            for k in 0..<samplesPerSide {
                let t = (Double(k) + 0.5) / Double(samplesPerSide)
                let px = Double(a.x) + ex * t, py = Double(a.y) + ey * t
                var best = 0.0
                var s = -Double(band)
                while s <= Double(band) {
                    best = max(best, grad(Int((px + nx * s).rounded()), Int((py + ny * s).rounded())))
                    s += 1
                }
                worst = min(worst, best)
            }
            sideMin.append(worst)
        }
        sideMin.sort()
        return (sideMin[1] + sideMin[2]) / 2
    }

    /// The capture UI guides the card to a fixed spot; when the caller passes
    /// that guide rect (normalized, y-down), candidates near it win and ones
    /// far away (clutter with strong edges — bins, tablets, shadows) lose.
    /// 1.0 at the guide center, floored at 0.15 so detection far off the
    /// guide (photos from the library!) is not impossible.
    public static func priorBoost(quad: [CGPoint], prior: CGRect?, imageSize: CGSize) -> Double {
        guard let prior, prior.width > 0, prior.height > 0 else { return 1.0 }
        let cx = quad.reduce(0) { $0 + $1.x } / 4 / imageSize.width
        let cy = quad.reduce(0) { $0 + $1.y } / 4 / imageSize.height
        let px = (prior.minX + prior.maxX) / 2, py = (prior.minY + prior.maxY) / 2
        let dx = cx - px, dy = cy - py
        let sigma = max(0.18, hypot(prior.width, prior.height) * 0.9)
        let d2 = (dx * dx + dy * dy) / (sigma * sigma)
        return max(0.15, exp(-d2 * 1.2))
    }

    /// Axis-aligned bounding quad per contour subpath of the observation's
    /// normalized path (CGPath API — stable since iOS 11, unlike the
    /// per-contour-index accessors). A contour's bbox is only a faithful card
    /// quad for near-upright captures; rotated cards keep coming from the
    /// rectangle detector, and the gates below reject skewed/sized-off quads.
    static func contourQuads(from observations: [VNContoursObservation]) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        for observation in observations {
            let path = observation.normalizedPath
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            var pointCount = 0
            func reset() {
                minX = .greatestFiniteMagnitude; minY = .greatestFiniteMagnitude
                maxX = -.greatestFiniteMagnitude; maxY = -.greatestFiniteMagnitude
                pointCount = 0
            }
            func finishSubpath() {
                defer { reset() }
                guard pointCount >= 4 else { return }
                let w = maxX - minX, h = maxY - minY
                let area = w * h
                // Area window mirrors the rectangle request's minimumSize (0.12
                // of the image => ~0.015 normalized area); the aspect window
                // brackets the ID-1 ratio (0.63 portrait / 1.585 landscape)
                // generously — CardQuality gates do the strict check.
                guard area >= 0.015, area <= 1.0 else { return }
                guard h > 0, w / h >= 0.45, w / h <= 2.25 else { return }
                // y-up normalized space => "top" is maxY.
                out.append([
                    CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY),
                    CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: minY),
                ])
            }
            func acc(_ p: CGPoint) {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
                pointCount += 1
            }
            // Dispatch on the raw C values, not the imported Swift cases:
            // CGPathElementType's Swift spelling has churned between SDKs
            // (.lineToPoint vs .AddLineToPoint vs .addLineToPoint), but the
            // underlying CGGeometry.h enum order has been ABI-stable since
            // the 90s (1=move, 2=line, 3=quad, 4=cubic, 5=close).
            path.applyWithBlock { elementPtr in
                let element = elementPtr.pointee
                switch element.type.rawValue {
                case 1: // kCGPathElementMoveToPoint — starts a new subpath
                    finishSubpath()
                    acc(element.points[0])
                case 2: // kCGPathElementAddLineToPoint
                    acc(element.points[0])
                case 3: // kCGPathElementAddQuadCurveToPoint — ctrl + endpoint
                    acc(element.points[0])
                    acc(element.points[1])
                case 4: // kCGPathElementAddCurveToPoint — two ctrls + endpoint
                    acc(element.points[0])
                    acc(element.points[1])
                    acc(element.points[2])
                case 5: // kCGPathElementCloseSubpath
                    finishSubpath()
                default: // kCGPathElementEmpty
                    break
                }
            }
            // Unterminated trailing subpath (path built without explicit close).
            finishSubpath()
        }
        return out
    }

    /// Pure selection logic (testable without Vision): score candidate quads as cards.
    public static func pickCard(
        from quads: [[CGPoint]], pixelWidth: Int, pixelHeight: Int
    ) -> [CGPoint]? {
        pick(from: quads, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
             gate: CardQuality.isPlausibleCardQuad)
    }

    static func pickSuggestable(
        from quads: [[CGPoint]], pixelWidth: Int, pixelHeight: Int
    ) -> [CGPoint]? {
        pick(from: quads, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
             gate: CardQuality.isSuggestableCardQuad)
    }

    private static func pick(
        from quads: [[CGPoint]], pixelWidth: Int, pixelHeight: Int,
        gate: ([CGPoint], Double) -> Bool
    ) -> [CGPoint]? {
        let imageArea = Double(pixelWidth * pixelHeight)
        var bestQuad: [CGPoint]?
        var bestScore = 0.0
        for corners in quads {
            guard corners.count == 4,
                  let quad = orderedQuad(
                    corners: corners, pixelWidth: pixelWidth, pixelHeight: pixelHeight
                  ) else { continue }
            guard gate(quad, imageArea) else { continue }
            let score = CardQuality.score(quad, imageArea: imageArea)
            if score > bestScore { bestScore = score; bestQuad = quad }
        }
        return bestQuad
    }

    /// Vision observations use normalized coordinates with a bottom-left origin;
    /// convert to y-down pixels and pipeline corner ordering.
    public static func orderedQuad(
        corners: [CGPoint], pixelWidth: Int, pixelHeight: Int
    ) -> [CGPoint]? {
        let pts = corners.map {
            CGPoint(x: $0.x * CGFloat(pixelWidth), y: (1 - $0.y) * CGFloat(pixelHeight))
        }
        return QuadOrdering.order(pts)
    }
}
#endif

#if canImport(Vision)
import Vision

/// The capture UI's dashed card guide, normalized (y-down). Detection and
/// the live finder treat it as a strong prior — the user is told to line the
/// card up with it, so the card IS there until proven otherwise.
public enum CaptureGuide {
    public static let rect = CGRect(x: 0.09, y: 0.30, width: 0.82, height: 0.28)

    /// Guide corners as a TL,TR,BR,BL pixel quad in an image of `size`.
    public static func quad(in size: CGSize) -> [CGPoint] {
        let pts = [
            CGPoint(x: rect.minX * size.width, y: rect.minY * size.height),
            CGPoint(x: rect.maxX * size.width, y: rect.minY * size.height),
            CGPoint(x: rect.maxX * size.width, y: rect.maxY * size.height),
            CGPoint(x: rect.minX * size.width, y: rect.maxY * size.height),
        ]
        return QuadOrdering.order(pts) ?? pts
    }
}

/// Reads engraved/stamped bow text (brand + code) from the corrected card
/// view. Advisory only — feeds SystemSuggester.applyStamp, never final.
public enum BowStampReader {
    /// Blocking call — run on a background queue. Returns raw OCR strings.
    public static func readText(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
#endif
