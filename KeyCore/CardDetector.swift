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

    /// Two Vision detectors, two confidence tiers: rectangle + contour
    /// observations are pooled, the strict gate tries first, then the relaxed
    /// suggestion gate. A suggestion is never auto-applied.
    public static func detect(in image: CGImage) -> CardDetection? {
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 16
        rectangles.minimumSize = 0.12
        rectangles.minimumAspectRatio = 0.4
        rectangles.quadratureTolerance = 25
        rectangles.minimumConfidence = 0.35

        let contours = VNDetectContoursRequest()
        contours.contrastAdjustment = 1.7
        // Outermost contours plus one nesting level: captures the card edge
        // and its near-edge inner boundary without drowning in chip/text
        // contours (this request has no maximumObservations/minimumSize).
        contours.maximumRecallLevel = 2

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([rectangles, contours]) } catch { return nil }

        var observations: [VNRectangleObservation] = rectangles.results ?? []
        // VNContourObservation is a VNRectangleObservation subclass whose
        // corners are the contour's approximated bounding rectangle.
        observations.append(contentsOf: (contours.results ?? []).map { $0 as VNRectangleObservation })
        let usable = observations.filter { $0.confidence >= 0.30 }
        guard !usable.isEmpty else { return nil }

        if let quad = pickCard(from: usable, pixelWidth: image.width, pixelHeight: image.height) {
            return CardDetection(quad: quad, confident: true)
        }
        if let quad = pickSuggestable(from: usable, pixelWidth: image.width, pixelHeight: image.height) {
            return CardDetection(quad: quad, confident: false)
        }
        return nil
    }

    /// Pure selection logic (testable without Vision): score rectangle observations as cards.
    public static func pickCard(
        from observations: [VNRectangleObservation], pixelWidth: Int, pixelHeight: Int
    ) -> [CGPoint]? {
        pick(from: observations, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
             gate: CardQuality.isPlausibleCardQuad)
    }

    static func pickSuggestable(
        from observations: [VNRectangleObservation], pixelWidth: Int, pixelHeight: Int
    ) -> [CGPoint]? {
        pick(from: observations, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
             gate: CardQuality.isSuggestableCardQuad)
    }

    private static func pick(
        from observations: [VNRectangleObservation], pixelWidth: Int, pixelHeight: Int,
        gate: ([CGPoint], Double) -> Bool
    ) -> [CGPoint]? {
        let imageArea = Double(pixelWidth * pixelHeight)
        var bestQuad: [CGPoint]?
        var bestScore = 0.0
        for obs in observations {
            guard let quad = orderedQuad(
                observation: obs, pixelWidth: pixelWidth, pixelHeight: pixelHeight
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
        observation: VNRectangleObservation, pixelWidth: Int, pixelHeight: Int
    ) -> [CGPoint]? {
        let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
        let pts = corners.map {
            CGPoint(x: $0.x * CGFloat(pixelWidth), y: (1 - $0.y) * CGFloat(pixelHeight))
        }
        return QuadOrdering.order(pts)
    }
}
#endif

#if canImport(Vision)
import Vision

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
