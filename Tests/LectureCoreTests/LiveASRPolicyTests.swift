import XCTest
@testable import LectureCore

final class LiveASRPolicyTests: XCTestCase {
    func testDelayedRetriesDoNotBlockFreshAudioAndRunWhenNotLive() {
        let statuses: [SegmentStatus] = [.queued, .queued, .queued]
        let deferred: Set<Int> = [0, 1]
        XCTAssertEqual(LiveASRPolicy.nextIndex(statuses: statuses, deferred: deferred, live: true), 2)
        XCTAssertNil(LiveASRPolicy.nextIndex(statuses: [.queued, .queued], deferred: deferred, live: true, activeWorkers: 1, recovering: true))
        XCTAssertEqual(LiveASRPolicy.nextIndex(statuses: [.queued, .queued], deferred: deferred, live: true), 0)
        XCTAssertEqual(LiveASRPolicy.nextIndex(statuses: statuses, deferred: deferred, live: true, activeWorkers: 1, recovering: true), 2)
        XCTAssertEqual(LiveASRPolicy.nextIndex(statuses: [.queued, .queued], deferred: deferred, live: false), 0)
    }

    func testTotalAttemptsRemainBoundedAndFilePolicyIsUnchanged() {
        let live = LiveASRPolicy.retryPolicy(microphoneSession: true, deferred: false)
        let recovery = LiveASRPolicy.retryPolicy(microphoneSession: true, deferred: true)
        XCTAssertEqual(live.timeoutSeconds, 8)
        XCTAssertEqual(live.budgetSeconds, live.timeoutSeconds)
        XCTAssertEqual(live.maximumAttempts, 1)
        XCTAssertEqual(recovery.timeoutSeconds, 8)
        XCTAssertEqual(live.maximumAttempts + recovery.maximumAttempts, 3)
        XCTAssertEqual(LiveASRPolicy.retryPolicy(microphoneSession: false, deferred: false).maximumAttempts, 3)
    }

    func testExplicitMicrophoneRetryKeepsItsSessionAttemptBudget() {
        // An explicit retry retains its original microphone source. Stop itself cancels work.
        let explicitRetry = LiveASRPolicy.retryPolicy(microphoneSession: true, deferred: false)
        let recovery = LiveASRPolicy.retryPolicy(microphoneSession: true, deferred: true)
        XCTAssertEqual(explicitRetry.maximumAttempts, 1)
        XCTAssertEqual(explicitRetry.maximumAttempts + recovery.maximumAttempts, 3)
        XCTAssertEqual(LiveASRPolicy.retryPolicy(microphoneSession: false, deferred: false).maximumAttempts, 3)
    }

    func testAuthenticationRateLimitsAndRetryAfterAreNeverSilentlyDeferred() {
        var attempt = RequestAttempt(stage: "asr", model: "test", number: 1, seconds: 4)
        XCTAssertTrue(LiveASRPolicy.canDefer(APIRequestFailure(message: "timeout", attempts: [attempt])))
        for status in [400, 401, 402, 403, 429, 200] {
            attempt.status = status
            XCTAssertFalse(LiveASRPolicy.canDefer(APIRequestFailure(message: "error", attempts: [attempt])))
        }
        attempt.status = 503; attempt.retryAfterSeconds = 60
        XCTAssertFalse(LiveASRPolicy.canDefer(APIRequestFailure(message: "wait", attempts: [attempt])))
    }
}
