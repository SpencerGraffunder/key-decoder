import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(Preferences.lockEnabled) private var lockEnabled = false
    @Environment(\.modelContext) private var context
    @Query private var records: [KeyRecord]

    @State private var shareItem: ShareFileItem?
    @State private var showImporter = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Security") {
                    Toggle("Require Face ID / Touch ID", isOn: $lockEnabled)
                        .disabled(!BiometricLock.isAvailable)
                        .accessibilityHint("Locks the app and key library behind device biometrics")
                    if !BiometricLock.isAvailable {
                        Text("No biometrics available on this device (or disabled in Settings), so the lock cannot be enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Saved codes are sensitive — the lock keeps them private on a shared device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Backup") {
                    Button {
                        exportJSON()
                    } label: {
                        Label("Export library (JSON, with photos)", systemImage: "arrow.up.doc")
                    }
                    Button {
                        exportCSV()
                    } label: {
                        Label("Export list (CSV, no photos)", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import JSON backup", systemImage: "arrow.down.doc")
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false
                ) { result in
                    handleImport(result)
                }

                Section("Key systems") {
                    ForEach(KeySystemLibrary.bundled) { system in
                        KeySystemRow(system: system)
                    }
                    Text("Add more keyways by editing Resources/keysystems.json — the app reads them at launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    Text(
                        "Key Decoder is free forever: no ads, no accounts, no network. Photos and codes never leave this device."
                    )
                    .font(.callout)
                    Text(
                        "Use only with keys you own or are authorized to copy."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $shareItem) { item in
                ShareFileSheet(item: item)
            }
        }
    }

    private func exportJSON() {
        do {
            let data = try LibraryExport.encode(LibraryExport.makeFile(from: records))
            shareItem = ShareFileItem(
                name: "keydecoder-library.json",
                url: try LibraryExport.writeTempFile(named: "keydecoder-library.json", data: data)
            )
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        let data = Data(LibraryExport.csv(from: records).utf8)
        do {
            shareItem = ShareFileItem(
                name: "keydecoder-library.csv",
                url: try LibraryExport.writeTempFile(named: "keydecoder-library.csv", data: data)
            )
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            statusMessage = "Import cancelled."
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let file = try LibraryExport.decode(data)
            let outcome = try LibraryExport.apply(file, in: context)
            statusMessage = "Imported \(outcome.inserted) key(s), skipped \(outcome.skipped) already present."
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

struct ShareFileItem: Identifiable {
    let name: String
    let url: URL
    var id: String { name + url.lastPathComponent }
}

struct ShareFileSheet: View {
    let item: ShareFileItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(item.name)
                    .font(.headline)
                ShareLink(item: item.url) {
                    Text("Share \(item.name)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct KeySystemRow: View {
    let system: KeySystemDefinition

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("Depth table (in): \(depthList)")
                    .font(.caption.monospacedDigit())
                ForEach(system.sources, id: \.self) { source in
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let notes = system.notes {
                    Text(notes)
                        .font(.caption2)
                        .italic()
                }
            }
            .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(system.name)
                    Spacer()
                    Text(system.isVerified ? "verified" : "draft")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            system.isVerified ? Color.green.opacity(0.18) : Color.orange.opacity(0.18),
                            in: Capsule()
                        )
                        .foregroundStyle(system.isVerified ? Color.green : Color.orange)
                        .accessibilityLabel(system.isVerified ? "Numbers cross-checked against published specs" : "Single-source numbers — verify before relying on them")
                }
                Text("\(system.pinCount)-pin · depths \(system.firstCode)–\(system.firstCode + system.depthsIn.count - 1) · first cut \(String(format: "%.3f", system.firstCutIn))″ · spacing \(String(format: "%.3f", system.spacingIn))″")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var depthList: String {
        system.depthsIn
            .enumerated()
            .map { "\($0.offset + system.firstCode)=\(String(format: "%.3f", $0.element))" }
            .joined(separator: " ")
    }
}
