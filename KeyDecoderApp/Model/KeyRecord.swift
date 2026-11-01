import Foundation
import SwiftData

/// A saved key. Photos live on disk (ImageStore); this record references them.
@Model
final class KeyRecord {
    @Attribute(.unique) var id: UUID
    var label: String
    var notes: String
    var tags: [String]
    var code: String
    var systemID: String
    var systemName: String
    var createdAt: Date
    var photoFile: String?
    var correctedFile: String?
    var snapshotJSON: String?

    init(
        id: UUID = UUID(),
        label: String,
        notes: String = "",
        tags: [String] = [],
        code: String,
        systemID: String,
        systemName: String,
        createdAt: Date = .now,
        photoFile: String? = nil,
        correctedFile: String? = nil,
        snapshotJSON: String? = nil
    ) {
        self.id = id
        self.label = label
        self.notes = notes
        self.tags = tags
        self.code = code
        self.systemID = systemID
        self.systemName = systemName
        self.createdAt = createdAt
        self.photoFile = photoFile
        self.correctedFile = correctedFile
        self.snapshotJSON = snapshotJSON
    }

    var snapshot: KeyMeasurementSnapshot? {
        get {
            guard let snapshotJSON, let data = snapshotJSON.data(using: .utf8) else { return nil }
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy =
                .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            return try? decoder.decode(KeyMeasurementSnapshot.self, from: data)
        }
        set {
            guard let snapshot = newValue else {
                snapshotJSON = nil
                return
            }
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy =
                .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            guard let data = try? encoder.encode(snapshot) else {
                snapshotJSON = nil
                return
            }
            snapshotJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

/// What a decode produced — stored with the record so the detail screen can show
/// per-cut measurements even if key-system tables change later.
struct KeyMeasurementSnapshot: Codable, Equatable {
    struct Cut: Codable, Equatable, Identifiable {
        var id: Int { index }
        let index: Int
        let depthIn: Double
        let digit: Int
        let marginSteps: Double
        let outOfTable: Bool
        let lowConfidence: Bool
        let isManualOverride: Bool
    }

    let systemID: String
    let systemName: String
    let code: String
    let cuts: [Cut]
    let warnings: [String]
    let pixelsPerMm: Double

    init(
        result: CutScanResult, systemName: String,
        warnings: [String], pixelsPerMm: Double
    ) {
        self.systemID = result.params.systemID
        self.systemName = systemName
        self.code = result.codeString
        self.cuts = result.cuts.map {
            Cut(
                index: $0.index, depthIn: $0.depthIn, digit: $0.digit,
                marginSteps: $0.marginSteps, outOfTable: $0.outOfTable,
                lowConfidence: $0.lowConfidence, isManualOverride: $0.isManualOverride
            )
        }
        self.warnings = warnings
        self.pixelsPerMm = pixelsPerMm
    }

    init(
        systemID: String, systemName: String, code: String,
        cuts: [Cut], warnings: [String], pixelsPerMm: Double
    ) {
        self.systemID = systemID
        self.systemName = systemName
        self.code = code
        self.cuts = cuts
        self.warnings = warnings
        self.pixelsPerMm = pixelsPerMm
    }
}
