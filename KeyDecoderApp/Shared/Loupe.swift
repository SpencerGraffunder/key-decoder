import SwiftUI

/// Circular magnifier bubble shown while dragging alignment markers: renders
/// the pixels under the finger at pixel-true zoom with a crosshair, so card
/// corners and cut centers stay visible under the fingertip.
struct Loupe: View {
    /// Pixels source (the displayed image).
    let image: CGImage
    /// Focus point in IMAGE pixel coordinates.
    let focus: CGPoint
    /// Mapping of the dragged view so the loupe shows true pixel zoom.
    let fit: ImageFit
    var size: CGFloat = 176
    var zoom: CGFloat = 6

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context.clip(to: Path(ellipseIn: CGRect(origin: .zero, size: canvasSize)))
            let s = fit.scale * zoom
            let rect = CGRect(
                x: center.x - focus.x * s,
                y: center.y - focus.y * s,
                width: CGFloat(image.width) * s,
                height: CGFloat(image.height) * s
            )
            context.draw(Image(decorative: image, scale: 1), in: rect)
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - 18, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + 18, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 18))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + 18))
            context.stroke(cross, with: .color(.red.opacity(0.9)), lineWidth: 1)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)),
                with: .color(.red)
            )
        }
        .frame(width: size, height: size)
        // Circle backdrop — a plain .background here sat behind the SQUARE
        // frame and drew the grey box Spec called "crappy".
        .background(Circle().fill(.black.opacity(0.30)))
        .overlay(Circle().stroke(.white.opacity(0.95), lineWidth: 3))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
        .allowsHitTesting(false)
    }
}

/// Floats the loupe directly above the FOCUS point (which the drag handlers
/// keep ~70 pt above the finger). Applied outside the image clip but inside
/// the page VStack — no vertical clamping at all, so the bubble may spill
/// over the header, the photo frame edge, anything: Spec wants it "free to
/// move about the whole screen" above the finger, never trapped in the
/// image area. Horizontal position follows the focus (clamped only enough
/// to keep the crosshair's worth of context on screen).
struct ScreenLoupe: ViewModifier {
    let image: CGImage?
    let focus: CGPoint?          // image coords
    let fit: ImageFit
    let viewSize: CGSize
    var loupeSize: CGFloat = 184

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if let image, let focus {
                let p = fit.toView(focus)
                Loupe(image: image, focus: focus, fit: fit, size: loupeSize)
                    .position(
                        x: min(max(p.x, loupeSize * 0.30), max(viewSize.width - loupeSize * 0.30, loupeSize * 0.30)),
                        y: p.y - loupeSize / 2 - 26
                    )
            }
        }
    }
}

/// Type-erased ButtonStyle so styles can vary per row condition.
struct AnyButtonStyle: ButtonStyle {
    private let _make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        _make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { _make(configuration) }
}
