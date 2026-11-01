import SwiftData
import SwiftUI

struct LibraryView: View {
    @Query(sort: \KeyRecord.createdAt, order: .reverse) private var records: [KeyRecord]
    @State private var search = ""
    @State private var systemFilter: String?
    @State private var tagFilter: String?
    @AppStorage(Preferences.gridView) private var gridView = true
    @State private var showDecode = false

    private var availableSystems: [String] {
        Array(Set(records.map(\.systemName))).sorted()
    }

    private var availableTags: [String] {
        Array(Set(records.flatMap(\.tags))).sorted()
    }

    private var filtered: [KeyRecord] {
        records.filter { record in
            (systemFilter == nil || record.systemName == systemFilter)
                && (tagFilter == nil || record.tags.contains(tagFilter ?? ""))
                && (
                    search.isEmpty
                        || record.label.localizedCaseInsensitiveContains(search)
                        || record.code.localizedCaseInsensitiveContains(search)
                        || record.tags.contains { $0.localizedCaseInsensitiveContains(search) }
                )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label("No keys yet", systemImage: "key.horizontal")
                    } description: {
                        Text("Photograph a key lying on an ID or credit card to decode its bitting code.")
                    } actions: {
                        Button("Decode a key") { showDecode = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if gridView {
                    grid
                } else {
                    list
                }
            }
            .navigationTitle("My Keys")
            .searchable(text: $search, prompt: "Label, tag, or code")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Type", selection: $systemFilter) {
                            Text("All types").tag(String?.none)
                            ForEach(availableSystems, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        Picker("Tag", selection: $tagFilter) {
                            Text("All tags").tag(String?.none)
                            ForEach(availableTags, id: \.self) { tag in
                                Text(tag).tag(String?.some(tag))
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter keys by type or tag")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        gridView.toggle()
                    } label: {
                        Image(systemName: gridView ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityLabel(gridView ? "Switch to list view" : "Switch to grid view")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDecode = true
                    } label: {
                        Image(systemName: "camera")
                    }
                    .accessibilityLabel("Decode a new key")
                }
            }
            .navigationDestination(for: KeyRecord.self) { record in
                DetailView(record: record)
            }
            .sheet(isPresented: $showDecode) {
                DecodeFlowView()
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                spacing: 12
            ) {
                ForEach(filtered) { record in
                    NavigationLink(value: record) {
                        KeyTile(record: record)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private var list: some View {
        List {
            ForEach(filtered) { record in
                NavigationLink(value: record) {
                    KeyRow(record: record)
                }
            }
        }
    }
}

struct KeyTile: View {
    let record: KeyRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(record.label.isEmpty ? "Untitled key" : record.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("\(record.systemName) · \(record.code)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    var thumbnail: some View {
        Group {
            if let image = ImageStore.image(record.correctedFile ?? record.photoFile) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "key.horizontal")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct KeyRow: View {
    let record: KeyRecord

    var body: some View {
        HStack(spacing: 12) {
            KeyTile(record: record).thumbnail
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label.isEmpty ? "Untitled key" : record.label)
                    .font(.body.weight(.medium))
                Text("\(record.systemName) · \(record.code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
