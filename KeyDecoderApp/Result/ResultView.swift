import SwiftData
import SwiftUI
import KeyCore

/// Result + save: code, per-cut measurements, label/tags/notes, on-device storage.
struct ResultView: View {
    let flow: DecodeFlow

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var tagsText = ""
    @State private var notes = ""

    private var system: KeySystemDefinition? { flow.currentSystem }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                if let image = flow.correctedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                summary
                fields
                Button(action: save) {
                    Text("Save to library").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("Everything stays on this device — no accounts, no network, no analytics.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding()
        }
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { flow.step = .review }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            Text(flow.effectiveCode)
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if let system {
                Text(system.name + (system.isVerified ? "" : " (draft numbers)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let result = flow.result {
                let uncertain = result.cuts.filter { $0.lowConfidence || $0.outOfTable }.count
                if uncertain > 0 {
                    Label(
                        "Some cuts are uncertain — verify depths before trusting this code as certain.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                } else {
                    Label("All cuts matched the depth table confidently.", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var summary: some View {
        if let result = flow.result, !result.cuts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cuts")
                    .font(.headline)
                ForEach(result.cuts) { cut in
                    HStack {
                        Text("Cut \(cut.index + 1)")
                        Spacer()
                        if !cut.depthIn.isNaN {
                            Text(String(format: "%.3f″", cut.depthIn))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text("→ \(cut.digit)")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Label (e.g. Front door)", text: $label)
                .textFieldStyle(.roundedBorder)
            TextField("Tags (comma separated)", text: $tagsText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .frame(minHeight: 70)
                    .padding(6)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func save() {
        guard let system else { dismiss(); return }
        let code = flow.effectiveCode
        let cuts: [KeyMeasurementSnapshot.Cut]
        let warnings: [String]
        let pixelsPerMm: Double
        if let result = flow.result {
            cuts = result.cuts.map {
                KeyMeasurementSnapshot.Cut(
                    index: $0.index, depthIn: $0.depthIn, digit: $0.digit,
                    marginSteps: $0.marginSteps, outOfTable: $0.outOfTable,
                    lowConfidence: $0.lowConfidence, isManualOverride: $0.isManualOverride
                )
            }
            warnings = flow.warnings.map(\.rawValue)
            pixelsPerMm = flow.pixelsPerMm
        } else {
            cuts = flow.manualSnapshotCuts
            warnings = ["manual-entry"]
            pixelsPerMm = flow.pixelsPerMm
        }
        let snapshot = KeyMeasurementSnapshot(
            systemID: system.id, systemName: system.name,
            code: code, cuts: cuts, warnings: warnings, pixelsPerMm: pixelsPerMm
        )
        let record = KeyRecord(
            label: trimmed(label) ?? defaultLabel(system: system, code: code),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: parseTags(tagsText),
            code: code,
            systemID: system.id,
            systemName: system.name,
            photoFile: flow.photo.flatMap { ImageStore.save($0) },
            correctedFile: flow.correctedImage.flatMap { ImageStore.save($0) }
        )
        record.snapshot = snapshot
        context.insert(record)
        try? context.save()
        dismiss()
    }

    private func trimmed(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func defaultLabel(system: KeySystemDefinition, code: String) -> String {
        "\(system.name) \(code)"
    }

    private func parseTags(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
