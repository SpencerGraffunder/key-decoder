import SwiftUI
import KeyCore

/// Live review screen: draggable shoulder / spine / cut markers over the corrected
/// photo, per-cut depths + digits, boundary flags, and manual digit entry.
struct ReviewView: View {
    let flow: DecodeFlow

    /// Image-space point under the finger while dragging a marker (loupe focus).
    @State private var loupeFocus: CGPoint?
    /// "That's not my key" mode: next tap re-segments at the tapped blob.
    @State private var pickMode = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let result = flow.result, flow.scene != nil {
                markersView(result)
                pickKeyRow
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
            if uncertainCount > 0 {
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

    /// Top three ranked systems — the CURRENT one highlighted first — each
    /// carrying the evidence behind it ("stamped "KW1"", "spacing ~.151 · 5
    /// cuts"). Tap any other to switch instantly.
    private var suggestionChips: some View {
        let shown = flow.suggestions.prefix(3)
        return Group {
            if !shown.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Label("System:", systemImage: "wand.and.stars")
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(Array(shown), id: \.system.id) { s in
                            let isCurrent = s.system.id == flow.systemID
                            Button {
                                if !isCurrent { flow.setSystem(s.system.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 3) {
                                        if isCurrent {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 9))
                                        }
                                        Text(s.system.name).font(.caption.weight(.semibold))
                                    }
                                    Text(isCurrent
                                         ? (s.reason ?? "in use")
                                         : (s.reason ?? "tap to switch"))
                                        .font(.caption2)
                                        .foregroundStyle(isCurrent ? .primary.opacity(0.75) : .secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                            }
                            .buttonStyle(isCurrent ? AnyButtonStyle(.borderedProminent)
                                                   : AnyButtonStyle(.bordered))
                            .buttonBorderShape(.capsule)
                            .accessibilityLabel(isCurrent
                                ? "\(s.system.name), current system"
                                : "\(s.system.name). \(s.reason ?? "Switch to it")")
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
                let fit = ImageFit(
                    imageSize: CGSize(
                        width: image.cgImage?.width ?? Int(image.size.width),
                        height: image.cgImage?.height ?? Int(image.size.height)
                    ),
                    viewSize: geo.size
                )
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)

                    if let blade = flow.scene?.blade, let params = flow.params {
                        overlayLines(blade: blade, params: params, result: result, fit: fit)
                        handles(blade: blade, result: result, fit: fit, size: geo.size)
                    }

                    if pickMode {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                pickAttemptFeedback = flow.statusMessage
                                flow.statusMessage = ""
                                flow.pickKeyRegion(atImagePoint: fit.clampedToImage(location))
                                pickMode = false
                            }
                    }
                }
                .modifier(LoupeOverlay(
                    image: image.cgImage, focus: loupeFocus, fit: fit, viewSize: geo.size
                ))
            }
            .frame(minHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func overlayLines(
        blade: BladeAnalysis, params: CutGridParams, result: CutScanResult, fit: ImageFit
    ) -> some View {
        Canvas { context, _ in
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
                let color: Color = cut.isManualOverride ? .blue
                    : cut.outOfTable ? .red
                    : cut.lowConfidence ? .orange : .green
                context.stroke(
                    tick,
                    with: .color(color.opacity(0.95)),
                    style: StrokeStyle(lineWidth: 2, dash: [4, 3])
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func handles(
        blade: BladeAnalysis, result: CutScanResult, fit: ImageFit, size: CGSize
    ) -> some View {
        ZStack {
            if let params = flow.params {
                handle(position: fit.toView(
                    blade.xy(u: params.shoulderU, v: params.spine.v(at: params.shoulderU))
                ), color: .yellow, label: "Shoulder line", loupeMap: { fit.clampedToImage($0) }) { point in
                    flow.dragShoulder(toImagePoint: fit.toImage(point))
                }
                let spineMidU = (params.shoulderU + blade.tipU) / 2
                handle(position: fit.toView(
                    blade.xy(u: spineMidU, v: params.spine.v(at: spineMidU))
                ), color: .cyan, label: "Spine line", loupeMap: { fit.clampedToImage($0) }) { point in
                    flow.dragSpine(toImagePoint: fit.toImage(point))
                }
            }
            ForEach(result.cuts) { cut in
                let edgeV = flow.scene?.blade.cutEdgeV(at: cut.centerU)
                    ?? flow.params?.spine.v(at: cut.centerU) ?? 0
                handle(
                    position: fit.toView(flow.scene?.blade.xy(u: cut.centerU, v: edgeV) ?? .zero),
                    color: cut.isManualOverride ? .blue
                        : cut.outOfTable ? .red
                        : cut.lowConfidence ? .orange : .green,
                    label: "Cut \(cut.index + 1) center",
                    loupeMap: { fit.clampedToImage($0) }
                ) { point in
                    flow.dragCut(cut.index, toImagePoint: fit.toImage(point))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func handle(
        position: CGPoint, color: Color, label: String,
        loupeMap: @escaping (CGPoint) -> CGPoint = { $0 },
        action: @escaping (CGPoint) -> Void
    ) -> some View {
        // Ring, not a disc: a solid dot hides the very cut you are aligning.
        Circle()
            .fill(.white.opacity(0.12))
            .overlay(Circle().stroke(color, lineWidth: 2.5))
            .overlay(Circle().fill(color).frame(width: 4, height: 4))
            .frame(width: 26, height: 26)
            .shadow(radius: 2)
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        action(value.location)
                        loupeFocus = loupeMap(value.location)
                    }
                    .onEnded { _ in loupeFocus = nil }
            )
            .accessibilityLabel(label)
            .accessibilityHint("Drag to adjust")
    }

    /// "the app grabbed the wrong object" escape hatch.
    private var pickKeyRow: some View {
        HStack(spacing: 8) {
            Button {
                pickMode.toggle()
            } label: {
                Label(pickMode ? "Cancel" : "Wrong key area? Tap the key",
                      systemImage: "hand.tap")
            }
            .font(.caption)
            .buttonStyle(.bordered)
            if pickMode {
                Text("Now tap directly on the key blade")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            Spacer()
        }
        .padding(.horizontal)
        .overlay(alignment: .top) {
            // Pick-failure feedback from the flow (re-pick attempts only).
            if pickAttemptFeedback != nil && !flow.statusMessage.isEmpty {
                Text(flow.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Snapshot of the pre-tap statusMessage; shown only if the tap changes it
    /// (i.e. it becomes the re-pick failure notice). Cleared on any change.
    @State private var pickAttemptFeedback: String? = nil


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

    private var footer: some View {
        HStack {
            Button("Retake") { flow.retake() }
            Spacer()
            Button {
                flow.step = .result
            } label: {
                Text("Continue").frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .disabled(flow.effectiveCode.isEmpty)
        }
        .padding()
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
