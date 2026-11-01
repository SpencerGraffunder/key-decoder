#if canImport(Vision)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Vision

/// Auto-detection of the ISO ID-1 reference card via Vision rectangle detection.
/// Failure always returns nil — the UI must then offer the manual four-handle path.
public enum CardDetector {
    /// Blocking call — run on a background queue. Returns the quad ordered
    /// TL,TR,BR,BL in y-down pixel coordinates of `image`, or nil.
    public static func detectCardQuad(in image: CGImage) -> [CGPoint]? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 16
        request.minimumSize = 0.12
        request.minimumAspectRatio = 0.4
        request.quadratureTolerance = 25
        request.minimumConfidence = 0.35

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var candidates = [VNRectangleObservation]()
        do {
            try handler.perform([request])
            candidates = (request.results ?? []).filter { $0.confidence >= 0.35 }
        } catch {
            return nil
        }
        return pickCard(from: candidates, pixelWidth: image.width, pixelHeight: image.height)
    }

    /// Pure selection logic (testable without Vision): score rectangle observations as cards.
    public static func pickCard(
        from observations: [VNRectangleObservation], pixelWidth: Int, pixelHeight: Int
    ) -> [CGPoint]? {
        let imageArea = Double(pixelWidth * pixelHeight)
        var bestQuad: [CGPoint]?
        var bestScore = 0.0
        for obs in observations {
            guard let quad = orderedQuad(
                observation: obs, pixelWidth: pixelWidth, pixelHeight: pixelHeight
            ) else { continue }
            guard CardQuality.isPlausibleCardQuad(quad, imageArea: imageArea) else { continue }
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
