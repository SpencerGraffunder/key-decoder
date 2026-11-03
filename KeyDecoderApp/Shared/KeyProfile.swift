import SwiftUI
import KeyCore

/// A black-and-white vector silhouette of the blade a code would cut: metal
/// on top, sawtooth bitting edge below — one V per cut, peaks between cuts,
/// exactly like the blank coming off a code cutter. Data-driven from the key
/// system's depth table; nothing is drawn from a photo.
struct KeyProfileShape: Shape {
    /// Depth digits, cut 1 (bow side) first.
    let digits: [Int]
    let system: KeySystemDefinition

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard !digits.isEmpty, let dminRaw = system.depthsIn.min(),
              let dmaxRaw = system.depthsIn.max() else { return p }
        let dmin = dminRaw, dmax = max(dmaxRaw, dminRaw + 1e-6)
        let span = dmax - dmin
        func depth(of digit: Int) -> Double { system.depth(digit: digit) ?? dmin }

        // Vertical layout: a solid metal strip up top; the cut edge occupies
        // the band from edgeTop (shallowest cut) down to edgeBottom (deepest).
        let top = rect.minY + rect.height * 0.05
        let edgeTop = rect.minY + rect.height * 0.28
        let edgeBottom = rect.maxY - rect.height * 0.05
        func y(_ d: Double) -> CGFloat {
            edgeTop + CGFloat((d - dmin) / span) * (edgeBottom - edgeTop)
        }

        // Horizontal layout: shoulder at the left, cuts evenly spaced toward
        // the tip; the last cut sits slightly before the tip end.
        let n = digits.count
        let xSh = rect.minX + rect.width * 0.16
        let xTip = rect.maxX - rect.width * 0.02
        func x(_ i: Int) -> CGFloat {
            n == 1 ? (xSh + xTip) / 2 : xSh + (xTip - xSh) * CGFloat(i) / CGFloat(n - 1)
        }

        p.move(to: CGPoint(x: rect.minX, y: top))
        p.addLine(to: CGPoint(x: xTip, y: top))
        // Tip edge drops to the last cut's depth.
        p.addLine(to: CGPoint(x: xTip, y: y(depth(of: digits[n - 1]))))
        // Sawtooth back toward the shoulder: V at each cut, peak (the
        // shallower of the neighbouring cuts) between them.
        for i in stride(from: n - 1, through: 0, by: -1) {
            p.addLine(to: CGPoint(x: x(i), y: y(depth(of: digits[i]))))
            if i > 0 {
                let shallow = min(depth(of: digits[i - 1]), depth(of: digits[i]))
                p.addLine(to: CGPoint(x: (x(i) + x(i - 1)) / 2, y: y(shallow)))
            }
        }
        // Shoulder edge straight up and close along the top face.
        p.addLine(to: CGPoint(x: rect.minX, y: y(depth(of: digits[0]))))
        p.closeSubpath()
        return p
    }
}

/// Card showing the profile plus a caption. Hidden unless digits + a known
/// system are available.
struct KeyProfilePreview: View {
    let digits: [Int]
    let system: KeySystemDefinition?

    var body: some View {
        if let system, !digits.isEmpty {
            VStack(spacing: 4) {
                KeyProfileShape(digits: digits, system: system)
                    .fill(Color.black)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                    )
                    .accessibilityLabel(
                        "Illustration of a key cut with code \(digits.map(String.init).joined(separator: ", "))"
                    )
                Text("What a key cut with this code looks like")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(max(2.0, 0.6 + 0.42 * CGFloat(digits.count)), contentMode: .fit)
        }
    }
}
