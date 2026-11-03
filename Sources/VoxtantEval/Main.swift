import Foundation
import AVFoundation
import CryptoKit
import LectureCore

struct Corpus: Codable {
    var datasetID: String
    var cases: [CaseEntry]
}
struct CaseEntry: Codable {
    var id: String
    var sourceID: String
    var date: String
    var split: String
    var duration: Double
    var audio: String
    var eligible: Bool
}
struct PreparedChunk: Codable {
    var id: Int
    var start: Double
    var end: Double
    var file: String
    var sha256: String
}
struct PreparedCase: Codable {
    var id: String
    var sampleRate: Double
    var duration: Double
    var rmsDB: Double
    var peakDB: Double
    var chunks: [PreparedChunk]
}
struct PreparedCorpus: Codable {
    var datasetID: String
    var segmenter: String = "core-1.2-2.8s-preroll120ms-threshold-48dB-normalize0.8-gain8"
    var cases: [PreparedCase]
}
struct RunConfig: Codable {
    var datasetID: String
    var preparedHash: String
    var sourceHash: String
    var asrModel: String
    var translationModel: String
    var asrOnly: Bool?
    var asrLanguageHint: SpeechLanguage?
    var split: String
    var caseIDs: [String]
    var settings: TranslationSettings
}
struct ContextTrace: Codable {
    var asr: String?
    var translation: String?
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func save<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}
func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: url))
}

func prepare(root: URL, corpus: Corpus) throws {
    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("prepared.json").path) else {
        throw LectureError.message("Prepared chunks are immutable; use a new dataset directory for a new preparation.")
    }
    var prepared: [PreparedCase] = []
    for entry in corpus.cases {
        let audio = try AVAudioFile(forReading: root.appendingPathComponent(entry.audio))
        let format = audio.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192), format.sampleRate > 0 else {
            throw LectureError.message("Cannot decode \(entry.id)")
        }
        let output = root.appendingPathComponent("cases/\(entry.id)/chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var segmenter = AudioSegmenter(sampleRate: format.sampleRate, threshold: Float(pow(10, -48.0 / 20)))
        var chunks: [PreparedChunk] = []
        var energy: Double = 0; var frames = 0; var peak: Float = 0
        func store(_ chunk: AudioChunk) throws {
            let file = "cases/\(entry.id)/chunks/" + String(format: "%05d.wav", chunks.count)
            let data = WAVEncoder.encode(samples: chunk.samples, sampleRate: format.sampleRate, normalize: true)
            try data.write(to: root.appendingPathComponent(file), options: .atomic)
            chunks.append(PreparedChunk(id: chunks.count, start: chunk.start, end: chunk.end, file: file, sha256: digest(data)))
        }
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
            for c in 0..<Int(format.channelCount) {
                for f in mono.indices { mono[f] += channels[c][f] / Float(format.channelCount) }
            }
            for value in mono { energy += Double(value * value); peak = max(peak, abs(value)) }
            frames += mono.count
            for chunk in segmenter.append(mono) { try store(chunk) }
        }
        if let chunk = segmenter.flush() { try store(chunk) }
        prepared.append(PreparedCase(id: entry.id, sampleRate: format.sampleRate,
            duration: Double(frames) / format.sampleRate, rmsDB: 20 * log10(max(1e-10, sqrt(energy / Double(max(1, frames))))),
            peakDB: 20 * log10(max(1e-10, Double(peak))), chunks: chunks))
        print("Prepared \(entry.id): \(chunks.count) chunks (\(entry.split))"); fflush(stdout)
    }
    try save(PreparedCorpus(datasetID: corpus.datasetID, cases: prepared), to: root.appendingPathComponent("prepared.json"))
}

@MainActor
final class Pipeline {
    let root: URL
    let output: URL
    let entry: CaseEntry
    let prepared: PreparedCase
    let config: RunConfig
    let client: OpenRouterClient
    let createdAt = Date()
    var segments: [Segment] = []
    var asrTasks: [Int: Task<Void, Never>] = [:]
    var translationTasks: [Int: Task<Void, Never>] = [:]
    var traces: [String: ContextTrace] = [:]
    var stopped = false

    init(root: URL, run: URL, entry: CaseEntry, prepared: PreparedCase, config: RunConfig, client: OpenRouterClient) throws {
        self.root = root; self.output = run.appendingPathComponent("cases/" + entry.id)
        self.entry = entry; self.prepared = prepared; self.config = config; self.client = client
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.appendingPathComponent("session.json").path) {
            let previous = try read(SessionReport.self, from: output.appendingPathComponent("session.json"))
            guard previous.segments.count == prepared.chunks.count else { throw LectureError.message("Resume chunk count mismatch") }
            segments = previous.segments
            for segment in segments {
                let prefix = "Segment \(segment.id): Local speech gate v1:"
                if let note = previous.notes.first(where: { $0.hasPrefix(prefix) }) { speechGateNotes[segment.id] = note }
            }
            for i in segments.indices where ![.complete, .failed].contains(segments[i].status) {
                segments[i].status = segments[i].transcript.isEmpty ? .queued : .ready
            }
            traces = (try? read([String: ContextTrace].self, from: output.appendingPathComponent("contexts.json"))) ?? [:]
        } else {
            segments = prepared.chunks.map { chunk in
                var segment = Segment(id: chunk.id, start: chunk.start, end: chunk.end, file: chunk.file,
                    capturedAt: createdAt, asrModel: config.asrModel, translationModel: config.translationModel)
                segment.queuedAt = Date()
                return segment
            }
        }
        for chunk in prepared.chunks {
            guard digest(try Data(contentsOf: root.appendingPathComponent(chunk.file))) == chunk.sha256 else {
                throw LectureError.message("Audio hash mismatch: \(entry.id)/\(chunk.id)")
            }
        }
    }

    func run() async throws -> Bool {
        let started = Date()
        while segments.contains(where: { ![.complete, .failed].contains($0.status) }) || !asrTasks.isEmpty || !translationTasks.isEmpty {
            if segments.filter({ $0.status == .failed }).count >= 4 { stopped = true }
            if !stopped { schedule() }
            if stopped && asrTasks.isEmpty && translationTasks.isEmpty { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try persist()
        let state: [String: String] = ["state": stopped ? "stopped_after_failures" : "finished", "wallSeconds": String(Date().timeIntervalSince(started))]
        try save(state, to: output.appendingPathComponent("state.json"))
        print("\(entry.id): \(segments.filter { $0.status == .complete }.count)/\(segments.count) complete, \(segments.filter { $0.status == .failed }.count) failed")
        fflush(stdout)
        return !stopped
    }

    private var speechGateNotes: [Int: String] = [:]

    private func schedule() {
        while asrTasks.count < 2, let i = segments.firstIndex(where: { $0.status == .queued }) {
            segments[i].status = .transcribing; segments[i].asrStartedAt = Date()
            let context = segments.prefix(i).filter { !$0.transcript.isEmpty }.suffix(3).map(\.transcript).joined(separator: "\n")
            traces[String(i), default: ContextTrace()].asr = context
            let file = root.appendingPathComponent(segments[i].file)
            asrTasks[i] = Task {
                do {
                    let result = try await client.transcribe(file: file, model: config.asrModel, context: context, settings: config.settings, filterNonSpeech: true, languageHint: config.asrLanguageHint)
                    if let gate = result.speechGate {
                        speechGateNotes[i] = "Segment \(segments[i].id): " + gate.note
                        if gate.skipASR { segments[i].translationMode = "local-nonspeech-v1"; segments[i].translationCost = 0 }
                    }
                    segments[i].transcript = result.text; segments[i].asrSeconds = result.seconds; segments[i].asrCost = result.cost
                    segments[i].attempts = (segments[i].attempts ?? []) + result.attempts
                    segments[i].transcriptReadyAt = Date()
                    segments[i].status = config.asrOnly == true || result.text.isEmpty ? .complete : .ready
                    if config.asrOnly == true && result.speechGate?.skipASR != true { segments[i].translationMode = "asr-only-validation" }
                } catch { fail(i, error) }
                asrTasks[i] = nil
                do { try persist() } catch { print("Persist failed: \(error.localizedDescription)") }
            }
        }
        while translationTasks.count < 2, let i = segments.firstIndex(where: { $0.status == .ready }) {
            segments[i].status = .translating; segments[i].translationStartedAt = Date()
            let context = segments.prefix(i).filter { !$0.transcript.isEmpty }.suffix(3).map(\.transcript).joined(separator: "\n")
            traces[String(i), default: ContextTrace()].translation = context
            let text = segments[i].transcript
            translationTasks[i] = Task {
                do {
                    let result = try await client.translate(text, context: context, model: config.translationModel, settings: config.settings)
                    segments[i].translation = result.text; segments[i].translationSeconds = result.seconds; segments[i].translationCost = result.cost
                    segments[i].attempts = (segments[i].attempts ?? []) + result.attempts
                    segments[i].translationMode = result.attempts.isEmpty ? "local-chinese-preserve" : "configured-" + config.settings.mode.rawValue
                    segments[i].displayedAt = Date(); segments[i].status = .complete
                } catch { fail(i, error) }
                translationTasks[i] = nil
                do { try persist() } catch { print("Persist failed: \(error.localizedDescription)") }
            }
        }
    }
    private func fail(_ i: Int, _ error: Error) {
        segments[i].status = .failed; segments[i].error = error.localizedDescription
        if let failure = error as? APIRequestFailure { segments[i].attempts = (segments[i].attempts ?? []) + failure.attempts }
        print("\(entry.id)/\(i) failed: \(error.localizedDescription)"); fflush(stdout)
    }
    private func persist() throws {
        var report = SessionReport(createdAt: createdAt, source: "file", duration: prepared.duration, recording: entry.audio, segments: segments)
        report.translationSettings = config.settings
        report.notes.append("ASR language hint: " + (config.settings.asrLanguage ?? config.asrLanguageHint?.rawValue ?? "auto"))
        report.notes += speechGateNotes.keys.sorted().compactMap { speechGateNotes[$0] }
        if config.asrOnly == true { report.notes.append("ASR-only validation; no translation requests. Failed clips do not prevent attempts on remaining cases.") }
        report.notes.append("Validation replay: batch processing only, latencySeconds is intentionally absent. Exact contexts in contexts.json.")
        try save(report, to: output.appendingPathComponent("session.json"))
        try save(traces, to: output.appendingPathComponent("contexts.json"))
    }
}

@main
struct VoxtantEval {
    @MainActor
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 3 else { throw LectureError.message("Usage: VoxtantEval prepare DATASET | run DATASET RUN_FOLDER") }
            let command = CommandLine.arguments[1]
            let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            if command == "exchange-rate", CommandLine.arguments.count == 3 {
                let rate = try await USDRUBRate.fetch()
                try save(rate, to: URL(fileURLWithPath: CommandLine.arguments[2]))
                print("CBR USD/RUB \(rate.effectiveDate): \(rate.rublesPerUSD)")
                return
            }
            if command == "asr-options", CommandLine.arguments.count == 4 {
                try await evaluateASROptions(root: root, output: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true))
                return
            }
            if command == "speech-gate", CommandLine.arguments.count == 4 {
                try await evaluateSpeechGate(root: root, output: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true))
                return
            }
            if command == "translation", CommandLine.arguments.count == 4 {
                try await evaluateTranslations(root: root, output: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true))
                return
            }
            let corpus = try read(Corpus.self, from: root.appendingPathComponent("manifest.json"))
            if command == "prepare" { try prepare(root: root, corpus: corpus); return }
            guard command == "run", CommandLine.arguments.count == 4 else { throw LectureError.message("Invalid eval command") }
            let run = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
            let config = try read(RunConfig.self, from: run.appendingPathComponent("config.json"))
            let preparedURL = root.appendingPathComponent("prepared.json")
            guard config.datasetID == corpus.datasetID, digest(try Data(contentsOf: preparedURL)) == config.preparedHash else {
                throw LectureError.message("Dataset/prepared fingerprint mismatch")
            }
            let prepared = try read(PreparedCorpus.self, from: preparedURL)
            guard prepared.datasetID == corpus.datasetID, Set(config.caseIDs).count == config.caseIDs.count else { throw LectureError.message("Invalid prepared data or duplicate cases") }
            try config.settings.validate()
            let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { throw LectureError.message("No Keychain credential provided") }
            let client = OpenRouterClient(key: key)
            var processed = 0; var attempted = 0; var stopped = false
            for id in config.caseIDs {
                guard let entry = corpus.cases.first(where: { $0.id == id }), entry.eligible, entry.split == config.split,
                      let item = prepared.cases.first(where: { $0.id == id }) else { throw LectureError.message("Invalid case selection or split") }
                attempted += 1
                let pipeline = try Pipeline(root: root, run: run, entry: entry, prepared: item, config: config, client: client)
                if !(try await pipeline.run()) {
                    stopped = true
                    if config.asrOnly == true { continue }
                    break
                }
                processed += 1
            }
            try save(["state": stopped ? (config.asrOnly == true ? "finished_with_case_failures" : "stopped_after_failures") : "finished", "processedCases": String(processed), "attemptedCases": String(attempted), "plannedCases": String(config.caseIDs.count)], to: run.appendingPathComponent("state.json"))
            if stopped { exit(2) }
        } catch { fputs("VoxtantEval: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
