import SwiftUI
import UIKit

/// Four draggable handles to place on the reference card's corners — the manual
/// fallback whenever Vision cannot find the card (or the user prefers manual).
///
/// Interaction model (Spec feedback: markers were untouchable at the frame
/// edges and the loupe invisible):
/// - The image is rendered into a Canvas through `ImageFit`, so ONE coordinate
///   space governs drawing and gestures (no SwiftUI transforms to fight).
/// - A single full-frame drag gesture picks the nearest corner within 44 pt —
///   fingers no longer need to land on a tiny dot — and drags anywhere else to
///   PAN, so zoomed-in corners at the frame border stay reachable.
/// - Starts zoomed onto the card (the capture hint says roughly where the card
///   goes, so the default framing is the card itself); double-tap toggles
///   whole-photo ↔ card-zoom.
/// - The loupe rides ABOVE the finger and is attached outside the clip, so it
///   may spill past the photo frame.
struct CardQuadEditorView: View {
    let image: UIImage
    let flow: DecodeFlow

    @State private var quad: [CGPoint]
    @State private var loupeFocus: CGPoint?
    @State private var dragPoint: CGPoint?
    @State private var quadWarning: String?
    private static let dragLift: CGFloat = 70

    @State private var zoom: CGFloat = 1
    @State private var center: CGPoint?
    @State private var viewSize: CGSize = CGSize(width: 375, height: 460)
    @State private var zoomedToCard = false

    /// Overlay-drag bookkeeping.
    @State private var activeCorner: Int?
    @State private var panStart: (center: CGPoint, scale: CGFloat)?
    @State private var didPan = false

    init(image: UIImage, flow: DecodeFlow) {
        self.image = image
        self.flow = flow
        let pixelSize = Self.pixelSize(of: image)
        _quad = State(initialValue: flow.quad ?? Self.defaultQuad(pixelSize: pixelSize))
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(flow.statusMessage.isEmpty
                 ? "Drag the four rings onto the corners of the reference card."
                 : flow.statusMessage)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            GeometryReader { geo in
                let pix = Self.pixelSize(of: image)
                let fit = ImageFit(
                    imageSize: pix, viewSize: geo.size,
                    zoom: zoom, center: center
                )
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        if let cg = image.cgImage {
                            context.draw(
                                Image(decorative: cg, scale: 1),
                                in: fit.imageRectInView
                            )
                        }
                        if let dp = dragPoint {
                            var cross = Path()
                            cross.move(to: CGPoint(x: dp.x - 10, y: dp.y))
                            cross.addLine(to: CGPoint(x: dp.x + 10, y: dp.y))
                            cross.move(to: CGPoint(x: dp.x, y: dp.y - 10))
                            cross.addLine(to: CGPoint(x: dp.x, y: dp.y + 10))
                            context.stroke(cross, with: .color(.red.opacity(0.95)), lineWidth: 1.5)
                        }
                        var outline = Path()
                        let pts = quad.map(fit.toView)
                        outline.move(to: pts[0])
                        for p in pts.dropFirst() { outline.addLine(to: p) }
                        outline.closeSubpath()
                        context.stroke(
                            outline,
                            with: .color(.accentColor),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                    }

                    ForEach(quad.indices, id: \.self) { i in
                        ring(color: .accentColor)
                            .position(fit.toView(quad[i]))
                            .accessibilityLabel("Card corner \(i + 1)")
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(fit: fit, handles: quad.map(fit.toView)))
                .onTapGesture(count: 2) { toggleZoom() }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // Outside the clip: the bubble is allowed to spill over the frame.
                .modifier(ScreenLoupe(
                    image: image.cgImage, focus: loupeFocus, fit: fit, viewSize: geo.size
                ))
                .onAppear { viewSize = geo.size }
                .onChange(of: geo.size) { _, new in viewSize = new }
            }
            .frame(minHeight: 320)
            .padding(.horizontal)

            Text(zoomedToCard
                 ? "Drag outside a ring to pan · double-tap to see the whole photo"
                 : "Double-tap to zoom onto the card")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let quadWarning {
                Label(quadWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                if quadWarning == nil, let w = Self.quadAspectWarning(quad) {
                    // First tap on a non-card-shaped quad only warns — the
                    // second tap confirms anyway. Never a dead end (Spec).
                    quadWarning = w
                } else {
                    flow.confirmQuad(quad)
                }
            } label: {
                Text("Use card").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle("Reference card")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { initialFraming() }
    }

    private func ring(color: Color) -> some View {
        Circle()
            .fill(.white.opacity(0.12))
            .overlay(Circle().stroke(color, lineWidth: 2.5))
            .overlay(Circle().fill(color).frame(width: 5, height: 5))
            .frame(width: 34, height: 34)
            .shadow(radius: 2)
    }

    /// Sanity-check the marked quad against credit-card proportions
    /// (1.586 landscape / 0.631 portrait, generous for perspective foreshortening).
    static func quadAspectWarning(_ q: [CGPoint]) -> String? {
        guard q.count == 4 else { return nil }
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        let w = (d(q[0], q[1]) + d(q[3], q[2])) / 2
        let hh = (d(q[0], q[3]) + d(q[1], q[2])) / 2
        guard hh > 1, w > 1 else { return "That shape is degenerate — put the rings on the card's four corners." }
        let ratio = w / hh
        if abs(log(ratio / 1.586)) <= 0.42 || abs(log(ratio / 0.631)) <= 0.42 { return nil }
        return String(format: "That doesn't look like a card (ratio %.2f, want ~1.59). Tap again to use it anyway, or move the rings onto the card corners.", ratio)
    }

    // MARK: - Gesture

    private func dragGesture(fit: ImageFit, handles: [CGPoint]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                grabIfNeeded(start: value.startLocation, fit: fit, handles: handles)
                act(value: value, fit: fit)
            }
            .onEnded { _ in
                activeCorner = nil
                panStart = nil
                didPan = false
                loupeFocus = nil
                dragPoint = nil
            }
    }

    /// Nearest corner within 44 pt wins; a touch far from every ring pans.
    private func grabIfNeeded(start: CGPoint, fit: ImageFit, handles: [CGPoint]) {
        guard activeCorner == nil, panStart == nil else { return }
        let distances: [CGFloat] = handles.map { hypot($0.x - start.x, $0.y - start.y) }
        if let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }),
           let minDist = distances.min(), minDist <= 44 {
            activeCorner = nearest
        } else {
            panStart = (fit.focus, fit.scale)
        }
    }

    private func act(value: DragGesture.Value, fit: ImageFit) {
        if let i = activeCorner {
            // Corner rides ABOVE the finger (with the crosshair marking it)
            // so the fingertip never covers the ring being placed.
            let raised = CGPoint(x: value.location.x, y: value.location.y - Self.dragLift)
            let p = fit.clampedToImage(raised)
            quad[i] = p
            loupeFocus = p
            dragPoint = raised
            quadWarning = nil
        } else if let ps = panStart {
            if hypot(value.translation.width, value.translation.height) > 6 { didPan = true }
            if didPan {
                center = fit.panTarget(from: ps.center, translation: value.translation)
            }
        }
    }

    // MARK: - Framing

    /// Frame the card on entry: the capture hint tells the user to put the
    /// card roughly dead-center, so the (auto- or default-) quad marks the
    /// region worth magnifying — "zoom in a bit first" (Spec).
    private func initialFraming() {
        applyCardFraming()
    }

    private func applyCardFraming() {
        let pix = Self.pixelSize(of: image)
        let fit = ImageFit(imageSize: pix, viewSize: viewSize)
        let pts = quad
        guard let first = pts.first else { return }
        var rect = CGRect(origin: first, size: .zero)
        for p in pts.dropFirst() { rect = rect.union(CGRect(origin: p, size: .zero)) }
        center = CGPoint(x: rect.midX, y: rect.midY)
        zoom = fit.zoomToFit(rect: rect, fill: 0.62, maxZoom: 2.6)
        zoomedToCard = zoom > 1.02
    }

    private func toggleZoom() {
        withAnimation(.snappy) {
            if zoomedToCard {
                zoom = 1
                center = nil
                zoomedToCard = false
            } else {
                applyCardFraming()
            }
        }
    }

    // MARK: - Geometry helpers

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
