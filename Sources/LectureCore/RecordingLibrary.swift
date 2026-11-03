import Foundation

public enum RecordingLibrary {
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxtant Recordings", isDirectory: true)
    }
    public static func createSession(root: URL, date: Date, timeZone: TimeZone = .current) throws -> URL {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
        formatter.dateFormat = "HH-mm-ss"
        let folder = day.appendingPathComponent(formatter.string(from: date) + "_" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        return folder
    }
}

public struct RecordingMetadata: Codable {
    public var schemaVersion = 1
    public var id: String
    public var createdAt: Date
    public var source: String
    public var status: String
    public var durationSeconds: Double
    public var recording: String
    public var transcript = "transcript.txt"
    public var translation = "translation.txt"
    public var session = "session.json"
    public var asrModel: String
    public var translationModel: String
    public var languageSettings: TranslationSettings
    public var asrLanguageHint: String?
    public var microphone: String?
    public var speechThresholdDB: Double
    public var asrWAVSampleRate = 16000
    public var audioChunkTargetSeconds = 1.2
    public var audioChunkMaximumSeconds = 2.8
    public var speechGate = "apple-soundanalysis-v1-conservative"
    public var cost: SessionCostSummary
    public init(folder: URL, createdAt: Date, source: String, status: String, duration: Double, recording: String,
                asrModel: String, translationModel: String, settings: TranslationSettings, hint: String?, microphone: String?, cost: SessionCostSummary, speechThresholdDB: Double = -48) {
        id = folder.lastPathComponent; self.createdAt = createdAt; self.source = source; self.status = status
        durationSeconds = duration; self.recording = recording; self.asrModel = asrModel
        self.translationModel = translationModel; languageSettings = settings; asrLanguageHint = hint
        self.microphone = microphone; self.cost = cost; self.speechThresholdDB = speechThresholdDB
    }
}
