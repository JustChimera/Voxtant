import Foundation

public enum SegmentStatus: String, Codable, Sendable {
    case queued, transcribing, ready, translating, complete, failed
}

public struct Segment: Identifiable, Codable, Sendable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var file: String
    public var capturedAt: Date
    public var status: SegmentStatus = .queued
    public var transcript = ""
    public var translation = ""
    public var error: String?
    public var asrSeconds: Double?
    public var translationSeconds: Double?
    public var latencySeconds: Double?
    public var asrCost: Double?
    public var translationCost: Double?
    public var asrModel: String
    public var translationModel: String
    public var queuedAt: Date?
    public var asrStartedAt: Date?
    public var transcriptReadyAt: Date?
    public var translationStartedAt: Date?
    public var displayedAt: Date?
    public var translationMode: String?
    public var attempts: [RequestAttempt]?

    public init(id: Int, start: Double, end: Double, file: String,
                capturedAt: Date, asrModel: String, translationModel: String) {
        self.id = id
        self.start = start
        self.end = end
        self.file = file
        self.capturedAt = capturedAt
        self.asrModel = asrModel
        self.translationModel = translationModel
    }
}

public struct SessionReport: Codable {
    public var schemaVersion = 2
    public var createdAt: Date
    public var source: String
    public var duration: Double
    public var recording: String
    public var segments: [Segment]
    public var notes: [String] = [
        "Segment timestamps are audio boundaries, not word timestamps.",
        "Latency is measured from the end of a captured chunk to its final displayed translation.",
        "File imports are batch tests; their latency is not a live microphone measurement.",
        "Energy-based speech gating; 1.2-2.8 s non-overlapping chunks, 120 ms pre-roll.",
        "Capture timestamps use the input buffer host clock; older schema v1 used an approximate engine-start clock.",
        "Pure Chinese bypasses translation; mixed Chinese spans are masked and restored locally.",
        "ASR WAV copies are peak-normalized to 0.8 with gain capped at 8x; original audio is unchanged.",
        "Costs are reported by the API when available; missing costs are unknown, not zero."
    ]

    public init(createdAt: Date, source: String, duration: Double, recording: String, segments: [Segment]) {
        self.createdAt = createdAt
        self.source = source
        self.duration = duration
        self.recording = recording
        self.segments = segments
    }
}

public enum TranslationGuard {
    public static func hanCharacters(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { scalar in
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value) ||
            (0x20000...0x323AF).contains(scalar.value)
        }
    }

    public static func preservesChinese(source: String, translation: String) -> Bool {
        hanCharacters(source) == hanCharacters(translation)
    }
}
