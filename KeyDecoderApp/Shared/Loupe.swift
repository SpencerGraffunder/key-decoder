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
    var size: CGFloat = 132
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
            cross.move(to: CGPoint(x: center.x - 16, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + 16, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 16))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + 16))
            context.stroke(cross, with: .color(.red.opacity(0.9)), lineWidth: 1)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)),
                with: .color(.red)
            )
        }
        .frame(width: size, height: size)
        .background(.black.opacity(0.25))
        .overlay(Circle().stroke(.white.opacity(0.95), lineWidth: 3))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        .allowsHitTesting(false)
    }
}

/// Positions a loupe above (or below, near the top edge) a focus point given
/// in image coordinates, clamped inside the hosting view.
struct LoupeOverlay: ViewModifier {
    let image: CGImage?
    let focus: CGPoint?          // image coords
    let fit: ImageFit
    let viewSize: CGSize

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if let image, let focus {
                let p = fit.toView(focus)
                let above = p.y > 150
                Loupe(image: image, focus: focus, fit: fit)
                    .position(
                        x: min(max(p.x, 72), viewSize.width - 72),
                        y: above ? max(p.y - 118, 76) : min(p.y + 118, viewSize.height - 76)
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
