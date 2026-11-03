import XCTest
@testable import LectureCore

private final class PartialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ text: String) { lock.lock(); stored.append(text); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

final class StreamingTests: XCTestCase {
    func testSSEIgnoresCommentsAndAcceptsRepeatedUsageFinish() throws {
        var parser = ChatStreamAccumulator()
        XCTAssertNil(try parser.consume(": OPENROUTER PROCESSING"))
        for line in [#"data: {"choices":[{"delta":{"content":"Привет"},"finish_reason":"stop"}]}"#, "",
                     #"data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}],"usage":{"cost":0.002}}"#, "",
                     "data: [DONE]", ""] { _ = try parser.consume(line) }
        let result = try parser.result()
        XCTAssertEqual(parser.text, "Привет")
        XCTAssertEqual((result["usage"] as? [String: Double])?["cost"], 0.002)
    }

    func testMissingDoneAndMidstreamErrorNeverBecomeCompleteText() throws {
        var parser = ChatStreamAccumulator()
        _ = try parser.consume(#"data: {"choices":[{"delta":{"content":"Начало"}}]}"#)
        _ = try parser.consume("")
        XCTAssertThrowsError(try parser.result())
        _ = try parser.consume(#"data: {"error":{"code":503,"message":"unavailable"}}"#)
        _ = try parser.consume("")
        XCTAssertNotNil(try parser.result()["error"])
    }

    func testProtectedPartialDoesNotLeakSplitTokensOrEraseRepetitions() throws {
        let protected = ChineseProtection("Say 你好, 你好")
        let token = protected.spans[0].token
        for length in 1..<token.count {
            let partial = protected.partial("Скажите " + token.prefix(length))
            XCTAssertNotNil(partial)
            XCTAssertFalse(partial!.contains("__"))
        }
        XCTAssertEqual(protected.partial("Скажите " + token), "Скажите 你好, 你好")
        XCTAssertNil(protected.partial("Скажите __ZH_DEADBEEF_9__"))
        XCTAssertNil(protected.partial("Скажите " + token + token))
        XCTAssertNil(protected.partial("Лишние иероглифы 中文"))
    }

    func testStreamingNativeClientRestoresHanBeforePublishing() async throws {
        let collector = PartialCollector()
        let client = makeClient { request in
            let body = Self.body(request)
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual((body["provider"] as? [String: String])?["sort"], "latency")
            let messages = body["messages"] as! [[String: Any]]
            let user = messages[1]["content"] as! String
            let data = try! JSONSerialization.jsonObject(with: Data(user.utf8)) as! [String: String]
            XCTAssertNotNil(data["current_utterance"])
            let expression = try! NSRegularExpression(pattern: #"__ZH_[A-F0-9]{8}_0__"#)
            let match = expression.firstMatch(in: user, range: NSRange(user.startIndex..., in: user))!
            let token = String(user[Range(match.range, in: user)!])
            return (200, Self.events(["Скажите ", String(token.prefix(3)), String(token.dropFirst(3))]))
        }
        let result = try await client.translate("Say 你好", context: "", model: "test", latencyRouting: true,
            onPartial: { text in collector.add(text) })
        XCTAssertEqual(result.text, "Скажите 你好")
        XCTAssertEqual(result.cost, 0.002)
        XCTAssertTrue(collector.values.contains("Скажите "))
        XCTAssertTrue(collector.values.allSatisfy { !$0.contains("__ZH_") && !$0.contains("__Z") })
    }

    func testTruncatedStreamingResponseIsRejected() async throws {
        let client = makeClient { _ in (200, Self.events(["Незавершённый"], finish: "length")) }
        do {
            _ = try await client.translate("Unfinished", context: "", model: "test", onPartial: { _ in })
            XCTFail("A truncated response must not be committed")
        } catch let error as APIRequestFailure { XCTAssertEqual(error.attempts.count, 1) }
    }

    private func makeClient(_ handler: @escaping (URLRequest) -> (Int, String)) -> OpenRouterClient {
        StreamURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamURLProtocol.self]
        return OpenRouterClient(key: "test-key", session: URLSession(configuration: configuration),
                                retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelaySeconds: 0))
    }

    private static func events(_ parts: [String], finish: String = "stop") -> String {
        var lines = [": keepalive\n\n"]
        for part in parts {
            let json: [String: Any] = ["choices": [["delta": ["content": part]]]]
            lines.append("data: " + String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)! + "\n\n")
        }
        lines.append("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(finish)\"}],\"usage\":{\"cost\":0.002}}\n\ndata: [DONE]\n\n")
        return lines.joined()
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

private final class StreamURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, text) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
