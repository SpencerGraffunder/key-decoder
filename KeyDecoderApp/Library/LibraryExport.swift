import Foundation
import SwiftData

/// Codable transfer record — one file holds the whole library for backup/restore.
struct KeyRecordExport: Codable {
    var id: UUID
    var label: String
    var notes: String
    var tags: [String]
    var code: String
    var systemID: String
    var systemName: String
    var createdAt: Date
    var photoJPEG: String?
    var correctedJPEG: String?
    var snapshot: KeyMeasurementSnapshot?
}

struct LibraryExportFile: Codable {
    var version: Int
    var exportedAt: Date
    var records: [KeyRecordExport]
}

enum LibraryExport {
    static func makeFile(from records: [KeyRecord]) -> LibraryExportFile {
        LibraryExportFile(
            version: 1,
            exportedAt: Date(),
            records: records.map { record in
                KeyRecordExport(
                    id: record.id,
                    label: record.label,
                    notes: record.notes,
                    tags: record.tags,
                    code: record.code,
                    systemID: record.systemID,
                    systemName: record.systemName,
                    createdAt: record.createdAt,
                    photoJPEG: ImageStore.data(record.photoFile)?.base64EncodedString(),
                    correctedJPEG: ImageStore.data(record.correctedFile)?.base64EncodedString(),
                    snapshot: record.snapshot
                )
            }
        )
    }

    static func encode(_ file: LibraryExportFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    static func decode(_ data: Data) throws -> LibraryExportFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryExportFile.self, from: data)
    }

    static func csv(from records: [KeyRecord]) -> String {
        var lines = ["id,label,tags,type,code,created,notes"]
        let formatter = ISO8601DateFormatter()
        for record in records {
            let fields = [
                record.id.uuidString,
                record.label,
                record.tags.joined(separator: "; "),
                record.systemName,
                record.code,
                formatter.string(from: record.createdAt),
                record.notes.replacingOccurrences(of: "\n", with: " "),
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    struct ImportResult {
        var inserted = 0
        var skipped = 0
    }

    /// Merge-import: existing ids are skipped, images are rewritten to disk.
    @discardableResult
    static func apply(_ file: LibraryExportFile, in context: ModelContext) throws -> ImportResult {
        var result = ImportResult()
        let existing = Set(try context.fetch(FetchDescriptor<KeyRecord>()).map(\.id))
        for exported in file.records {
            guard !existing.contains(exported.id) else {
                result.skipped += 1
                continue
            }
            var photoFile: String?
            var correctedFile: String?
            if let base64 = exported.photoJPEG, let data = Data(base64Encoded: base64) {
                photoFile = ImageStore.write(data, name: exported.id.uuidString + "-original.jpg")
            }
            if let base64 = exported.correctedJPEG, let data = Data(base64Encoded: base64) {
                correctedFile = ImageStore.write(data, name: exported.id.uuidString + "-corrected.jpg")
            }
            let record = KeyRecord(
                id: exported.id,
                label: exported.label,
                notes: exported.notes,
                tags: exported.tags,
                code: exported.code,
                systemID: exported.systemID,
                systemName: exported.systemName,
                createdAt: exported.createdAt,
                photoFile: photoFile,
                correctedFile: correctedFile
            )
            record.snapshot = exported.snapshot
            context.insert(record)
            result.inserted += 1
        }
        try context.save()
        return result
    }

    static func writeTempFile(named name: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
