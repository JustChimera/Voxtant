import XCTest
@testable import LectureCore

final class SpeechGateTests: XCTestCase {
    func testOnlyFullyCoveredLowSpeechAudioCanBeVetoed() {
        XCTAssertTrue(SpeechGate.shouldSkip(scores: [0.001, 0.02], duration: 2.8, coveredUntil: 3, failed: false))
        XCTAssertFalse(SpeechGate.shouldSkip(scores: [0.001], duration: 2.8, coveredUntil: 2.5, failed: false))
        XCTAssertFalse(SpeechGate.shouldSkip(scores: [0.001], duration: 0.7, coveredUntil: 2, failed: false))
        XCTAssertFalse(SpeechGate.shouldSkip(scores: [0.001], duration: 11, coveredUntil: 12, failed: false))
    }
    func testOneSpeechOrUncertainWindowPreservesTheWholeUtterance() {
        XCTAssertFalse(SpeechGate.shouldSkip(scores: [0, 0.051, 0], duration: 2, coveredUntil: 3, failed: false))
        XCTAssertFalse(SpeechGate.shouldSkip(scores: [SpeechGate.speechThreshold], duration: 2, coveredUntil: 3, failed: false))
    }
    func testMissingFailedAndInvalidAnalysisAlwaysPassesThrough() async {
        for scores in [[], [-1], [Double.nan], [Double.infinity]] {
            XCTAssertFalse(SpeechGate.shouldSkip(scores: scores, duration: 2, coveredUntil: 3, failed: false))
        }
        XCTAssertFalse(SpeechGate.shouldSkip(scores: [0], duration: 2, coveredUntil: 3, failed: true))
        let result = await SpeechGate.inspect(file: URL(fileURLWithPath: "/nonexistent/voxtant-test.wav"))
        XCTAssertFalse(result.skipASR)
        XCTAssertEqual(result.reason, "unavailable-pass-through")
    }
}
