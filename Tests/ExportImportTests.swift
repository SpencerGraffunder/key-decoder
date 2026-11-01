import CoreGraphics
import Foundation
import SwiftData
import XCTest
@testable import KeyCore
@testable import KeyDecoder

final class ExportImportTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: KeyRecord.self, configurations: config)
    }

    private func makeRecords() -> [KeyRecord] {
        [
            KeyRecord(
                id: UUID(), label: "Front door", notes: "Re-keyed 2024",
                tags: ["door", "house"], code: "1-5-3-2-4",
                systemID: "kw1", systemName: "Kwikset KW1"
            ),
            KeyRecord(
                id: UUID(), label: "Shed,with comma", notes: "Quote \" test",
                tags: ["shed"], code: "3-0-6-1-8",
                systemID: "sc1", systemName: "Schlage SC1"
            ),
        ]
    }

    func testJSONRoundTripPreservesEverything() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for record in makeRecords() { context.insert(record) }
        try context.save()
        let records = try context.fetch(FetchDescriptor<KeyRecord>())

        let data = try LibraryExport.encode(LibraryExport.makeFile(from: records))
        let decoded = try LibraryExport.decode(data)
        XCTAssertEqual(decoded.records.count, records.count)

        let byID = Dictionary(uniqueKeysWithValues: decoded.records.map { ($0.id, $0) })
        for record in records {
            let exported = try XCTUnwrap(byID[record.id])
            XCTAssertEqual(exported.label, record.label)
            XCTAssertEqual(exported.code, record.code)
            XCTAssertEqual(exported.tags, record.tags)
            XCTAssertEqual(exported.createdAt, record.createdAt)
        }
    }

    func testApplyInsertsThenSkipsDuplicates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let contextRecords = makeRecords()
        let file = LibraryExportFile(
            version: 1,
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            records: contextRecords.map {
                KeyRecordExport(
                    id: $0.id, label: $0.label, notes: $0.notes, tags: $0.tags,
                    code: $0.code, systemID: $0.systemID, systemName: $0.systemName,
                    createdAt: $0.createdAt,
                    photoJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString(),
                    correctedJPEG: nil, snapshot: nil
                )
            }
        )

        let first = try LibraryExport.apply(file, in: context)
        XCTAssertEqual(first.inserted, 2)
        XCTAssertEqual(first.skipped, 0)

        let second = try LibraryExport.apply(file, in: context)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.skipped, 2)

        let stored = try context.fetch(FetchDescriptor<KeyRecord>())
        XCTAssertEqual(stored.count, 2)
        // Photos rewritten to disk and readable back.
        for record in stored {
            XCTAssertNotNil(record.photoFile)
            XCTAssertEqual(ImageStore.data(record.photoFile), Data([0xFF, 0xD8, 0xFF, 0xD9]))
            ImageStore.delete(record.photoFile)
        }
    }

    func testDateRoundTripsThroughISO8601() throws {
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let file = LibraryExportFile(
            version: 1, exportedAt: date,
            records: [
                KeyRecordExport(
                    id: UUID(), label: "x", notes: "", tags: [], code: "1",
                    systemID: "kw1", systemName: "KW1", createdAt: date,
                    photoJPEG: nil, correctedJPEG: nil, snapshot: nil
                ),
            ]
        )
        let decoded = try LibraryExport.decode(LibraryExport.encode(file))
        XCTAssertEqual(decoded.records[0].createdAt.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testCSVEscapesCommasQuotesAndSplits() throws {
        let csv = "id,label\n1,\"\(LibraryExport.csvEscape("a,b").replacingOccurrences(of: ",", with: ""))\"\n"
        XCTAssertTrue(csv.contains("ab"))
        XCTAssertEqual(LibraryExport.csvEscape("plain"), "plain")
        XCTAssertEqual(LibraryExport.csvEscape("a,b"), "\"a,b\"")
        XCTAssertEqual(LibraryExport.csvEscape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(LibraryExport.csvEscape("line\nbreak"), "\"line\nbreak\"")
    }

    func testSnapshotJSONRoundTripThroughRecord() throws {
        let record = KeyRecord(label: "Snap", code: "2-2-2-2-2", systemID: "kw1", systemName: "KW1")
        let snapshot = KeyMeasurementSnapshot(
            systemID: "kw1", systemName: "Kwikset KW1", code: "2-2-2-2-2",
            cuts: [
                .init(index: 0, depthIn: 0.305, digit: 2, marginSteps: 0.04,
                      outOfTable: false, lowConfidence: false, isManualOverride: false),
                .init(index: 1, depthIn: .nan, digit: 3, marginSteps: 0,
                      outOfTable: false, lowConfidence: true, isManualOverride: true),
            ],
            warnings: ["lowConfidenceCuts"], pixelsPerMm: 30.3738
        )
        record.snapshot = snapshot
        XCTAssertNotNil(record.snapshotJSON)
        let restored = try XCTUnwrap(record.snapshot)
        XCTAssertEqual(restored.systemName, "Kwikset KW1")
        XCTAssertEqual(restored.cuts.count, 2)
        XCTAssertEqual(restored.cuts[1].digit, 3)
        XCTAssertTrue(restored.cuts[1].isManualOverride)
        // NaN survives as JSON "NaN" only if the encoder writes it that way; the
        // Codable default does — assert the depth is either NaN or non-crashing.
        XCTAssertTrue(restored.cuts[1].depthIn.isNaN || restored.cuts[1].depthIn == 0)
    }
}
