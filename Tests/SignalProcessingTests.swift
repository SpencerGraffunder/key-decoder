import XCTest
@testable import KeyCore

final class SignalProcessingTests: XCTestCase {
    func testOtsuSeparatesBimodal() {
        var pixels = [UInt8](repeating: 40, count: 500)
        pixels += [UInt8](repeating: 200, count: 500)
        let t = otsuThreshold(pixels)
        XCTAssertGreaterThan(Int(t), 40)
        XCTAssertLessThan(Int(t), 200)
    }

    func testMorphologyClosesSinglePixelGap() {
        let w = 9, h = 5
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            mask[y * w + 2] = true   // bar at x=2
            mask[y * w + 4] = true   // bar at x=4, 1-px gap at x=3
        }
        let closed = Morphology.close(mask, w, h, iterations: 1)
        XCTAssertTrue(closed[2 * w + 3], "closing must bridge the 1-px gap")
        XCTAssertFalse(closed[2 * w + 6], "closing must not invent area far away")
    }

    func testFillHolesFillsInteriorOnly() {
        let w = 9, h = 9
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<w { mask[i] = true; mask[(h - 1) * w + i] = true }
        for y in 0..<h { mask[y * w] = true; mask[y * w + w - 1] = true }
        let filled = ConnectedComponents.fillHoles(mask, w, h)
        XCTAssertTrue(filled[4 * w + 4], "interior hole must be filled")
        // The frame touches the borders, so there is no exterior background: all filled.
        XCTAssertEqual(filled.filter { $0 }.count, w * h)
    }

    func testLargestComponentKeepsBigBlob() {
        let w = 20, h = 10
        var mask = [Bool](repeating: false, count: w * h)
        for y in 1..<9 {
            for x in 1..<9 { mask[y * w + x] = true }        // 8x8 blob
        }
        mask[5 * w + 15] = true                              // 1-px speck
        let (kept, area) = ConnectedComponents.largestComponent(mask, w, h)
        XCTAssertEqual(area, 64)
        XCTAssertTrue(kept[4 * w + 4])
        XCTAssertFalse(kept[5 * w + 15])
    }

    func testRobustLineFitIgnoresOutliers() {
        var xs = [Double](), ys = [Double]()
        for x in stride(from: 0.0, through: 99.0, by: 1.0) {
            xs.append(x); ys.append(2 * x + 5)
        }
        // Outliers on a few columns (a scalloped edge on the wrong side).
        for x in [10.0, 40.0, 70.0] {
            xs.append(x); ys.append(2 * x + 40)
        }
        let fit = try? XCTUnwrap(LineFitting.robustFit(xs: xs, ys: ys))
        XCTAssertNotNil(fit)
        if let fit {
            XCTAssertEqual(fit.line.slope, 2.0, accuracy: 0.02)
            XCTAssertEqual(fit.line.intercept, 5.0, accuracy: 1.0)
            XCTAssertLessThan(fit.rms, 0.5)
        }
    }

    func testMedianOddEven() {
        XCTAssertEqual(Statistics.median([3, 1, 2]), 2)
        XCTAssertEqual(Statistics.median([4, 1, 2, 3]), 2.5)
        XCTAssertNil(Statistics.median([]))
    }

    func testPeakCountDetectsScallops() {
        let values: [Double?] = [0, 0, 6, 0, 0, 0, 6, 0, 0, 0, 6, 0, 0]
        let count = Signal1D.prominentPeakCount(values, minDistance: 3, prominence: 3)
        XCTAssertEqual(count, 3)
    }

    func testAutocorrelationFindsSpacing() {
        let period = 12
        var values = [Double]()
        for i in 0..<200 {
            let phase = i % period
            values.append(phase < 4 ? 1 : 0)
        }
        let centered = values.map { $0 - 0.33 }
        let lag = Signal1D.autocorrelationPeak(centered, lagMin: 6, lagMax: 18)
        XCTAssertEqual(lag, period)
    }
}
