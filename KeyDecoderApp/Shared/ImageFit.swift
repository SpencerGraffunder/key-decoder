import CoreGraphics
import Foundation

/// Maps between image pixel coordinates and an image displayed `.fit`-style,
/// optionally panned/zoomed (a focus point in image space sits at the view
/// center at `baseScale * zoom`). ALL drawing (Canvas image, mask glow,
/// markers) and ALL drag math goes through this one mapping — the image is
/// rendered into a Canvas at computed coordinates instead of SwiftUI
/// scale/offset transforms, so gesture locations (which live in the plain
/// ZStack space) stay correct under pan/zoom.
struct ImageFit {
    let imageSize: CGSize
    let viewSize: CGSize
    var zoom: CGFloat = 1
    /// Image-space point placed at the view center; nil = image center.
    var center: CGPoint? = nil

    var baseScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }

    var scale: CGFloat { baseScale * zoom }

    var focus: CGPoint {
        center ?? CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
    }

    var offsetX: CGFloat { viewSize.width / 2 - focus.x * scale }
    var offsetY: CGFloat { viewSize.height / 2 - focus.y * scale }

    func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: offsetX + point.x * scale, y: offsetY + point.y * scale)
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(x: (point.x - offsetX) / scale, y: (point.y - offsetY) / scale)
    }

    func clampedToImage(_ point: CGPoint) -> CGPoint {
        let p = toImage(point)
        return CGPoint(
            x: min(max(0, p.x), imageSize.width),
            y: min(max(0, p.y), imageSize.height)
        )
    }

    /// Where should the focus sit after dragging by `translation` (view points),
    /// starting from `startCenter` (image coords). Clamped so the focus stays
    /// inside the image.
    func panTarget(from startCenter: CGPoint, translation: CGSize) -> CGPoint {
        guard scale > 0 else { return startCenter }
        let c = CGPoint(
            x: startCenter.x - translation.width / scale,
            y: startCenter.y - translation.height / scale
        )
        return CGPoint(
            x: min(max(0, c.x), imageSize.width),
            y: min(max(0, c.y), imageSize.height)
        )
    }

    /// Zoom that fits `rect` (image coords) filling `fill` of the view, capped.
    func zoomToFit(rect: CGRect, fill: CGFloat, maxZoom: CGFloat) -> CGFloat {
        guard rect.width > 0, rect.height > 0, baseScale > 0 else { return 1 }
        let z = min(
            viewSize.width / (rect.width * baseScale),
            viewSize.height / (rect.height * baseScale)
        ) * fill
        return min(max(1, z), maxZoom)
    }

    /// Image rect as drawn in view space (Canvas destination).
    var imageRectInView: CGRect {
        CGRect(origin: toView(.zero), size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
    }
}
