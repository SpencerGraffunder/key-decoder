import XCTest
@testable import KeyCore

final class KeySystemTests: XCTestCase {
    func testBowStampMatcher() throws {
        let systems = KeySystemLibrary.bundled
        XCTAssertEqual(BowStamp.match(texts: ["KWKSET"], in: systems)?.system.id, "kw1")
        XCTAssertEqual(BowStamp.match(texts: [" KW-1 "], in: systems)?.system.id, "kw1",
                       "punctuation and case must be normalized away")
        XCTAssertEqual(BowStamp.match(texts: ["SCHLAGE"], in: systems)?.system.id, "sc1")
        XCTAssertNil(BowStamp.match(texts: ["sc", "1"], in: systems),
                     "fragments must not match")
        // Tie-break goes to the earlier candidate; one distinct text = one hit.
        let tie = BowStamp.match(texts: ["KW1", "SCHLAGE"], in: systems)
        XCTAssertEqual(tie?.system.id, "kw1")
        XCTAssertEqual(tie?.hits, 1)
        XCTAssertNil(BowStamp.match(texts: ["nothing here"], in: systems))
    }

    func testApplyStampPromotesMatchedSystem() throws {
        let systems = KeySystemLibrary.bundled
        guard let kw1 = KeySystemLibrary.system(id: "kw1", in: systems),
              let sc1 = KeySystemLibrary.system(id: "sc1", in: systems) else {
            return XCTFail("bundled systems missing")
        }
        let base = [
            SystemSuggestion(system: sc1, score: 0.01, detectedSpacingIn: 0.156, detectedCutCount: 6),
            SystemSuggestion(system: kw1, score: 0.02, detectedSpacingIn: 0.156, detectedCutCount: 6),
        ]
        let out = SystemSuggester.applyStamp(texts: ["KW1"], candidates: systems, to: base)
        XCTAssertEqual(out.first?.system.id, "kw1", "stamped system must lead regardless of fit")
        XCTAssertTrue(out.first?.reason?.contains("stamped") ?? false)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.last?.system.id, "sc1")
        XCTAssertEqual(SystemSuggester.applyStamp(texts: ["nothing here"], candidates: systems, to: base),
                       base, "no match must leave suggestions untouched")
    }

    func testBundledDefinitionsLoad() throws {
        let systems = KeySystemLibrary.bundled
        XCTAssertFalse(systems.isEmpty, "keysystems.json must ship in the KeyCore bundle")
        XCTAssertNotNil(KeySystemLibrary.system(id: "kw1", in: systems))
        XCTAssertNotNil(KeySystemLibrary.system(id: "sc1", in: systems))
        XCTAssertEqual(KeySystemLibrary.defaultCandidates(in: systems).count,
                       systems.filter { $0.isVerified }.count)
    }

    func testKW1Numbers() throws {
        let kw1 = try XCTUnwrap(KeySystemLibrary.system(id: "kw1", in: KeySystemLibrary.bundled))
        XCTAssertEqual(kw1.pinCount, 5)
        XCTAssertEqual(kw1.firstCode, 1)
        XCTAssertEqual(kw1.digitRange, 1..<7)
        XCTAssertEqual(kw1.firstCutIn, 0.247, accuracy: 1e-9)
        XCTAssertEqual(kw1.spacingIn, 0.150, accuracy: 1e-9)
        XCTAssertEqual(kw1.incrementIn, 0.023, accuracy: 1e-9)
        XCTAssertEqual(kw1.depthsIn, [0.329, 0.306, 0.283, 0.260, 0.237, 0.214])
        XCTAssertEqual(kw1.alignment, .shoulder)
        XCTAssertEqual(kw1.macs, 4)
    }

    func testSC1Numbers() throws {
        let sc1 = try XCTUnwrap(KeySystemLibrary.system(id: "sc1", in: KeySystemLibrary.bundled))
        XCTAssertEqual(sc1.pinCount, 5)
        XCTAssertEqual(sc1.firstCode, 0)
        XCTAssertEqual(sc1.firstCutIn, 0.231, accuracy: 1e-9)
        XCTAssertEqual(sc1.spacingIn, 0.156, accuracy: 1e-9)
        XCTAssertEqual(sc1.incrementIn, 0.015, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(sc1.depthsIn.first), 0.335, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(sc1.depthsIn.last), 0.200, accuracy: 1e-9)
        let sc1p6 = try XCTUnwrap(KeySystemLibrary.system(id: "sc1-6p", in: KeySystemLibrary.bundled))
        XCTAssertEqual(sc1p6.pinCount, 6)
        XCTAssertEqual(sc1p6.depthsIn, sc1.depthsIn)
    }

    func testDepthLookupExact() throws {
        let kw1 = try XCTUnwrap(KeySystemLibrary.system(id: "kw1", in: KeySystemLibrary.bundled))
        let hit = kw1.lookup(depthIn: 0.283)
        XCTAssertEqual(hit.digit, 3)
        XCTAssertEqual(hit.marginSteps, 0, accuracy: 1e-9)
        XCTAssertFalse(hit.nearBoundary)
        XCTAssertFalse(hit.outOfTable)
    }

    /// A measurement 0.39 increments off its nearest table entry sits in the
    /// flagged boundary zone (docs/ALGORITHM.md §4).
    func testDepthLookupNearBoundary() throws {
        let kw1 = try XCTUnwrap(KeySystemLibrary.system(id: "kw1", in: KeySystemLibrary.bundled))
        let near = kw1.lookup(depthIn: 0.320) // between 1 (.329) and 2 (.306)
        XCTAssertEqual(near.digit, 1)
        XCTAssertGreaterThan(near.marginSteps, 0.35)
        XCTAssertLessThanOrEqual(near.marginSteps, 0.5)
        XCTAssertTrue(near.nearBoundary)
        XCTAssertFalse(near.outOfTable)
    }

    func testDepthLookupExactlyMidStepIsFlaggedNotOutside() throws {
        let kw1 = try XCTUnwrap(KeySystemLibrary.system(id: "kw1", in: KeySystemLibrary.bundled))
        let mid = kw1.lookup(depthIn: (0.329 + 0.306) / 2)
        XCTAssertEqual(mid.marginSteps, 0.5, accuracy: 1e-9)
        XCTAssertFalse(mid.outOfTable, "0.5 is not > 0.5")
        XCTAssertTrue(mid.nearBoundary)
    }

    func testDepthLookupOutOfTable() throws {
        let sc1 = try XCTUnwrap(KeySystemLibrary.system(id: "sc1", in: KeySystemLibrary.bundled))
        let bad = sc1.lookup(depthIn: 0.400)
        XCTAssertEqual(bad.digit, 0, "nearest entry is still reported")
        XCTAssertGreaterThan(bad.marginSteps, 0.5)
        XCTAssertTrue(bad.outOfTable)
    }

    func testDraftSystemsExistForFutureUse() {
        let systems = KeySystemLibrary.bundled
        for id in ["yale-y114", "sargent-r6", "arrow-b", "master-standard"] {
            let system = KeySystemLibrary.system(id: id, in: systems)
            XCTAssertNotNil(system, "\(id) should be present (draft status)")
            if let system { XCTAssertFalse(system.isVerified) }
        }
    }

    func testJSONRoundTrip() throws {
        let systems = KeySystemLibrary.bundled
        let file = KeySystemFile(schemaVersion: 1, systems: systems)
        let data = try JSONEncoder().encode(file)
        let decoded = try KeySystemLibrary.decode(data)
        XCTAssertEqual(decoded, systems)
    }
}
