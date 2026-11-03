import Foundation

public struct RequestAttempt: Codable, Sendable, Equatable {
    public var stage: String
    public var model: String
    public var number: Int
    public var seconds: Double
    public var status: Int?
    public var requestID: String?
    public var provider: String?
    public var retryAfterSeconds: Double?
    public var cost: Double?
    public var error: String?
}

public struct RecognizedWord: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
}

public struct APIResult: Sendable {
    public var text: String
    public var seconds: Double
    public var cost: Double?
    public var attempts: [RequestAttempt] = []
    public var words: [RecognizedWord]? = nil
    public var speechGate: SpeechGateObservation? = nil
}

public enum LectureError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public struct APIRequestFailure: LocalizedError {
    public let message: String
    public let attempts: [RequestAttempt]
    public var errorDescription: String? { message }
}

public struct RetryPolicy {
    public var maximumAttempts = 3
    public var timeoutSeconds = 8.0
    public var budgetSeconds = 20.0
    public var baseDelaySeconds = 0.6
    public init(maximumAttempts: Int = 3, baseDelaySeconds: Double = 0.6) {
        self.maximumAttempts = maximumAttempts
        self.baseDelaySeconds = baseDelaySeconds
    }
}

public struct OpenRouterClient {
    private let key: String
    private let session: URLSession
    private let retryPolicy: RetryPolicy

    public init(key: String, session: URLSession = .shared, retryPolicy: RetryPolicy = RetryPolicy()) {
        self.key = key
        self.session = session
        self.retryPolicy = retryPolicy
    }

    public func transcribe(file: URL, model: String, context: String = "", settings: TranslationSettings = .init(), wordTimestamps: Bool = false, filterNonSpeech: Bool = false, audioEventTags: Bool = false, languageHint: SpeechLanguage? = nil) async throws -> APIResult {
        try settings.validate()
        let gate = filterNonSpeech ? await SpeechGate.inspect(file: file) : nil
        try Task.checkCancellation()
        if gate?.skipASR == true {
            return APIResult(text: "", seconds: 0, cost: 0, speechGate: gate)
        }
        let audio = try Data(contentsOf: file).base64EncodedString()
        if model.hasPrefix("google/") {
            guard !wordTimestamps else { throw LectureError.message("Этот режим ASR не возвращает временные метки слов.") }
            var result = try await request(path: "chat/completions", stage: "asr", body: [
                "model": model, "temperature": 0, "max_tokens": 300,
                "reasoning": ["enabled": false],
                "messages": [["role": "user", "content": [
                    ["type": "text", "text": """
                    \(settings.asrInstructions)
                    Prior utterances (context only): \(context)
                    """],
                    ["type": "input_audio", "input_audio": ["data": audio, "format": "wav"]]
                ]]]
            ], extract: Self.chatText)
            result.speechGate = gate
            return result
        }
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audio, "format": "wav"],
            "response_format": "json"
        ]
        if model == "elevenlabs/scribe-v2" {
            body["provider"] = ["options": ["elevenlabs": ["tag_audio_events": audioEventTags]]]
        }
        if let language = settings.asrLanguage ?? languageHint?.rawValue { body["language"] = language }
        if wordTimestamps {
            body["response_format"] = "verbose_json"
            body["timestamp_granularities"] = ["word"]
        }
        var result = try await request(path: "audio/transcriptions", stage: "asr", body: body,
                                       extract: { $0["text"] as? String })
        result.speechGate = gate
        return result
    }

    public func translate(_ text: String, context: String, model: String,
                          settings: TranslationSettings = .init(), latencyRouting: Bool = false,
                          onPartial: (@Sendable (String) -> Void)? = nil) async throws -> APIResult {
        try settings.validate()
        let protection = settings.protectsChinese ? ChineseProtection(text) : nil
        if protection?.isChineseOnly == true { onPartial?(text); return APIResult(text: text, seconds: 0, cost: 0) }
        let tokenInstructions = protection == nil ? "" : """
        Tokens beginning __ZH_ represent protected Chinese spans. Copy every token EXACTLY ONCE,
        in the same order. Never translate, expand, explain or remove a token.
        """ + (settings.target.usesHan ? "" : "\nOutput no Han characters yourself; restoration is handled by the app.")
        let instructions = settings.translationInstructions + "\n" + tokenInstructions
        let maskedContext = protection == nil ? context : ChineseProtection(context).masked
        let current = protection?.masked ?? text
        let started = Date()
        var attempts: [RequestAttempt] = []
        for validationAttempt in 0..<2 {
            do {
                var body: [String: Any] = [
                    "model": model,
                    "messages": [
                        ["role": "system", "content": instructions + (validationAttempt == 0 ? "" : "\nCRITICAL: Return only the result and preserve every protected token exactly once in order.")],
                        ["role": "user", "content": String(data: try JSONSerialization.data(
                            withJSONObject: ["context": maskedContext, "current_utterance": current], options: [.sortedKeys]), encoding: .utf8)!]
                    ],
                    "temperature": 0, "max_tokens": 500, "stream": onPartial != nil
                ]
                if latencyRouting { body["provider"] = ["sort": "latency"] }
                if onPartial != nil { body["stream_options"] = ["include_usage": true] }
                let allowsHan = settings.target.usesHan
                let publisher: (@Sendable (String) -> Void)?
                if let callback = onPartial {
                    publisher = { raw in callback(protection?.partial(raw, allowAdditionalHan: allowsHan) ?? (protection == nil ? raw : "")) }
                } else { publisher = nil }
                let result = try await request(path: "chat/completions", stage: "translation", body: body,
                                               extract: Self.chatText, onText: publisher)
                attempts += result.attempts
                do {
                    guard !result.text.isEmpty else { throw LectureError.message("Переводчик вернул пустой текст.") }
                    return APIResult(text: try protection?.restore(result.text, allowAdditionalHan: settings.target.usesHan) ?? result.text, seconds: Date().timeIntervalSince(started),
                                     cost: Self.totalCost(attempts), attempts: attempts)
                } catch {
                    if validationAttempt == 1 {
                        throw APIRequestFailure(message: error.localizedDescription, attempts: attempts)
                    }
                }
            } catch let error as APIRequestFailure {
                let combined = error.attempts == attempts ? attempts : attempts + error.attempts
                throw APIRequestFailure(message: error.message, attempts: combined)
            }
        }
        throw APIRequestFailure(message: "Перевод не прошёл проверку результата.", attempts: attempts)
    }

    /// Optional model timing estimates, not verified word alignment. Reject partial/malformed metadata.
    static func wordTimings(_ json: [String: Any]) -> [RecognizedWord]? {
        guard let rows = json["words"] as? [[String: Any]], !rows.isEmpty else { return nil }
        let duration = (json["duration"] as? NSNumber)?.doubleValue
        var words: [RecognizedWord] = []
        for row in rows {
            guard let text = row["word"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = (row["start"] as? NSNumber)?.doubleValue,
                  let end = (row["end"] as? NSNumber)?.doubleValue,
                  start.isFinite, end.isFinite, start >= 0, end >= start,
                  start >= (words.last?.start ?? 0),
                  duration == nil || (duration!.isFinite && end <= duration! + 0.1) else { return nil }
            words.append(RecognizedWord(text: text, start: start, end: end))
        }
        return words
    }

    private static func chatText(_ json: [String: Any]) -> String? {
        let choices = json["choices"] as? [[String: Any]]
        if let reason = choices?.first?["finish_reason"] as? String, reason != "stop" { return nil }
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String
    }

    private static func totalCost(_ attempts: [RequestAttempt]) -> Double? {
        guard attempts.allSatisfy({ $0.cost != nil }) else { return nil }
        return attempts.reduce(0) { $0 + ($1.cost ?? 0) }
    }

    private func request(path: String, stage: String, body: [String: Any],
                         extract: ([String: Any]) -> String?, onText: (@Sendable (String) -> Void)? = nil) async throws -> APIResult {
        let model = body["model"] as? String ?? "unknown"
        let started = Date()
        var attempts: [RequestAttempt] = []
        var lastError = "Ошибка запроса"
        for number in 1...max(1, retryPolicy.maximumAttempts) {
            try Task.checkCancellation()
            let remaining = retryPolicy.budgetSeconds - Date().timeIntervalSince(started)
            guard remaining > 0 else { break }
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/" + path)!)
            request.httpMethod = "POST"
            request.timeoutInterval = min(retryPolicy.timeoutSeconds, remaining)
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Voxtant", forHTTPHeaderField: "X-Title")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let attemptStarted = Date()
            var log = RequestAttempt(stage: stage, model: model, number: number, seconds: 0)
            var retryable = false
            do {
                let http: HTTPURLResponse?
                let json: [String: Any]
                if let onText {
                    onText("")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    (json, http) = try await streamedChat(session: session, request: request,
                        deadline: started.addingTimeInterval(retryPolicy.budgetSeconds), onText: onText)
                } else {
                    let (data, response) = try await session.data(for: request)
                    http = response as? HTTPURLResponse
                    json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                }
                try Task.checkCancellation()
                let error = json["error"] as? [String: Any]
                let metadata = error?["metadata"] as? [String: Any]
                let code = (error?["code"] as? NSNumber)?.intValue ??
                    (error?["code"] as? String).flatMap(Int.init) ?? http?.statusCode ?? 0
                log.status = code
                log.requestID = http?.value(forHTTPHeaderField: "X-Request-Id") ?? json["id"] as? String
                log.provider = metadata?["provider_name"] as? String ?? json["provider"] as? String
                log.retryAfterSeconds = Self.retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
                log.cost = ((json["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue
                if (200..<300).contains(code), error == nil, let text = extract(json) {
                    log.seconds = Date().timeIntervalSince(attemptStarted)
                    attempts.append(log)
                    return APIResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        seconds: Date().timeIntervalSince(started), cost: Self.totalCost(attempts), attempts: attempts,
                        words: body["response_format"] as? String == "verbose_json" ? Self.wordTimings(json) : nil)
                }
                let detail = error?["message"] as? String ?? "Ответ без текста"
                lastError = "\(stage == "asr" ? "ASR" : "Перевод") · OpenRouter \(code): \(redact(detail))"
                if code == 401 || code == 403 { lastError += ". Проверьте ключ и доступ к модели." }
                if code == 402 { lastError += ". Проверьте баланс OpenRouter." }
                if code == 429 { lastError += ". Лимит запросов; повторите позже." }
                retryable = [408, 429, 500, 502, 503, 504].contains(code)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = "\(stage == "asr" ? "ASR" : "Перевод"): \(redact(error.localizedDescription))"
                if let network = error as? URLError {
                    retryable = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(network.code)
                }
            }
            log.seconds = Date().timeIntervalSince(attemptStarted)
            log.error = lastError
            attempts.append(log)
            let delay = log.retryAfterSeconds ?? retryPolicy.baseDelaySeconds * pow(2, Double(number - 1))
            guard retryable, number < retryPolicy.maximumAttempts,
                  Date().timeIntervalSince(started) + delay < retryPolicy.budgetSeconds else { break }
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        throw APIRequestFailure(message: lastError + " Аудио сохранено.", attempts: attempts)
    }

    public static func retryAfter(_ value: String?) -> Double? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    private func redact(_ text: String) -> String {
        String(text.replacingOccurrences(of: key, with: "[redacted]").prefix(350))
    }
}
