#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Display rotation that levels the KEY rather than the card (issue #4).
///
/// The corrected view is deskewed by the CARD homography, so a key lying at an
/// angle on the card still looks diagonal in the review and gallery screens.
/// This computes the extra rotation that makes the detected key's SPINE (its
/// top edge) run horizontal, with the blade and cuts hanging BELOW it — the
/// canonical upright key reading. Rotation is applied to the display only
/// (and baked into the saved corrected image); measurement geometry stays in
/// corrected-image space.
public enum KeyLeveling {
    /// Rotation angle in radians for the standard y-down rotation matrix
    /// R(a)·(x,y) = (x·cos a − y·sin a, x·sin a + y·cos a), normalized to
    /// (−π, π]. `axis`/`perp`/`spineSlope` use the BladeAnalysis convention
    /// (u along the blade, v = perp, spine line v = slope·u + intercept).
    ///
    /// Derivation: the spine direction in image space is d/du of
    /// xy(u, spine.v(u)) = axis + slope·perp. With `spineIsTop` the blade body
    /// lies toward +perp, so rotating the spine to +x automatically maps
    /// +perp to +y (down) — spine up, cuts below. Otherwise the blade lies
    /// toward −perp, so the spine must land on −x for −perp to reach +y.
    public static func levelAngle(
        axis: (x: Double, y: Double),
        perp: (x: Double, y: Double),
        spineSlope: Double,
        spineIsTop: Bool
    ) -> Double {
        let tx = axis.x + spineSlope * perp.x
        let ty = axis.y + spineSlope * perp.y
        let phi = atan2(ty, tx)
        var a = spineIsTop ? -phi : .pi - phi
        while a > .pi { a -= 2 * .pi }
        while a <= -.pi { a += 2 * .pi }
        return a
    }

    public static func levelAngle(blade: BladeAnalysis) -> Double {
        levelAngle(
            axis: blade.axis, perp: blade.perp,
            spineSlope: blade.spine.slope, spineIsTop: blade.spineIsTop
        )
    }
}
