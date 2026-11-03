import SwiftUI
import KeyCore

/// Live review screen, in two deliberate stages (Spec flow request):
/// 1. CONFIRM THE KEY — the segmentation glows green over what the app thinks
///    is the key; tap the key itself to re-detect, or confirm. Nothing else is
///    editable until the key location is agreed.
/// 2. ADJUST — the view zooms onto the confirmed key and every marker
///    (shoulder/spine/cuts) can be dragged; the loupe rides above the finger.
///
/// All marker math lives in ONE coordinate space: the image and overlays are
/// drawn into Canvases through `ImageFit` (no SwiftUI transforms), and a single
/// full-frame drag gesture hit-tests the nearest handle within 44 pt — the old
/// per-dot gestures reported locations in the tiny dot's own space, which made
/// drags land nowhere and markers snap back on release.
struct ReviewView: View {
    let flow: DecodeFlow

    // MARK: - State

    @State private var loupeFocus: CGPoint?
    /// Finger position minus the lift while dragging a marker (view space):
    /// the adjusted point and loupe ride ABOVE the finger (Spec).
    @State private var dragPoint: CGPoint?
    private static let dragLift: CGFloat = 70
    @State private var pickMode = false

    @State private var zoom: CGFloat = 1
    @State private var center: CGPoint?
    @State private var viewSize: CGSize = CGSize(width: 375, height: 300)
    @State private var keyZoomActive = false

    @State private var keyConfirmed = false
    @State private var glow: CGImage?

    @State private var activeHandleID: Int?
    @State private var draggedHandle: ReviewHandle?
    @State private var panStart: (center: CGPoint, scale: CGFloat)?
    @State private var didPan = false

    private var confirmStage: Bool { flow.scene != nil && !keyConfirmed }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let result = flow.result, flow.scene != nil {
                markersView(result)
                confirmRow
                cutList(result)
            } else {
                manualEntry
            }
            footer
        }
        .navigationTitle("Review cuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    KeyIDGuideView()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Key ID guide")
            }
            if flow.photo != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        flow.step = .cardEditor
                    } label: {
                        Image(systemName: "rectangle.dashed")
                    }
                    .accessibilityLabel("Adjust card corners")
                }
            }
            if keyConfirmed && flow.scene != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.snappy) {
                            if keyZoomActive { fitWhole() } else { zoomToKey() }
                        }
                    } label: {
                        Image(systemName: keyZoomActive ? "arrow.up.left.and.arrow.down.right" : "viewfinder")
                    }
                    .accessibilityLabel(keyZoomActive ? "Show whole photo" : "Zoom to key")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        flow.flipBladeAxis()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Flip spine/base axis")
                }
            }
        }
        .onAppear {
            if flow.scene == nil { keyConfirmed = true }   // nothing to confirm in manual mode
        }
        .task(id: flow.pickGeneration) { glow = buildGlow() }
        .onChange(of: flow.pickGeneration) { _, _ in
            // A pick finished. Empty status = success.
            guard flow.statusMessage.isEmpty else { return }
            if confirmStage {
                withAnimation(.snappy) { confirmKey() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(flow.effectiveCode)
                    .font(.system(.title, design: .monospaced).weight(.bold))
                    .accessibilityLabel("Bitting code \(flow.effectiveCode.replacingOccurrences(of: "-", with: " dash "))")
                Spacer()
                systemMenu
            }
            suggestionChips
            if uncertainCount > 0 && !confirmStage {
                Label(
                    "\(uncertainCount) cut(s) uncertain — nudge markers or set digits manually.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Top three ranked systems — the CURRENT one highlighted — each carrying
    /// the evidence behind it. Chip is its own view: nested ternaries inside
    /// buttonStyle/Text here blew the type-checker budget on CI.
    private var suggestionChips: some View {
        let top = Array(flow.suggestions.prefix(3))
        return Group {
            if !top.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Label("System:", systemImage: "wand.and.stars")
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(top, id: \.system.id) { s in
                            SuggestionChip(
                                name: s.system.name,
                                reason: s.reason,
                                isCurrent: s.system.id == flow.systemID
                            ) {
                                if s.system.id != flow.systemID { flow.setSystem(s.system.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var systemMenu: some View {
        Menu {
            ForEach(sortedSystems) { system in
                Button {
                    flow.setSystem(system.id)
                } label: {
                    Text("\(system.name)\(system.isVerified ? "" : " (draft)")")
                }
            }
        } label: {
            Label(currentSystemName, systemImage: "gearshape.2")
                .font(.subheadline)
        }
        .accessibilityLabel("Key system: \(currentSystemName). Choose key system.")
    }

    private var sortedSystems: [KeySystemDefinition] {
        flow.systems.sorted {
            if $0.isVerified != $1.isVerified { return $0.isVerified }
            return $0.name < $1.name
        }
    }

    private var currentSystemName: String {
        flow.currentSystem?.name ?? "Key system"
    }

    private var uncertainCount: Int {
        flow.result?.cuts.filter { $0.lowConfidence || $0.outOfTable }.count ?? 0
    }

    // MARK: - Markers

    @ViewBuilder
    private func markersView(_ result: CutScanResult) -> some View {
        if let image = flow.correctedImage {
            GeometryReader { geo in
                let pix = CGSize(
                    width: image.cgImage?.width ?? Int(image.size.width),
                    height: image.cgImage?.height ?? Int(image.size.height)
                )
                let fit = ImageFit(imageSize: pix, viewSize: geo.size, zoom: zoom, center: center)
                let hs = makeHandles(result: result, fit: fit)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        if let cg = image.cgImage {
                            context.draw(Image(decorative: cg, scale: 1), in: fit.imageRectInView)
                        }
                        if let glow {
                            context.draw(Image(decorative: glow, scale: 1), in: fit.imageRectInView)
                        }
                    }

                    if let blade = flow.scene?.blade, flow.params != nil {
                        overlayLines(blade: blade, result: result, fit: fit)
                        ForEach(hs) { h in
                            ring(color: h.color).position(h.point)
                        }
                    }

                    if let dp = dragPoint {
                        Path { p in
                            p.move(to: CGPoint(x: dp.x - 10, y: dp.y))
                            p.addLine(to: CGPoint(x: dp.x + 10, y: dp.y))
                            p.move(to: CGPoint(x: dp.x, y: dp.y - 10))
                            p.addLine(to: CGPoint(x: dp.x, y: dp.y + 10))
                        }
                        .stroke(.red.opacity(0.95), lineWidth: 1.5)
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(fit: fit, handles: hs))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // Outside the clip: the bubble may spill past the frame — Spec
                // prefers that over being squeezed inside.
                .modifier(ScreenLoupe(
                    image: image.cgImage, focus: loupeFocus, fit: fit, viewSize: geo.size
                ))
                .overlay(alignment: .top) { confirmBanner }
                .overlay(alignment: .center) {
                    if flow.isPicking {
                        ProgressView("Finding your key…")
                            .padding(12)
                            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.white)
                    }
                }
                .onAppear { viewSize = geo.size }
                .onChange(of: geo.size) { _, new in viewSize = new }
            }
            .frame(minHeight: 280)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var confirmBanner: some View {
        if confirmStage {
            VStack(spacing: 2) {
                Label("Is the green glow on your key?", systemImage: "hand.tap")
                    .font(.callout.weight(.semibold))
                Text(flow.statusMessage.isEmpty
                     ? "Tap your key itself to re-detect — or press “That’s my key” below."
                     : flow.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(flow.statusMessage.isEmpty ? Color.white.opacity(0.85) : Color.yellow)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(10)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
            .padding(8)
        }
    }

    private func ring(color: Color) -> some View {
        Circle()
            .fill(.white.opacity(0.12))
            .overlay(Circle().stroke(color, lineWidth: 2.5))
            .overlay(Circle().fill(color).frame(width: 5, height: 5))
            .frame(width: 32, height: 32)
            .shadow(radius: 2)
            .allowsHitTesting(false)
    }

    private func overlayLines(blade: BladeAnalysis, result: CutScanResult, fit: ImageFit) -> some View {
        Canvas { context, _ in
            guard let params = flow.params else { return }
            let spineStart = blade.xy(u: params.shoulderU, v: params.spine.v(at: params.shoulderU))
            let spineEnd = blade.xy(u: blade.tipU, v: params.spine.v(at: blade.tipU))
            var spine = Path()
            spine.move(to: fit.toView(spineStart))
            spine.addLine(to: fit.toView(spineEnd))
            context.stroke(spine, with: .color(.cyan.opacity(0.9)), lineWidth: 2)

            let shoulderTop = blade.xy(
                u: params.shoulderU,
                v: params.spine.v(at: params.shoulderU) - blade.bladeWidthPx * 1.4
            )
            let shoulderBot = blade.xy(
                u: params.shoulderU,
                v: params.spine.v(at: params.shoulderU) + blade.bladeWidthPx * 2.2
            )
            var shoulder = Path()
            shoulder.move(to: fit.toView(shoulderTop))
            shoulder.addLine(to: fit.toView(shoulderBot))
            context.stroke(shoulder, with: .color(.yellow.opacity(0.9)), lineWidth: 2)

            for cut in result.cuts {
                let edge = blade.cutEdgeV(at: cut.centerU)
                    ?? params.spine.v(at: cut.centerU) + blade.bladeWidthPx
                var tick = Path()
                tick.move(to: fit.toView(blade.xy(u: cut.centerU, v: params.spine.v(at: cut.centerU))))
                tick.addLine(to: fit.toView(blade.xy(u: cut.centerU, v: edge)))
                context.stroke(
                    tick,
                    with: .color(ReviewView.cutColor(cut).opacity(0.95)),
                    style: StrokeStyle(lineWidth: 2, dash: [4, 3])
                )
            }
        }
        .allowsHitTesting(false)
    }

    private static func cutColor(_ cut: CutMeasurement) -> Color {
        if cut.isManualOverride { return .blue }
        if cut.outOfTable { return .red }
        if cut.lowConfidence { return .orange }
        return .green
    }

    /// -100 shoulder, -101 spine, ≥0 cut index. apply receives a view-space point.
    private func makeHandles(result: CutScanResult, fit: ImageFit) -> [ReviewHandle] {
        guard let scene = flow.scene, let params = flow.params else { return [] }
        let blade = scene.blade
        var out: [ReviewHandle] = [
            // Shoulder drag sits at the blade's BOTTOM corner so it never
            // collides with the spine line's shoulder-end handle.
            ReviewHandle(
                id: -100,
                point: fit.toView(blade.xy(
                    u: params.shoulderU,
                    v: params.spine.v(at: params.shoulderU) + blade.bladeWidthPx * 1.15
                )),
                color: .yellow
            ) { p in flow.dragShoulder(toImagePoint: fit.toImage(p)) },
            // Spine line, END handles: each end pivots the line about the
            // other — fixes a spine caught on the wrong axis (Spec).
            ReviewHandle(
                id: -101,
                point: fit.toView(blade.xy(u: params.shoulderU, v: params.spine.v(at: params.shoulderU))),
                color: .cyan
            ) { p in flow.dragSpineEnd(atU: params.shoulderU, toImagePoint: fit.toImage(p)) },
            ReviewHandle(
                id: -102,
                point: fit.toView(blade.xy(u: blade.tipU, v: params.spine.v(at: blade.tipU))),
                color: .cyan
            ) { p in flow.dragSpineEnd(atU: blade.tipU, toImagePoint: fit.toImage(p)) },
        ]
        for cut in result.cuts {
            let edgeV = blade.cutEdgeV(at: cut.centerU) ?? params.spine.v(at: cut.centerU)
            out.append(ReviewHandle(
                id: cut.index,
                point: fit.toView(blade.xy(u: cut.centerU, v: edgeV)),
                color: ReviewView.cutColor(cut)
            ) { p in flow.dragCut(cut.index, toImagePoint: fit.toImage(p)) })
        }
        return out
    }

    // MARK: - One gesture for the whole frame

    private func dragGesture(fit: ImageFit, handles hs: [ReviewHandle]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                grabIfNeeded(start: value.startLocation, fit: fit, handles: hs)
                act(value: value, fit: fit)
            }
            .onEnded { value in
                release(fit: fit, end: value)
            }
    }

    /// First frame of a drag: nearest handle within 44 pt, else pan mode.
    /// Handle-grabbing is disabled during key-confirm and re-pick, so a touch
    /// anywhere (not on a handle) becomes a "tap to re-detect".
    private func grabIfNeeded(start: CGPoint, fit: ImageFit, handles hs: [ReviewHandle]) {
        guard activeHandleID == nil, panStart == nil else { return }
        if !confirmStage && !pickMode {
            let distances: [CGFloat] = hs.map {
                hypot($0.point.x - start.x, $0.point.y - start.y)
            }
            if let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }),
               let minDist = distances.min(), minDist <= 44 {
                activeHandleID = hs[nearest].id
                draggedHandle = hs[nearest]
            }
        }
        if activeHandleID == nil { panStart = (fit.focus, fit.scale) }
    }

    private func act(value: DragGesture.Value, fit: ImageFit) {
        if let h = draggedHandle {
            // Effective point rides ABOVE the finger; the crosshair marks it.
            let raised = CGPoint(x: value.location.x, y: value.location.y - Self.dragLift)
            h.apply(raised)
            loupeFocus = fit.clampedToImage(raised)
            dragPoint = raised
        } else if let ps = panStart {
            if hypot(value.translation.width, value.translation.height) > 6 { didPan = true }
            if didPan {
                center = fit.panTarget(from: ps.center, translation: value.translation)
            }
        }
    }

    private func release(fit: ImageFit, end: DragGesture.Value) {
        let total = hypot(end.translation.width, end.translation.height)
        let wasTap = total < 10 && draggedHandle == nil && !didPan
        activeHandleID = nil
        draggedHandle = nil
        panStart = nil
        didPan = false
        loupeFocus = nil
        dragPoint = nil
        if wasTap && (confirmStage || pickMode) {
            flow.pickKeyRegion(atImagePoint: fit.clampedToImage(end.startLocation))
            pickMode = false
        }
    }

    // MARK: - Stages

    /// Confirm button row during stage 1; re-pick affordance during stage 2.
    @ViewBuilder
    private var confirmRow: some View {
        if confirmStage {
            HStack {
                Button {
                    withAnimation(.snappy) { confirmKey() }
                } label: {
                    Label("That’s my key", systemImage: "checkmark.circle.fill")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(.horizontal)
        } else {
            HStack(spacing: 8) {
                Button {
                    pickMode.toggle()
                } label: {
                    Label(pickMode ? "Cancel" : "Wrong key? Tap to reselect", systemImage: "hand.tap")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                if pickMode {
                    Text("Now tap directly on the key blade")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if !pickMode && !flow.statusMessage.isEmpty {
                    Text(flow.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal)
        }
    }

    private func confirmKey() {
        keyConfirmed = true
        zoomToKey()
    }

    private func zoomToKey() {
        guard let bbox = flow.keyBBox(), let image = flow.correctedImage else {
            fitWhole()
            return
        }
        let pix = CGSize(
            width: image.cgImage?.width ?? Int(image.size.width),
            height: image.cgImage?.height ?? Int(image.size.height)
        )
        let fit = ImageFit(imageSize: pix, viewSize: viewSize)
        center = CGPoint(x: bbox.midX, y: bbox.midY)
        zoom = fit.zoomToFit(rect: bbox, fill: 0.72, maxZoom: 3.2)
        keyZoomActive = true
    }

    private func fitWhole() {
        zoom = 1
        center = nil
        keyZoomActive = false
    }

    /// Soft green alpha wash over the segmentation mask — "this is what the
    /// app is reading as YOUR key".
    private func buildGlow() -> CGImage? {
        guard let scene = flow.scene else { return nil }
        let m = scene.mask
        guard m.width > 0, m.height > 0, m.mask.count == m.width * m.height else { return nil }
        let alpha: UInt8 = 115
        var pixels = [UInt8](repeating: 0, count: m.mask.count * 4)
        for i in m.mask.indices where m.mask[i] {
            // premultipliedLast: channels pre-scaled by their own alpha
            pixels[i * 4] = UInt8(40 * Int(alpha) / 255)
            pixels[i * 4 + 1] = UInt8(220 * Int(alpha) / 255)
            pixels[i * 4 + 2] = UInt8(120 * Int(alpha) / 255)
            pixels[i * 4 + 3] = alpha
        }
        guard let ctx = CGContext(
            data: &pixels, width: m.width, height: m.height,
            bitsPerComponent: 8, bytesPerRow: m.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }

    // MARK: - Cut list

    private func cutList(_ result: CutScanResult) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                ForEach(result.cuts) { cut in
                    cutRow(cut)
                }
                ForEach(warningTexts, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: 180)
        .disabled(confirmStage)
        .opacity(confirmStage ? 0.5 : 1)
    }

    private func cutRow(_ cut: CutMeasurement) -> some View {
        HStack(spacing: 10) {
            Text("Cut \(cut.index + 1)")
                .font(.callout.weight(.medium))
                .frame(width: 58, alignment: .leading)
            Text(cut.depthIn.isNaN ? "no data" : String(format: "%.3f″", cut.depthIn))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            flagIcon(cut)
            Stepper(value: digitBinding(cut), in: digitBounds) {
                Text("\(cut.digit)")
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .frame(minWidth: 18)
            }
            .accessibilityLabel("Depth digit for cut \(cut.index + 1)")
            if cut.isManualOverride {
                Button("auto") { flow.clearDigitOverride(cut.index) }
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func digitBinding(_ cut: CutMeasurement) -> Binding<Int> {
        Binding(
            get: { cut.digit },
            set: { flow.setDigitOverride(cut.index, to: $0) }
        )
    }

    private var digitBounds: ClosedRange<Int> {
        guard let system = flow.currentSystem else { return 0...9 }
        return system.digitRange.lowerBound ... (system.digitRange.upperBound - 1)
    }

    @ViewBuilder
    private func flagIcon(_ cut: CutMeasurement) -> some View {
        if cut.isManualOverride {
            Image(systemName: "hand.draw.fill").foregroundStyle(.blue)
        } else if cut.outOfTable {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        } else if cut.lowConfidence {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    // MARK: - Manual entry (segmentation failed or user chose manual)

    private var manualEntry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "Manual mode — set each cut depth by hand (consult a depth-and-space chart if needed).",
                    systemImage: "hand.draw"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if let photo = flow.photo {
                    Image(uiImage: photo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                ForEach(flow.manualDigits.indices, id: \.self) { index in
                    HStack {
                        Text("Cut \(index + 1)")
                        Spacer()
                        Stepper(
                            value: Binding(
                                get: { flow.manualDigits[index] },
                                set: { flow.setDigitOverride(index, to: $0) }
                            ),
                            in: digitBounds
                        ) {
                            Text("\(flow.manualDigits[index])")
                                .font(.system(.body, design: .monospaced).weight(.bold))
                                .frame(minWidth: 18)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
    }

    // MARK: - Footer

    private var canContinue: Bool {
        guard !flow.effectiveCode.isEmpty else { return false }
        if flow.scene != nil { return keyConfirmed }
        return true
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if flow.scene != nil && !keyConfirmed {
                Text("Confirm the key location first")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Retake") { flow.retake() }
                Spacer()
                Button {
                    flow.step = .result
                } label: {
                    Text("Continue").frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var warningTexts: [String] {
        flow.warnings.map { warning in
            switch warning {
            case .segmentationFailed: return "Could not segment the key — use manual mode."
            case .bladeAnalysisFailed: return "Could not read the blade — use manual mode."
            case .bladeLengthSuspicious: return "Blade length looks unusual; check the scale (card corners)."
            case .gridBeyondBlade: return "The cut grid runs past the blade; drag the shoulder marker."
            case .outOfTableCuts: return "Some depths are outside the key system table; consider another system."
            case .lowConfidenceCuts: return "Some cuts sit near a depth boundary — verify before copying."
            }
        }
    }
}

// MARK: - Marker handle

private struct ReviewHandle: Identifiable {
    let id: Int              // -100 shoulder, -101 spine, >= 0 cut index
    let point: CGPoint       // view space
    let color: Color
    let apply: (CGPoint) -> Void
}

// MARK: - Suggestion chip

private struct SuggestionChip: View {
    let name: String
    let reason: String?
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                    }
                    Text(name).font(.caption.weight(.semibold))
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(isCurrent ? Color.primary.opacity(0.75) : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
        }
        .buttonBorderShape(.capsule)
        .modifier(ChipProminence(current: isCurrent))
        .accessibilityLabel(accessibilityText)
    }

    private var subtitle: String {
        if let reason { return reason }
        return isCurrent ? "in use" : "tap to switch"
    }

    private var accessibilityText: String {
        if isCurrent { return "\(name), current system. \(subtitle)" }
        return "\(name). \(subtitle)"
    }
}

private struct ChipProminence: ViewModifier {
    let current: Bool
    func body(content: Content) -> some View {
        if current {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
