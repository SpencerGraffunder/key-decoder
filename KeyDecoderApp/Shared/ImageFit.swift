import CoreGraphics
import Foundation

/// Maps between image pixel coordinates and a `.fit`-displayed image inside a view.
struct ImageFit {
    let imageSize: CGSize
    let viewSize: CGSize

    var scale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }

    var offsetX: CGFloat { (viewSize.width - imageSize.width * scale) / 2 }
    var offsetY: CGFloat { (viewSize.height - imageSize.height * scale) / 2 }

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
}
