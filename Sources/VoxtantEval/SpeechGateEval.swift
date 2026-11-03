import Foundation
import AVFoundation
import LectureCore

struct SpeechGateFixture: Codable {
    struct Entry: Codable { var id: String; var audio: String; var expectedSpeech: Bool }
    var cases: [Entry]
}

func evaluateSpeechGate(root: URL, output: URL) async throws {
    let manifest = root.appendingPathComponent("speech-gate-cases.json")
    let fixture = try read(SpeechGateFixture.self, from: manifest)
    guard !FileManager.default.fileExists(atPath: output.path), fixture.cases.count <= 200,
          Set(fixture.cases.map(\.id)).count == fixture.cases.count else { throw LectureError.message("New output directory and unique bounded cases required") }
    for entry in fixture.cases {
        let audio = try AVAudioFile(forReading: root.appendingPathComponent(entry.audio))
        guard audio.length > 0 else { throw LectureError.message("Empty acoustic fixture: " + entry.id) }
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try Data(contentsOf: manifest).write(to: output.appendingPathComponent("cases.json"), options: .atomic)
    var observations: [[String: Any]] = []
    var speechLost = 0; var noiseSkipped = 0
    for entry in fixture.cases {
        let file = root.appendingPathComponent(entry.audio)
        let result = await SpeechGate.inspect(file: file)
        if entry.expectedSpeech && result.skipASR { speechLost += 1 }
        if !entry.expectedSpeech && result.skipASR { noiseSkipped += 1 }
        var row: [String: Any] = ["id": entry.id, "expectedSpeech": entry.expectedSpeech,
            "skipASR": result.skipASR, "reason": result.reason, "windows": result.analyzedWindows,
            "seconds": result.seconds, "audioSHA256": digest(try Data(contentsOf: file))]
        if let score = result.maximumSpeechScore { row["maximumSpeechScore"] = score }
        observations.append(row)
    }
    let report: [String: Any] = ["classifier": "Apple SoundAnalysis version1", "windowSeconds": 1,
        "threshold": SpeechGate.speechThreshold, "minimumSeconds": SpeechGate.minimumSeconds,
        "fixtureSHA256": digest(try Data(contentsOf: manifest)),
        "runnerSHA256": digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
        "platform": ProcessInfo.processInfo.operatingSystemVersionString, "cases": observations,
        "speechCases": fixture.cases.filter(\.expectedSpeech).count, "speechLost": speechLost,
        "noiseCases": fixture.cases.filter { !$0.expectedSpeech }.count, "noiseSkipped": noiseSkipped,
        "note": "Local acoustic gate only; no ASR, Keychain, microphone or network requests. Not real-lecture transcription accuracy."]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"), options: .atomic)
    print("Speech preserved: \(fixture.cases.filter(\.expectedSpeech).count - speechLost)/\(fixture.cases.filter(\.expectedSpeech).count); noise skipped: \(noiseSkipped)/\(fixture.cases.filter { !$0.expectedSpeech }.count)")
}
