import SwiftData
import KeyCore
import SwiftUI

struct DetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let record: KeyRecord

    @State private var showDeleteConfirm = false
    @State private var shareImageURL: URL?

    private var photo: UIImage? {
        ImageStore.image(record.correctedFile ?? record.photoFile)
    }

    private var originalPhoto: UIImage? {
        ImageStore.image(record.photoFile)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                photoView
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(alignment: .firstTextBaseline) {
                    Text(record.code)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = record.code
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy code")
                }
                Text(record.systemName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let snapshot = record.snapshot, !snapshot.cuts.isEmpty {
                    cutTable(snapshot)
                }

                editableFields

                shareSection

                Text("Saved \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(record.label.isEmpty ? "Key" : record.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete", role: .destructive) { showDeleteConfirm = true }
            }
        }
        .confirmationDialog(
            "Delete this key? Its photos will be removed from this device.",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
        }
    }

    @ViewBuilder
    private var photoView: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "key.horizontal")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cutTable(_ snapshot: KeyMeasurementSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Measured cuts")
                .font(.headline)
            ForEach(snapshot.cuts) { cut in
                HStack {
                    Text("Cut \(cut.index + 1)")
                        .font(.body.monospacedDigit())
                    Spacer()
                    Text(String(format: "%.3f in", cut.depthIn))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("→ \(cut.digit)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    if cut.isManualOverride {
                        Image(systemName: "hand.draw")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Manually set")
                    } else if cut.outOfTable {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Out-of-table measurement")
                    } else if cut.lowConfidence {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Low confidence")
                    }
                }
                .font(.callout)
            }
            if !snapshot.warnings.isEmpty {
                Text(snapshot.warnings.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var editableFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Label", text: binding(\.label))
                .textFieldStyle(.roundedBorder)
            TextField("Tags (comma separated)", text: tagsBinding)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityLabel("Tags, separated by commas")
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: binding(\.notes))
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onChange(of: record.label) { _, _ in try? context.save() }
        .onChange(of: record.notes) { _, _ in try? context.save() }
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share")
                .font(.headline)
            HStack {
                ShareLink(
                    item: shareText,
                    subject: Text("\(record.label) — key code")
                ) {
                    Label("Text", systemImage: "text.badge.plus")
                }
                if let shareImageURL {
                    ShareLink(item: shareImageURL) {
                        Label("Photo", systemImage: "photo")
                    }
                }
            }
        }
        .task(id: record.id) { prepareShareImage() }
    }

    private var shareText: String {
        var lines = [
            record.label.isEmpty ? "Key" : record.label,
            "\(record.systemName): \(record.code)",
        ]
        if let snapshot = record.snapshot {
            let depths = snapshot.cuts
                .map { String(format: "%.3f", $0.depthIn) }
                .joined(separator: " / ")
            if !depths.isEmpty { lines.append("Depths (in): \(depths)") }
        }
        if !record.notes.isEmpty { lines.append(record.notes) }
        lines.append("Tags: \(record.tags.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    private func prepareShareImage() {
        guard let photo, let data = photo.jpegData(compressionQuality: 0.85) else { return }
        shareImageURL = try? LibraryExport.writeTempFile(
            named: (record.label.isEmpty ? "key" : record.label) + ".jpg", data: data
        )
    }

    private func delete() {
        ImageStore.delete(record.photoFile)
        ImageStore.delete(record.correctedFile)
        context.delete(record)
        try? context.save()
        dismiss()
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<KeyRecord, String>) -> Binding<String> {
        Binding(
            get: { record[keyPath: keyPath] },
            set: { record[keyPath: keyPath] = $0 }
        )
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { record.tags.joined(separator: ", ") },
            set: { text in
                record.tags = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
