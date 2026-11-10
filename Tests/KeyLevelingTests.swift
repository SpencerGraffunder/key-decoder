import CoreGraphics
import XCTest
@testable import KeyCore

/// Issue #4: the review/gallery rotation levels the image on the KEY spine.
/// The tests below check the algebra the display mapping and the baked saved
/// image both rely on, using the standard y-down rotation matrix
/// R(a)·(x,y) = (x·cos a − y·sin a, x·sin a + y·cos a).
final class KeyLevelingTests: XCTestCase {
    private func rotate(_ p: CGPoint, by a: Double) -> CGPoint {
        CGPoint(
            x: p.x * CGFloat(cos(a)) - p.y * CGFloat(sin(a)),
            y: p.x * CGFloat(sin(a)) + p.y * CGFloat(cos(a))
        )
    }

    /// spineIsTop: after rotating by the level angle the spine runs along +x
    /// and the blade body (+perp) points DOWN (+y), i.e. spine up, cuts below.
    private func assertLevelTop(spineSlope: Double, theta: Double, file: StaticString = #filePath, line: UInt = #line) {
        let axis = (x: cos(theta), y: sin(theta))
        let perp = (x: -sin(theta), y: cos(theta))
        let a = KeyLeveling.levelAngle(axis: axis, perp: perp, spineSlope: spineSlope, spineIsTop: true)
        // Spine direction in image space: d/du of xy(u, spine.v(u)) = axis + slope·perp.
        let t = rotate(CGPoint(x: axis.x + spineSlope * perp.x, y: axis.y + spineSlope * perp.y), by: a)
        XCTAssertEqual(t.x, abs(t.x), accuracy: 1e-9, "spine must point +x", file: file, line: line)
        XCTAssertEqual(t.y, 0, accuracy: 1e-9, "spine must be horizontal", file: file, line: line)
        // v-increase direction PERPENDICULAR to the spine (axis when the spine
        // carries a deliberate slope): the blade body lies toward +v.
        let n = rotate(CGPoint(x: perp.x - spineSlope * axis.x, y: perp.y - spineSlope * axis.y), by: a)
        XCTAssertEqual(n.x, 0, accuracy: 1e-9, "blade side must be vertical", file: file, line: line)
        XCTAssertEqual(n.y, abs(n.y), accuracy: 1e-9, "blade must hang below the spine", file: file, line: line)
    }

    /// !spineIsTop: the spine is the LOWER edge line; the blade body (−perp)
    /// must still end up below the spine after leveling.
    private func assertLevelBottom(spineSlope: Double, theta: Double, file: StaticString = #filePath, line: UInt = #line) {
        let axis = (x: cos(theta), y: sin(theta))
        let perp = (x: -sin(theta), y: cos(theta))
        let a = KeyLeveling.levelAngle(axis: axis, perp: perp, spineSlope: spineSlope, spineIsTop: false)
        let t = rotate(CGPoint(x: axis.x + spineSlope * perp.x, y: axis.y + spineSlope * perp.y), by: a)
        XCTAssertEqual(t.y, 0, accuracy: 1e-9, "spine must be horizontal", file: file, line: line)
        let n = rotate(CGPoint(x: -(perp.x - spineSlope * axis.x), y: -(perp.y - spineSlope * axis.y)), by: a)
        XCTAssertEqual(n.x, 0, accuracy: 1e-9, "blade side must be vertical", file: file, line: line)
        XCTAssertEqual(n.y, abs(n.y), accuracy: 1e-9, "blade must hang below the spine", file: file, line: line)
    }

    func testLevelTopAcrossTilts() {
        var theta = -3.0
        while theta <= 3.0 {
            assertLevelTop(spineSlope: 0, theta: theta)
            assertLevelBottom(spineSlope: 0, theta: theta)
            theta += 0.25
        }
    }

    func testLevelWithSpineSlope() {
        // A slanted spine fit (slope in blade space) must level too.
        for slope in [-0.08, -0.01, 0.0, 0.01, 0.08] {
            assertLevelTop(spineSlope: slope, theta: 0.5)
            assertLevelTop(spineSlope: slope, theta: -2.4)
            assertLevelBottom(spineSlope: slope, theta: 1.1)
            assertLevelBottom(spineSlope: slope, theta: -2.9)
        }
    }

    func testAlreadyLevelKeyNeedsNoRotation() {
        // Key level and spine-up already (u along +x, blade below): angle 0.
        let a = KeyLeveling.levelAngle(axis: (x: 1, y: 0), perp: (x: 0, y: 1), spineSlope: 0, spineIsTop: true)
        XCTAssertEqual(a, 0, accuracy: 1e-12)
    }

    func testAngleNormalizedIntoRange() {
        var theta = -7.0
        while theta <= 7.0 {
            for top in [true, false] {
                let a = KeyLeveling.levelAngle(axis: (x: cos(theta), y: sin(theta)), perp: (x: -sin(theta), y: cos(theta)), spineSlope: 0.03, spineIsTop: top)
                XCTAssertGreaterThan(a, -.pi - 1e-12)
                XCTAssertLessThanOrEqual(a, .pi + 1e-12)
            }
            theta += 0.2
        }
    }

    func testLevelAngleFromBlade() {
        // Drive the BladeAnalysis convenience with the same numbers as the
        // direct overload (the blade stores axis/perp/spine/spineIsTop as-is).
        let theta = 0.7
        let blade = BladeAnalysis(
            angle: theta, origin: CGPoint(x: 500, y: 500),
            axis: (x: cos(theta), y: sin(theta)), perp: (x: -sin(theta), y: cos(theta)),
            pixelsPerMm: 30,
            uMin: 0, uMax: 400, headPresent: true, shoulderU: 40, tipU: 390,
            spineIsTop: true, spine: SpineLine(slope: 0.02, intercept: 10),
            spineRms: 0.5, cutSideRms: 1.2, bladeWidthPx: 60, headLenPx: 40,
            columns: ColumnProfile(uMin: 0, vTop: [], vBot: [], counts: [])
        )
        let viaBlade = KeyLeveling.levelAngle(blade: blade)
        let direct = KeyLeveling.levelAngle(
            axis: blade.axis, perp: blade.perp,
            spineSlope: blade.spine.slope, spineIsTop: blade.spineIsTop
        )
        XCTAssertEqual(viaBlade, direct, accuracy: 1e-12)
    }
}
