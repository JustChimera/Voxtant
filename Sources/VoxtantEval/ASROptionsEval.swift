import Foundation
import LectureCore

struct ASROptionsFixture: Codable {
    struct Entry: Codable { var id: String; var audio: String; var audioSHA256: String; var role: String }
    var cases: [Entry]
}

struct ASROptionsObservation: Codable {
    var caseID: String
    var profile: String
    var model: String
    var language: String?
    var status: String
    var text = ""
    var seconds = 0.0
    var attempts: [RequestAttempt] = []
    var error: String?
}

func evaluateASROptions(root: URL, output: URL) async throws {
    let manifest = root.appendingPathComponent("asr-options-cases.json")
    let fixture = try read(ASROptionsFixture.self, from: manifest)
    guard fixture.cases.count == 6, Set(fixture.cases.map(\.id)).count == 6,
          !FileManager.default.fileExists(atPath: output.path) else { throw LectureError.message("Six unique clips and new output are required") }
    for entry in fixture.cases {
        guard digest(try Data(contentsOf: root.appendingPathComponent(entry.audio))) == entry.audioSHA256 else {
            throw LectureError.message("Audio fingerprint mismatch")
        }
    }
    let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !key.isEmpty else { throw LectureError.message("No Keychain credential provided") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try Data(contentsOf: manifest).write(to: output.appendingPathComponent("cases.json"), options: .atomic)
    try save(["fixtureSHA256": digest(try Data(contentsOf: manifest)),
        "runnerSHA256": digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
        "maximumRequests": "24", "audioEventTags": "false", "speechGate": "disabled for option isolation",
        "notes": "No human reference; script compliance/latency only, not semantic accuracy."], to: output.appendingPathComponent("config.json"))
    var policy = RetryPolicy(maximumAttempts: 1, baseDelaySeconds: 0)
    policy.timeoutSeconds = 8; policy.budgetSeconds = 8
    let client = OpenRouterClient(key: key, retryPolicy: policy)
    let profiles: [(String, String, String?)] = [
        ("scribe-auto", "elevenlabs/scribe-v2", nil), ("scribe-zh", "elevenlabs/scribe-v2", "zh"),
        ("gpt-auto", "openai/gpt-transcribe", nil), ("gpt-zh", "openai/gpt-transcribe", "zh")]
    var rows: [ASROptionsObservation] = []
    var disabled = Set<String>()
    for (index, entry) in fixture.cases.enumerated() {
        let order = Array(profiles[(index % profiles.count)...]) + Array(profiles[..<(index % profiles.count)])
        for (name, model, language) in order {
            var row = ASROptionsObservation(caseID: entry.id, profile: name, model: model, language: language, status: "skipped")
            if !disabled.contains(model) {
                var settings = TranslationSettings()
                if language != nil { settings.mode = .single; settings.source = .zh }
                let started = Date()
                do {
                    let result = try await client.transcribe(file: root.appendingPathComponent(entry.audio), model: model,
                        settings: settings, filterNonSpeech: false)
                    row.text = result.text; row.seconds = result.seconds; row.attempts = result.attempts; row.status = "ok"
                } catch {
                    row.status = "failed"; row.seconds = Date().timeIntervalSince(started); row.error = error.localizedDescription
                    if let failure = error as? APIRequestFailure { row.attempts = failure.attempts }
                    if row.attempts.contains(where: { [401,402].contains($0.status ?? 0) }) { disabled.formUnion(profiles.map { $0.1 }) }
                    else if row.attempts.contains(where: { [400,403,404].contains($0.status ?? 0) }) { disabled.insert(model) }
                }
            }
            rows.append(row)
            try save(row, to: output.appendingPathComponent(entry.id + "--" + name + ".json"))
            print(entry.id + " / " + name + ": " + row.status)
            fflush(stdout)
        }
    }
    try save(rows, to: output.appendingPathComponent("results.json"))
}
