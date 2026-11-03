import Foundation

/// SSE framing and chat deltas. Usage frames may repeat finish_reason and contain no text.
struct ChatStreamAccumulator {
    private var dataLines: [String] = []
    private(set) var text = ""
    private(set) var done = false
    private var finishReason: String?
    private var identifier: String?
    private var provider: String?
    private var usage: [String: Any]?
    private(set) var error: [String: Any]?

    mutating func consume(_ line: String) throws -> String? {
        if line.isEmpty { return try dispatch() }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
        return nil
    }

    mutating func dispatch() throws -> String? {
        guard !dataLines.isEmpty else { return nil }
        let value = dataLines.joined(separator: "\n"); dataLines.removeAll(keepingCapacity: true)
        if value == "[DONE]" { done = true; return nil }
        guard let bytes = value.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw LectureError.message("Повреждён поток перевода.")
        }
        if let failure = json["error"] as? [String: Any] { error = failure; return nil }
        identifier = json["id"] as? String ?? identifier
        provider = json["provider"] as? String ?? provider
        usage = json["usage"] as? [String: Any] ?? usage
        let choice = (json["choices"] as? [[String: Any]])?.first
        let delta = choice?["delta"] as? [String: Any]
        let content = delta?["content"] as? String ?? ""
        if !content.isEmpty {
            guard finishReason == nil else { throw LectureError.message("Неожиданное продолжение завершённого перевода.") }
            text += content
        }
        if let reason = choice?["finish_reason"] as? String { finishReason = reason }
        return content.isEmpty ? nil : text
    }

    func result() throws -> [String: Any] {
        if let error { return ["error": error] }
        guard done, let finishReason else { throw URLError(.networkConnectionLost) }
        var json: [String: Any] = ["choices": [["message": ["content": text], "finish_reason": finishReason]]]
        if let identifier { json["id"] = identifier }
        if let provider { json["provider"] = provider }
        if let usage { json["usage"] = usage }
        return json
    }
}

func streamedChat(session: URLSession, request: URLRequest, deadline: Date,
                  onText: @Sendable (String) -> Void) async throws -> ([String: Any], HTTPURLResponse?) {
    let (bytes, response) = try await session.bytes(for: request)
    return try await withTaskCancellationHandler(operation: {
        defer { bytes.task.cancel() }
        let http = response as? HTTPURLResponse
        if !(200..<300).contains(http?.statusCode ?? 0) {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard Date() <= deadline, data.count < 262_144 else { throw URLError(.timedOut) }
                data.append(byte)
            }
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], http)
        }
        var parser = ChatStreamAccumulator()
        var lineBytes = Data()
        // AsyncBytes.lines omits empty lines on some runtimes; SSE needs blank frame delimiters.
        for try await byte in bytes {
            try Task.checkCancellation()
            guard Date() <= deadline else { throw URLError(.timedOut) }
            if byte == 10 {
                guard let raw = String(data: lineBytes, encoding: .utf8) else { throw LectureError.message("Повреждён UTF-8 поток перевода.") }
                lineBytes.removeAll(keepingCapacity: true)
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                if let text = try parser.consume(line) { onText(text) }
                if parser.done || parser.error != nil { break }
            } else {
                guard lineBytes.count < 262_144 else { throw LectureError.message("Слишком большой кадр потока перевода.") }
                lineBytes.append(byte)
            }
        }
        if !lineBytes.isEmpty {
            guard let line = String(data: lineBytes, encoding: .utf8) else { throw LectureError.message("Повреждён UTF-8 поток перевода.") }
            _ = try parser.consume(line)
        }
        if let text = try parser.dispatch() { onText(text) }
        return (try parser.result(), http)
    }, onCancel: { bytes.task.cancel() })
}
