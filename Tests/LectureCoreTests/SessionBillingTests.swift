import XCTest
@testable import LectureCore

final class SessionBillingTests: XCTestCase {
    func testCBRParserUsesUSDNominalAndDatedRate() throws {
        let xml = "<ValCurs Date=\"03.11.2026\"><Valute><CharCode>EUR</CharCode><Nominal>1</Nominal><Value>99,0</Value></Valute><Valute><CharCode>USD</CharCode><Nominal>10</Nominal><Value>900,1250</Value></Valute></ValCurs>"
        let rate = try USDRUBRate.parse(Data(xml.utf8))
        XCTAssertEqual(rate.rublesPerUSD, 90.0125)
        XCTAssertEqual(rate.effectiveDate, "03.11.2026")
        XCTAssertThrowsError(try USDRUBRate.parse(Data("<ValCurs/>".utf8)))
        XCTAssertThrowsError(try USDRUBRate.parse(Data(xml.replacingOccurrences(of: "900,1250", with: "bad").utf8)))
    }
    func testCostsCountAttemptsOnceAndIncludeRetries() {
        var segment = cell(); segment.status = .complete; segment.transcript = "hello"
        segment.asrCost = 0.01; segment.translationCost = 0.02
        segment.attempts = [RequestAttempt(stage: "asr", model: "test", number: 1, seconds: 1, cost: 0.01),
            RequestAttempt(stage: "translation", model: "test", number: 1, seconds: 1, cost: 0.02),
            RequestAttempt(stage: "translation", model: "test", number: 2, seconds: 1, cost: 0.03)]
        let cost = SessionCostSummary(segments: [segment], rate: USDRUBRate(rublesPerUSD: 90, effectiveDate: "03.11.2026"))
        XCTAssertEqual(cost.reportedUSD, 0.06, accuracy: 0.00001)
        XCTAssertEqual(cost.approximateRUB!, 5.4, accuracy: 0.00001)
        XCTAssertTrue(cost.isComplete)
    }
    func testCancelledOrUnpricedRequestsNeverBecomeACompleteBill() {
        var segment = cell(); segment.status = .complete; segment.asrCost = 0.01
        segment.translationMode = "cancelled-by-user"
        let cost = SessionCostSummary(segments: [segment], rate: nil)
        XCTAssertFalse(cost.isComplete)
        XCTAssertTrue(cost.compactLabel.hasPrefix("от "))
        XCTAssertNil(cost.approximateRUB)
        segment.asrCost = nil
        XCTAssertEqual(SessionCostSummary(segments: [segment], rate: nil).compactLabel, "$— · ₽—")
    }
    func testLocalNoiseAndEmptyASRHaveNoTranslationCharge() {
        var segment = cell(); segment.status = .complete; segment.asrCost = 0
        segment.translationMode = "local-nonspeech-v1"; segment.translationCost = 0
        let local = SessionCostSummary(segments: [segment], rate: nil)
        XCTAssertEqual(local.reportedUSD, 0); XCTAssertTrue(local.isComplete)
        segment.translationCost = nil
        XCTAssertTrue(SessionCostSummary(segments: [segment], rate: nil).isComplete)
    }
    func testRecordingFoldersRespectLocalDateAndAreUnique() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = ISO8601DateFormatter().date(from: "2026-11-02T20:00:00Z")!
        let first = try RecordingLibrary.createSession(root: root, date: date, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let second = try RecordingLibrary.createSession(root: root, date: date, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "2026-11-03")
        XCTAssertTrue(first.lastPathComponent.hasPrefix("04-00-00_"))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("chunks").path))
    }
    private func cell() -> Segment { Segment(id: 0, start: 0, end: 1, file: "chunk.wav", capturedAt: Date(), asrModel: "test", translationModel: "test") }
}
