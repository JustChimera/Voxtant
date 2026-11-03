import Foundation
import LectureCore

struct TranslationFixture: Decodable {
    struct Entry: Decodable {
        var id: String
        var text: String
        var context: String?
        var settings: TranslationSettings?
    }
    var version: String
    var cases: [Entry]
}

struct TranslationEvalConfig: Codable {
    var fixtureSHA256: String
    var models: [String]
    var repetitions: Int
    var streaming: Bool?
    var latencyRouting: Bool?
}

struct TranslationObservation: Codable {
    var caseID: String
    var model: String
    var repetition: Int
    var status: String
    var text = ""
    var seconds: Double = 0
    var firstTextSeconds: Double?
    var cost: Double?
    var attempts: [RequestAttempt] = []
    var error: String?
}

private final class FirstTranslationText: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date()
    private var first: Double?
    func observe(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = Date().timeIntervalSince(started) }
    }
    var seconds: Double? { lock.lock(); defer { lock.unlock() }; return first }
}

@MainActor
func evaluateTranslations(root: URL, output: URL) async throws {
    let fixtureURL = root.appendingPathComponent("cases.json")
    let config = try read(TranslationEvalConfig.self, from: output.appendingPathComponent("config.json"))
    guard digest(try Data(contentsOf: fixtureURL)) == config.fixtureSHA256,
          (1...3).contains(config.repetitions), !config.models.isEmpty, config.models.count <= 6,
          Set(config.models).count == config.models.count else { throw LectureError.message("Invalid translation experiment") }
    let fixture = try read(TranslationFixture.self, from: fixtureURL)
    guard fixture.cases.count <= 24, Set(fixture.cases.map(\.id)).count == fixture.cases.count else { throw LectureError.message("Invalid fixture cases") }
    let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !key.isEmpty else { throw LectureError.message("No Keychain credential provided") }
    let client = OpenRouterClient(key: key, retryPolicy: RetryPolicy(maximumAttempts: 1, baseDelaySeconds: 0))
    var disabled = Set<String>()
    var consecutiveErrors: [String: Int] = [:]
    var attempts = 0
    for repetition in 0..<config.repetitions {
        for (index, entry) in fixture.cases.enumerated() {
            let shift = (repetition + index) % config.models.count
            let models = Array(config.models[shift...]) + Array(config.models[..<shift])
            for model in models {
                let folder = output.appendingPathComponent("responses/" + model.replacingOccurrences(of: "/", with: "--") + "/" + entry.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("\(repetition).json")
                if FileManager.default.fileExists(atPath: file.path) { continue }
                var row = TranslationObservation(caseID: entry.id, model: model, repetition: repetition, status: "skipped")
                if disabled.contains(model) || attempts >= 300 {
                    row.error = "Model temporarily unavailable or bounded attempt budget reached"
                } else {
                    let start = Date()
                    let timing = FirstTranslationText()
                    let publish: (@Sendable (String) -> Void)?
                    if config.streaming == true { publish = { text in timing.observe(text) } }
                    else { publish = nil }
                    do {
                        let result = try await client.translate(entry.text, context: entry.context ?? "", model: model,
                            settings: entry.settings ?? .init(), latencyRouting: config.latencyRouting == true, onPartial: publish)
                        row.status = "ok"; row.text = result.text; row.seconds = result.seconds
                        row.cost = result.cost; row.attempts = result.attempts
                        if !result.attempts.isEmpty { consecutiveErrors[model] = 0 }
                    } catch {
                        row.status = "failed"; row.seconds = Date().timeIntervalSince(start); row.error = error.localizedDescription
                        if let failure = error as? APIRequestFailure { row.attempts = failure.attempts }
                        consecutiveErrors[model, default: 0] += 1
                        if row.attempts.contains(where: { [401, 402].contains($0.status ?? 0) }) {
                            disabled.formUnion(config.models)
                        } else if row.attempts.contains(where: { [400, 403, 404].contains($0.status ?? 0) }) || consecutiveErrors[model, default: 0] >= 2 {
                            disabled.insert(model)
                        }
                    }
                    row.firstTextSeconds = timing.seconds
                    attempts += row.attempts.count
                }
                try save(row, to: file)
                print("Translation \(repetition + 1)/\(config.repetitions) \(entry.id) · \(model): \(row.status) \(String(format: "%.2f", row.seconds))s"); fflush(stdout)
            }
        }
    }
}
