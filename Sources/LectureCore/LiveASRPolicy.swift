import Foundation

/// New live audio has priority. At most one idle-slot recovery uses the same saved WAV.
public enum LiveASRPolicy {
    public static func nextIndex(statuses: [SegmentStatus], deferred: Set<Int>, live: Bool, activeWorkers: Int = 0, recovering: Bool = false) -> Int? {
        if let fresh = statuses.indices.first(where: { statuses[$0] == .queued && !deferred.contains($0) }) { return fresh }
        if live && (activeWorkers > 0 || recovering) { return nil }
        return statuses.indices.first(where: { statuses[$0] == .queued })
    }

    public static func retryPolicy(microphoneSession: Bool, deferred: Bool) -> RetryPolicy {
        if microphoneSession && !deferred {
            // A short client deadline does not accelerate provider inference.
            var policy = RetryPolicy(maximumAttempts: 1)
            policy.timeoutSeconds = 8
            policy.budgetSeconds = 8
            return policy
        }
        return RetryPolicy(maximumAttempts: deferred ? 2 : 3)
    }

    public static func canDefer(_ failure: APIRequestFailure) -> Bool {
        guard let last = failure.attempts.last, last.retryAfterSeconds == nil else { return false }
        // Explicit rate limits/auth errors remain visible; never bypass Retry-After.
        guard let status = last.status else { return true }
        return [408, 500, 502, 503, 504].contains(status)
    }
}
