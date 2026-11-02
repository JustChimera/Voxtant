import XCTest
@testable import LectureCore

final class CoreTests: XCTestCase {
    func testContinuousSpeechHasBoundedNonOverlappingChunksAndTail() {
        var segmenter = AudioSegmenter(sampleRate: 1000)
        let chunks = segmenter.append([Float](repeating: 0.1, count: 10_000))
        let tail = segmenter.flush()!
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertEqual(chunks[0].end, 2.8, accuracy: 0.02)
        XCTAssertEqual(chunks[1].start, chunks[0].end)
        XCTAssertEqual(tail.start, chunks[2].end)
        XCTAssertEqual(tail.end, 10)
        XCTAssertEqual(chunks.reduce(tail.samples.count) { $0 + $1.samples.count }, 10_000)
    }

    func testSilenceIsNotSentButOffsetsArePreserved() {
        var segmenter = AudioSegmenter(sampleRate: 1000)
        XCTAssertTrue(segmenter.append([Float](repeating: 0, count: 4500)).isEmpty)
        _ = segmenter.append([Float](repeating: 0.1, count: 1000))
        let tail = segmenter.flush()!
        XCTAssertEqual(tail.start, 4.38, accuracy: 0.001)
        XCTAssertEqual(tail.samples.count, 1120)
        XCTAssertEqual(tail.end, 5.5)
        XCTAssertNil(segmenter.flush())
    }

    func testPauseClosesSegmentAfterTarget() {
        var segmenter = AudioSegmenter(sampleRate: 1000)
        XCTAssertTrue(segmenter.append([Float](repeating: 0.1, count: 900)).isEmpty)
        let chunks = segmenter.append([Float](repeating: 0, count: 400))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].end, 1.2, accuracy: 0.02)
    }

    func testWAVHeaderAndResamplingDuration() {
        let wav = WAVEncoder.encode(samples: [Float](repeating: 0.5, count: 4800), sampleRate: 48000)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(wav.count, 44 + 1600 * 2)
        XCTAssertEqual(Array(wav[24..<28]), [0x80, 0x3e, 0, 0])
        XCTAssertEqual(Array(wav[44..<46]), [0xff, 0x3f])
    }

    func testQuietAudioGainIsBoundedAndSilenceStaysSilent() {
        let wav = WAVEncoder.encode(samples: [Float](repeating: 0.02, count: 1600), sampleRate: 16000, normalize: true)
        let value = Int16(bitPattern: UInt16(wav[44]) | UInt16(wav[45]) << 8)
        XCTAssertEqual(Double(value) / 32767, 0.16, accuracy: 0.0001)
        let silence = WAVEncoder.encode(samples: [Float](repeating: 0, count: 1600), sampleRate: 16000, normalize: true)
        XCTAssertTrue(silence.dropFirst(44).allSatisfy { $0 == 0 })
    }

    func testChineseGuardChecksOrderAndRepetitions() {
        XCTAssertTrue(TranslationGuard.preservesChinese(source: "Because 因为…所以…", translation: "Потому что 因为…所以…"))
        XCTAssertFalse(TranslationGuard.preservesChinese(source: "你好你好", translation: "你好"))
        XCTAssertFalse(TranslationGuard.preservesChinese(source: "因为所以", translation: "所以因为"))
        XCTAssertFalse(TranslationGuard.preservesChinese(source: "中文", translation: "Китайский"))
        XCTAssertTrue(TranslationGuard.preservesChinese(source: "English", translation: "Русский"))
    }

    func testASRRequestKeepsAutomaticLanguageAndReadsUsage() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let json = Self.body(request)
            XCTAssertNil(json["language"])
            XCTAssertEqual(json["model"] as? String, "qwen/qwen3-asr-1.7b")
            return (200, #"{"text":"The pattern 因为所以","usage":{"cost":0.00002}}"#)
        }
        let result = try await client.transcribe(file: audio, model: "qwen/qwen3-asr-1.7b")
        XCTAssertEqual(result.text, "The pattern 因为所以")
        XCTAssertEqual(result.cost, 0.00002)
    }

    func testTranslationRetriesCorruptedChinese() async throws {
        var calls = 0
        let client = makeClient { request in
            calls += 1
            let messages = Self.body(request)["messages"] as! [[String: Any]]
            let content = messages.last!["content"] as! String
            let regex = try! NSRegularExpression(pattern: #"__ZH_[A-F0-9]{8}_0__"#)
            let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content))!
            let token = String(content[Range(match.range, in: content)!])
            return (200, Self.chatResponse(calls == 1 ? "Причина" : "Конструкция " + token))
        }
        let result = try await client.translate("The pattern 因为所以", context: "", model: "test")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.text, "Конструкция 因为所以")
        XCTAssertEqual(result.cost, 0.002)
        XCTAssertEqual(result.attempts.count, 2)
    }

    func testRateLimitIsActionableAndDoesNotLeakKey() async throws {
        let client = makeClient { _ in (429, #"{"error":{"message":"test-key rate limit"}}"#) }
        do {
            _ = try await client.translate("Hello", context: "", model: "test")
            XCTFail("Expected rate-limit failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("429"))
            XCTAssertTrue(error.localizedDescription.lowercased().contains("повторите позже"))
            XCTAssertFalse(error.localizedDescription.contains("test-key"))
        }
    }

    func testPureChineseSkipsTranslationAPIAndKeepsExactOriginal() async throws {
        let client = makeClient { _ in XCTFail("Chinese-only must not reach API"); return (500, "{}") }
        let result = try await client.translate("我是老师。你是学生。", context: "English", model: "test")
        XCTAssertEqual(result.text, "我是老师。你是学生。")
        XCTAssertEqual(result.cost, 0)
        XCTAssertTrue(result.attempts.isEmpty)
    }

    func testGeminiASRUsesAudioAndLessonContextWithoutForcingSingleLanguage() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
            let json = Self.body(request)
            XCTAssertNil(json["language"])
            let messages = json["messages"] as! [[String: Any]]
            let parts = messages[0]["content"] as! [[String: Any]]
            XCTAssertTrue((parts[0]["text"] as! String).contains("previous lesson"))
            XCTAssertEqual(parts[1]["type"] as? String, "input_audio")
            return (200, Self.chatResponse("For example, 我是老师"))
        }
        let result = try await client.transcribe(file: audio, model: "google/gemini-2.5-flash", context: "previous lesson")
        XCTAssertEqual(result.text, "For example, 我是老师")
        XCTAssertEqual(result.attempts.first?.stage, "asr")
    }

    func testProtectionRestoresPunctuationAndRejectsDuplicatesOrReordering() throws {
        let protection = ChineseProtection("Say 你好, then repeat 你好.")
        XCTAssertFalse(protection.masked.contains("你好"))
        let first = protection.spans[0].token
        let second = protection.spans[1].token
        XCTAssertEqual(try protection.restore("Скажите \(first), затем повторите \(second)."), "Скажите 你好, затем повторите 你好.")
        XCTAssertThrowsError(try protection.restore(first + first + second))
        XCTAssertThrowsError(try protection.restore(second + first))
        XCTAssertThrowsError(try protection.restore(first + second + "新增"))
        let grammar = ChineseProtection("The pattern 因为…所以…")
        XCTAssertEqual(try grammar.restore("Конструкция " + grammar.spans[0].token + "…"), "Конструкция 因为…所以…")
    }

    func testRateLimitRetriesThenSucceedsAndLogsBothAttempts() async throws {
        var calls = 0
        let client = makeClient { _ in
            calls += 1
            return calls == 1 ? (429, #"{"error":{"code":429,"message":"busy"}}"#) : (200, Self.chatResponse("Привет"))
        }
        let result = try await client.translate("Hello", context: "", model: "test")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.text, "Привет")
        XCTAssertEqual(result.attempts.map(\.status), [429, 200])
        XCTAssertEqual(result.attempts.first?.stage, "translation")
        XCTAssertNil(result.cost, "A failed attempt with unknown cost must not be counted as free")
    }

    func testLongRetryAfterIsNotIgnoredOrWaitedBeyondLiveBudget() async throws {
        var calls = 0
        let client = makeClient { _ in calls += 1; return (429, #"{"error":{"message":"busy"}}"#) }
        MockURLProtocol.headers = ["Retry-After": "60"]
        do { _ = try await client.translate("Hello", context: "", model: "test"); XCTFail("Expected failure") }
        catch let error as APIRequestFailure {
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(error.attempts.first?.retryAfterSeconds, 60)
        }
    }

    func testAuthenticationErrorsAreNotRetried() async throws {
        var calls = 0
        let client = makeClient { _ in calls += 1; return (401, #"{"error":{"message":"bad key"}}"#) }
        do { _ = try await client.translate("Hello", context: "", model: "test"); XCTFail("Expected failure") }
        catch { XCTAssertEqual(calls, 1) }
    }

    func testTimeoutRetriesAndKeepsStageInDiagnostic() async throws {
        var calls = 0
        let client = makeClient { _ in
            calls += 1
            return calls == 1 ? (URLError.timedOut.rawValue, "") : (200, Self.chatResponse("Привет"))
        }
        let result = try await client.translate("Hello", context: "", model: "test")
        XCTAssertEqual(calls, 2)
        XCTAssertNil(result.attempts[0].status)
        XCTAssertTrue(result.attempts[0].error!.contains("Перевод"))
    }

    func testBodyErrorCodeIsHandledEvenWithHTTP200() async throws {
        var calls = 0
        let client = makeClient { _ in
            calls += 1
            return calls == 1 ? (200, #"{"error":{"code":503,"message":"busy"}}"#) : (200, Self.chatResponse("Привет"))
        }
        let result = try await client.translate("Hello", context: "", model: "test")
        XCTAssertEqual(result.attempts.map(\.status), [503, 200])
    }

    func testCancellationInterruptsBackoff() async throws {
        let started = expectation(description: "first request")
        var calls = 0
        let client = makeClient { _ in calls += 1; started.fulfill(); return (429, #"{"error":{"message":"busy"}}"#) }
        MockURLProtocol.headers = ["Retry-After": "10"]
        let task = Task { try await client.translate("Hello", context: "", model: "test") }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private static func chatResponse(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": text]]], "usage": ["cost": 0.001]
        ])
        return String(data: data, encoding: .utf8)!
    }

    private func makeClient(_ handler: @escaping (URLRequest) -> (Int, String)) -> OpenRouterClient {
        MockURLProtocol.handler = handler
        MockURLProtocol.headers = [:]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return OpenRouterClient(key: "test-key", session: URLSession(configuration: config), retryPolicy: RetryPolicy(baseDelaySeconds: 0))
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler!(request)
        if status < 0 { client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: status))); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
