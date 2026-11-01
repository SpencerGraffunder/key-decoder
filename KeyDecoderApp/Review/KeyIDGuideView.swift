import SwiftUI
import KeyCore

/// In-app, caliper-free key identification guide. Every example diagram is
/// drawn from the same keysystems.json the measurement engine uses, so the
/// examples always match the shipped numbers.
struct KeyIDGuideView: View {
    private var systems: [KeySystemDefinition] {
        KeySystemLibrary.bundled.filter { $0.isVerified }
    }

    var body: some View {
        List {
            Section("Identifying without calipers") {
                TipRow(symbol: "a.square", title: "Read the stamp first",
                       text: "Brand blanks carry the maker or code engraved on the bow: KWKSET or KW1 for Kwikset, SCHLAGE or SC1 for Schlage, M for Master. The app OCRs the bow automatically and puts a stamped match on top of the suggestions.")
                TipRow(symbol: "1.circle", title: "Count the cuts",
                       text: "Kwikset KW1: 5 cuts. Schlage SC1: usually 6 (5 happens). Master: 4\u{2013}5. The review chips show the app\u{2019}s detected cut count.")
                TipRow(symbol: "ruler", title: "Compare the spacing",
                       text: "KW1 cuts sit .150 in apart, SC1 .156 in. Half a thousandth per gap is invisible, but it accumulates across the blade \u{2014} over 5 gaps it is 0.03 in, a visible sliver near the tip. The app shows its measured spacing to 3 decimals.")
                TipRow(symbol: "waveform", title: "Look at cut shape and digit range",
                       text: "KW1 has deep rounded scallops, 0.023 in per step, digits 1\u{2013}5. SC1 has shallower, finer steps, 0.015 in, digits 0\u{2013}9: if the code reads like 0\u{2013}9 it is almost certainly Schlage.")
                TipRow(symbol: "capsule.portrait", title: "Bow and keyway feel",
                       text: "Kwikset bows are chunky and rounded with a wavy (paracentric) keyway. Schlage bows are flat ovals with a plain keyway. Master has a small round bow, often sawtooth bitting with side pins.")
                TipRow(symbol: "pin.fill", title: "Cross-pins and side-pins",
                       text: "An extra pin, post, or sidebar on the blade means a restricted keyline even when spacing matches. Do not treat it as a plain KW1/SC1 blank.")
            }
            Section("Systems on this device") {
                ForEach(systems) { system in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(system.name).font(.headline)
                            Spacer()
                            Text("\(system.manufacturer) \u{00b7} \(system.isVerified ? "verified" : "draft")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        KeySystemDiagram(system: system)
                            .frame(height: 74)
                        Text(summary(for: system))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Text("Diagrams are schematic: spacing and relative cut depths are to scale from keysystems.json; the bow is stylized.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("Key ID guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summary(for s: KeySystemDefinition) -> String {
        let lo = s.digitRange.lowerBound, hi = s.digitRange.upperBound - 1
        var parts = [
            "\(s.pinCount) cuts",
            String(format: "spacing %.3f in", s.spacingIn),
            "digits \(lo)\u{2013}\(hi)",
        ]
        if !s.stampAliases.isEmpty {
            parts.append("stamped \u{201c}\(s.stampAliases.joined(separator: "\u{201d} / \u{201c}"))\u{201d}")
        }
        return parts.joined(separator: " \u{00b7} ")
    }
}

private struct TipRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Schematic key drawing driven by the system JSON: spacing, cut count, and
/// relative cut depths are to scale.
struct KeySystemDiagram: View {
    let system: KeySystemDefinition

    var body: some View {
        Canvas { context, size in
            let spacing = system.spacingIn
            let depths = system.depthsIn
            let n = min(system.pinCount, max(depths.count, 1))
            guard n > 0, size.width > 40, spacing > 0 else { return }
            let maxDepth = depths.max() ?? 0.3
            let minDepth = depths.min() ?? 0.2
            let depthSpan = max(maxDepth - minDepth, 1e-6)

            let bowIn = 0.60
            let shoulderIn = 0.28
            let tailIn = 0.34
            let totalIn = bowIn + shoulderIn + spacing * Double(n - 1) + tailIn
            let scale = Double(size.width) / totalIn * 0.98
            let offsetX = (size.width - CGFloat(totalIn * scale)) / 2
            func X(_ inches: Double) -> CGFloat { offsetX + CGFloat(inches * scale) }

            let spineY = size.height * 0.76
            let crestY = size.height * 0.34
            let headY = crestY - 4
            let maxDrop = size.height * 0.30

            var bow = Path()
            bow.addRoundedRect(
                in: CGRect(x: X(0), y: spineY - size.height * 0.50,
                           width: X(bowIn) - X(0) + 4, height: size.height * 0.58),
                cornerSize: CGSize(width: 10, height: 10))
            var slot = Path()
            slot.addRoundedRect(
                in: CGRect(x: X(0.12), y: spineY - size.height * 0.26,
                           width: X(0.30) - X(0.12), height: size.height * 0.13),
                cornerSize: CGSize(width: 3, height: 3))
            context.fill(bow, with: .color(.secondary.opacity(0.45)))
            // Color.opacity(_:) now resolves to the ShapeStyle overload here
            // (returns `some ShapeStyle`, not Color) — dim via the context
            // copy instead, which is what GraphicsContext opacity is for.
            // UIColor-bridged color: the bare `background` name here hits
            // View.background method overloads instead of a Color property.
            var faded = context
            faded.opacity *= 0.9
            faded.fill(slot, with: .color(Color(uiColor: .systemBackground)))

            let shoulderEnd = bowIn + shoulderIn
            let firstCut = shoulderEnd + 0.08
            var blade = Path()
            blade.move(to: CGPoint(x: X(bowIn) - 4, y: headY))
            blade.addLine(to: CGPoint(x: X(shoulderEnd - 0.05), y: headY))
            blade.addLine(to: CGPoint(x: X(shoulderEnd + 0.03), y: crestY))
            for i in 0..<n {
                let cx = firstCut + Double(i) * spacing
                let rel = (maxDepth - depths[i]) / depthSpan
                let drop = 5 + CGFloat(rel) * maxDrop
                let half = CGFloat(max(system.cutWidthIn ?? 0.09, 0.06)) * CGFloat(scale) / 2
                blade.addLine(to: CGPoint(x: X(cx) - half, y: crestY))
                blade.addLine(to: CGPoint(x: X(cx), y: crestY + drop))
                blade.addLine(to: CGPoint(x: X(cx) + half, y: crestY))
            }
            let lastCut = firstCut + Double(n - 1) * spacing
            blade.addLine(to: CGPoint(x: X(lastCut + 0.10), y: crestY))
            blade.addLine(to: CGPoint(x: X(totalIn), y: crestY + 6))
            blade.addLine(to: CGPoint(x: X(totalIn), y: spineY))
            blade.addLine(to: CGPoint(x: X(bowIn) - 4, y: spineY))
            blade.closeSubpath()
            context.fill(blade, with: .color(.secondary.opacity(0.45)))

            for i in 0..<n {
                let cx = firstCut + Double(i) * spacing
                let digit = system.firstCode + i
                context.draw(
                    Text("\(digit)").font(.system(size: 8, design: .monospaced)),
                    at: CGPoint(x: X(cx), y: spineY + 7))
            }
        }
        .accessibilityLabel(
            "Schematic of \(system.name): \(system.pinCount) cuts at \(String(format: "%.3f", system.spacingIn)) inch spacing"
        )
    }
}
