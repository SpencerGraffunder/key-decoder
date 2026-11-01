import SwiftUI
import UIKit

/// Four draggable handles to place on the reference card's corners — the manual
/// fallback whenever Vision cannot find the card (or the user prefers manual).
struct CardQuadEditorView: View {
    let image: UIImage
    let flow: DecodeFlow

    @State private var quad: [CGPoint]
    @State private var loupeFocus: CGPoint?

    init(image: UIImage, flow: DecodeFlow) {
        self.image = image
        self.flow = flow
        let pixelSize = Self.pixelSize(of: image)
        _quad = State(initialValue: flow.quad ?? Self.defaultQuad(pixelSize: pixelSize))
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(flow.statusMessage.isEmpty
                 ? "Drag the four corners onto the corners of the reference card."
                 : flow.statusMessage)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            GeometryReader { geo in
                let fit = ImageFit(
                    imageSize: Self.pixelSize(of: image),
                    viewSize: geo.size
                )
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)

                    Path { path in
                        let pts = quad.map(fit.toView)
                        path.move(to: pts[0])
                        for p in pts.dropFirst() { path.addLine(to: p) }
                        path.closeSubpath()
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

                    ForEach(quad.indices, id: \.self) { i in
                        Circle()
                            .fill(.white.opacity(0.12))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2.5))
                            .overlay(Circle().fill(Color.accentColor).frame(width: 4, height: 4))
                            .frame(width: 30, height: 30)
                            .shadow(radius: 2)
                            .position(fit.toView(quad[i]))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let p = fit.clampedToImage(value.location)
                                        quad[i] = p
                                        loupeFocus = p
                                    }
                                    .onEnded { _ in loupeFocus = nil }
                            )
                            .accessibilityLabel("Card corner \(i + 1)")
                    }
                }
                .modifier(LoupeOverlay(
                    image: image.cgImage, focus: loupeFocus, fit: fit, viewSize: geo.size
                ))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)

            Button {
                flow.confirmQuad(quad)
            } label: {
                Text("Use card").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle("Reference card")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func pixelSize(of image: UIImage) -> CGSize {
        guard let cg = image.cgImage else { return image.size }
        return CGSize(width: cg.width, height: cg.height)
    }

    static func defaultQuad(pixelSize: CGSize) -> [CGPoint] {
        let insetX = pixelSize.width * 0.08
        let insetY = pixelSize.height * 0.12
        return [
            CGPoint(x: insetX, y: insetY),
            CGPoint(x: pixelSize.width - insetX, y: insetY),
            CGPoint(x: pixelSize.width - insetX, y: pixelSize.height - insetY),
            CGPoint(x: insetX, y: pixelSize.height - insetY),
        ]
    }
}
