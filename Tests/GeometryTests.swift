import CoreGraphics
import XCTest
@testable import KeyCore

final class GeometryTests: XCTestCase {
    func testHomographyMapsQuadToRect() throws {
        let quad: [CGPoint] = [
            CGPoint(x: 100, y: 120), CGPoint(x: 900, y: 80),
            CGPoint(x: 950, y: 620), CGPoint(x: 60, y: 660),
        ]
        let rect: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 2600, y: 0),
            CGPoint(x: 2600, y: 1640), CGPoint(x: 0, y: 1640),
        ]
        let h = try XCTUnwrap(Homography3.fromQuad(quad, to: rect))
        for i in 0..<4 {
            let p = h.apply(quad[i])
            XCTAssertEqual(p.x, rect[i].x, accuracy: 1e-4)
            XCTAssertEqual(p.y, rect[i].y, accuracy: 1e-4)
        }
    }

    func testHomographyRoundTripInsideQuad() throws {
        let quad: [CGPoint] = [
            CGPoint(x: 300, y: 200), CGPoint(x: 2200, y: 150),
            CGPoint(x: 2300, y: 1500), CGPoint(x: 250, y: 1600),
        ]
        let rect: [CGPoint] = [
            .zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 60), CGPoint(x: 0, y: 60),
        ]
        let h = try XCTUnwrap(Homography3.fromQuad(quad, to: rect))
        let inv = try XCTUnwrap(h.inverted())
        for u in stride(from: 0.2, through: 0.8, by: 0.2) {
            for v in stride(from: 0.2, through: 0.8, by: 0.2) {
                let q = CGPoint(x: u * 100, y: v * 60)
                let back = inv.apply(q)
                let forth = h.apply(back)
                XCTAssertEqual(forth.x, q.x, accuracy: 1e-3)
                XCTAssertEqual(forth.y, q.y, accuracy: 1e-3)
            }
        }
    }

    func testQuadOrderingHandlesShuffledInput() throws {
        let rect: [CGPoint] = [
            CGPoint(x: 40, y: 20), CGPoint(x: 340, y: 20),
            CGPoint(x: 340, y: 220), CGPoint(x: 40, y: 220),
        ]
        let shuffled = [rect[2], rect[0], rect[3], rect[1]]
        let ordered = try XCTUnwrap(QuadOrdering.order(shuffled))
        XCTAssertEqual(ordered[0].x, 40, accuracy: 1)
        XCTAssertEqual(ordered[0].y, 20, accuracy: 1)
        XCTAssertEqual(ordered[1].x, 340, accuracy: 1)
        XCTAssertEqual(ordered[2].y, 220, accuracy: 1)
        XCTAssertEqual(ordered[3].x, 40, accuracy: 1)
        XCTAssertEqual(QuadOrdering.aspect(ordered), 300.0 / 200.0, accuracy: 1e-6)
    }

    func testQuadOrderingPicksLongEdgeFirst() throws {
        // A rotated card: corners listed from a visually portrait start.
        let quad: [CGPoint] = [
            CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 400),
            CGPoint(x: 500, y: 360), CGPoint(x: 420, y: 20),
        ]
        let ordered = try XCTUnwrap(QuadOrdering.order(quad))
        let firstEdge = QuadOrdering.edgeLen(ordered[0], ordered[1])
        let secondEdge = QuadOrdering.edgeLen(ordered[1], ordered[2])
        XCTAssertGreaterThan(firstEdge, secondEdge)
        XCTAssertGreaterThan(QuadOrdering.aspect(ordered), 1.0)
    }

    func testCardQualityGate() {
        let good: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1586, y: 0),
            CGPoint(x: 1586, y: 1000), CGPoint(x: 0, y: 1000),
        ]
        XCTAssertTrue(CardQuality.isPlausibleCardQuad(good, imageArea: 2000 * 2000))
        let tiny: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0),
            CGPoint(x: 300, y: 190), CGPoint(x: 0, y: 190),
        ]
        XCTAssertFalse(CardQuality.isPlausibleCardQuad(tiny, imageArea: 2000 * 2000))
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0),
            CGPoint(x: 1000, y: 1000), CGPoint(x: 0, y: 1000),
        ]
        XCTAssertFalse(CardQuality.isPlausibleCardQuad(square, imageArea: 1100 * 1100))
    }

    func testCardSuggestGateTiers() {
        // Strong perspective can foreshorten the card below the strict gate's
        // 1.30 aspect floor; it must still be usable as an editor suggestion.
        let foreshortened: [CGPoint] = [
            CGPoint(x: 200, y: 100), CGPoint(x: 1400, y: 60),
            CGPoint(x: 1420, y: 1060), CGPoint(x: 180, y: 1100),
        ]
        XCTAssertFalse(CardQuality.isPlausibleCardQuad(foreshortened, imageArea: 2000 * 2000))
        XCTAssertTrue(CardQuality.isSuggestableCardQuad(foreshortened, imageArea: 2000 * 2000))
        // Squares and specks fail even the relaxed gate.
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0),
            CGPoint(x: 1000, y: 1000), CGPoint(x: 0, y: 1000),
        ]
        XCTAssertFalse(CardQuality.isSuggestableCardQuad(square, imageArea: 1100 * 1100))
        let tiny: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0),
            CGPoint(x: 300, y: 190), CGPoint(x: 0, y: 190),
        ]
        XCTAssertFalse(CardQuality.isSuggestableCardQuad(tiny, imageArea: 2000 * 2000))
    }

    func testIdentityWarpPreservesImage() throws {
        let w = 32, h = 24
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { pixels[y * w + x] = UInt8((x * 8 + y * 3) % 256) }
        }
        let img = try XCTUnwrap(GrayImage(width: w, height: h, pixels: pixels))
        let quad: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: CGFloat(w), y: 0),
            CGPoint(x: CGFloat(w), y: CGFloat(h)), CGPoint(x: 0, y: CGFloat(h)),
        ]
        let warped = try XCTUnwrap(
            Perspective.warpGray(img, quad: quad, outputWidth: w, outputHeight: h)
        )
        // Identity mapping: interior samples must be exact.
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                XCTAssertEqual(warped.image.pixel(x, y), img.pixel(x, y))
            }
        }
    }

    func testCalibrationPixelsPerMmMatchesWidth() {
        let ppm = Perspective.pixelsPerMm()
        XCTAssertEqual(ppm, 2600.0 / 85.60, accuracy: 1e-9)
        // A card-edge distance measured in the corrected image converts back to mm.
        let edgePx = 40.0
        XCTAssertEqual(edgePx / ppm, 40.0 / (2600.0 / 85.60), accuracy: 1e-12)
    }
}
