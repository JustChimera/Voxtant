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

    func testScribeDisablesAudioEventsWithoutForcingAMixedLanguage() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = makeClient { request in
            let body = Self.body(request)
            let provider = body["provider"] as? [String: Any]
            let options = provider?["options"] as? [String: Any]
            let scribe = options?["elevenlabs"] as? [String: Any]
            XCTAssertEqual(scribe?["tag_audio_events"] as? Bool, false)
            XCTAssertNil(body["language"])
            return (200, #"{"text":"Say 我是老师, 我是老师"}"#)
        }
        let result = try await client.transcribe(file: audio, model: "elevenlabs/scribe-v2")
        XCTAssertEqual(result.text, "Say 我是老师, 我是老师")
    }

    func testMixedASRLanguageHintIsIndependentOfTranslationRules() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let mixed = TranslationSettings()
        let client = makeClient { request in
            XCTAssertEqual(Self.body(request)["language"] as? String, "zh")
            return (200, #"{"text":"我是老师，你是学生。"}"#)
        }
        let result = try await client.transcribe(file: audio, model: "elevenlabs/scribe-v2", settings: mixed, languageHint: .zh)
        XCTAssertEqual(result.text, "我是老师，你是学生。")
        XCTAssertEqual(mixed.target, .ru)
        XCTAssertEqual(mixed.mode, .mixed)
        XCTAssertTrue(mixed.protectsChinese)
    }

    func testSingleSourceLanguageTakesPrecedenceOverMixedHint() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        var single = TranslationSettings(); single.mode = .single; single.source = .en
        let client = makeClient { request in
            XCTAssertEqual(Self.body(request)["language"] as? String, "en")
            return (200, #"{"text":"English control"}"#)
        }
        _ = try await client.transcribe(file: audio, model: "openai/gpt-transcribe", settings: single, languageHint: .zh)
    }

    func testOptInWordTimingsPreserveRepeatedHanAndRequestVerboseJSON() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = makeClient { request in
            let body = Self.body(request)
            XCTAssertEqual(body["response_format"] as? String, "verbose_json")
            XCTAssertEqual(body["timestamp_granularities"] as? [String], ["word"])
            return (200, #"{"text":"Say 你好你好","duration":3,"words":[{"word":"Say","start":0,"end":0.5},{"word":"你好","start":0.5,"end":1.5},{"word":"你好","start":1.5,"end":1.5}]}"#)
        }
        let result = try await client.transcribe(file: audio, model: "elevenlabs/scribe-v2", wordTimestamps: true)
        XCTAssertEqual(result.text, "Say 你好你好")
        XCTAssertEqual(result.words?.map(\.text), ["Say", "你好", "你好"])
        XCTAssertEqual(result.words?.last?.end, 1.5)
    }

    func testMalformedWordTimingsAreNotUsedForPartialAlignment() {
        let valid: [String: Any] = ["word": "我", "start": 0.0, "end": 0.5]
        for invalid in [
            ["word": "你", "start": -1.0, "end": 0.5],
            ["word": "你", "start": 0.5, "end": 0.1],
            ["word": "你", "start": 0.5, "end": Double.infinity],
            ["word": "你", "start": 0.5, "end": 5.0],
            ["word": "你", "start": 0.5]
        ] as [[String: Any]] {
            XCTAssertNil(OpenRouterClient.wordTimings(["words": [valid, invalid], "duration": 1.0]))
        }
        XCTAssertNil(OpenRouterClient.wordTimings(["words": [
            ["word": "你", "start": 1.0, "end": 1.5], valid
        ]]))
    }

    func testMissingWordMetadataKeepsTheRecognizedTranscript() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = makeClient { _ in (200, #"{"text":"你好你好"}"#) }
        let result = try await client.transcribe(file: audio, model: "elevenlabs/scribe-v2", wordTimestamps: true)
        XCTAssertEqual(result.text, "你好你好")
        XCTAssertNil(result.words)
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

    func testSingleASRPassesSelectedLanguage() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        var settings = TranslationSettings()
        settings.mode = .single
        settings.source = .de
        let client = makeClient { request in
            XCTAssertEqual(Self.body(request)["language"] as? String, "de")
            return (200, #"{"text":"Guten Tag"}"#)
        }
        _ = try await client.transcribe(file: audio, model: "qwen/qwen3-asr-1.7b", settings: settings)
    }

    func testSingleChineseCanBeTranslatedInsteadOfBypassed() async throws {
        var settings = TranslationSettings()
        settings.mode = .single
        settings.source = .zh
        settings.target = .en
        var calls = 0
        let client = makeClient { request in
            calls += 1
            let messages = Self.body(request)["messages"] as! [[String: Any]]
            let prompt = messages[0]["content"] as! String
            XCTAssertTrue(prompt.contains("Target language: English"))
            XCTAssertTrue(prompt.contains("Mandarin Chinese: translate to English"))
            XCTAssertTrue((messages[1]["content"] as! String).contains("你好"))
            return (200, Self.chatResponse("Hello"))
        }
        let result = try await client.translate("你好", context: "", model: "test", settings: settings)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.text, "Hello")
    }

    func testMixedChineseTranslationCheckboxUsesTranslationAPI() async throws {
        var settings = TranslationSettings()
        settings.sources = [.init(.en), .init(.zh)]
        let client = makeClient { request in
            let messages = Self.body(request)["messages"] as! [[String: Any]]
            XCTAssertTrue((messages[0]["content"] as! String).contains("Mandarin Chinese: translate to Russian"))
            XCTAssertFalse((messages[1]["content"] as! String).contains("__ZH_"))
            return (200, Self.chatResponse("Скажите привет"))
        }
        let result = try await client.translate("Say 你好", context: "", model: "test", settings: settings)
        XCTAssertEqual(result.text, "Скажите привет")
    }

    func testMixedPreservesChineseAndAllowsJapaneseTarget() async throws {
        var settings = TranslationSettings()
        settings.target = .ja
        let client = makeClient { request in
            let messages = Self.body(request)["messages"] as! [[String: Any]]
            let content = messages[1]["content"] as! String
            let regex = try! NSRegularExpression(pattern: #"__ZH_[A-F0-9]{8}_0__"#)
            let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content))!
            let token = String(content[Range(match.range, in: content)!])
            return (200, Self.chatResponse("例は" + token))
        }
        let result = try await client.translate("Example 你好", context: "", model: "test", settings: settings)
        XCTAssertEqual(result.text, "例は你好")
    }

    func testMixedRulesForOtherLanguagesAreSentAndChineseNotAlwaysProtected() async throws {
        var settings = TranslationSettings()
        settings.sources = [.init(.fr), .init(.en, translate: false)]
        settings.target = .de
        let client = makeClient { request in
            let messages = Self.body(request)["messages"] as! [[String: Any]]
            let prompt = messages[0]["content"] as! String
            XCTAssertTrue(prompt.contains("French: translate to German"))
            XCTAssertTrue(prompt.contains("English: keep the exact original text"))
            XCTAssertTrue(prompt.contains("ONE integrated text"))
            return (200, Self.chatResponse("Hallo, hello"))
        }
        let result = try await client.translate("Bonjour, hello", context: "", model: "test", settings: settings)
        XCTAssertEqual(result.text, "Hallo, hello")
        settings.sources = [.init(.ja), .init(.zh, translate: false)]
        XCTAssertFalse(settings.protectsChinese, "Han-only masking cannot distinguish Japanese kanji from Chinese")
    }

    func testInvalidLanguageConfigurationNeverReachesNetwork() async throws {
        var settings = TranslationSettings()
        settings.sources = []
        let client = makeClient { _ in XCTFail("Invalid settings must fail before sending"); return (500, "{}") }
        do {
            _ = try await client.translate("Hello", context: "", model: "test", settings: settings)
            XCTFail("Expected validation error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("язык")) }
        settings.sources = [.init(.en), .init(.en, translate: false)]
        XCTAssertThrowsError(try settings.validate())
    }

    func testLanguagePreferencesPersistAndCorruptValuesFallBack() throws {
        let name = "local.voxtant.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        var settings = TranslationSettings()
        settings.mode = .single
        settings.source = .ko
        settings.target = .fr
        TranslationPreferences.save(settings, to: preferences)
        XCTAssertEqual(TranslationPreferences.load(from: UserDefaults(suiteName: name)!), settings)
        preferences.set(Data("invalid".utf8), forKey: "Voxtant.TranslationSettings.v1")
        XCTAssertEqual(TranslationPreferences.load(from: preferences), TranslationSettings())
    }

    func testSessionLanguageMetadataIsOptionalForOldReports() throws {
        let report = SessionReport(createdAt: Date(), source: "file", duration: 0, recording: "source.wav", segments: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        json.removeValue(forKey: "translationSettings")
        let old = try JSONDecoder().decode(SessionReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.translationSettings)
        var current = old
        current.translationSettings = TranslationSettings()
        let restored = try JSONDecoder().decode(SessionReport.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(restored.translationSettings, TranslationSettings())
    }

    func testAcousticNoiseVetoAvoidsAnASRRequestAndKeepsTheSavedWAV() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let original = WAVEncoder.encode(samples: [Float](repeating: 0, count: 20_800), sampleRate: 16_000)
        try original.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = makeClient { _ in XCTFail("Local nonspeech must not reach the API"); return (200, #"{"text":"invented"}"#) }
        let result = try await client.transcribe(file: audio, model: "test", filterNonSpeech: true)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.speechGate?.skipASR, true)
        XCTAssertTrue(result.attempts.isEmpty)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(try Data(contentsOf: audio), original)
    }

    func testShortAcousticInputPassesThroughAndNeverDeduplicatesChinese() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try WAVEncoder.encode(samples: [Float](repeating: 0, count: 8000), sampleRate: 16_000).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = makeClient { _ in (200, #"{"text":"你好你好"}"#) }
        let result = try await client.transcribe(file: audio, model: "test", filterNonSpeech: true)
        XCTAssertEqual(result.text, "你好你好")
        XCTAssertEqual(result.attempts.count, 1)
        XCTAssertEqual(result.speechGate?.reason, "short-pass-through")
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
