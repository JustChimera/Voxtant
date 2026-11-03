import Foundation
import LectureCore

/// Exercises real orchestration against stalled local URLProtocol requests, without audio hardware.
@MainActor
enum StopSmokeTest {
    static func run(folder: URL, preferences: UserDefaults) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let chunks = folder.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let wav = WAVEncoder.encode(samples: [Float](repeating: 0.1, count: 8000), sampleRate: 16_000)
        try wav.write(to: chunks.appendingPathComponent("fixture.wav"))
        StopURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StopURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); StopURLProtocol.reset() }
        let model = DemoModel(loadKeychain: false, preferences: preferences, clientFactory: { policy in
            OpenRouterClient(key: "test-only", session: session, retryPolicy: policy)
        }, recordingsRoot: folder.appendingPathComponent("library"))
        try model.newSession(source: "microphone")
        let librarySession = model.folder!
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: librarySession.appendingPathComponent("metadata.json"))) as! [String: Any]
        checks["recordings_are_grouped_by_day_and_session"] = librarySession.deletingLastPathComponent().lastPathComponent.count == 10 && librarySession.deletingLastPathComponent().deletingLastPathComponent().path == model.recordingsRoot.path
        checks["new_recording_has_agent_readable_metadata"] = metadata["asrModel"] != nil && metadata["cost"] != nil && metadata["transcript"] as? String == "transcript.txt" && metadata["recording"] as? String == "recording.caf"

        model.folder = folder
        model.segments = (0..<5).map { index in
            var cell = Segment(id: index, start: Double(index), end: Double(index + 1), file: "chunks/fixture.wav",
                capturedAt: Date(), asrModel: "test/asr", translationModel: "test/translator")
            cell.status = index == 4 ? .complete : .failed
            if index == 1 { cell.transcript = "Hello" }
            if index == 4 { cell.translation = "Готовый перевод." }
            return cell
        }
        model.retryFailed()
        model.isRecording = true
        for _ in 0..<150 {
            if StopURLProtocol.startedCount >= 3 && !model.partialTranslations.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        checks["stop_fixture_has_stalled_asr_and_live_translation"] = StopURLProtocol.startedCount == 3 && !model.partialTranslations.isEmpty
        let started = Date()
        await model.stop()
        checks["stop_returns_without_waiting_for_server"] = Date().timeIntervalSince(started) < 0.5
        checks["stop_immediately_clears_busy_and_queue"] = !model.busy && model.pending == 0 && !model.isRecording && !model.isStopping
        checks["stop_discards_provisional_text"] = model.partialTranslations.isEmpty
        checks["stop_preserves_completed_text"] = model.segments[4].translation == "Готовый перевод."
        checks["stop_cancellation_is_not_a_recognition_failure"] = model.failures == 0 && model.completeCount == 1 && model.state == "Остановлено"
        checks["stop_retains_original_chunk"] = (try Data(contentsOf: chunks.appendingPathComponent("fixture.wav"))) == wav
        let stored = try JSONDecoder().decode(StopExport.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        checks["stop_marks_abandoned_cells_in_export"] = stored.segments.filter { $0.translationMode == "cancelled-by-user" }.count == 4

        // Reuse an index immediately: old cancellation handlers must not fail or clear this work.
        StopURLProtocol.finishNewRequests()
        var next = Segment(id: 0, start: 0, end: 0.5, file: "chunks/fixture.wav", capturedAt: Date(),
            asrModel: "test/asr", translationModel: "test/translator")
        next.status = .failed
        model.segments = [next]
        model.retryFailed()
        for _ in 0..<150 {
            if !model.busy && StopURLProtocol.cancelledCount >= 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        checks["stop_cancels_asr_and_quiet_sse_transport"] = StopURLProtocol.cancelledCount >= 3
        checks["new_work_after_stop_ignores_old_callbacks"] = !model.busy && model.failures == 0 && model.segments[0].translation == "Новая запись." && model.partialTranslations.isEmpty
        return checks
    }
}

private struct StopExport: Decodable {
    struct Cell: Decodable { var translationMode: String? }
    var segments: [Cell]
}

private final class StopURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started = 0
    private static var cancelled = 0
    private static var completeNew = false
    private var heldRequest = false
    static var startedCount: Int { lock.lock(); defer { lock.unlock() }; return started }
    static var cancelledCount: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
    static func reset() { lock.lock(); defer { lock.unlock() }; started = 0; cancelled = 0; completeNew = false }
    static func finishNewRequests() { lock.lock(); completeNew = true; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.started += 1; let complete = Self.completeNew; heldRequest = !complete; Self.lock.unlock()
        let translation = request.url?.path.hasSuffix("chat/completions") == true
        if !translation && !complete { return }
        let headers = ["Content-Type": translation ? "text/event-stream" : "application/json"]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: String
        if translation {
            let text = complete ? "Новая запись." : "Предварительный текст"
            var frame: [String: Any] = ["choices": [["delta": ["content": text]]]]
            if complete { frame = ["choices": [["delta": ["content": text], "finish_reason": "stop"]]] }
            body = "data: " + String(data: try! JSONSerialization.data(withJSONObject: frame), encoding: .utf8)! + "\n\n" + (complete ? "data: [DONE]\n\n" : "")
        } else { body = "{\"text\":\"New transcript\"}" }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if complete { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.lock.lock(); if heldRequest { Self.cancelled += 1 }; Self.lock.unlock() }
}
