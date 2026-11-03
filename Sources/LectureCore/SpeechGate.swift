import Foundation
import AVFoundation
import SoundAnalysis

public struct SpeechGateObservation: Codable, Sendable {
    public var skipASR: Bool
    public var reason: String
    public var maximumSpeechScore: Double?
    public var analyzedWindows: Int
    public var seconds: Double

    public var note: String {
        "Local speech gate v1: \(reason), maxSpeech=\(maximumSpeechScore.map { String(format: "%.5f", $0) } ?? "unknown"), windows=\(analyzedWindows), seconds=\(String(format: "%.3f", seconds))."
    }
}

/// Conservative acoustic veto. Uncertain, short, unsupported and failed analysis pass through.
public enum SpeechGate {
    public static let speechThreshold = 0.05
    public static let minimumSeconds = 1.0

    public static func shouldSkip(scores: [Double], duration: Double, coveredUntil: Double, failed: Bool) -> Bool {
        guard !failed, duration.isFinite, duration >= minimumSeconds, duration <= 10,
              coveredUntil.isFinite, coveredUntil >= duration, !scores.isEmpty,
              scores.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < speechThreshold }) else { return false }
        return true
    }

    public static func inspect(file: URL) async -> SpeechGateObservation {
        await Task.detached(priority: .userInitiated) { analyze(file: file) }.value
    }

    public static func analyze(file: URL) -> SpeechGateObservation {
        let started = Date()
        func result(_ reason: String, skip: Bool = false, scores: [Double] = []) -> SpeechGateObservation {
            SpeechGateObservation(skipASR: skip, reason: reason, maximumSpeechScore: scores.max(),
                analyzedWindows: scores.count, seconds: Date().timeIntervalSince(started))
        }
        do {
            let audio = try AVAudioFile(forReading: file)
            let format = audio.processingFormat
            let duration = Double(audio.length) / format.sampleRate
            guard duration.isFinite, duration >= minimumSeconds else { return result("short-pass-through") }
            guard duration <= 10, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
                  format.sampleRate > 0, format.channelCount > 0 else { return result("unsupported-pass-through") }
            let frames = AVAudioFrameCount(audio.length)
            // Pad analysis only, so final real samples are covered by a full classifier window.
            // The saved WAV and the ASR payload remain byte-for-byte unchanged.
            let paddedFrames = AVAudioFrameCount((ceil(duration / 0.5) * 0.5 + 1) * format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: paddedFrames) else {
                return result("unavailable-pass-through")
            }
            try audio.read(into: buffer, frameCount: frames)
            guard buffer.frameLength == frames, let channels = buffer.floatChannelData else { return result("unavailable-pass-through") }
            for channel in 0..<Int(format.channelCount) {
                channels[channel].advanced(by: Int(frames)).initialize(repeating: 0, count: Int(paddedFrames - frames))
            }
            buffer.frameLength = paddedFrames
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 1, preferredTimescale: 48_000)
            request.overlapFactor = 0.5
            guard request.knownClassifications.contains("speech") else { return result("unavailable-pass-through") }
            let observer = SpeechObserver()
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)
            analyzer.analyze(buffer, atAudioFramePosition: 0)
            analyzer.completeAnalysis()
            let snapshot = observer.snapshot()
            let skip = shouldSkip(scores: snapshot.scores, duration: duration,
                coveredUntil: snapshot.coveredUntil, failed: snapshot.failed)
            return result(skip ? "non-speech" : snapshot.failed || snapshot.scores.isEmpty ? "unavailable-pass-through" : "speech-or-uncertain", skip: skip, scores: snapshot.scores)
        } catch { return result("unavailable-pass-through") }
    }
}

private final class SpeechObserver: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private var scores: [Double] = []
    private var coveredUntil = 0.0
    private var failed = false
    func request(_ request: SNRequest, didProduce result: SNResult) {
        lock.lock(); defer { lock.unlock() }
        guard let result = result as? SNClassificationResult,
              let speech = result.classification(forIdentifier: "speech") else { failed = true; return }
        let start = result.timeRange.start.seconds
        let end = result.timeRange.end.seconds
        guard start.isFinite, end.isFinite, start >= 0, start <= coveredUntil + 0.001, end > start else { failed = true; return }
        scores.append(speech.confidence)
        coveredUntil = max(coveredUntil, end)
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock(); failed = true; lock.unlock()
    }
    func requestDidComplete(_ request: SNRequest) {}
    func snapshot() -> (scores: [Double], coveredUntil: Double, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (scores, coveredUntil, failed)
    }
}
