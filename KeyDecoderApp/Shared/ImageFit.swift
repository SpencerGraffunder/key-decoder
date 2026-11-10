import CoreGraphics
import Foundation
import func Foundation.cos
import func Foundation.sin

/// Maps between image pixel coordinates and an image displayed `.fit`-style,
/// optionally panned/zoomed (a focus point in image space sits at the view
/// center at `baseScale * zoom`) and optionally ROTATED (issue #4: the key
/// review levelizes on the key spine). ALL drawing (Canvas image, mask glow,
/// markers) and ALL drag math go through this one mapping — the image is
/// rendered into a Canvas at computed coordinates (via `viewTransform`)
/// instead of SwiftUI scale/offset/rotation transforms, so gesture locations
/// (which live in the plain ZStack space) stay correct under pan/zoom/rotate.
struct ImageFit {
    let imageSize: CGSize
    let viewSize: CGSize
    var zoom: CGFloat = 1
    /// Image-space point placed at the view center; nil = image center.
    var center: CGPoint? = nil
    /// Radians to rotate the DISPLAYED content about the focus, using the
    /// standard y-down rotation matrix — the same convention as
    /// `KeyLeveling.levelAngle` and the baked saved image. Geometry stays in
    /// unrotated corrected-image coordinates.
    var rotation: CGFloat = 0

    private var cosR: CGFloat { CGFloat(cos(Double(rotation))) }
    private var sinR: CGFloat { CGFloat(sin(Double(rotation))) }

    /// Base scale fits the ROTATED bounding box so rotation never clips.
    var baseScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let w = abs(imageSize.width * cosR) + abs(imageSize.height * sinR)
        let h = abs(imageSize.width * sinR) + abs(imageSize.height * cosR)
        return min(viewSize.width / w, viewSize.height / h)
    }

    var scale: CGFloat { baseScale * zoom }

    var focus: CGPoint {
        center ?? CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
    }

    private var viewCenter: CGPoint {
        CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }

    func toView(_ point: CGPoint) -> CGPoint {
        let dx = point.x - focus.x
        let dy = point.y - focus.y
        return CGPoint(
            x: viewCenter.x + scale * (dx * cosR - dy * sinR),
            y: viewCenter.y + scale * (dx * sinR + dy * cosR)
        )
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        let rx = (point.x - viewCenter.x) / scale
        let ry = (point.y - viewCenter.y) / scale
        return CGPoint(
            x: focus.x + rx * cosR + ry * sinR,
            y: focus.y - rx * sinR + ry * cosR
        )
    }

    func clampedToImage(_ point: CGPoint) -> CGPoint {
        let p = toImage(point)
        return CGPoint(
            x: min(max(0, p.x), imageSize.width),
            y: min(max(0, p.y), imageSize.height)
        )
    }

    /// Where should the focus sit after dragging by `translation` (view points),
    /// starting from `startCenter` (image coords). The translation is mapped
    /// back through the rotation, so panning follows the fingers, not the image
    /// axes. Clamped so the focus stays inside the image.
    func panTarget(from startCenter: CGPoint, translation: CGSize) -> CGPoint {
        guard scale > 0 else { return startCenter }
        let rx = translation.width / scale
        let ry = translation.height / scale
        let c = CGPoint(
            x: startCenter.x - (rx * cosR + ry * sinR),
            y: startCenter.y - (-rx * sinR + ry * cosR)
        )
        return CGPoint(
            x: min(max(0, c.x), imageSize.width),
            y: min(max(0, c.y), imageSize.height)
        )
    }

    /// Zoom that fits `rect` (image coords) filling `fill` of the view, capped.
    /// The rect's ROTATED extent is what must fit.
    func zoomToFit(rect: CGRect, fill: CGFloat, maxZoom: CGFloat) -> CGFloat {
        guard rect.width > 0, rect.height > 0, baseScale > 0 else { return 1 }
        let w = abs(rect.width * cosR) + abs(rect.height * sinR)
        let h = abs(rect.width * sinR) + abs(rect.height * cosR)
        let z = min(
            viewSize.width / (w * baseScale),
            viewSize.height / (h * baseScale)
        ) * fill
        return min(max(1, z), maxZoom)
    }

    /// Image rect as drawn in view space — the axis-aligned bounding box of
    /// the rotated corners. (For DRAWING the image use `viewTransform`; this
    /// box is for hit/clamp math only.)
    var imageRectInView: CGRect {
        var loX = CGFloat.greatestFiniteMagnitude, loY = loX
        var hiX = -CGFloat.greatestFiniteMagnitude, hiY = hiX
        let corners = [
            CGPoint.zero,
            CGPoint(x: imageSize.width, y: 0),
            CGPoint(x: imageSize.width, y: imageSize.height),
            CGPoint(x: 0, y: imageSize.height),
        ]
        for c in corners.map(toView) {
            loX = min(loX, c.x); hiX = max(hiX, c.x)
            loY = min(loY, c.y); hiY = max(hiY, c.y)
        }
        return CGRect(x: loX, y: loY, width: hiX - loX, height: hiY - loY)
    }

    /// The image-pixel -> view-point affine, matching `toView` exactly. Set it
    /// as a Canvas context's `transform` and draw into
    /// `CGRect(origin: .zero, size: imageSize)` to render rotated content.
    var viewTransform: CGAffineTransform {
        CGAffineTransform(translationX: viewCenter.x, y: viewCenter.y)
            .scaledBy(x: scale, y: scale)
            .rotated(by: rotation)
            .translatedBy(x: -focus.x, y: -focus.y)
    }
}
